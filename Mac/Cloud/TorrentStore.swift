import CryptoKit
import Darwin
import Foundation
import os

/// A file inside a torrent.
struct TorrentFile: Codable, Equatable, Identifiable {
    let index: Int
    let size: Int64
    let path: String

    var id: Int { index }
    var name: String { (path as NSString).lastPathComponent }
    var isVideo: Bool {
        ["mkv", "mp4", "m4v", "mov", "avi", "ts", "m2ts", "webm", "wmv", "mpg", "mpeg"].contains((path as NSString).pathExtension.lowercased())
    }
    var looksLikeEpisode: Bool {
        name.range(of: #"[Ss]\d{1,3}[ ._-]?[Ee]\d{1,4}|(?<![0-9])\d{1,2}x\d{2,3}(?![0-9])"#, options: .regularExpression) != nil
    }
}

/// One film or episode of a torrent on its way to Drive.
struct TorrentItem: Codable, Equatable, Identifiable {
    let filmID: UInt64
    let fileIndex: Int
    var name: String
    var folder: String
    let size: Int64
    let partSet: String
    var parts: [UploadPart]
    var done = false

    var id: UInt64 { filmID }
    var uploadedBytes: Int64 { parts.filter { $0.driveID != nil }.reduce(0) { $0 + $1.size } }
}

/// A torrent Reel Server is working on.
struct TorrentJob: Codable, Equatable, Identifiable {
    enum Phase: String, Codable { case details, choosing, working, done, failed }

    let id: UUID
    let source: String
    var name: String
    var phase: Phase = .details
    var files: [TorrentFile] = []
    var items: [TorrentItem] = []
    var problem: String?

    /// The item being downloaded now: the first that isn't done.
    var current: TorrentItem? { items.first { !$0.done } }
    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
    var uploadedBytes: Int64 { items.reduce(0) { $0 + ($1.done ? $1.size : $1.uploadedBytes) } }
}

/// Live figures for the screen; not saved.
struct TorrentLive: Equatable {
    var downloaded: Int64 = 0       // of the current item, including what's already in Drive
    var downloadRate = 0            // bytes per second
    var uploadToDrive = 0           // bytes per second
    var sending: [Int: Int64] = [:] // part → bytes of it already in Drive
    var peers = 0
    var seeds = 0
    var state = ""
}

/// Downloads torrents straight to Google Drive.
///
/// The helper (Tools/reel-torrent) downloads one file at a time in 1 GB parts and keeps only a few parts on this
/// Mac. Each part goes to Drive as one of the film's pieces, the same layout as a Faster Upload, and is checked
/// against Google's MD5 before the helper may delete it. When every part is there the film joins the library,
/// verified. Nothing is downloaded until it's approved in the Add Torrent window, and that window is the only
/// way in: magnet links aren't accepted over the network (port 8097).
@MainActor
final class TorrentStore: ObservableObject {
    @Published private(set) var jobs: [TorrentJob] = []
    @Published private(set) var live: [UUID: TorrentLive] = [:]
    /// The torrent whose files are being chosen, shown as a sheet.
    @Published var choosing: UUID?
    /// The Add Magnet Link window.
    @Published var askingForLink = false

    static let partSize: Int64 = 1 << 30
    private static let chunk = 16 << 20

    private let cloud: CloudStore
    private let folder: URL
    private var helpers: [UUID: TorrentHelper] = [:]
    private var uploading: [UUID: Set<Int>] = [:]
    /// Parts being sent on each of Drive's connections, across every torrent; a new part takes the least busy.
    private var laneUse = [Int](repeating: 0, count: DriveClient.laneCount)
    private var interface: String?
    private var address: String?
    private let log = Logger(subsystem: "com.bjartur.reel.server", category: "torrent")

    init(cloud: CloudStore, folder: URL) {
        self.cloud = cloud
        self.folder = folder
        attempt("Making a folder") { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        jobs = (try? JSONDecoder().decode([TorrentJob].self, from: Data(contentsOf: listURL))) ?? []
    }

    private var listURL: URL { folder.appendingPathComponent("torrents.json") }
    private func workdir(_ id: UUID) -> URL { folder.appendingPathComponent(id.uuidString) }

    private func save() {
        guard let data = attempt("Encoding the torrent list", { try JSONEncoder().encode(jobs) }) else { return }
        attempt("Saving the torrent list") { try data.write(to: listURL, options: .atomic) }
        attempt("Making the torrent list private") {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: listURL.path)
        }
    }

    private func edit(_ id: UUID, _ change: (inout TorrentJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index])
        save()
    }

    func job(_ id: UUID) -> TorrentJob? { jobs.first { $0.id == id } }

    // MARK: Starting

    /// Picks up unfinished torrents after Reel Server starts, and follows the network if a VPN comes or goes.
    func start() {
        interface = Self.internetInterface()
        address = interface.flatMap(Self.address(of:))
        // Moves his films and episodes, so only with his OK (defaults key set when he gives it).
        if UserDefaults.standard.bool(forKey: "refileTorrentNames") { refileOldNames() }
        for job in jobs where job.phase == .working || job.phase == .details || job.phase == .choosing {
            launch(job.id)
        }
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                self?.followNetwork()
            }
        }
    }

    /// Torrents added before 2026-11-26 named episodes' shows after the torrent's folder and disc films after
    /// their numbered clip. Moves them to where they'd go now: once, then nothing differs.
    private func refileOldNames() {
        let drive = cloud.driveClient
        for job in jobs where job.phase == .working || job.phase == .done {
            for (index, item) in job.items.enumerated() {
                guard let file = job.files.first(where: { $0.index == item.fileIndex }) else { continue }
                let folder = item.folder.hasPrefix(CloudStore.showsFolder + "/") ? showFolder(file, torrent: job.name) : item.folder
                let name = Self.filmName(file, torrent: job.name)
                guard folder != item.folder || name != item.name else { continue }
                log.notice("refiling \(item.name, privacy: .public) as \(folder, privacy: .public)/\(name, privacy: .public)")
                edit(job.id) { $0.items[index].folder = folder; $0.items[index].name = name }
                if item.done {
                    Task { await cloud.refile(item.filmID, folder: folder, name: name) }
                } else {
                    let sent = item.parts.compactMap(\.driveID)
                    Task { for id in sent { await attempt("Updating a file in Google Drive") { _ = try await drive.update(id, properties: ["folder": folder]) } } }
                }
            }
        }
    }

    /// From a magnet link opened in a browser, or pasted. Asks for files and shows the Add Torrent window.
    func open(_ link: String) {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("magnet:?") else { return }
        let hash = Self.infoHash(trimmed)
        if let existing = jobs.first(where: { $0.phase != .done && $0.phase != .failed && Self.infoHash($0.source) == hash }) {
            if existing.phase == .choosing || existing.phase == .details { choosing = existing.id }
            return
        }
        let job = TorrentJob(id: UUID(), source: trimmed, name: Self.displayName(trimmed) ?? "Torrent")
        jobs.append(job)
        save()
        choosing = job.id
        launch(job.id)
    }

    private func launch(_ id: UUID) {
        guard helpers[id] == nil, let job = job(id) else { return }
        guard let path = Bundle.main.path(forAuxiliaryExecutable: "reel-torrent") else {
            return edit(id) { $0.phase = .failed; $0.problem = "Reel Server’s torrent helper is missing. Reinstall Reel Server." }
        }
        let helper = TorrentHelper(executable: path, workdir: workdir(id), interface: interface ?? Self.internetInterface())
        helper.onLine = { [weak self] words in self?.handle(id, words) }
        helper.onExit = { [weak self] in
            guard let self else { return }
            self.helpers[id] = nil
            if let job = self.job(id), job.phase == .working {
                // It stopped by itself: try again in a while.
                Task {
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    if self.job(id)?.phase == .working { self.launch(id) }
                }
            }
        }
        helpers[id] = helper
        if job.problem != nil { edit(id) { $0.problem = nil } }
        do {
            try helper.run()
            helper.send("add \(Self.percent(job.source))")
            if job.phase == .working { resume(id) }
        } catch {
            helpers[id] = nil
            edit(id) { $0.phase = .failed; $0.problem = error.localizedDescription }
        }
    }

    /// Queues every unfinished item with the helper, in order, saying which parts are already in Drive. The helper
    /// works on several at once (a season pack's episodes) within its disk budget, so downloading never waits
    /// for the previous episode's upload.
    private func resume(_ id: UUID) {
        guard let job = job(id), let helper = helpers[id] else { return }
        let running = jobs.filter { $0.phase == .working }.count
        let window = Self.windowParts(sharedWith: running)
        for item in job.items where !item.done {
            let done = item.parts.indices.filter { item.parts[$0].driveID != nil }.map(String.init).joined(separator: ",")
            helper.send("start \(item.fileIndex) \(Self.partSize) \(window) \(done.isEmpty ? "-" : done)")
        }
    }

    // MARK: Choosing

    /// The approval: the files chosen in the Add Torrent window go to Drive.
    func approve(_ id: UUID, files: [TorrentFile], asShow: Bool) throws {
        guard let job = job(id), job.phase == .choosing, !files.isEmpty else { return }
        let total = files.reduce(0) { $0 + $1.size }
        if let free = cloud.quota?.free, free < total {
            throw CloudError("Google Drive has \(free.formatted(.byteCount(style: .file))) free; this needs \(total.formatted(.byteCount(style: .file))).")
        }
        let items = files.map { file -> TorrentItem in
            let folder = asShow ? self.showFolder(file, torrent: job.name) : "Films"
            let parts = stride(from: Int64(0), to: file.size, by: Int64.Stride(Self.partSize)).map {
                UploadPart(offset: $0, size: min(Self.partSize, file.size - $0))
            }
            return TorrentItem(filmID: UInt64.random(in: 1 << 32..<1 << 62), fileIndex: file.index,
                               name: Self.filmName(file, torrent: job.name),
                               folder: folder, size: file.size, partSet: UUID().uuidString, parts: parts)
        }
        edit(id) { $0.items = items; $0.phase = .working; $0.problem = nil }
        choosing = nil
        resume(id)
    }

    /// For an episode, the show is the torrent's folder (or the file's own folder), as in the TV shows drop folder.
    /// The show an episode belongs to: the name in front of its episode number ("Friends.S01E02…" → "Friends"),
    /// else the torrent's title without its season and quality words. Bonus material (featurettes, deleted scenes)
    /// goes to "<Show> Extras", so it doesn't sit beside the real episodes with the same numbers. A show already in
    /// the library under a similar name ("The office" for "The Office (US) (2005)") is used as it is.
    func showFolder(_ file: TorrentFile, torrent: String) -> String {
        var show = Self.cleanShow(file.looksLikeEpisode ? Self.textBeforeEpisode(file.name) : "")
        if show.isEmpty { show = Self.cleanShow(torrent) }
        if show.isEmpty { show = torrent }
        show = existingShow(like: show) ?? show
        if Self.isExtra(file) { show += " Extras" }
        return DropInspector.showFolder(of: "\(show)/\(file.name)")
    }

    private static func textBeforeEpisode(_ name: String) -> String {
        guard let match = name.range(of: #"[Ss]\d{1,3}[ ._-]?[Ee]\d|(?<![0-9])\d{1,2}x\d{2}"#, options: .regularExpression) else { return "" }
        return String(name[..<match.lowerBound])
    }

    private static func cleanShow(_ text: String) -> String {
        text.replacingOccurrences(of: #"[ ._-]*([Ss]\d{1,3}|Season ?\d+|Complete|\d{3,4}p).*$"#, with: "",
                                  options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " -"))
    }

    static func isExtra(_ file: TorrentFile) -> Bool {
        file.path.range(of: #"(?i)(^|/)(featurettes?|extras?|bonus|deleted scenes|behind the scenes|bloopers|interviews|trailers?|samples?)(/|$)"#,
                        options: .regularExpression) != nil
    }

    /// "The Office (US) (2005)" and "The office" are the same show: compared without case, years and countries.
    private func existingShow(like show: String) -> String? {
        func key(_ s: String) -> String {
            s.replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
                .lowercased().filter { $0.isLetter || $0.isNumber }
        }
        let wanted = key(show)
        guard !wanted.isEmpty else { return nil }
        let shows = Set(cloud.films.compactMap(\.show))
        return shows.filter { !$0.hasSuffix(" Extras") }.first { key($0) == wanted }
    }

    /// A Blu-ray disc's clips are numbered ("BDMV/STREAM/00000.m2ts"); the film is named after the torrent instead.
    static func filmName(_ file: TorrentFile, torrent: String) -> String {
        let numbered = file.name.range(of: #"^\d{5}\.(m2ts|mts)$"#, options: [.regularExpression, .caseInsensitive]) != nil
        guard numbered, !torrent.isEmpty else { return file.name }
        return "\(torrent).\((file.name as NSString).pathExtension)"
    }

    /// Stops a torrent and removes what it put in Drive for films that aren't finished. Finished ones stay.
    func cancel(_ id: UUID) {
        helpers[id]?.stop()
        helpers[id] = nil
        let unfinished = job(id)?.items.filter { !$0.done } ?? []
        let drive = cloud.driveClient
        Task {
            for item in unfinished {
                for part in item.parts { if let file = part.driveID { await attempt("Moving a file to Drive’s Bin") { try await drive.trash(file) } } }
            }
        }
        jobs.removeAll { $0.id == id }
        live[id] = nil
        if choosing == id { choosing = nil }
        save()
        removeIfPresent(workdir(id))
    }

    func clearFinished() {
        jobs.removeAll { $0.phase == .done }
        save()
    }

    // MARK: The helper's messages

    private func handle(_ id: UUID, _ words: [String]) {
        guard let verb = words.first else { return }
        switch verb {
        case "meta":
            if words.count >= 4 { edit(id) { $0.name = Self.unpercent(words[3]) } }
        case "file":
            guard words.count >= 4, let index = Int(words[1]), let size = Int64(words[2]) else { return }
            let file = TorrentFile(index: index, size: size, path: Self.unpercent(words[3]))
            edit(id) { if !$0.files.contains(file) { $0.files.append(file) } }
        case "files-end":
            if job(id)?.phase == .details { edit(id) { $0.phase = .choosing } }
        case "status":
            guard words.count >= 7 else { return }
            var current = live[id] ?? TorrentLive()
            current.downloaded = Int64(words[1]) ?? 0
            current.downloadRate = Int(words[2]) ?? 0
            current.peers = Int(words[4]) ?? 0
            current.seeds = Int(words[5]) ?? 0
            current.state = words[6]
            live[id] = current
        case "part":
            guard words.count >= 6, let file = Int(words[1]), let k = Int(words[2]), let size = Int64(words[4]) else { return }
            upload(id, file: file, part: k, size: size, path: Self.unpercent(words[5]))
        case "error":
            let message = Self.unpercent(words.dropFirst().joined(separator: " "))
            log.error("torrent \(id, privacy: .public): \(message, privacy: .public)")
            edit(id) { $0.problem = message }
        default:
            break
        }
    }

    // MARK: Into Drive

    private func upload(_ id: UUID, file: Int, part k: Int, size: Int64, path: String) {
        guard let job = job(id), let item = job.items.first(where: { $0.fileIndex == file && !$0.done }),
              item.parts.indices.contains(k) else { return }
        if item.parts[k].driveID != nil {
            helpers[id]?.send("uploaded \(file) \(k)")
            return
        }
        let key = Self.key(file, k)
        guard item.parts[k].size == size, uploading[id, default: []].insert(key).inserted else { return }
        let drive = cloud.driveClient
        let filmID = item.filmID
        let lane = laneUse.indices.min { laneUse[$0] < laneUse[$1] } ?? 0
        laneUse[lane] += 1
        Task {
            defer {
                uploading[id]?.remove(key)
                live[id]?.sending[key] = nil
                laneUse[lane] -= 1
            }
            var failures = 0
            while self.job(id)?.phase == .working {
                do {
                    let sent = try await send(item: item, part: k, path: path, lane: lane, drive: drive, job: id)
                    guard self.job(id)?.items.contains(where: { $0.filmID == filmID && !$0.done }) == true else { return }
                    edit(id) { job in
                        guard let i = job.items.firstIndex(where: { $0.filmID == filmID }) else { return }
                        job.items[i].parts[k].driveID = sent.id
                        job.items[i].parts[k].received = size
                        job.problem = nil
                    }
                    helpers[id]?.send("uploaded \(file) \(k)")
                    finishIfComplete(id, filmID: filmID)
                    return
                } catch {
                    failures += 1
                    edit(id) { $0.problem = "Part \(k + 1) didn’t reach Google Drive: \(error.localizedDescription) Trying again." }
                    try? await Task.sleep(nanoseconds: UInt64(min(failures, 12)) * 10_000_000_000)
                }
            }
        }
    }

    /// Sends one part and checks Google's MD5 against the file here. A mismatch is binned and sent again.
    private func send(item: TorrentItem, part k: Int, path: String, lane: Int, drive: DriveClient, job: UUID) async throws -> DriveFile {
        let local = try await Task.detached(priority: .utility) { try Self.md5(path) }.value
        let count = item.parts.count
        let digits = "\(count)".count
        let folder = try await cloud.reelFolder()
        let session = try await drive.beginUpload(
            name: "\(item.name).part\(String(format: "%0\(digits)d", k + 1))of\(count)", size: item.parts[k].size,
            parent: folder,
            properties: ["reel": "part", "id": "\(item.filmID)", "set": item.partSet, "folder": item.folder,
                         "offset": "\(item.parts[k].offset)", "count": "\(count)", "total": "\(item.size)",
                         "modified": "\(Int64(Date().timeIntervalSince1970))", "source": "torrent"])
        let size = item.parts[k].size
        var offset: Int64 = 0
        let started = Date()
        while true {
            let length = Int(min(Int64(Self.chunk), size - offset))
            let data = try await Task.detached { try CloudFiles.read(path, offset: offset, count: length) }.value
            let state = try await drive.sendChunk(session, data: data, offset: offset, size: size, lane: lane)
            switch state {
            case .done(let file):
                guard file.md5Checksum == local else {
                    await attempt("Moving a file to Drive’s Bin") { try await drive.trash(file.id) }
                    throw CloudError("Google’s copy didn’t match.")
                }
                return file
            case .received(let total):
                offset = total
                let seconds = max(Date().timeIntervalSince(started), 0.5)
                var current = live[job] ?? TorrentLive()
                current.uploadToDrive = Int(Double(offset) / seconds)
                current.sending[Self.key(item.fileIndex, k)] = offset
                live[job] = current
            case .expired:
                throw CloudError("Google closed the upload.")
            }
        }
    }

    private func finishIfComplete(_ id: UUID, filmID: UInt64) {
        guard let job = job(id), let item = job.items.first(where: { $0.filmID == filmID }),
              item.parts.allSatisfy({ $0.driveID != nil }) else { return }
        cloud.adoptFromTorrent(id: item.filmID, folder: item.folder, name: item.name, size: item.size,
                               parts: item.parts, partSet: item.partSet)
        edit(id) { job in
            if let i = job.items.firstIndex(where: { $0.filmID == filmID }) { job.items[i].done = true }
        }
        if self.job(id)?.current == nil {
            edit(id) { $0.phase = .done; $0.problem = nil }
            helpers[id]?.stop()
            helpers[id] = nil
            live[id] = nil
            removeIfPresent(workdir(id))
        }
    }

    // MARK: Network and disk

    /// The interface that carries internet traffic now: a VPN's tunnel when one is on. Torrent traffic goes the
    /// same way as everything else, and never around a VPN.
    nonisolated static func internetInterface() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/route")
        process.arguments = ["-n", "get", "1.1.1.1"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return text.split(separator: "\n").first { $0.contains("interface:") }?
            .split(separator: ":").last?.trimmingCharacters(in: .whitespaces)
    }

    /// The interface's IPv4 address.
    nonisolated static func address(of interface: String) -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard String(cString: entry.ifa_name) == interface, let addr = entry.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: host)
            }
        }
        return nil
    }

    private func followNetwork() {
        let now = Self.internetInterface()
        let nowAddress = now.flatMap(Self.address(of:))
        // A VPN that reconnects can keep its tunnel's name but get a new address; sockets on the old one are dead.
        guard now != interface || nowAddress != address else { return }
        log.notice("internet now goes through \(now ?? "nothing", privacy: .public); restarting torrents")
        interface = now
        address = nowAddress
        for (id, helper) in helpers {
            helper.stop()
            helpers[id] = nil
            launch(id)
        }
    }

    /// How many 1 GB parts a torrent may keep on this Mac: its share of the free space, keeping 10 GB for
    /// everything else. More parts on hand means more of them going to Drive at once.
    static func windowParts(sharedWith running: Int = 1) -> Int {
        let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let free = values?.volumeAvailableCapacityForImportantUsage ?? 0
        return Int(max(1, min(8, (free - (10 << 30)) / partSize / Int64(max(1, running)))))
    }

    // MARK: Helpers

    nonisolated static func md5(_ path: String) throws -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else { throw CloudError("Reel couldn’t read a downloaded part.") }
        defer { try? handle.close() }
        var hash = Insecure.MD5()
        while let data = try handle.read(upToCount: 8 << 20), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// One number for a part of a file, for the sets of parts on their way.
    static func key(_ file: Int, _ k: Int) -> Int { file * 100_000 + k }

    static func infoHash(_ magnet: String) -> String? {
        guard let range = magnet.range(of: #"btih:([0-9A-Za-z]+)"#, options: .regularExpression) else { return nil }
        return String(magnet[range].dropFirst(5)).lowercased()
    }

    static func displayName(_ magnet: String) -> String? {
        // Magnet links write spaces as "+", the way web forms do.
        URLComponents(string: magnet.replacingOccurrences(of: "+", with: "%20"))?.queryItems?.first { $0.name == "dn" }?.value
    }

    static func percent(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "!#$&'()*+,/:;=?@[]-._~")
            .union(.alphanumerics)) ?? text
    }

    static func unpercent(_ text: String) -> String { text.removingPercentEncoding ?? text }
}

/// Runs one reel-torrent process and reads its lines.
final class TorrentHelper: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()
    var onLine: @MainActor ([String]) -> Void = { _ in }
    var onExit: @MainActor () -> Void = {}

    init(executable: String, workdir: URL, interface: String?) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [workdir.path]
        var environment = ProcessInfo.processInfo.environment
        if let interface { environment["REEL_LISTEN"] = "\(interface):0" }
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
    }

    func run() throws {
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.buffer.append(data)
            while let end = self.buffer.firstIndex(of: 10) {
                let line = String(decoding: self.buffer[..<end], as: UTF8.self)
                self.buffer.removeSubrange(...end)
                let words = line.split(separator: " ").map(String.init)
                let deliver = self.onLine
                Task { @MainActor in deliver(words) }
            }
        }
        process.terminationHandler = { [weak self] _ in
            self?.output.fileHandleForReading.readabilityHandler = nil
            let done = self?.onExit
            Task { @MainActor in done?() }
        }
        try process.run()
    }

    func send(_ line: String) {
        guard process.isRunning else { return }
        try? input.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
    }

    func stop() {
        onExit = {}
        send("quit")
        let process = self.process
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if process.isRunning { process.terminate() } }
    }
}

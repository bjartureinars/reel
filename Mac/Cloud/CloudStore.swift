import CryptoKit
import Foundation
import os

struct CloudPaths {
    /// The folder films are dropped into.
    let drop: URL
    /// The folder TV shows are dropped into: Show/Season/episode, or loose episodes.
    let shows: URL
    /// The one temporarily downloaded film.
    let downloads: URL
    /// Catalog and bitrate measurements.
    let state: URL
    /// Where the cloud disk is mounted.
    let mount: URL
}

struct CloudFilm: Codable, Identifiable, Equatable {
    let id: UInt64
    var folder: String          // "Films", or "TV Shows/<Show>/Season NN" for an episode
    var name: String            // unique within the folder; also the name on the cloud disk
    var size: Int64
    var modified: Date
    var originalPath: String?
    var originalStamp: FileStamp?
    var uploadURL: URL?
    var driveID: String?
    var md5: String?
    /// Google holds a byte-identical copy that has been read back. Nothing is deleted before this is true.
    var verified = false
    var downloaded = false
    var source: PlaybackSource = .stream
    /// How far the single-file upload has got. Kept while a fast upload runs, so switching back loses nothing.
    var uploaded: Int64?
    var parts: [UploadPart]?
    /// Tells this fast upload's pieces from those of any earlier attempt.
    var partSet: String?
    /// The exact version of the original that was approved. Without it nothing is uploaded or deleted.
    var approvedStamp: FileStamp?

    // Versions and extras. A film's group is named after its default version: other versions point to it with
    // `versionOf`, extras with `extraOf`. Nothing moves in Drive; only the cloud disk shows the group as a folder.
    /// Another version of the film with this id (the default version). nil for a default version or a film alone.
    var versionOf: UInt64?
    /// The version's name in the Versions list: "4K", "Blu-ray".
    var versionLabel: String?
    /// Bonus material of the film with this id (the default version).
    var extraOf: UInt64?
    var extraKind: ExtraKind?
    var extraTitle: String?
    /// The group's folder on the cloud disk, "Title (Year)", kept on the default version.
    var groupFolder: String?

    var isApproved: Bool { originalStamp != nil && approvedStamp == originalStamp }

    var isEpisode: Bool { folder.hasPrefix(CloudStore.showsFolder + "/") }
    var show: String? { Self.show(inFolder: folder) }

    static func show(inFolder folder: String) -> String? {
        let parts = folder.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 3 && parts[0] == CloudStore.showsFolder[...] ? String(parts[1]) : nil
    }

    static func season(inFolder folder: String) -> Int? {
        guard show(inFolder: folder) != nil, let last = folder.split(separator: "/").last else { return nil }
        return Int(last.filter(\.isNumber))
    }

    var remote: RemoteFile? {
        if let driveID { return RemoteFile(pieces: [.init(id: driveID, offset: 0, size: size)]) }
        guard let parts, !parts.isEmpty else { return nil }
        let pieces = parts.compactMap { part in
            part.driveID.map { RemoteFile.Piece(id: $0, offset: part.offset, size: part.size) }
        }
        let remote = RemoteFile(pieces: pieces)
        return pieces.count == parts.count && remote.covers(size) ? remote : nil
    }
}

struct CloudJob: Equatable {
    enum Kind: Equatable { case measuring, uploading, checking, downloading }
    var kind: Kind
    var progress: Double = 0
    var megabitsPerSecond: Double?
    var secondsLeft: Double?
    /// More than one only during a fast upload.
    var connections = 1
}

/// Owns the catalog and every move of a film between the drop folder, Google Drive and the downloaded copy.
///
/// Deletion rules:
/// - Nothing is uploaded or deleted until that exact version of the file has been approved in Reel Server.
///   Matching checksums prove Google's copy equals the file here, not that the file here was finished.
/// - An original is deleted only after Drive's MD5 and size match a fresh hash of it, samples downloaded back
///   from Drive match, and the file is provably the same one that was hashed.
/// - A downloaded copy is only ever deleted for a film that is verified in Drive.
@MainActor
final class CloudStore: ObservableObject {
    /// The cloud disk's top folders. Their order fixes their NFS ids, so new ones go at the end.
    nonisolated static let folders = ["Films", "Home Videos", "TV Shows"]
    nonisolated static let showsFolder = "TV Shows"

    /// A folder a film in Drive may say it belongs in.
    nonisolated static func isKnownFolder(_ folder: String) -> Bool {
        folders.contains(folder) || CloudFilm.show(inFolder: folder) != nil
    }
    nonisolated private static let uploadChunk = 64 << 20
    nonisolated private static let partChunk = 24 << 20
    /// Connections left to uploading while a film plays, so the stream keeps the Wi-Fi.
    nonisolated private static let lanesWhilePlaying = 2
    /// Beyond this, starting again in pieces wouldn't beat finishing the single file.
    nonisolated private static let switchLimit = 0.6
    nonisolated private static let downloadChunk = 24 << 20
    nonisolated private static let downloadStreams = 4
    /// Left free after a download, for the remux buffer and macOS itself.
    nonisolated static let spaceMargin: Int64 = 8_000_000_000

    @Published private(set) var films: [CloudFilm] = []
    @Published private(set) var jobs: [UInt64: CloudJob] = [:]
    @Published private(set) var errors: [UInt64: String] = [:]
    @Published private(set) var connected: Bool
    @Published private(set) var quota: DriveQuota?
    @Published private(set) var problem: String?
    /// Uploads over several connections, which stores big films in Drive as pieces.
    @Published var fasterUploads = false {
        didSet {
            guard oldValue != fasterUploads else { return }
            onFasterUploadsChanged(fasterUploads)
        }
    }
    var onFasterUploadsChanged: (Bool) -> Void = { _ in }

    let paths: CloudPaths
    /// What's in the drop folder awaiting an OK. Deliberately not part of `films`, the library and upload queue.
    @Published private(set) var pending: [PendingFilm] = []
    /// Called when the set of films on the cloud disk changes.
    var onFilmsChanged: () -> Void = {}
    /// File names being played right now; those downloads are never offloaded.
    var namesPlaying: () -> Set<String> = { [] }

    private let drive: DriveClient
    private let disk: CloudDisk
    private let server: NFSServer
    private let ffprobe: () -> URL?
    private let scanInterval: TimeInterval
    private let settleTime: TimeInterval
    private let quietTime: TimeInterval
    private let partSize: Int64
    private var claimed: [UInt64: Set<Int>] = [:]
    private let log = Logger(subsystem: "com.bjartur.reel.server", category: "cloud")

    private var started = false
    private var driveFolder: String?
    private var unchangedSince: [String: (stamp: FileStamp, since: Date)] = [:]
    private var inspected: [String: (stamp: FileStamp, problem: String?)] = [:]
    private var inspecting: (path: String, progress: Double)?
    private var inspector: Task<Void, Never>?
    private var scanning = false
    /// Unverified uploads that were abandoned. Drive may hold a complete file for one, and it must never be
    /// taken for a film when syncing.
    private var discarded: Set<UInt64> = []
    private var loop: Task<Void, Never>?
    private var worker: Task<Void, Never>?
    private var workingOn: UInt64?
    private var retryAfter: [UInt64: Date] = [:]
    private var mismatches: [UInt64: Int] = [:]
    private var measured: Set<UInt64> = []
    private var downloadTasks: [UInt64: Task<Void, Never>] = [:]
    private var lastSync = Date.distantPast
    private var activity: NSObjectProtocol?

    init(paths: CloudPaths, drive: DriveClient, connected: Bool, ffprobe: @escaping () -> URL?,
         scanInterval: TimeInterval = 8, settleTime: TimeInterval = 15, quietTime: TimeInterval = 120,
         partSize: Int64 = 1 << 30) {
        self.paths = paths
        self.drive = drive
        self.connected = connected
        self.ffprobe = ffprobe
        self.scanInterval = scanInterval
        self.settleTime = settleTime
        self.quietTime = quietTime
        self.partSize = partSize
        disk = CloudDisk(drive: drive)
        server = NFSServer(source: disk, folders: Self.folders)
    }

    private var catalogURL: URL { paths.state.appendingPathComponent("catalog.json") }
    private var discardedURL: URL { paths.state.appendingPathComponent("discarded.json") }
    private func bitrateURL(_ id: UInt64) -> URL { paths.state.appendingPathComponent("bitrate/\(id).json") }
    func downloadURL(_ id: UInt64) -> URL { paths.downloads.appendingPathComponent("\(id).film") }
    private func partialURL(_ id: UInt64) -> URL { paths.downloads.appendingPathComponent("\(id).part") }
    func film(_ id: UInt64) -> CloudFilm? { films.first { $0.id == id } }
    /// For Reel for iPhone's files, which live next to the films.
    var driveClient: DriveClient { drive }
    /// Called after a film is removed, so its iPhone files go too.
    var onRemoved: (UInt64) -> Void = { _ in }

    /// The "Reel" folder in Drive.
    func reelFolder() async throws -> String {
        if let driveFolder { return driveFolder }
        let found = try await drive.folder()
        driveFolder = found
        return found
    }

    // MARK: Lifecycle

    /// Mounts the cloud disk. Must run before Jellyfin starts, so it never scans an empty mount point.
    func start() async throws {
        guard !started else { return }
        let fm = FileManager.default
        for folder in [paths.drop, paths.shows, paths.downloads, paths.state, paths.state.appendingPathComponent("bitrate")] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        if fm.fileExists(atPath: catalogURL.path) {
            // An unreadable catalog stops startup: replacing it with an empty one would lose track of films.
            films = try JSONDecoder().decode([CloudFilm].self, from: Data(contentsOf: catalogURL))
        }
        if fm.fileExists(atPath: discardedURL.path) {
            discarded = try JSONDecoder().decode(Set<UInt64>.self, from: Data(contentsOf: discardedURL))
        }
        // Anything queued without an OK (by Reel before approvals existed) leaves the library and waits for one.
        let unapproved = films.filter { $0.originalPath != nil && !$0.isApproved }
        if !unapproved.isEmpty {
            try discard(unapproved.filter { !$0.verified }.map(\.id))
            for index in films.indices where films[index].verified && !films[index].isApproved {
                films[index].originalPath = nil
                films[index].originalStamp = nil
            }
            try save()
        }
        for index in films.indices where films[index].downloaded {
            if FileStamp(path: downloadURL(films[index].id).path)?.size != films[index].size {
                films[index].downloaded = false
                films[index].source = .stream
            }
        }
        publishRoutes()
        try server.start()
        let port = server.port, mount = paths.mount
        do {
            try await Task.detached { try CloudMount.mount(port: port, at: mount) }.value
        } catch {
            server.stop()
            throw error
        }
        started = true
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                try? await Task.sleep(nanoseconds: UInt64(self.scanInterval * 1_000_000_000))
            }
        }
    }

    func stop() {
        guard started else { return }
        started = false
        loop?.cancel()
        worker?.cancel()
        inspector?.cancel()
        downloadTasks.values.forEach { $0.cancel() }
        CloudMount.unmount(paths.mount)
        server.stop()
    }

    func setConnected(_ value: Bool) {
        connected = value
        problem = nil
        driveFolder = nil
        lastSync = .distantPast
        retryAfter = [:]
        if value {
            errors = [:]
            Task { await tick() }
        } else {
            quota = nil
            worker?.cancel()
        }
    }

    func retry() {
        errors = [:]
        retryAfter = [:]
        mismatches = [:]
        problem = nil
        lastSync = .distantPast
        Task { await tick() }
    }

    private func tick() async {
        await scanDropFolder()
        if connected, Date().timeIntervalSince(lastSync) > 300 { await sync() }
        startNextJob()
        updateActivity()
    }

    private func updateActivity() {
        let busy = !jobs.isEmpty
        if busy, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated],
                                                             reason: "Moving films to or from Google Drive")
        } else if !busy, let token = activity {
            ProcessInfo.processInfo.endActivity(token)
            activity = nil
        }
    }

    // MARK: Catalog

    private func save() throws {
        let data = try JSONEncoder().encode(films)
        try data.write(to: catalogURL, options: .atomic)
        // Unfinished upload URLs work without a password.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: catalogURL.path)
    }

    private func edit(_ id: UInt64, _ change: (inout CloudFilm) -> Void) {
        guard let index = films.firstIndex(where: { $0.id == id }) else { return }
        change(&films[index])
        publishRoutes()
        do { try save() } catch { problem = "Reel couldn’t save its catalog: \(error.localizedDescription)" }
    }

    private func commitList() {
        publishRoutes()
        do { try save() } catch { problem = "Reel couldn’t save its catalog: \(error.localizedDescription)" }
        onFilmsChanged()
    }

    private func publishRoutes() {
        disk.update(films.map { film in
            var local: [String] = []
            if film.verified {
                if film.downloaded, film.source == .mac { local = [downloadURL(film.id).path] }
            } else if let original = film.originalPath {
                local = [original]
            }
            let place = place(film)
            return CloudDisk.Route(
                file: DiskFile(id: film.id, folder: place.folder, name: place.name, size: film.size, modified: film.modified),
                localPaths: local,
                remote: film.verified ? film.remote : nil)
        })
    }

    // MARK: Versions and extras

    /// The default version of the group a film belongs to, or nil if it's on its own.
    func groupRoot(_ film: CloudFilm) -> CloudFilm? {
        if let root = film.versionOf ?? film.extraOf { return self.film(root) }
        return films.contains { $0.versionOf == film.id || $0.extraOf == film.id } ? film : nil
    }

    /// The default version first, then the others by name.
    func versions(of root: UInt64) -> [CloudFilm] {
        guard let first = self.film(root) else { return [] }
        return [first] + films.filter { $0.versionOf == root }
            .sorted { ($0.versionLabel ?? $0.name).localizedStandardCompare($1.versionLabel ?? $1.name) == .orderedAscending }
    }

    func extras(of root: UInt64) -> [CloudFilm] {
        films.filter { $0.extraOf == root }.sorted {
            ($0.extraKind ?? .other, $0.extraTitle ?? $0.name) < ($1.extraKind ?? .other, $1.extraTitle ?? $1.name)
        }
    }

    /// Where a film appears on the cloud disk. A film with versions or extras gets a folder of its own, laid out
    /// the way Jellyfin expects: "Title (Year)/Title (Year) - Label.mkv" for each version, and extras in
    /// "Title (Year)/trailers/…", "Title (Year)/behind the scenes/…" and so on.
    func place(_ film: CloudFilm) -> (folder: String, name: String) {
        guard film.folder == "Films", let root = groupRoot(film) else { return (film.folder, film.name) }
        let group = Self.safeName(root.groupFolder ?? (root.name as NSString).deletingPathExtension)
        let ext = (film.name as NSString).pathExtension
        let dot = ext.isEmpty ? "" : ".\(ext)"
        if film.extraOf != nil {
            let kind = film.extraKind ?? .other
            let title = Self.safeName(film.extraTitle ?? (film.name as NSString).deletingPathExtension)
            let siblings = extras(of: root.id).filter { ($0.extraKind ?? .other) == kind }
            let same = siblings.filter { Self.safeName($0.extraTitle ?? ($0.name as NSString).deletingPathExtension) == title }
            let number = same.count > 1 ? " (\((same.firstIndex { $0.id == film.id } ?? 0) + 1))" : ""
            return ("Films/\(group)/\(kind.folder)", "\(title)\(number)\(dot)")
        }
        let label = Self.safeName(film.versionLabel ?? (film.id == root.id ? "Default" : "Version"))
        let siblings = versions(of: root.id).filter { Self.safeName($0.versionLabel ?? "") == label }
        let number = siblings.count > 1 ? " \((siblings.firstIndex { $0.id == film.id } ?? 0) + 1)" : ""
        return ("Films/\(group)", "\(group) - \(label)\(number)\(dot)")
    }

    /// The name a film has on the cloud disk (what Jellyfin and the players see).
    func diskName(_ film: CloudFilm) -> String { place(film).name }

    nonisolated static func safeName(_ text: String) -> String {
        let cleaned = text.replacingOccurrences(of: #"[/:\\]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return cleaned.isEmpty ? "Film" : cleaned
    }

    /// Makes `id` another version of `root`. A film that had versions or extras of its own brings them along.
    func addVersion(_ id: UInt64, to root: UInt64, label: String, groupFolder: String, rootLabel: String) throws {
        guard let film = self.film(id), let main = self.film(root), id != root else { return }
        guard film.folder == "Films", main.folder == "Films" else { throw CloudError("Only films can have versions.") }
        guard main.versionOf == nil, main.extraOf == nil else { throw CloudError("Add versions to the film’s default version.") }
        for index in films.indices where films[index].versionOf == id || films[index].extraOf == id {
            if films[index].versionOf == id { films[index].versionOf = root } else { films[index].extraOf = root }
        }
        edit(root) {
            if $0.groupFolder == nil { $0.groupFolder = groupFolder }
            if $0.versionLabel == nil { $0.versionLabel = rootLabel }
        }
        edit(id) { $0.versionOf = root; $0.extraOf = nil; $0.versionLabel = label; $0.groupFolder = nil }
        commitList()
    }

    /// Play uses the default version, and the group is listed under it.
    func makeDefault(_ id: UInt64) {
        guard let film = self.film(id), let root = film.versionOf, let old = self.film(root) else { return }
        for index in films.indices {
            if films[index].versionOf == root, films[index].id != id { films[index].versionOf = id }
            if films[index].extraOf == root { films[index].extraOf = id }
        }
        edit(root) { $0.versionOf = id; $0.groupFolder = nil }
        edit(id) { $0.versionOf = nil; $0.groupFolder = old.groupFolder }
        commitList()
    }

    func renameVersion(_ id: UInt64, label: String) {
        let clean = label.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        edit(id) { $0.versionLabel = clean }
        commitList()
    }

    /// Takes a version out of its group: it becomes a film of its own again.
    func separate(_ id: UInt64) {
        guard let film = self.film(id) else { return }
        if film.versionOf == nil, let next = films.first(where: { $0.versionOf == id }) {
            makeDefault(next.id)
        }
        edit(id) { $0.versionOf = nil; $0.extraOf = nil; $0.extraKind = nil; $0.extraTitle = nil; $0.groupFolder = nil }
        commitList()
    }

    /// Makes a film already in the library an extra of `root`.
    func makeExtra(_ id: UInt64, of root: UInt64, kind: ExtraKind, title: String, groupFolder: String) throws {
        guard let film = self.film(id), let main = self.film(root), id != root else { return }
        guard main.folder == "Films", film.folder == "Films" else { throw CloudError("Only films can have extras.") }
        guard !films.contains(where: { $0.versionOf == id || $0.extraOf == id }) else {
            throw CloudError("“\(film.name)” has versions or extras of its own.")
        }
        if main.groupFolder == nil { edit(root) { $0.groupFolder = groupFolder } }
        edit(id) { $0.extraOf = root; $0.versionOf = nil; $0.extraKind = kind; $0.extraTitle = title; $0.groupFolder = nil }
        commitList()
    }

    func editExtra(_ id: UInt64, kind: ExtraKind, title: String) {
        let clean = title.trimmingCharacters(in: .whitespaces)
        edit(id) { $0.extraKind = kind; if !clean.isEmpty { $0.extraTitle = clean } }
        commitList()
    }

    /// An extra from anywhere on this Mac. Choosing it here is the approval; a copy goes in a hidden folder inside
    /// the drop folder and takes the usual way (upload, check, then the copy is deleted). The original stays.
    func addExtra(from file: URL, to root: UInt64, kind: ExtraKind, title: String, groupFolder: String) async throws {
        guard let main = self.film(root), main.folder == "Films" else { throw CloudError("Only films can have extras.") }
        let folder = paths.drop.appendingPathComponent(".reel-extras", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent("\(UUID().uuidString).\(file.pathExtension)")
        try await Task.detached(priority: .userInitiated) { try FileManager.default.copyItem(at: file, to: copy) }.value
        guard let stamp = FileStamp(path: copy.path) else { throw CloudError("Reel couldn’t read the copy.") }
        if quota?.free.map({ $0 < stamp.size }) == true { throw CloudError("Google Drive doesn’t have room for it.") }
        var film = CloudFilm(id: UInt64.random(in: 1 << 32..<1 << 62), folder: "Films",
                             name: uniqueName(file.lastPathComponent, in: "Films"), size: stamp.size,
                             modified: stamp.modified, originalPath: copy.path, originalStamp: stamp)
        film.approvedStamp = stamp
        film.extraOf = root
        film.extraKind = kind
        film.extraTitle = title
        if self.film(root)?.groupFolder == nil { edit(root) { $0.groupFolder = groupFolder } }
        films.append(film)
        commitList()
        startNextJob()
    }

    // MARK: From torrents

    /// A film or episode a torrent download put in Drive part by part. Every byte passed the torrent's own hash
    /// check and every part's MD5 matched Google's, so it arrives verified, like a finished Faster Upload.
    /// Sync may have found the complete set first; then it's already here.
    func adoptFromTorrent(id: UInt64, folder: String, name: String, size: Int64, parts: [UploadPart], partSet: String) {
        guard film(id) == nil, !discarded.contains(id) else { return }
        var film = CloudFilm(id: id, folder: folder, name: uniqueName(name, in: folder), size: size, modified: Date(),
                             verified: true)
        film.parts = parts
        film.partSet = partSet
        guard film.remote != nil else { return }
        films.append(film)
        commitList()
    }

    /// Gives a film a new folder and name (a torrent's episode under its real show, a disc clip under the film's
    /// title). The Drive files keep the new folder too, so a fresh install files it the same way.
    func refile(_ id: UInt64, folder: String, name: String) async {
        guard let film = film(id), film.folder != folder || film.name != name, Self.isKnownFolder(folder) else { return }
        let unique = film.folder == folder && film.name == name ? name : uniqueName(name, in: folder)
        edit(id) { $0.folder = folder; $0.name = unique }
        commitList()
        let files = (film.parts?.compactMap(\.driveID) ?? []) + [film.driveID].compactMap { $0 }
        for file in files { _ = try? await drive.update(file, properties: ["folder": folder]) }
    }

    private func uniqueName(_ wanted: String, in folder: String) -> String {
        let url = URL(fileURLWithPath: wanted)
        let base = url.deletingPathExtension().lastPathComponent
        var name = wanted
        var number = 2
        while films.contains(where: { $0.folder == folder && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            name = "\(base) (\(number)).\(url.pathExtension)"
            number += 1
        }
        return name
    }

    // MARK: Drop folder

    private func scanDropFolder() async {
        guard !scanning else { return }
        scanning = true
        defer { scanning = false }
        let root = paths.drop, shows = paths.shows
        var found = await Task.detached { DropInspector.scan(root) + DropInspector.scan(shows, shows: true) }.value
        let now = Date()
        var seen: [String: (stamp: FileStamp, since: Date)] = [:]
        for item in found {
            guard let stamp = item.stamp else { continue }
            let before = unchangedSince[item.path]
            seen[item.path] = before?.stamp == stamp ? before : (stamp, now)
        }
        unchangedSince = seen

        for index in found.indices where found[index].state == .ready {
            let item = found[index]
            guard let stamp = item.stamp, let since = seen[item.path]?.since else { continue }
            if now.timeIntervalSince(since) < settleTime || abs(now.timeIntervalSince(stamp.modified)) < quietTime {
                found[index].state = .waiting("It changed recently, so Reel is waiting to see that it has stopped.")
                continue
            }
            let url = URL(fileURLWithPath: item.path)
            if await Task.detached(operation: { CloudFiles.isBeingWritten(url) }).value {
                found[index].state = .waiting("Another app is still writing it.")
            } else if let result = inspected[item.path], result.stamp == stamp {
                if let problem = result.problem { found[index].state = .blocked(problem) }
            } else {
                inspect(item.path, stamp)
                if let inspecting, inspecting.path == item.path {
                    found[index].state = .waiting("Checking for gaps, \(Int(inspecting.progress * 100))%")
                } else {
                    found[index].state = .waiting("Waiting to be checked for gaps.")
                }
            }
        }

        // No awaits from here on, so an approval can't land between reading the catalog and changing it.
        var changed = false
        var dropped: [UInt64] = []
        for index in films.indices {
            let film = films[index]
            guard let path = film.originalPath, workingOn != film.id else { continue }
            let current = FileStamp(path: path)
            if current == film.originalStamp { continue }
            if film.verified {
                films[index].originalPath = nil
                films[index].originalStamp = nil
                changed = true
            } else if current == nil, let moved = found.first(where: { $0.stamp != nil && $0.stamp == film.originalStamp }) {
                // Renamed or moved within the drop folder: still the file that was approved.
                films[index].originalPath = moved.path
                changed = true
            } else {
                // Changed or gone, so the OK no longer stands.
                dropped.append(film.id)
                changed = true
            }
        }
        if !dropped.isEmpty {
            do {
                try discard(dropped)
            } catch {
                problem = "Reel couldn’t save its catalog: \(error.localizedDescription)"
                return
            }
        }

        let known = Set(films.compactMap(\.originalPath))
        let waiting = found.filter { !known.contains($0.path) }
        if waiting != pending { pending = waiting }
        if changed { commitList() }
    }

    /// One whole-file read at a time.
    private func inspect(_ path: String, _ stamp: FileStamp) {
        guard inspector == nil else { return }
        inspecting = (path, 0)
        inspector = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { [weak self] () -> Result<String?, Error> in
                var shown = 0.0
                return Result {
                    try DropInspector.gap(in: path) { fraction in
                        guard fraction - shown >= 0.02 else { return }
                        shown = fraction
                        Task { @MainActor in
                            if self?.inspecting?.path == path { self?.inspecting?.progress = fraction }
                        }
                    }
                }
            }.value
            guard let self else { return }
            self.inspecting = nil
            self.inspector = nil
            guard !Task.isCancelled, FileStamp(path: path) == stamp else { return }
            switch result {
            case .success(let problem): self.inspected[path] = (stamp, problem)
            case .failure(let error): self.inspected[path] = (stamp, "Reel couldn’t read it: \(error.localizedDescription)")
            }
            await self.scanDropFolder()
        }
    }

    /// The one way into the upload-and-delete pipeline. Called only from the button in Reel Server.
    func approve(_ item: PendingFilm) throws {
        guard let current = pending.first(where: { $0.path == item.path }), current.state == .ready,
              let stamp = item.stamp, current.stamp == stamp, FileStamp(path: item.path) == stamp,
              let check = inspected[item.path], check.stamp == stamp, check.problem == nil,
              !films.contains(where: { $0.originalPath == item.path }) else {
            throw CloudError("That file changed or hasn’t passed Reel’s checks, so nothing was uploaded.")
        }
        var film = CloudFilm(id: UInt64.random(in: 1 << 32..<1 << 62), folder: item.folder,
                             name: uniqueName(item.name, in: item.folder), size: stamp.size, modified: stamp.modified,
                             originalPath: item.path, originalStamp: stamp)
        film.approvedStamp = stamp
        films.append(film)
        pending.removeAll { $0.path == item.path }
        commitList()
        startNextJob()
    }

    /// Takes unverified films out of the library. Files on the Mac and in Drive are left as they are.
    private func discard(_ ids: [UInt64]) throws {
        discarded.formUnion(ids)
        // On disk before the catalog forgets them, or a sync could bring them back as verified films.
        try JSONEncoder().encode(discarded).write(to: discardedURL, options: .atomic)
        films.removeAll { ids.contains($0.id) }
        for id in ids {
            errors[id] = nil
            retryAfter[id] = nil
        }
    }

    // MARK: Drive

    private func sync() async {
        lastSync = Date()
        do {
            quota = try await drive.quota()
            var changed = false
            for remote in try await drive.films() {
                guard let properties = remote.appProperties, let id = properties["id"].flatMap({ UInt64($0) }),
                      let size = remote.byteCount, let name = remote.name else { continue }
                // Films already known are left alone. Others were uploaded by an earlier install of Reel.
                guard !discarded.contains(id), film(id) == nil, !films.contains(where: { $0.driveID == remote.id }) else { continue }
                let folder = properties["folder"].flatMap { Self.isKnownFolder($0) ? $0 : nil } ?? "Films"
                let modified = properties["modified"].flatMap { Double($0) }.map(Date.init(timeIntervalSince1970:))
                films.append(CloudFilm(id: id, folder: folder, name: uniqueName(name, in: folder), size: size,
                                       modified: modified ?? Date(), driveID: remote.id, md5: remote.md5Checksum,
                                       verified: true))
                changed = true
            }
            for film in Self.filmsInPieces(try await drive.parts()) where self.film(film.id) == nil && !discarded.contains(film.id) {
                var film = film
                film.name = uniqueName(film.name, in: film.folder)
                films.append(film)
                changed = true
            }
            if changed { commitList() }
            problem = nil
        } catch {
            report(error, for: nil)
        }
    }

    /// Rebuilds films from fast-upload pieces. A set with anything missing, doubled or misplaced is ignored.
    nonisolated static func filmsInPieces(_ files: [DriveFile]) -> [CloudFilm] {
        Dictionary(grouping: files) { $0.appProperties?["set"] ?? "" }.compactMap { set, files -> CloudFilm? in
            guard !set.isEmpty, let first = files.first?.appProperties,
                  let id = first["id"].flatMap({ UInt64($0) }),
                  let total = first["total"].flatMap({ Int64($0) }),
                  let count = first["count"].flatMap({ Int($0) }), count == files.count,
                  let suffix = files[0].name?.range(of: ".part", options: .backwards),
                  let name = files[0].name.map({ String($0[..<suffix.lowerBound]) }) else { return nil }
            let parts = files.compactMap { file -> UploadPart? in
                guard let offset = file.appProperties?["offset"].flatMap({ Int64($0) }),
                      let size = file.byteCount else { return nil }
                return UploadPart(offset: offset, size: size, received: size, driveID: file.id)
            }.sorted { $0.offset < $1.offset }
            guard parts.count == count else { return nil }
            let folder = first["folder"].flatMap { Self.isKnownFolder($0) ? $0 : nil } ?? "Films"
            let modified = first["modified"].flatMap { Double($0) }.map(Date.init(timeIntervalSince1970:))
            var film = CloudFilm(id: id, folder: folder, name: name, size: total, modified: modified ?? Date(), verified: true)
            film.parts = parts
            film.partSet = set
            return film.remote == nil ? nil : film
        }
    }

    private func report(_ error: Error, for id: UInt64?) {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
        log.error("\(error.localizedDescription, privacy: .public)")
        if (error as? CloudError)?.needsSignIn == true {
            connected = false
            problem = error.localizedDescription
        } else if let id {
            errors[id] = error.localizedDescription
            retryAfter[id] = Date().addingTimeInterval(60)
        } else {
            problem = error.localizedDescription
        }
    }

    // MARK: Pipeline: measure → upload → check → delete original

    private func startNextJob() {
        guard worker == nil else { return }
        let waiting = films.filter { film in
            film.originalPath != nil && film.isApproved && (retryAfter[film.id] ?? .distantPast) < Date()
                && (connected || (!film.verified && !measured.contains(film.id)))
        }
        guard let next = waiting.first else { return }
        workingOn = next.id
        worker = Task { [weak self] in
            await self?.process(next.id)
            guard let self else { return }
            self.jobs[next.id] = nil
            self.workingOn = nil
            self.worker = nil
            self.updateActivity()
            if !Task.isCancelled { self.startNextJob() }
        }
        updateActivity()
    }

    private func process(_ id: UInt64) async {
        do {
            guard let film = film(id), film.isApproved, let path = film.originalPath else { return }
            let original = URL(fileURLWithPath: path)
            if await Task.detached(operation: { CloudFiles.isBeingWritten(original) }).value {
                throw CloudError("Another app is writing to this film, so Reel hasn’t uploaded or deleted it.")
            }
            if !measured.contains(id) { await measure(film) }
            guard connected else { return }
            // Either method returns early when the other one should take over.
            while let current = self.film(id), current.remote == nil {
                try Task.checkCancellation()
                if shouldUploadInParts(current) { try await uploadInParts(id) } else { try await upload(id) }
            }
            try await checkAndDeleteOriginal(id)
            await discardUnusedUpload(id)
            errors[id] = nil
            quota = try? await drive.quota()
        } catch {
            report(error, for: id)
        }
    }

    private func measure(_ film: CloudFilm) async {
        let output = bitrateURL(film.id)
        if !FileManager.default.fileExists(atPath: output.path), let path = film.originalPath, let probe = ffprobe() {
            jobs[film.id] = CloudJob(kind: .measuring)
            updateActivity()
            let values = try? await Task.detached(priority: .utility) {
                try CloudFiles.measureBitrate(of: path, ffprobe: probe)
            }.value
            if let values, let data = try? JSONEncoder().encode(values) { try? data.write(to: output, options: .atomic) }
            jobs[film.id] = nil
        }
        measured.insert(film.id)
    }

    private func upload(_ id: UInt64) async throws {
        guard let film = film(id), let path = film.originalPath, let stamp = film.originalStamp else { return }
        jobs[id] = CloudJob(kind: .uploading)
        updateActivity()
        var session: URL
        var offset: Int64 = 0
        var resumed: DriveClient.UploadState = .expired
        if let saved = film.uploadURL { resumed = try await drive.uploadState(saved, size: film.size) }
        switch resumed {
        case .done(let file):
            edit(id) { $0.driveID = file.id; $0.uploadURL = nil }
            return
        case .received(let count):
            session = film.uploadURL!
            offset = count
            edit(id) { $0.uploaded = count }
        case .expired:
            let current = try await drive.quota()
            quota = current
            if let free = current.free, free < film.size {
                throw CloudError("Google Drive has \(free.formatted(.byteCount(style: .file))) free; this film needs \(film.size.formatted(.byteCount(style: .file))).")
            }
            if driveFolder == nil { driveFolder = try await drive.folder() }
            session = try await drive.beginUpload(
                name: film.name, size: film.size, parent: driveFolder!,
                properties: ["reel": "film", "id": "\(film.id)", "folder": film.folder,
                             "modified": "\(Int64(film.modified.timeIntervalSince1970))"])
            let url = session
            edit(id) { $0.uploadURL = url; $0.uploaded = 0 }
        }

        let rate = RateMeter(done: offset, total: film.size)
        while true {
            try Task.checkCancellation()
            guard FileStamp(path: path) == stamp else { throw CloudError("The file changed while it was uploading.") }
            if let current = self.film(id), shouldUploadInParts(current) { return }
            let from = offset
            let count = Int(min(Int64(Self.uploadChunk), film.size - from))
            let state: DriveClient.UploadState
            if count > 0 {
                let data = try await Task.detached { try CloudFiles.read(path, offset: from, count: count) }.value
                state = try await drive.sendChunk(session, data: data, offset: from, size: film.size)
            } else {
                state = try await drive.uploadState(session, size: film.size)
            }
            switch state {
            case .done(let file):
                edit(id) { $0.driveID = file.id; $0.uploadURL = nil }
                return
            case .received(let total):
                guard total > from || count == 0 else { throw CloudError("The upload stopped making progress.") }
                if count == 0 { try await Task.sleep(nanoseconds: 2_000_000_000) }
                offset = total
                edit(id) { $0.uploaded = total }
                jobs[id] = rate.job(.uploading, done: total)
            case .expired:
                edit(id) { $0.uploadURL = nil; $0.uploaded = nil }
                throw CloudError("The upload expired and will start again.")
            }
        }
    }

    // MARK: Fast upload

    /// Drive takes a file over one connection only, so a fast upload sends consecutive pieces as separate files.
    private func shouldUploadInParts(_ film: CloudFilm) -> Bool {
        guard fasterUploads, film.driveID == nil, film.size > 2 * partSize else { return false }
        let single = film.uploaded ?? 0
        let pieces = film.parts?.reduce(0) { $0 + $1.received } ?? 0
        return pieces >= single && pieces > 0 || Double(single) < Self.switchLimit * Double(film.size)
    }

    /// Whether the switch can still change how this film uploads.
    func canSpeedUp(_ film: CloudFilm) -> Bool {
        guard !film.verified, film.driveID == nil, film.size > 2 * partSize else { return false }
        return film.parts != nil || Double(film.uploaded ?? 0) < Self.switchLimit * Double(film.size)
    }

    private func uploadInParts(_ id: UInt64) async throws {
        guard var film = film(id), let path = film.originalPath, let stamp = film.originalStamp else { return }
        jobs[id] = CloudJob(kind: .uploading, connections: DriveClient.laneCount)
        updateActivity()
        if film.parts == nil {
            let planned = stride(from: Int64(0), to: film.size, by: Int64.Stride(partSize)).map {
                UploadPart(offset: $0, size: min(partSize, film.size - $0))
            }
            edit(id) { $0.parts = planned; $0.partSet = UUID().uuidString }
            film = self.film(id) ?? film
        }
        let sent = film.parts?.reduce(0) { $0 + $1.received } ?? 0
        let current = try await drive.quota()
        quota = current
        if let free = current.free, free < film.size - sent {
            throw CloudError("Google Drive has \(free.formatted(.byteCount(style: .file))) free; this film needs \((film.size - sent).formatted(.byteCount(style: .file))).")
        }
        if driveFolder == nil { driveFolder = try await drive.folder() }
        let folder = driveFolder!
        let rate = RateMeter(done: sent, total: film.size)
        claimed[id] = []
        defer { claimed[id] = nil }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for lane in 0..<DriveClient.laneCount {
                group.addTask { try await self.runLane(lane, id: id, path: path, stamp: stamp, folder: folder, rate: rate) }
            }
            try await group.waitForAll()
        }
    }

    private var activeLanes: Int {
        namesPlaying().isEmpty ? DriveClient.laneCount : Self.lanesWhilePlaying
    }

    private func runLane(_ lane: Int, id: UInt64, path: String, stamp: FileStamp, folder: String,
                         rate: RateMeter) async throws {
        var failures = 0
        while fasterUploads {
            try Task.checkCancellation()
            guard let parts = film(id)?.parts, parts.contains(where: { $0.driveID == nil }) else { return }
            guard lane < activeLanes,
                  let index = parts.indices.first(where: { parts[$0].driveID == nil && claimed[id]?.contains($0) != true })
            else {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                continue
            }
            claimed[id]?.insert(index)
            defer { claimed[id]?.remove(index) }
            do {
                try await sendPart(index, lane: lane, id: id, path: path, stamp: stamp, folder: folder, rate: rate)
                failures = 0
            } catch {
                // A dropped connection on one lane mustn't stop the other seven.
                let passing = (error as? DriveError)?.isTransient ?? (error as? URLError).map { $0.code != .cancelled } ?? false
                failures += 1
                guard passing, failures < 6 else { throw error }
                try await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    /// Sends one piece until it's done, or until this lane should stand down.
    private func sendPart(_ index: Int, lane: Int, id: UInt64, path: String, stamp: FileStamp, folder: String,
                          rate: RateMeter) async throws {
        guard let film = film(id), let set = film.partSet, let parts = film.parts else { return }
        let part = parts[index]
        func finished(_ file: DriveFile) {
            edit(id) {
                $0.parts?[index].driveID = file.id
                $0.parts?[index].uploadURL = nil
                $0.parts?[index].received = part.size
            }
        }

        var state: DriveClient.UploadState = .expired
        if let saved = part.uploadURL { state = try await drive.uploadState(saved, size: part.size, lane: lane) }
        let session: URL
        var offset: Int64 = 0
        switch state {
        case .done(let file):
            return finished(file)
        case .received(let count):
            session = part.uploadURL!
            offset = count
        case .expired:
            let digits = "\(parts.count)".count
            let number = String(format: "%0\(digits)d", index + 1)
            session = try await drive.beginUpload(
                name: "\(film.name).part\(number)of\(parts.count)", size: part.size, parent: folder,
                properties: ["reel": "part", "id": "\(film.id)", "set": set, "folder": film.folder,
                             "offset": "\(part.offset)", "count": "\(parts.count)", "total": "\(film.size)",
                             "modified": "\(Int64(film.modified.timeIntervalSince1970))"])
            let url = session
            edit(id) { $0.parts?[index].uploadURL = url; $0.parts?[index].received = 0 }
        }

        while fasterUploads, lane < activeLanes {
            try Task.checkCancellation()
            guard FileStamp(path: path) == stamp else { throw CloudError("The file changed while it was uploading.") }
            let from = offset
            let count = Int(min(Int64(Self.partChunk), part.size - from))
            let result: DriveClient.UploadState
            if count > 0 {
                let data = try await Task.detached { try CloudFiles.read(path, offset: part.offset + from, count: count) }.value
                result = try await drive.sendChunk(session, data: data, offset: from, size: part.size, lane: lane)
            } else {
                result = try await drive.uploadState(session, size: part.size, lane: lane)
            }
            switch result {
            case .done(let file):
                finished(file)
            case .received(let total):
                guard total > from || count == 0 else { throw CloudError("The upload stopped making progress.") }
                if count == 0 { try await Task.sleep(nanoseconds: 2_000_000_000) }
                offset = total
                edit(id) { $0.parts?[index].received = total }
            case .expired:
                edit(id) { $0.parts?[index].reset() }
                return
            }
            let done = self.film(id)?.parts?.reduce(0) { $0 + $1.received } ?? 0
            var job = rate.job(.uploading, done: done)
            job.connections = activeLanes
            jobs[id] = job
            if case .done = result { return }
        }
    }

    /// Once verified, clears away whatever the other upload method left behind.
    private func discardUnusedUpload(_ id: UInt64) async {
        guard let film = film(id), film.verified else { return }
        if film.driveID != nil, let parts = film.parts {
            for piece in parts.compactMap(\.driveID) {
                do { try await drive.trash(piece) } catch { return }
            }
            edit(id) { $0.parts = nil; $0.partSet = nil }
        }
        edit(id) { $0.uploadURL = nil; $0.uploaded = nil }
    }

    // MARK: Check, then delete the original

    private func checkAndDeleteOriginal(_ id: UInt64) async throws {
        guard let film = film(id), let remote = film.remote,
              let path = film.originalPath, let stamp = film.originalStamp else { return }
        jobs[id] = CloudJob(kind: .checking)
        updateActivity()
        guard film.isApproved else {
            throw CloudError("This film hasn’t been approved, so Reel didn’t delete it.")
        }
        guard stamp.size == film.size, FileStamp(path: path) == stamp else {
            throw CloudError("The original changed, so Reel didn’t delete it.")
        }
        guard remote.covers(film.size) else {
            throw CloudError("Google’s pieces don’t add up to the whole film. The original is untouched.")
        }

        let sizes = remote.pieces.map(\.size)
        let hashes = try await Task.detached(priority: .utility) { [weak self] in
            var shown = 0.0
            return try CloudFiles.digests(path, pieces: sizes) { fraction in
                guard fraction - shown >= 0.02 else { return }
                shown = fraction
                Task { @MainActor in
                    if self?.jobs[id]?.kind == .checking { self?.jobs[id]?.progress = fraction }
                }
            }
        }.value
        guard hashes.pieces.count == remote.pieces.count else {
            throw CloudError("Not every piece was checked. The original is untouched.")
        }

        for (index, piece) in remote.pieces.enumerated() {
            let copy: DriveFile
            do {
                copy = try await drive.file(piece.id)
            } catch let error as DriveError where error.status == 404 {
                forgetUpload(piece, of: id)
                throw CloudError("The film is missing from Google Drive, so it will upload again. The original is untouched.")
            }
            if copy.trashed == true {
                forgetUpload(piece, of: id)
                throw CloudError("The film is in Drive’s Bin, so it will upload again. The original is untouched.")
            }
            guard let theirHash = copy.md5Checksum, let theirSize = copy.byteCount else {
                throw CloudError("Google hasn’t reported a checksum yet. The original is untouched.")
            }
            guard theirHash.lowercased() == hashes.pieces[index], theirSize == piece.size else {
                mismatches[id, default: 0] += 1
                edit(id) { $0.verified = false }
                if mismatches[id]! < 3 {
                    try await drive.trash(piece.id)
                    forgetUpload(piece, of: id)
                } else {
                    retryAfter[id] = .distantFuture
                }
                throw CloudError("Google’s copy didn’t match. The original is untouched.")
            }
        }

        // A matching checksum doesn't prove Google will serve the file back, so fetch some of every piece.
        let sample = Int(min(1 << 20, film.size))
        let last = film.size - Int64(sample)
        let offsets = Set([0, last / 2, last] + remote.pieces.map { min($0.offset, last) })
        for offset in offsets.sorted() {
            let theirs = try await drive.read(remote, offset: offset, count: sample)
            let ours = try await Task.detached { try CloudFiles.read(path, offset: offset, count: sample) }.value
            guard theirs == ours else { throw CloudError("A part read back from Google didn’t match. The original is untouched.") }
        }

        let original = URL(fileURLWithPath: path)
        if await Task.detached(operation: { CloudFiles.isBeingWritten(original) }).value {
            throw CloudError("Another app is writing to the original, so Reel didn’t delete it.")
        }
        try Task.checkCancellation()
        guard let index = films.firstIndex(where: { $0.id == id }), films[index].remote == remote,
              films[index].approvedStamp == stamp else {
            throw CloudError("The upload changed during the check, so Reel didn’t delete the original.")
        }
        guard FileStamp(path: path) == stamp else {
            throw CloudError("The original changed during the check, so Reel didn’t delete it.")
        }
        films[index].verified = true
        films[index].md5 = hashes.whole
        films[index].source = .stream
        // The record of the Drive copy must be on disk before the original goes.
        try save()
        publishRoutes()
        try Self.delete(path, ifStill: stamp, inside: isInside(path, paths.shows) ? paths.shows : paths.drop)
        log.notice("Verified in Drive; deleted original \(path, privacy: .private)")
        edit(id) { $0.originalPath = nil; $0.originalStamp = nil }
    }

    private func forgetUpload(_ piece: RemoteFile.Piece, of id: UInt64) {
        edit(id) { film in
            film.verified = false
            if film.driveID == piece.id {
                film.driveID = nil
                film.uploaded = nil
            } else if let index = film.parts?.firstIndex(where: { $0.driveID == piece.id }) {
                film.parts?[index].reset()
            }
        }
    }

    /// Renames first, so a file that appears at the same path meanwhile can't be the one that's deleted.
    private func isInside(_ path: String, _ root: URL) -> Bool {
        let base = root.resolvingSymlinksInPath().path
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path.hasPrefix(base + "/")
    }

    nonisolated static func delete(_ path: String, ifStill stamp: FileStamp, inside root: URL) throws {
        let folder = URL(fileURLWithPath: path).deletingLastPathComponent().resolvingSymlinksInPath().path
        let base = root.resolvingSymlinksInPath().path
        guard folder == base || folder.hasPrefix(base + "/") else {
            throw CloudError("That file is outside the drop folder, so Reel won’t delete it.")
        }
        let doomed = folder + "/.reel-verified-\(UUID().uuidString)"
        guard rename(path, doomed) == 0 else { throw CloudError("Reel couldn’t remove the original.") }
        guard FileStamp(path: doomed) == stamp else {
            _ = renamex_np(doomed, path, UInt32(RENAME_EXCL))
            throw CloudError("The original changed, so Reel didn’t delete it.")
        }
        guard unlink(doomed) == 0 else {
            _ = renamex_np(doomed, path, UInt32(RENAME_EXCL))
            throw CloudError("Reel couldn’t delete the original.")
        }
    }

    // MARK: Watching

    /// Called as a film is selected to play.
    func prepare(_ id: UInt64, source: PlaybackSource) throws {
        guard let film = film(id) else { throw CloudError("That film isn’t in the library.") }
        guard film.verified else { return } // still played from the drop folder
        switch source {
        case .mac:
            guard film.downloaded, FileStamp(path: downloadURL(id).path)?.size == film.size else {
                edit(id) { $0.downloaded = false; $0.source = .stream }
                throw CloudError("The film isn’t downloaded on your Mac.")
            }
        case .stream:
            guard connected else { throw CloudError("Reel Server isn’t signed in to Google Drive.") }
        }
        edit(id) { $0.source = source }
        // Watching something else makes room, but doesn't cancel a download that's on its way.
        for other in films where other.id != id && other.downloaded {
            offload(other.id)
        }
    }

    func download(_ id: UInt64) throws {
        guard let film = film(id), film.verified, film.remote != nil else {
            throw CloudError("The film is still on your Mac, so there’s nothing to download.")
        }
        guard !film.downloaded, downloadTasks[id] == nil else { return }
        guard connected else { throw CloudError("Reel Server isn’t signed in to Google Drive.") }

        let playing = namesPlaying()
        let others = films.filter { $0.id != id && $0.verified }
        let reclaimable = others
            .filter { $0.downloaded && !playing.contains(diskName($0)) }
            .reduce(0) { $0 + $1.size }
            + others.reduce(0) { $0 + (FileStamp(path: partialURL($1.id).path)?.size ?? 0) }
        let needed = film.size - (FileStamp(path: partialURL(id).path)?.size ?? 0) + Self.spaceMargin
        let available = CloudFiles.freeSpace(at: paths.downloads) + reclaimable
        // Check before offloading, so a download that can't fit doesn't cost the film already here.
        guard available >= needed else {
            throw CloudError("Not enough space on your Mac: this needs \(needed.formatted(.byteCount(style: .file))) and \(available.formatted(.byteCount(style: .file))) can be freed. You can still stream it.")
        }
        offloadOthers(keeping: id)
        errors[id] = nil
        jobs[id] = CloudJob(kind: .downloading)
        downloadTasks[id] = Task { [weak self] in
            do {
                try await self?.runDownload(film)
            } catch {
                self?.report(error, for: id)
            }
            guard let self else { return }
            self.jobs[id] = nil
            self.downloadTasks[id] = nil
            self.updateActivity()
        }
        updateActivity()
    }

    private func runDownload(_ film: CloudFilm) async throws {
        guard let remote = film.remote else { return }
        let partial = partialURL(film.id)
        let drive = self.drive
        var hasher = Insecure.MD5()
        var offset: Int64 = 0
        if let existing = FileStamp(path: partial.path), existing.size <= film.size {
            hasher = try await Task.detached { try CloudFiles.md5(partial.path) }.value
            offset = existing.size
        } else {
            try Data().write(to: partial)
        }
        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }
        try handle.seekToEnd()

        let rate = RateMeter(done: offset, total: film.size)
        while offset < film.size {
            try Task.checkCancellation()
            let base = offset
            let parts = try await withThrowingTaskGroup(of: (Int, Data).self) { group -> [Data] in
                for part in 0..<Self.downloadStreams {
                    let start = base + Int64(part * Self.downloadChunk)
                    guard start < film.size else { break }
                    let count = Int(min(Int64(Self.downloadChunk), film.size - start))
                    group.addTask { (part, try await drive.read(remote, offset: start, count: count)) }
                }
                var received: [(Int, Data)] = []
                for try await part in group { received.append(part) }
                return received.sorted { $0.0 < $1.0 }.map(\.1)
            }
            let soFar = hasher
            hasher = try await Task.detached {
                var updated = soFar
                for data in parts {
                    try handle.write(contentsOf: data)
                    updated.update(data: data)
                }
                return updated
            }.value
            offset += parts.reduce(0) { $0 + Int64($1.count) }
            jobs[film.id] = rate.job(.downloading, done: offset)
        }
        try handle.synchronize()
        if let expected = film.md5?.lowercased(), expected != CloudFiles.hex(hasher) {
            try FileManager.default.removeItem(at: partial)
            throw CloudError("The download was damaged. Try again.")
        }
        if film.md5 == nil, remote.pieces.count > 1 {
            // A catalog rebuilt from Drive knows each piece's checksum, but not the whole film's.
            let sizes = remote.pieces.map(\.size)
            let ours = try await Task.detached { try CloudFiles.digests(partial.path, pieces: sizes).pieces }.value
            for (index, piece) in remote.pieces.enumerated() {
                let theirs = try await drive.file(piece.id).md5Checksum
                guard theirs?.lowercased() == ours[index] else {
                    try FileManager.default.removeItem(at: partial)
                    throw CloudError("The download was damaged. Try again.")
                }
            }
        }
        guard self.film(film.id)?.verified == true else { throw CancellationError() }
        let final = downloadURL(film.id)
        if FileManager.default.fileExists(atPath: final.path) { try FileManager.default.removeItem(at: final) }
        try FileManager.default.moveItem(at: partial, to: final)
        edit(film.id) { $0.downloaded = true; $0.source = .mac }
    }

    func cancelDownload(_ id: UInt64) {
        downloadTasks[id]?.cancel()
        try? FileManager.default.removeItem(at: partialURL(id))
        errors[id] = nil
    }

    func offload(_ id: UInt64) {
        guard let film = film(id), film.verified, !namesPlaying().contains(diskName(film)) else { return }
        downloadTasks[id]?.cancel()
        try? FileManager.default.removeItem(at: downloadURL(id))
        try? FileManager.default.removeItem(at: partialURL(id))
        if film.downloaded { edit(id) { $0.downloaded = false; $0.source = .stream } }
    }

    private func offloadOthers(keeping id: UInt64) {
        for other in films where other.id != id && other.verified {
            offload(other.id)
        }
    }

    /// Removes a film from the library. Both copies stay recoverable: Drive's Bin and the Mac's Trash.
    func remove(_ id: UInt64) async throws {
        guard let film = film(id) else { return }
        guard !namesPlaying().contains(diskName(film)) else { throw CloudError("Stop playing the film first.") }
        // A default version hands the group to the next version; with none, its extras go with it.
        if film.versionOf == nil, film.extraOf == nil {
            if let next = films.first(where: { $0.versionOf == id }) {
                makeDefault(next.id)
                separate(id)
            } else {
                for extra in extras(of: id) { try await remove(extra.id) }
            }
        }
        if workingOn == id {
            worker?.cancel()
            await worker?.value
        }
        guard let film = self.film(id) else { return }
        for driveID in [film.driveID].compactMap({ $0 }) + (film.parts ?? []).compactMap(\.driveID) {
            try await drive.trash(driveID)
            disk.forget(driveID)
        }
        if let path = film.originalPath, FileManager.default.fileExists(atPath: path) {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
        }
        downloadTasks[id]?.cancel()
        for url in [downloadURL(id), partialURL(id), bitrateURL(id)] { try? FileManager.default.removeItem(at: url) }
        errors[id] = nil
        films.removeAll { $0.id == id }
        commitList()
        onRemoved(id)
    }

    // MARK: For the UI and the Apple TV

    /// The film behind a path on the cloud disk.
    func film(atDiskPath path: String) -> CloudFilm? {
        guard path.hasPrefix(paths.mount.path + "/") else { return nil }
        let parts = path.dropFirst(paths.mount.path.count + 1).split(separator: "/")
        guard parts.count >= 2 else { return nil }
        let name = parts[parts.count - 1].precomposedStringWithCanonicalMapping
        let folder = parts.dropLast().joined(separator: "/").precomposedStringWithCanonicalMapping
        return films.first {
            let place = place($0)
            return place.folder.precomposedStringWithCanonicalMapping == folder && place.name.precomposedStringWithCanonicalMapping == name
        }
    }

    func bitrates(_ id: UInt64) -> [Double] {
        guard let data = try? Data(contentsOf: bitrateURL(id)),
              let values = try? JSONDecoder().decode([Double].self, from: data) else { return [] }
        return values
    }

    func status(_ film: CloudFilm) -> FilmStatus {
        let job = jobs[film.id]
        let percent = Int((job?.progress ?? 0) * 100)
        let phase: FilmStatus.Phase
        let detail: String
        if !film.verified {
            phase = .local
            switch job?.kind {
            case .uploading:
                let connections = job?.connections ?? 1
                detail = connections > 1
                    ? "Uploading faster over \(connections) connections, \(percent)%"
                    : "Uploading to Google Drive, \(percent)%"
            case .checking: detail = "Checking Google’s copy, \(percent)%"
            case .measuring: detail = "Measuring bitrate"
            default: detail = connected ? "Waiting to upload" : "On your Mac, waiting for Google Drive"
            }
        } else if job?.kind == .downloading {
            phase = .downloading
            detail = "Downloading to your Mac, \(percent)%"
        } else if film.downloaded {
            phase = .downloaded
            detail = "In Google Drive and on your Mac"
        } else {
            phase = .cloud
            detail = "In Google Drive"
        }
        let grouped = film.extraOf == nil && groupRoot(film) != nil && versions(of: groupRoot(film)!.id).count > 1
        return FilmStatus(phase: phase, size: film.size, detail: detail, progress: job?.progress,
                          megabitsPerSecond: job?.megabitsPerSecond, secondsLeft: job?.secondsLeft, error: errors[film.id],
                          versionLabel: grouped ? film.versionLabel : nil, isDefaultVersion: grouped ? film.versionOf == nil : nil,
                          extraTitle: film.extraOf != nil ? film.extraTitle : nil)
    }
}

private struct RateMeter {
    let startBytes: Int64
    let total: Int64
    let began = Date()

    init(done: Int64, total: Int64) {
        startBytes = done
        self.total = total
    }

    func job(_ kind: CloudJob.Kind, done: Int64) -> CloudJob {
        let seconds = max(Date().timeIntervalSince(began), 0.001)
        let speed = Double(done - startBytes) / seconds
        return CloudJob(kind: kind, progress: Double(done) / Double(max(total, 1)),
                        megabitsPerSecond: speed * 8 / 1_000_000,
                        secondsLeft: speed > 0 ? Double(total - done) / speed : nil)
    }
}

import AppKit
import Foundation
import SwiftUI

enum LibraryKind: String, CaseIterable, Identifiable {
    case films = "Films"
    case shows = "TV Shows"
    var id: String { rawValue }
    var collectionType: String { self == .films ? "movies" : "tvshows" }
    var symbol: String { self == .films ? "film" : "tv" }
    /// What the library page lists: films, or whole shows (their episodes are inside).
    var itemTypes: String { self == .films ? "Movie,Video" : "Series" }
}

enum AddMode: String, CaseIterable, Identifiable {
    case move, copy, link
    var id: String { rawValue }
    var label: String {
        switch self {
        case .move: return "Move into the library"
        case .copy: return "Copy into the library"
        case .link: return "Leave in place (link)"
        }
    }
}

struct Transfer: Identifiable {
    let id = UUID()
    let name: String
    var progress: Double?      // nil = indeterminate
    var failed: String?
    var done = false
}

/// Runs Jellyfin as a child process, configures it with no wizard, and exposes library state to the UI.
@MainActor
final class ServerManager: ObservableObject {
    static let shared = ServerManager()

    enum State: Equatable {
        case starting(String)
        case running
        case missing
        case failed(String)
    }

    @Published private(set) var state: State = .starting("Starting…")
    @Published private(set) var serverName = Host.current().localizedName ?? "Mac"
    @Published private(set) var version: String?
    @Published private(set) var libraries: [LibraryKind: [Item]] = [:]
    @Published private(set) var sessions: [SessionInfo] = []
    @Published private(set) var scanProgress: Double?
    @Published var transfers: [Transfer] = []
    @Published private(set) var lanAddress: String?

    @Published var addMode: AddMode = AddMode(rawValue: UserDefaults.standard.string(forKey: "addMode") ?? "") ?? .move {
        didSet { UserDefaults.standard.set(addMode.rawValue, forKey: "addMode") }
    }
    @Published var keepAwakeWhileStreaming: Bool = UserDefaults.standard.object(forKey: "keepAwake") as? Bool ?? true {
        didSet { UserDefaults.standard.set(keepAwakeWhileStreaming, forKey: "keepAwake") }
    }

    private(set) var client: JellyfinClient
    let google: GoogleAuth
    let cloud: CloudStore
    /// Watch progress to copy to a film once it has moved into its versions-and-extras folder.
    var pendingWatchStates: [UInt64: UserData] = [:]
    /// Torrents downloading straight to Google Drive.
    let torrents: TorrentStore
    @Published private(set) var cloudProblem: String?
    private lazy var controlAPI = ControlAPI(server: self)
    /// Supplies Reel for iPhone through Google Drive.
    private(set) lazy var phone = PhoneBridge(server: self)
    var currentUserId: String? { userId }
    private var process: Process?
    private var userId: String?
    private var folderIds: [LibraryKind: String] = [:]
    private var bonjour: NetService?
    private var pollTask: Task<Void, Never>?
    private var awakeToken: NSObjectProtocol?
    private var stopping = false

    // MARK: Paths

    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Reel", isDirectory: true)
    var jellyfinApp: URL { support.appendingPathComponent("Jellyfin.app") }
    var dataDir: URL { support.appendingPathComponent("server", isDirectory: true) }
    let logsDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/Reel", isDirectory: true)
    let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Reel/jellyfin", isDirectory: true)
    /// The library lives in ~/Movies, which iCloud doesn't sync, so files are always on this disk.
    let libraryRoot = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Reel", isDirectory: true)
    func folder(for kind: LibraryKind) -> URL { libraryRoot.appendingPathComponent(kind.rawValue, isDirectory: true) }

    var adminName: String { NSUserName() }
    var adminPassword: String {
        if let pw = Keychain.get("server.password") { return pw }
        let chars = Array("abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        let pw = String((0..<20).map { _ in chars.randomElement()! })
        Keychain.set(pw, for: "server.password")
        return pw
    }

    private init() {
        client = JellyfinClient(baseURL: URL(string: "http://127.0.0.1:\(Reel.port)")!,
                                token: Keychain.get("server.token"),
                                deviceName: (Host.current().localizedName ?? "Mac") + " (Reel Server)",
                                deviceId: DeviceIdentity.id)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Reel", isDirectory: true)
        let auth = GoogleAuth()
        google = auth
        cloud = CloudStore(
            paths: CloudPaths(drop: home.appendingPathComponent("Reel/movies", isDirectory: true),
                              shows: home.appendingPathComponent("Reel/tv shows", isDirectory: true),
                              downloads: home.appendingPathComponent("Movies/Reel/Now Playing", isDirectory: true),
                              state: supportDir.appendingPathComponent("cloud", isDirectory: true),
                              mount: supportDir.appendingPathComponent("cloud-disk", isDirectory: true)),
            drive: DriveClient(token: { rejected in try await auth.token(rejected: rejected) }),
            connected: auth.isSignedIn,
            ffprobe: {
                let probe = supportDir.appendingPathComponent("Jellyfin.app/Contents/MacOS/ffprobe")
                return FileManager.default.isExecutableFile(atPath: probe.path) ? probe : nil
            })
        torrents = TorrentStore(cloud: cloud, folder: supportDir.appendingPathComponent("torrents", isDirectory: true))
        lanAddress = Self.currentLANAddress()
        cloud.onFilmsChanged = { [weak self] in
            guard let self, self.state == .running else { return }
            Task { await self.rescan() }
        }
        cloud.fasterUploads = UserDefaults.standard.bool(forKey: "fasterUploads")
        cloud.onFasterUploadsChanged = { UserDefaults.standard.set($0, forKey: "fasterUploads") }
        cloud.namesPlaying = { [weak self] in self?.namesBeingPlayed() ?? [] }
        cloud.onRemoved = { [weak self] id in
            guard let self else { return }
            Task { await self.phone.forget(id) }
        }
    }

    // MARK: Google Drive

    func signInToGoogle() async throws {
        try await google.signIn()
        cloud.setConnected(true)
    }

    func signOutOfGoogle() async {
        await google.signOut()
        cloud.setConnected(false)
    }

    private func namesBeingPlayed() -> Set<String> {
        let all = libraries.values.joined()
        return Set(sessions.compactMap { session in
            guard let playing = session.nowPlayingItem else { return nil }
            let path = playing.path ?? all.first { $0.id == playing.id }?.path
            return path.map { ($0 as NSString).lastPathComponent }
        })
    }

    func cloudFilm(itemID: String) async -> CloudFilm? {
        var path = libraries.values.joined().first { $0.id == itemID }?.path
        if path == nil, let userId { path = (try? await client.item(itemID, userId: userId))?.path }
        return path.flatMap { cloud.film(atDiskPath: $0) }
    }

    // MARK: Lifecycle

    func start() async {
        stopping = false
        state = .starting("Starting Jellyfin…")
        cloudProblem = nil
        do {
            // The cloud disk has to be there before Jellyfin looks at its libraries.
            try await cloud.start()
        } catch {
            cloudProblem = error.localizedDescription
        }
        do {
            try await controlAPI.start()
        } catch {
            cloudProblem = "The Apple TV controls couldn’t start on port \(Reel.controlPort): \(error.localizedDescription)"
        }
        do {
            let alreadyUp = try await isServerUp()
            if !alreadyUp {
                try launchProcess()
                state = .starting("Waiting for Jellyfin to start (the first launch can take a minute)…")
                try await waitForServer(timeout: 240)
            }
            state = .starting("Setting up your library…")
            try await configureWhenReady()
            state = .running
            publishBonjour()
            startPolling()
            phone.start()
            torrents.start()
            // The cloud disk's list can change before Jellyfin is up, when onFilmsChanged can't rescan.
            await rescan()
            await removeVanished()
            await refreshLibraries()
            await dressExtrasShows()
        } catch let error as ServerSetupError where error == .missing {
            state = .missing
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func stop() {
        stopping = true
        pollTask?.cancel()
        phone.stop()
        bonjour?.stop()
        process?.terminate()
        controlAPI.stop()
        cloud.stop()
        updateKeepAwake(false)
    }

    func restart() async {
        stop()
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        await start()
    }

    enum ServerSetupError: Error, Equatable { case missing }

    private func isServerUp() async throws -> Bool {
        (try? await client.publicInfo()) != nil
    }

    private func locate(_ name: String, directory: Bool = false) -> URL? {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: jellyfinApp, includingPropertiesForKeys: [.isDirectoryKey]) else { return nil }
        for case let url as URL in e where url.lastPathComponent == name {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir == directory { return url }
        }
        return nil
    }

    private func launchProcess() throws {
        guard FileManager.default.fileExists(atPath: jellyfinApp.path),
              let binary = locate("jellyfin") else { throw ServerSetupError.missing }
        let fm = FileManager.default
        for dir in [dataDir, dataDir.appendingPathComponent("config"), logsDir, cacheDir, libraryRoot,
                    folder(for: .films), folder(for: .shows), cloud.paths.shows] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        var args = ["--datadir", dataDir.path,
                    "--configdir", dataDir.appendingPathComponent("config").path,
                    "--cachedir", cacheDir.path,
                    "--logdir", logsDir.path]
        if let web = locate("jellyfin-web", directory: true) { args += ["--webdir", web.path] } else { args.append("--nowebclient") }
        if let ffmpeg = locate("ffmpeg") { args += ["--ffmpeg", ffmpeg.path] }

        let p = Process()
        p.executableURL = binary
        p.arguments = args
        p.currentDirectoryURL = binary.deletingLastPathComponent()
        // Jellyfin's default (1 GB / 200 s) reads 350 MB before every start and seek, which is slow from Drive.
        p.environment = ProcessInfo.processInfo.environment.merging([
            "JELLYFIN_FFmpeg__probesize": "40M", "JELLYFIN_FFmpeg__analyzeduration": "10M",
        ]) { _, new in new }
        let logURL = logsDir.appendingPathComponent("jellyfin-console.log")
        fm.createFile(atPath: logURL.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            p.standardOutput = handle
            p.standardError = handle
        }
        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in self?.processEnded(code: proc.terminationStatus) }
        }
        try p.run()
        process = p
    }

    private func processEnded(code: Int32) {
        process = nil
        guard !stopping else { return }
        state = .failed("Jellyfin stopped unexpectedly (code \(code)). See the log in ~/Library/Logs/Reel.")
        bonjour?.stop()
    }

    private func waitForServer(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await isServerUp() { return }
            if process == nil, !stopping { throw JellyfinError(status: 0, message: "Jellyfin quit while starting. See ~/Library/Logs/Reel.") }
            try await Task.sleep(nanoseconds: 700_000_000)
        }
        throw JellyfinError(status: 0, message: "Jellyfin didn't start within \(Int(timeout)) seconds.")
    }

    // MARK: Automatic setup (replaces Jellyfin's web wizard)

    /// Jellyfin 12 answers /System/Info/Public from a temporary boot server, then closes it before the real
    /// one is up, so the first requests after "ready" can be refused or get a 503.
    private func configureWhenReady() async throws {
        let deadline = Date().addingTimeInterval(120)
        while true {
            do {
                return try await configure()
            } catch {
                let booting = error is URLError || ((error as? JellyfinError)?.status ?? 0) >= 500
                guard booting, !stopping, Date() < deadline else { throw error }
                try await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    private func configure() async throws {
        let info = try await client.publicInfo()
        version = info.version
        if info.startupWizardCompleted != true {
            _ = try? await client.send("GET", "/Startup/User")
            try await client.send("POST", "/Startup/Configuration", json: [
                "UICulture": "en-US", "MetadataCountryCode": "US", "PreferredMetadataLanguage": "en",
            ])
            try await client.send("POST", "/Startup/User", json: ["Name": adminName, "Password": adminPassword])
            try await client.send("POST", "/Startup/RemoteAccess", json: [
                "EnableRemoteAccess": true, "EnableAutomaticPortMapping": false,
            ])
            try await client.send("POST", "/Startup/Complete")
        }
        try await signIn()
        try await ensureServerSettings()
        try await ensureEncodingSettings()
        try await ensureLibraries()
    }

    private func signIn() async throws {
        if client.token != nil, let me = try? await client.me() {
            userId = me.id
            return
        }
        client.token = nil
        let result: AuthResult = try await client.post("/Users/AuthenticateByName",
                                                       json: ["Username": adminName, "Pw": adminPassword])
        client.token = result.accessToken
        userId = result.user.id
        Keychain.set(result.accessToken, for: "server.token")
    }

    private func ensureServerSettings() async throws {
        let data = try await client.send("GET", "/System/Configuration")
        guard var config = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        var changed = false
        func set(_ key: String, _ value: Any) {
            if (config[key] as AnyObject?)?.isEqual(value) != true { config[key] = value; changed = true }
        }
        set("QuickConnectAvailable", true)
        set("ServerName", "Reel on \(serverName)")
        if changed { try await client.send("POST", "/System/Configuration", json: config) }
    }

    /// Without these, a remux is written to disk at full speed: a 50 GB film fills the Mac and playback dies.
    private func ensureEncodingSettings() async throws {
        let data = try await client.send("GET", "/System/Configuration/encoding")
        guard var options = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let wanted: [String: NSNumber] = ["EnableThrottling": true, "ThrottleDelaySeconds": 60,
                                          "EnableSegmentDeletion": true, "SegmentKeepSeconds": 60]
        guard wanted.contains(where: { (options[$0.key] as? NSNumber) != $0.value }) else { return }
        for (key, value) in wanted { options[key] = value }
        try await client.send("POST", "/System/Configuration/encoding", json: options)
    }

    private func ensureLibraries() async throws {
        var folders: [VirtualFolder] = try await client.get("/Library/VirtualFolders")
        for kind in LibraryKind.allCases where !folders.contains(where: { $0.name == kind.rawValue }) {
            let path = folder(for: kind)
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            try await client.send("POST", "/Library/VirtualFolders", query: [
                .init("name", kind.rawValue), .init("collectionType", kind.collectionType),
                .init("paths", path.path), .init("refreshLibrary", "true"),
            ], json: ["LibraryOptions": [
                "EnableRealtimeMonitor": true,
                "EnableChapterImageExtraction": false,
                "ExtractChapterImagesDuringLibraryScan": false,
                "PreferredMetadataLanguage": "en",
                "MetadataCountryCode": "US",
            ] as [String: Any]])
            folders = try await client.get("/Library/VirtualFolders")
        }
        // Reel used to have a Home Videos library. It's taken out of Jellyfin only while empty; the folder stays.
        if let old = folders.first(where: { $0.name == "Home Videos" }), let userId, let parent = old.itemId,
           let inside = try? await client.items(userId: userId, parentId: parent, types: "Movie,Video"), inside.isEmpty {
            await attempt("Removing the empty Home Videos library") { _ = try await client.send("DELETE", "/Library/VirtualFolders", query: [.init("name", "Home Videos"),
                                                                                .init("refreshLibrary", "false")]) }
            folders.removeAll { $0.name == "Home Videos" }
        }
        if CloudMount.isMounted(cloud.paths.mount) {
            for kind in LibraryKind.allCases {
                let path = cloud.paths.mount.appendingPathComponent(kind.rawValue).path
                guard let library = folders.first(where: { $0.name == kind.rawValue }),
                      library.locations?.contains(path) != true else { continue }
                try await client.send("POST", "/Library/VirtualFolders/Paths", query: [.init("refreshLibrary", "true")],
                                      json: ["Name": kind.rawValue, "PathInfo": ["Path": path]] as [String: Any])
            }
        }
        for f in folders {
            if let kind = LibraryKind(rawValue: f.name) { folderIds[kind] = f.itemId }
        }
    }

    // MARK: Library

    func refreshLibraries() async {
        guard let userId else { return }
        for kind in LibraryKind.allCases {
            guard let parent = folderIds[kind] else { continue }
            if let items = try? await client.items(userId: userId, parentId: parent, types: kind.itemTypes,
                                                   sortBy: "DateCreated,SortName", descending: true) {
                libraries[kind] = items
            }
        }
    }

    /// Jellyfin keeps items whose files have gone when their library folder is empty (it takes that for a
    /// disconnected drive). Reel's own local folders are always on this Mac, so anything listed there whose file
    /// is gone really is gone. The Google Drive disk is never pruned this way: Reel's catalog decides what's there.
    func removeVanished() async {
        guard let userId else { return }
        let fm = FileManager.default
        let locals = LibraryKind.allCases.map { folder(for: $0).path + "/" }
        guard fm.fileExists(atPath: libraryRoot.path) else { return }
        func isLocal(_ path: String) -> Bool { locals.contains { path.hasPrefix($0) } }
        // Nothing at all at the path, not even a link: a link to an unplugged drive is kept.
        func exists(_ path: String) -> Bool { (try? fm.attributesOfItem(atPath: path)) != nil }

        let page: ItemsPage? = try? await client.get("/Items", [
            .init("userId", userId), .init("recursive", "true"), .init("includeItemTypes", "Movie,Video,Episode"),
            .init("fields", "Path"), .init("enableImages", "false"),
        ])
        var doomed: [String] = []
        var shows = Set<String>()
        for item in page?.items ?? [] {
            guard let path = item.path, isLocal(path), !exists(path) else { continue }
            if let show = item.seriesId { shows.insert(show) }
            doomed.append(item.id)
        }
        // A show whose folder has gone goes as a whole, with its seasons.
        for show in shows {
            if let series = try? await client.item(show, userId: userId), let path = series.path, isLocal(path), !exists(path) {
                doomed.append(series.id)
            }
        }
        for id in doomed {
            await attempt("Removing a vanished item from Jellyfin") { _ = try await client.send("DELETE", "/Items/\(id)") }
        }
    }

    func rescan() async {
        await attempt("Asking Jellyfin to rescan") { _ = try await client.send("POST", "/Library/Refresh") }
        scanProgress = 0
    }

    func posterURL(for item: Item, kind: LibraryKind) -> URL? {
        client.imageURL(for: item, maxWidth: 400)
    }

    /// The episodes of a show, in order.
    func episodes(of series: Item) async -> [Item] {
        guard let userId else { return [] }
        let page: ItemsPage? = try? await client.get("/Shows/\(series.id)/Episodes", [
            .init("userId", userId), .init("fields", "Path,Overview,MediaStreams,DateCreated"),
            .init("enableImageTypes", "Primary,Backdrop,Thumb"),
        ])
        return page?.items ?? []
    }

    /// A whole show: every episode goes, as for a film (Drive's Bin, or the Mac's Trash).
    func removeShow(_ series: Item) async {
        for episode in await episodes(of: series) { await removeFromLibrary(episode, rescanAfter: false) }
        await rescan()
    }

    /// Moves the file to the Trash (recoverable), then rescans.
    func removeFromLibrary(_ item: Item) async {
        await removeFromLibrary(item, rescanAfter: true)
    }

    private func removeFromLibrary(_ item: Item, rescanAfter: Bool) async {
        guard let path = item.path else { return }
        if path.hasPrefix(cloud.paths.mount.path + "/") {
            guard let film = cloud.film(atDiskPath: path) else { return await rescan() }
            do {
                try await cloud.remove(film.id)
            } catch {
                transfers.append(Transfer(name: item.title, progress: nil, failed: error.localizedDescription))
            }
            return
        }
        let url = URL(fileURLWithPath: path)
        // A film in its own folder takes its subtitles and artwork with it.
        var target = url
        if let library = libraryFolderContaining(url),
           url.deletingLastPathComponent().standardizedFileURL.path != library.standardizedFileURL.path {
            target = url.deletingLastPathComponent()
        }
        _ = try? await NSWorkspace.shared.recycle([target])
        if rescanAfter { await rescan() }
    }

    private func libraryFolderContaining(_ url: URL) -> URL? {
        LibraryKind.allCases.map(folder(for:)).first { url.path.hasPrefix($0.path) }
    }

    // MARK: Adding files

    private static let videoExtensions: Set<String> = ["mkv", "mp4", "m4v", "mov", "avi", "ts", "m2ts", "mts", "webm", "wmv", "mpg", "mpeg", "vob", "iso"]

    func add(_ urls: [URL], to kind: LibraryKind) {
        // Links stay in the local library; everything else goes through the drop folder to Google Drive.
        let destination: URL
        switch addMode {
        case .link: destination = folder(for: kind)
        case .move, .copy: destination = kind == .shows ? cloud.paths.shows : cloud.paths.drop
        }
        attempt("Making a folder") { try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true) }
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            let dropPath = (kind == .shows ? cloud.paths.shows : cloud.paths.drop).resolvingSymlinksInPath().path
            let sourcePath = url.resolvingSymlinksInPath().path
            if addMode != .link, sourcePath.hasPrefix(dropPath + "/") || dropPath.hasPrefix(sourcePath + "/")
                || sourcePath == dropPath { continue }
            if !isDir.boolValue, !Self.videoExtensions.contains(url.pathExtension.lowercased()) { continue }
            let isDirectory = isDir.boolValue
            let transfer = Transfer(name: url.lastPathComponent, progress: nil)
            transfers.append(transfer)
            let mode = addMode
            let target = Self.uniqueDestination(for: url, in: destination)
            Task.detached(priority: .userInitiated) { [weak self] in
                do {
                    try await Self.perform(mode, from: url, to: target, isDirectory: isDirectory) { fraction in
                        Task { @MainActor in self?.updateTransfer(transfer.id) { $0.progress = fraction } }
                    }
                    await MainActor.run { self?.updateTransfer(transfer.id) { $0.done = true; $0.progress = 1 } }
                    await self?.rescan()
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    await MainActor.run { self?.transfers.removeAll { $0.id == transfer.id } }
                } catch {
                    await MainActor.run { self?.updateTransfer(transfer.id) { $0.failed = error.localizedDescription } }
                }
            }
        }
    }

    func dismissTransfer(_ id: UUID) { transfers.removeAll { $0.id == id } }

    private func updateTransfer(_ id: UUID, _ change: (inout Transfer) -> Void) {
        guard let i = transfers.firstIndex(where: { $0.id == id }) else { return }
        change(&transfers[i])
    }

    nonisolated private static func uniqueDestination(for source: URL, in folder: URL) -> URL {
        var candidate = folder.appendingPathComponent(source.lastPathComponent)
        var n = 2
        let base = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            candidate = folder.appendingPathComponent(name)
            n += 1
        }
        return candidate
    }

    nonisolated private static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let ka = try? a.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
        let kb = try? b.deletingLastPathComponent().resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
        guard let ka, let kb else { return false }
        return ka.isEqual(kb)
    }

    nonisolated private static func perform(_ mode: AddMode, from source: URL, to target: URL, isDirectory: Bool,
                                            progress: @escaping @Sendable (Double) -> Void) async throws {
        let fm = FileManager.default
        switch mode {
        case .link:
            try fm.createSymbolicLink(at: target, withDestinationURL: source)
        case .move where sameVolume(source, target):
            try fm.moveItem(at: source, to: target)   // instant: same disk, no extra space used
        case .move, .copy:
            if isDirectory {
                try fm.copyItem(at: source, to: target)
            } else {
                try copyFile(from: source, to: target, progress: progress)
            }
            if mode == .move { try fm.trashItem(at: source, resultingItemURL: nil) }
        }
    }

    /// Chunked copy so large films show real progress.
    nonisolated private static func copyFile(from source: URL, to target: URL,
                                             progress: @escaping @Sendable (Double) -> Void) throws {
        let fm = FileManager.default
        let total = Double((try? fm.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.int64Value ?? 0)
        let partial = target.appendingPathExtension("reelpart")
        fm.createFile(atPath: partial.path, contents: nil)
        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: partial)
        defer { try? input.close(); try? output.close() }
        var copied = 0.0
        var lastReport = Date.distantPast
        while true {
            let chunk = try input.read(upToCount: 8 * 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            try output.write(contentsOf: chunk)
            copied += Double(chunk.count)
            if total > 0, Date().timeIntervalSince(lastReport) > 0.25 {
                lastReport = Date()
                progress(copied / total)
            }
        }
        try output.close()
        try fm.moveItem(at: partial, to: target)
    }

    // MARK: Apple TV pairing

    func authorizeAppleTV(code: String) async throws {
        guard let userId else { throw JellyfinError(status: 0, message: "The server isn't ready yet.") }
        let digits = code.filter(\.isNumber)
        let ok: Bool = try await client.post("/QuickConnect/Authorize",
                                             [.init("code", digits), .init("userId", userId)])
        if !ok { throw JellyfinError(status: 400, message: "That code didn't match. Check the code on your TV and try again.") }
    }

    // MARK: Bonjour

    private func publishBonjour() {
        bonjour?.stop()
        let service = NetService(domain: "local.", type: Reel.bonjourType + ".", name: serverName, port: Int32(Reel.port))
        var txt: [String: Data] = ["v": Data("1".utf8)]
        if let version { txt["jf"] = Data(version.utf8) }
        service.setTXTRecord(NetService.data(fromTXTRecord: txt))
        service.publish()
        bonjour = service
    }

    // MARK: Polling: scan progress, active streams, keep-awake

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollOnce(refreshLibrary: tick % 6 == 0)
                tick += 1
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    private func pollOnce(refreshLibrary: Bool) async {
        lanAddress = Self.currentLANAddress()
        if let all: [SessionInfo] = try? await client.get("/Sessions", [.init("activeWithinSeconds", "60")]) {
            sessions = all.filter { $0.nowPlayingItem != nil }
        }
        updateKeepAwake(keepAwakeWhileStreaming && !sessions.isEmpty)
        if let tasks: [ScheduledTask] = try? await client.get("/ScheduledTasks", [.init("isHidden", "false")]),
           let scan = tasks.first(where: { $0.key == "RefreshLibrary" }) {
            let running = scan.state == "Running"
            let wasRunning = scanProgress != nil
            scanProgress = running ? (scan.currentProgressPercentage ?? 0) / 100 : nil
            if wasRunning && !running {
                await removeVanished()
                await refreshLibraries()
                await dressExtrasShows()
                await applyPendingWatchStates()
            }
            else if running || refreshLibrary { await refreshLibraries() }
        }
    }

    var isStreaming: Bool { !sessions.isEmpty }

    /// A sleeping Mac mini drops the stream, so hold the system awake while something plays.
    private func updateKeepAwake(_ on: Bool) {
        if on, awakeToken == nil {
            awakeToken = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated],
                                                               reason: "Streaming to Apple TV")
        } else if !on, let token = awakeToken {
            ProcessInfo.processInfo.endActivity(token)
            awakeToken = nil
        }
    }

    // MARK: Network

    static func currentLANAddress() -> String? {
        var addresses: [String: String] = [:]
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard let addr = ptr.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            addresses[String(cString: ptr.pointee.ifa_name)] = String(cString: host)
        }
        return addresses["en0"] ?? addresses["en1"] ?? addresses.values.first
    }

    var webDashboardURL: URL { URL(string: "http://127.0.0.1:\(Reel.port)/web/")! }
}

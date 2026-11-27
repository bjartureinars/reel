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
/// Split by job across CloudStore*.swift; the most important is CloudStore+Originals.swift (deleting originals).
/// Its published state is set only by those files; everything else reads it.
@MainActor
final class CloudStore: ObservableObject {
    /// The cloud disk's top folders. Their order fixes their NFS ids, so new ones go at the end.
    nonisolated static let folders = ["Films", "Home Videos", "TV Shows"]
    nonisolated static let showsFolder = "TV Shows"

    /// A folder a film in Drive may say it belongs in.
    nonisolated static func isKnownFolder(_ folder: String) -> Bool {
        folders.contains(folder) || CloudFilm.show(inFolder: folder) != nil
    }
    nonisolated static let uploadChunk = 64 << 20
    nonisolated static let partChunk = 24 << 20
    /// Connections left to uploading while a film plays, so the stream keeps the Wi-Fi.
    nonisolated static let lanesWhilePlaying = 2
    /// Beyond this, starting again in pieces wouldn't beat finishing the single file.
    nonisolated static let switchLimit = 0.6
    nonisolated static let downloadChunk = 24 << 20
    nonisolated static let downloadStreams = 4
    /// Left free after a download, for the remux buffer and macOS itself.
    nonisolated static let spaceMargin: Int64 = 8_000_000_000

    @Published var films: [CloudFilm] = []
    @Published var jobs: [UInt64: CloudJob] = [:]
    @Published var errors: [UInt64: String] = [:]
    @Published var connected: Bool
    @Published var quota: DriveQuota?
    @Published var problem: String?
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
    @Published var pending: [PendingFilm] = []
    /// Called when the set of films on the cloud disk changes.
    var onFilmsChanged: () -> Void = {}
    /// File names being played right now; those downloads are never offloaded.
    var namesPlaying: () -> Set<String> = { [] }

    let drive: DriveClient
    let disk: CloudDisk
    let server: NFSServer
    let ffprobe: () -> URL?
    let scanInterval: TimeInterval
    let settleTime: TimeInterval
    let quietTime: TimeInterval
    let partSize: Int64
    var claimed: [UInt64: Set<Int>] = [:]
    let log = Logger(subsystem: "com.bjartur.reel.server", category: "cloud")

    var started = false
    var driveFolder: String?
    var unchangedSince: [String: (stamp: FileStamp, since: Date)] = [:]
    var inspected: [String: (stamp: FileStamp, problem: String?)] = [:]
    var inspecting: (path: String, progress: Double)?
    var inspector: Task<Void, Never>?
    var scanning = false
    /// Unverified uploads that were abandoned. Drive may hold a complete file for one, and it must never be
    /// taken for a film when syncing.
    var discarded: Set<UInt64> = []
    var loop: Task<Void, Never>?
    var worker: Task<Void, Never>?
    var workingOn: UInt64?
    var retryAfter: [UInt64: Date] = [:]
    var mismatches: [UInt64: Int] = [:]
    var measured: Set<UInt64> = []
    var downloadTasks: [UInt64: Task<Void, Never>] = [:]
    var lastSync = Date.distantPast
    var activity: NSObjectProtocol?

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

    var catalogURL: URL { paths.state.appendingPathComponent("catalog.json") }
    var discardedURL: URL { paths.state.appendingPathComponent("discarded.json") }
    func bitrateURL(_ id: UInt64) -> URL { paths.state.appendingPathComponent("bitrate/\(id).json") }
    func downloadURL(_ id: UInt64) -> URL { paths.downloads.appendingPathComponent("\(id).film") }
    func partialURL(_ id: UInt64) -> URL { paths.downloads.appendingPathComponent("\(id).part") }
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

    func tick() async {
        await scanDropFolder()
        if connected, Date().timeIntervalSince(lastSync) > 300 { await sync() }
        startNextJob()
        updateActivity()
    }

    func updateActivity() {
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

    func save() throws {
        let data = try JSONEncoder().encode(films)
        try data.write(to: catalogURL, options: .atomic)
        // Unfinished upload URLs work without a password.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: catalogURL.path)
    }

    func edit(_ id: UInt64, _ change: (inout CloudFilm) -> Void) {
        guard let index = films.firstIndex(where: { $0.id == id }) else { return }
        change(&films[index])
        publishRoutes()
        do { try save() } catch { problem = "Reel couldn’t save its catalog: \(error.localizedDescription)" }
    }

    func commitList() {
        publishRoutes()
        do { try save() } catch { problem = "Reel couldn’t save its catalog: \(error.localizedDescription)" }
        onFilmsChanged()
    }

    func publishRoutes() {
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

struct RateMeter {
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

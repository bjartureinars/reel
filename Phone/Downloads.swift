import CryptoKit
import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// A film saved on the phone, or on its way.
struct Download: Codable, Identifiable, Equatable {
    enum State: String, Codable {
        /// The Mac is making the smaller copy.
        case waitingForMac
        case downloading
        case checking
        case ready
        case failed
    }

    struct Source: Codable, Equatable {
        let driveID: String
        let offset: Int64
        let size: Int64
        let md5: String?
    }

    struct Chunk: Codable, Equatable {
        let index: Int
        let driveID: String
        let fileOffset: Int64
        let offset: Int64
        let length: Int64
        var done = false
    }

    let id: String
    let quality: CopyQuality
    var size: Int64
    var sources: [Source] = []
    var chunks: [Chunk] = []
    var state: State
    var problem: String?
    let added: Date

    var folder: URL { Folders.downloads.appendingPathComponent("\(id)-\(quality.rawValue)", isDirectory: true) }
    func url(_ chunk: Int) -> URL { folder.appendingPathComponent("\(chunk).chunk") }
    var doneBytes: Int64 { chunks.filter(\.done).reduce(0) { $0 + $1.length } }

    var reader: LocalReader {
        LocalReader(parts: chunks.map { .init(url: url($0.index), offset: $0.offset, size: $0.length) })
    }
}

/// Saves films on the phone, from Google Drive, in the background. Each film is fetched as 256 MB pieces,
/// so a dropped connection loses little and a sign-in token can be renewed between pieces.
@MainActor
final class DownloadCenter: NSObject, ObservableObject {
    static let sessionID = "com.bjartur.reel.phone.downloads"
    private static let chunkSize: Int64 = 256 << 20

    @Published private(set) var downloads: [String: Download] = Store.load("downloads.json") ?? [:]
    /// Bytes arrived in pieces still in progress.
    @Published private(set) var partial: [String: Int64] = [:]
    @Published private(set) var speed: [String: Double] = [:]
    @AppStorage("downloadOverCellular") var overCellular = false

    private var drive: DriveClient!
    private weak var library: Library?
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.httpMaximumConnectionsPerHost = 6
        config.allowsCellularAccess = overCellular
        config.timeoutIntervalForResource = 24 * 3600
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    private var running: [String: Set<Int>] = [:]
    private var inProgress: [Int: Int64] = [:]   // task id → bytes so far
    private var taskChunk: [Int: (film: String, chunk: Int)] = [:]
    private var rate: [String: (Date, Int64)] = [:]
    private var topping = false
    var backgroundCompletion: (() -> Void)?

    func attach(library: Library) {
        self.library = library
        drive = library.drive
        Task { await reconnect() }
    }

    private func save() { Store.save(downloads, as: "downloads.json") }

    func download(for film: Film) -> Download? { downloads[film.id] }

    /// Bytes on the phone and in flight, for progress.
    func received(_ download: Download) -> Int64 { download.doneBytes + (partial[download.id] ?? 0) }

    // MARK: Starting and stopping

    func start(_ film: Film, quality: CopyQuality) async throws {
        guard let library else { return }
        let needed = film.estimatedSize(quality) + 1_000_000_000
        guard Folders.freeSpace > needed else {
            throw CloudError("\(film.fullTitle) needs \(needed.fileSize) free on this \(Device.name). You have \(Folders.freeSpace.fileSize).")
        }
        if let old = downloads[film.id] { remove(old) }
        var download = Download(id: film.id, quality: quality, size: film.estimatedSize(quality), state: .downloading, added: Date())
        if quality == .original {
            plan(&download, film.pieces.map { .init(driveID: $0.id, offset: $0.offset, size: $0.size, md5: $0.md5) })
        } else if let copy = library.copies[film.id]?[quality] {
            plan(&download, [.init(driveID: copy.driveID, offset: 0, size: copy.size, md5: copy.md5)])
        } else {
            download.state = .waitingForMac
            try await library.requestCopy(film, quality)
        }
        downloads[film.id] = download
        save()
        await topUp()
    }

    private func plan(_ download: inout Download, _ sources: [Download.Source]) {
        download.sources = sources
        download.size = sources.reduce(0) { $0 + $1.size }
        download.chunks = []
        for source in sources {
            var at: Int64 = 0
            while at < source.size {
                let length = min(Self.chunkSize, source.size - at)
                download.chunks.append(.init(index: download.chunks.count, driveID: source.driveID, fileOffset: at,
                                             offset: source.offset + at, length: length))
                at += length
            }
        }
        download.state = .downloading
        try? FileManager.default.createDirectory(at: download.folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var folder = download.folder
        try? folder.setResourceValues(values)
    }

    func remove(_ download: Download) {
        session.getAllTasks { tasks in
            for task in tasks where task.taskDescription?.hasPrefix(download.id + "|") == true { task.cancel() }
        }
        running[download.id] = nil
        partial[download.id] = nil
        try? FileManager.default.removeItem(at: download.folder)
        downloads[download.id] = nil
        save()
        if download.state == .waitingForMac, let film = library?.film(download.id) {
            Task { await library?.cancelRequest(film, download.quality) }
        }
    }

    func retry(_ film: Film) async {
        guard var download = downloads[film.id] else { return }
        download.problem = nil
        if download.state == .failed { download.state = download.chunks.isEmpty ? .waitingForMac : .downloading }
        downloads[film.id] = download
        save()
        if download.state == .waitingForMac { try? await library?.requestCopy(film, download.quality) }
        await topUp()
    }

    var usedSpace: Int64 { downloads.values.reduce(0) { $0 + $1.doneBytes } }

    func setCellular(_ allowed: Bool) {
        overCellular = allowed
        session.configuration.allowsCellularAccess = allowed
    }

    // MARK: Keeping pieces moving

    /// After a relaunch, finds out which pieces the system is still fetching.
    private func reconnect() async {
        let tasks = await session.allTasks
        for task in tasks {
            guard let (film, chunk) = Self.parse(task.taskDescription) else { task.cancel(); continue }
            running[film, default: []].insert(chunk)
            taskChunk[task.taskIdentifier] = (film, chunk)
        }
        await topUp()
    }

    /// Checks on copies the Mac is making, starts pieces, and checks finished films.
    func topUp() async {
        guard !topping, let library else { return }
        topping = true
        defer { topping = false }
        let inBackground = AppState.inBackground
        let window = inBackground ? 12 : 6
        for id in downloads.keys.sorted() {
            guard var download = downloads[id] else { continue }
            if download.state == .waitingForMac {
                if let copy = library.copies[id]?[download.quality] {
                    plan(&download, [.init(driveID: copy.driveID, offset: 0, size: copy.size, md5: copy.md5)])
                    downloads[id] = download
                    save()
                    if let film = library.film(id) { await library.finishedRequest(film, download.quality) }
                } else if let request = library.requests[id]?[download.quality], request.progress.phase == .failed {
                    download.state = .failed
                    download.problem = request.progress.detail ?? "Your Mac couldn’t make that copy."
                    downloads[id] = download
                    save()
                }
                continue
            }
            if download.state == .downloading, download.chunks.allSatisfy(\.done) {
                await check(id)
                continue
            }
            guard download.state == .downloading else { continue }
            let active = running.values.reduce(0) { $0 + $1.count }
            guard active < window else { break }
            let busy = running[id] ?? []
            for chunk in download.chunks where !chunk.done && !busy.contains(chunk.index) {
                guard running.values.reduce(0, { $0 + $1.count }) < window else { break }
                do {
                    let request = try await drive.mediaRequest(chunk.driveID, range: chunk.fileOffset...(chunk.fileOffset + chunk.length - 1))
                    let task = session.downloadTask(with: request)
                    task.taskDescription = "\(id)|\(chunk.index)"
                    task.countOfBytesClientExpectsToReceive = chunk.length
                    task.priority = URLSessionTask.highPriority
                    running[id, default: []].insert(chunk.index)
                    taskChunk[task.taskIdentifier] = (id, chunk.index)
                    task.resume()
                } catch {
                    fail(id, error.localizedDescription)
                    break
                }
            }
        }
    }

    private func fail(_ id: String, _ message: String) {
        guard var download = downloads[id] else { return }
        download.state = .failed
        download.problem = message
        downloads[id] = download
        save()
    }

    /// Every byte checked against Google's MD5 before the film counts as downloaded.
    private func check(_ id: String) async {
        guard var download = downloads[id] else { return }
        download.state = .checking
        downloads[id] = download
        save()
        let snapshot = download
        let result = await Task.detached(priority: .utility) { () -> String? in
            for source in snapshot.sources {
                guard let expected = source.md5 else { continue }
                var hasher = Insecure.MD5()
                for chunk in snapshot.chunks where chunk.driveID == source.driveID {
                    guard let handle = try? FileHandle(forReadingFrom: snapshot.url(chunk.index)) else { return "A piece is missing." }
                    defer { try? handle.close() }
                    var total: Int64 = 0
                    while let data = try? handle.read(upToCount: 8 << 20), !data.isEmpty {
                        hasher.update(data: data)
                        total += Int64(data.count)
                    }
                    if total != chunk.length { return "A piece is the wrong size." }
                }
                let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                if digest != expected.lowercased() { return source.driveID }
            }
            return nil
        }.value
        guard var current = downloads[id], current.state == .checking else { return }
        if let bad = result {
            // Fetch that file again.
            for index in current.chunks.indices where current.chunks[index].driveID == bad || bad.count < 30 {
                current.chunks[index].done = false
                try? FileManager.default.removeItem(at: current.url(current.chunks[index].index))
            }
            current.state = .downloading
            current.problem = nil
        } else {
            current.state = .ready
        }
        downloads[id] = current
        save()
        if current.state == .downloading { await topUp() }
    }

    // MARK: From the session

    nonisolated private static func parse(_ description: String?) -> (String, Int)? {
        guard let parts = description?.split(separator: "|"), parts.count == 2, let chunk = Int(parts[1]) else { return nil }
        return (String(parts[0]), chunk)
    }

    fileprivate func finished(_ film: String, _ chunk: Int, file: URL?, status: Int, error: Error?) {
        running[film]?.remove(chunk)
        guard var download = downloads[film], let index = download.chunks.firstIndex(where: { $0.index == chunk }) else {
            if let file { try? FileManager.default.removeItem(at: file) }
            return
        }
        if let file {
            let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? -1
            if (status == 206 || (status == 200 && download.chunks[index].length == size)) && size == download.chunks[index].length {
                let target = download.url(chunk)
                try? FileManager.default.removeItem(at: target)
                do {
                    try FileManager.default.moveItem(at: file, to: target)
                    download.chunks[index].done = true
                } catch {
                    download.problem = error.localizedDescription
                }
            } else {
                try? FileManager.default.removeItem(at: file)
                if status == 403 || status == 404 { download.state = .failed; download.problem = "Google Drive refused the download (\(status))." }
            }
        }
        downloads[film] = download
        save()
    }

    fileprivate func progressed(_ film: String, task: Int, bytes: Int64) {
        inProgress[task] = bytes
        let total = taskChunk.filter { $0.value.film == film }.keys.reduce(Int64(0)) { $0 + (inProgress[$1] ?? 0) }
        partial[film] = total
        let now = Date()
        let received = (downloads[film]?.doneBytes ?? 0) + total
        if let (then, before) = rate[film], now.timeIntervalSince(then) >= 2 {
            speed[film] = Double(received - before) * 8 / now.timeIntervalSince(then) / 1_000_000
            rate[film] = (now, received)
        } else if rate[film] == nil {
            rate[film] = (now, received)
        }
    }

    fileprivate func ended(task: Int) {
        inProgress[task] = nil
        if let (film, _) = taskChunk.removeValue(forKey: task) {
            partial[film] = taskChunk.filter { $0.value.film == film }.keys.reduce(Int64(0)) { $0 + (inProgress[$1] ?? 0) }
        }
    }

    fileprivate func allEventsDelivered() {
        Task {
            await topUp()
            backgroundCompletion?()
            backgroundCompletion = nil
        }
    }
}

extension DownloadCenter: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let (film, chunk) = Self.parse(downloadTask.taskDescription) else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        // The file at `location` is gone when this returns, so keep it first.
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let moved = (try? FileManager.default.moveItem(at: location, to: kept)) != nil
        Task { @MainActor in
            self.finished(film, chunk, file: moved ? kept : nil, status: status, error: nil)
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let (film, _) = Self.parse(downloadTask.taskDescription) else { return }
        let id = downloadTask.taskIdentifier
        Task { @MainActor in self.progressed(film, task: id, bytes: totalBytesWritten) }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let id = task.taskIdentifier
        let parsed = Self.parse(task.taskDescription)
        Task { @MainActor in
            self.ended(task: id)
            if let (film, chunk) = parsed { self.running[film]?.remove(chunk) }
            if !AppState.inBackground { await self.topUp() }
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in self.allEventsDelivered() }
    }
}

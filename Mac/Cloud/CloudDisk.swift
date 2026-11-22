import Darwin
import Foundation

/// Where each film's bytes come from right now: the drop folder, the downloaded copy, or Google Drive.
/// The path Jellyfin sees never changes, so artwork and resume positions survive upload, offload and download.
final class CloudDisk: DiskSource {
    struct Route {
        let file: DiskFile
        /// Tried in order before Drive.
        let localPaths: [String]
        let remote: RemoteFile?
    }

    private let lock = NSLock()
    private var routes: [UInt64: Route] = [:]
    private var list: [DiskFile] = []
    private let remote: RangeCache

    init(drive: DriveClient) {
        remote = RangeCache(drive: drive)
    }

    func update(_ new: [Route]) {
        lock.lock()
        defer { lock.unlock() }
        routes = Dictionary(new.map { ($0.file.id, $0) }, uniquingKeysWith: { first, _ in first })
        list = new.map(\.file)
    }

    func files() -> [DiskFile] {
        lock.lock()
        defer { lock.unlock() }
        return list
    }

    func read(_ file: DiskFile, offset: Int64, count: Int) throws -> Data {
        lock.lock()
        let route = routes[file.id]
        lock.unlock()
        guard let route else { throw POSIXError(.ESTALE) }
        for path in route.localPaths where FileStamp(path: path)?.size == file.size {
            if let data = try? CloudFiles.read(path, offset: offset, count: count) { return data }
        }
        guard let source = route.remote else { throw POSIXError(.ENOENT) }
        return try remote.read(source, size: file.size, offset: offset, count: count)
    }

    func forget(_ driveID: String) { remote.forget(driveID) }
}

/// In-memory read-ahead over Drive. Nothing streamed is written to disk.
final class RangeCache {
    private struct Key: Hashable {
        let file: String
        let index: Int64
    }

    private var sources: [String: RemoteFile] = [:]

    private enum Chunk {
        case loading
        case ready(Data)
        case failed(Error, at: Date)
    }

    static let chunkSize = 8 << 20
    private static let capacity = 48    // 384 MB
    private static let readAhead: Int64 = 10    // 80 MB in flight: about 10 s even at this film's peaks
    private static let deadline: TimeInterval = 60

    private let drive: DriveClient
    private let condition = NSCondition()
    private var chunks: [Key: Chunk] = [:]
    private var lastUsed: [Key: UInt64] = [:]
    private var recentlyRead: Set<Key> = []
    private var clock: UInt64 = 0

    init(drive: DriveClient) {
        self.drive = drive
    }

    func read(_ source: RemoteFile, size: Int64, offset: Int64, count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        let file = source.key
        condition.lock()
        sources[file] = source
        condition.unlock()
        let chunk = Int64(Self.chunkSize)
        let end = offset + Int64(count)
        var result = Data(capacity: count)
        for index in (offset / chunk)...((end - 1) / chunk) {
            let data = try wait(Key(file: file, index: index), size: size)
            let start = index * chunk
            let lower = Int(max(offset, start) - start)
            let upper = Int(min(end, start + Int64(data.count)) - start)
            guard upper > lower else { throw POSIXError(.EIO) }
            result.append(data.subdata(in: data.startIndex + lower..<data.startIndex + upper))
        }
        return result
    }

    private func wait(_ key: Key, size: Int64) throws -> Data {
        condition.lock()
        defer { condition.unlock() }
        // Read ahead only for sequential reading; the first reads of a film jump between header, index and seek point.
        let sequential = recentlyRead.contains(Key(file: key.file, index: key.index - 1))
        recentlyRead.insert(key)
        load(key, size: size)
        if sequential {
            for step in 1...Self.readAhead { load(Key(file: key.file, index: key.index + step), size: size) }
        }
        let limit = Date().addingTimeInterval(Self.deadline)
        while true {
            switch chunks[key] {
            case .ready(let data):
                touch(key)
                return data
            case .failed(let error, let when):
                // Ride out short internet drops; give up only on errors that won't fix themselves.
                let permanent = (error as? DriveError).map { !$0.isTransient } ?? (error as? CloudError)?.needsSignIn ?? false
                if permanent || Date() >= limit { throw error }
                if Date().timeIntervalSince(when) >= 1 { load(key, size: size) }
            case .loading:
                break
            case nil:
                load(key, size: size)
            }
            if Date() >= limit { throw POSIXError(.ETIMEDOUT) }
            _ = condition.wait(until: min(limit, Date().addingTimeInterval(1)))
        }
    }

    /// Call with the lock held.
    private func load(_ key: Key, size: Int64) {
        let start = key.index * Int64(Self.chunkSize)
        guard start >= 0, start < size else { return }
        switch chunks[key] {
        case .loading, .ready: return
        case .failed(_, let when) where Date().timeIntervalSince(when) < 1: return
        default: break
        }
        guard let source = sources[key.file] else { return }
        chunks[key] = .loading
        touch(key)
        let count = Int(min(Int64(Self.chunkSize), size - start))
        Task.detached(priority: .userInitiated) { [self] in
            let result: Chunk
            do {
                result = .ready(try await drive.read(source, offset: start, count: count, attempts: 3))
            } catch {
                result = .failed(error, at: Date())
            }
            store(key, result)
        }
    }

    private func store(_ key: Key, _ chunk: Chunk) {
        condition.lock()
        defer { condition.unlock() }
        chunks[key] = chunk
        touch(key)
        while chunks.count > Self.capacity {
            let idle = chunks.filter { if case .loading = $0.value { return false } else { return true } }
            guard let oldest = idle.keys.min(by: { lastUsed[$0, default: 0] < lastUsed[$1, default: 0] }) else { break }
            chunks[oldest] = nil
            lastUsed[oldest] = nil
            recentlyRead.remove(oldest)
        }
        condition.broadcast()
    }

    private func touch(_ key: Key) {
        clock += 1
        lastUsed[key] = clock
    }

    func forget(_ file: String) {
        condition.lock()
        defer { condition.unlock() }
        chunks = chunks.filter { $0.key.file != file }
        sources[file] = nil
        lastUsed = lastUsed.filter { $0.key.file != file }
        recentlyRead = recentlyRead.filter { $0.file != file }
        condition.broadcast()
    }
}

/// Mounts the NFS server as an ordinary folder.
enum CloudMount {
    static func mount(port: UInt16, at folder: URL) throws {
        unmount(folder) // left behind if Reel Server crashed
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let options = [
            "vers=3", "tcp", "port=\(port)", "mountport=\(port)", "nolocks", "rdonly", "soft", "intr",
            "timeo=300", "retrans=4", "rsize=1048576", "readahead=8", "nobrowse", "noresvport", "actimeo=3",
        ].joined(separator: ",")
        guard run("/sbin/mount_nfs", ["-o", options, "127.0.0.1:/", folder.path]) == 0, isMounted(folder) else {
            throw CloudError("The cloud disk didn’t mount. Restart Reel Server.")
        }
    }

    static func unmount(_ folder: URL) {
        if isMounted(folder) { _ = run("/sbin/umount", ["-f", folder.path]) }
    }

    /// Reads the mount table without touching the folder, which would hang on a dead mount.
    static func isMounted(_ folder: URL) -> Bool {
        var table: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&table, MNT_NOWAIT)
        guard count > 0, let table else { return false }
        for index in 0..<Int(count) {
            var entry = table[index]
            let path = withUnsafeBytes(of: &entry.f_mntonname) {
                String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
            }
            if path == folder.path { return true }
        }
        return false
    }

    private static func run(_ tool: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}

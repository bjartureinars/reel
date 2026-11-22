import Foundation

/// Bytes of a film, from Google Drive or a download on the phone. Called from the engine's thread and blocks.
protocol FilmReader: AnyObject {
    var size: Int64 { get }
    func read(_ offset: Int64, into buffer: UnsafeMutablePointer<UInt8>, count: Int) -> Int
    func cancel()
}

/// Network figures for the bitrate panel.
final class Throughput: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [(Date, Int)] = []

    func add(_ bytes: Int) {
        lock.lock()
        samples.append((Date(), bytes))
        samples.removeAll { $0.0 < Date().addingTimeInterval(-10) }
        lock.unlock()
    }

    /// Over the last few seconds.
    var megabitsPerSecond: Double {
        lock.lock()
        defer { lock.unlock() }
        let cutoff = Date().addingTimeInterval(-5)
        let recent = samples.filter { $0.0 >= cutoff }
        return Double(recent.reduce(0) { $0 + $1.1 }) * 8 / 5 / 1_000_000
    }
}

/// Reads a film straight from Google Drive. Sequential reading fetches ahead in parallel 8 MB pieces;
/// a jump fetches only a small block, because seeking in a Blu-ray file means many small jumps.
final class DriveReader: FilmReader, @unchecked Sendable {
    private enum Chunk {
        case loading
        case ready(Data)
        case failed(Error, Date)
    }

    static let chunkSize: Int64 = 8 << 20
    private static let blockSize: Int64 = 512 << 10
    private static let readAhead: Int64 = 8
    private static let capacity = 28
    private static let deadline: TimeInterval = 45

    let size: Int64
    let throughput = Throughput()
    private let remote: RemoteFile
    private let drive: DriveClient
    private let condition = NSCondition()
    private var chunks: [Int64: Chunk] = [:]
    private var blocks: [(start: Int64, data: Data)] = []
    private var used: [Int64: UInt64] = [:]
    private var clock: UInt64 = 0
    private var lastEnd: Int64 = -1
    private var streak = 0
    private var cancelled = false

    init(remote: RemoteFile, size: Int64, drive: DriveClient) {
        self.remote = remote
        self.size = size
        self.drive = drive
    }

    func cancel() {
        condition.lock()
        cancelled = true
        condition.broadcast()
        condition.unlock()
    }

    func read(_ offset: Int64, into buffer: UnsafeMutablePointer<UInt8>, count: Int) -> Int {
        guard offset < size, count > 0 else { return 0 }
        let wanted = Int(min(Int64(count), size - offset))
        condition.lock()
        defer { condition.unlock() }
        streak = offset == lastEnd ? streak + 1 : 0
        lastEnd = offset + Int64(wanted)

        // Already here?
        if let block = blocks.first(where: { $0.start <= offset && offset + Int64(wanted) <= $0.start + Int64($0.data.count) }) {
            copy(block.data, from: Int(offset - block.start), wanted, to: buffer)
            return wanted
        }
        let index = offset / Self.chunkSize
        let sequential = streak >= 4 || chunks[index] != nil
        if !sequential {
            // A jump: fetch just enough to answer, and keep it in case reading carries on from here.
            let length = Int(min(max(Int64(wanted), Self.blockSize), size - offset))
            condition.unlock()
            let result = Result { try fetch(offset, length) }
            condition.lock()
            guard let data = try? result.get(), data.count >= wanted, !cancelled else { return -1 }
            blocks.append((offset, data))
            if blocks.count > 16 { blocks.removeFirst() }
            copy(data, from: 0, wanted, to: buffer)
            return wanted
        }

        // Fetch further ahead the longer reading stays sequential: a seek reads a few blocks in a row too,
        // and fetching 64 MB for each of those would starve the read that's actually waited for.
        let ahead = min(Self.readAhead, Int64(streak / 8))
        var done = 0
        while done < wanted {
            let at = offset + Int64(done)
            let index = at / Self.chunkSize
            load(index)
            if ahead > 0 { for step in 1...ahead { load(index + step) } }
            guard let data = waitFor(index) else { return done > 0 ? done : -1 }
            let start = Int(at - index * Self.chunkSize)
            let n = min(wanted - done, data.count - start)
            guard n > 0 else { return done > 0 ? done : -1 }
            copy(data, from: start, n, to: buffer + done)
            done += n
        }
        return done
    }

    private func copy(_ data: Data, from start: Int, _ count: Int, to buffer: UnsafeMutablePointer<UInt8>) {
        data.withUnsafeBytes { raw in
            buffer.update(from: raw.baseAddress!.assumingMemoryBound(to: UInt8.self) + start, count: count)
        }
    }

    private func fetch(_ offset: Int64, _ length: Int) throws -> Data {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Data, Error> = .failure(CancellationError())
        let task = Task.detached(priority: .userInitiated) { [drive, remote] in
            result = await Result { try await drive.read(remote, offset: offset, count: length, attempts: 4) }
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + Self.deadline) == .timedOut {
            task.cancel()
            throw URLError(.timedOut)
        }
        let data = try result.get()
        throughput.add(data.count)
        return data
    }

    /// With the lock held.
    private func load(_ index: Int64) {
        let start = index * Self.chunkSize
        guard start < size, !cancelled else { return }
        switch chunks[index] {
        case .loading, .ready: return
        case .failed(_, let when) where Date().timeIntervalSince(when) < 1: return
        default: break
        }
        chunks[index] = .loading
        touch(index)
        let length = Int(min(Self.chunkSize, size - start))
        Task.detached(priority: .userInitiated) { [weak self, drive, remote] in
            let chunk: Chunk
            do {
                let data = try await drive.read(remote, offset: start, count: length, attempts: 4)
                self?.throughput.add(data.count)
                chunk = .ready(data)
            } catch {
                chunk = .failed(error, Date())
            }
            self?.store(index, chunk)
        }
    }

    private func store(_ index: Int64, _ chunk: Chunk) {
        condition.lock()
        defer { condition.unlock() }
        chunks[index] = chunk
        touch(index)
        while chunks.count > Self.capacity {
            let idle = chunks.filter { if case .loading = $0.value { return false } else { return true } }
            guard let oldest = idle.keys.min(by: { used[$0, default: 0] < used[$1, default: 0] }) else { break }
            chunks[oldest] = nil
            used[oldest] = nil
        }
        condition.broadcast()
    }

    private func touch(_ index: Int64) {
        clock += 1
        used[index] = clock
    }

    /// With the lock held.
    private func waitFor(_ index: Int64) -> Data? {
        let limit = Date().addingTimeInterval(Self.deadline)
        while !cancelled {
            switch chunks[index] {
            case .ready(let data):
                touch(index)
                return data
            case .failed(let error, let when):
                let permanent = (error as? DriveError).map { !$0.isTransient } ?? (error as? CloudError)?.needsSignIn ?? false
                if permanent || Date() >= limit { return nil }
                if Date().timeIntervalSince(when) >= 1 { chunks[index] = nil; load(index) }
            case .loading:
                break
            case nil:
                load(index)
            }
            if Date() >= limit { return nil }
            _ = condition.wait(until: min(limit, Date().addingTimeInterval(0.5)))
        }
        return nil
    }
}

/// Reads a downloaded film: consecutive chunk files on the phone.
final class LocalReader: FilmReader, @unchecked Sendable {
    struct Part {
        let url: URL
        let offset: Int64
        let size: Int64
    }

    let size: Int64
    let throughput = Throughput()
    private let parts: [Part]
    private var handles: [Int: FileHandle] = [:]
    private let lock = NSLock()

    init(parts: [Part]) {
        self.parts = parts.sorted { $0.offset < $1.offset }
        size = parts.reduce(0) { $0 + $1.size }
    }

    func cancel() {}

    func read(_ offset: Int64, into buffer: UnsafeMutablePointer<UInt8>, count: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        var done = 0
        while done < count, offset + Int64(done) < size {
            let at = offset + Int64(done)
            guard let index = parts.lastIndex(where: { $0.offset <= at }) else { return -1 }
            let part = parts[index]
            if handles[index] == nil { handles[index] = try? FileHandle(forReadingFrom: part.url) }
            guard let handle = handles[index] else { return done > 0 ? done : -1 }
            let n = Int(min(Int64(count - done), part.offset + part.size - at))
            guard (try? handle.seek(toOffset: UInt64(at - part.offset))) != nil,
                  let data = try? handle.read(upToCount: n), !data.isEmpty else { return done > 0 ? done : -1 }
            data.withUnsafeBytes { buffer.advanced(by: done).update(from: $0.baseAddress!.assumingMemoryBound(to: UInt8.self), count: data.count) }
            done += data.count
        }
        return done
    }
}

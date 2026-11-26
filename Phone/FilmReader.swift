import Foundation

/// Reads a film straight from Google Drive.
final class DriveReader: RangeReader, @unchecked Sendable {
    init(remote: RemoteFile, size: Int64, drive: DriveClient) {
        super.init(size: size, isPermanent: { error in
            (error as? DriveError).map { !$0.isTransient } ?? (error as? CloudError)?.needsSignIn ?? false
        }, fetch: { offset, count in
            try await drive.read(remote, offset: offset, count: count, attempts: 4)
        })
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

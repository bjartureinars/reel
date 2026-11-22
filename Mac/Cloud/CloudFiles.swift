import CryptoKit
import Darwin
import Foundation

/// Identifies one exact version of a file on this Mac.
struct FileStamp: Codable, Equatable {
    let size: Int64
    let modifiedNanoseconds: Int64
    let inode: UInt64
    let device: Int32

    /// nil for anything that isn't a regular file. Symlinks are never followed, so they can never be deleted through.
    init?(path: String) {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        size = info.st_size
        modifiedNanoseconds = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
        inode = info.st_ino
        device = info.st_dev
    }

    var modified: Date { Date(timeIntervalSince1970: Double(modifiedNanoseconds) / 1_000_000_000) }
}

enum CloudFiles {
    static func read(_ path: String, offset: Int64, count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        var data = Data(count: count)
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            var got = 0
            while got < count {
                let n = pread(fd, raw.baseAddress! + got, count - got, offset + Int64(got))
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return false }
                got += n
            }
            return true
        }
        guard ok else { throw POSIXError(.EIO) }
        return data
    }

    /// Streams the whole file without filling the disk cache.
    static func md5(_ path: String, into initial: Insecure.MD5 = Insecure.MD5(),
                    progress: (Double) -> Void = { _ in }) throws -> Insecure.MD5 {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)
        let total = Double(max(lseek(fd, 0, SEEK_END), 1))
        lseek(fd, 0, SEEK_SET)
        var hasher = initial
        var buffer = [UInt8](repeating: 0, count: 8 << 20)
        var done = 0.0
        while true {
            try Task.checkCancellation()
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n < 0 && errno == EINTR { continue }
            if n < 0 { throw POSIXError(.EIO) }
            if n == 0 { return hasher }
            buffer.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[0..<n])) }
            done += Double(n)
            progress(done / total)
        }
    }

    /// The whole file's MD5 and each consecutive piece's, from a single read.
    static func digests(_ path: String, pieces: [Int64],
                        progress: (Double) -> Void = { _ in }) throws -> (whole: String, pieces: [String]) {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)
        let total = pieces.reduce(0, +)
        guard lseek(fd, 0, SEEK_END) == total else { throw CloudError("The file’s size changed.") }
        lseek(fd, 0, SEEK_SET)
        var whole = Insecure.MD5()
        var hashes: [String] = []
        var buffer = [UInt8](repeating: 0, count: 8 << 20)
        var done: Int64 = 0
        for size in pieces {
            var piece = Insecure.MD5()
            var left = size
            while left > 0 {
                try Task.checkCancellation()
                let wanted = Int(min(left, Int64(buffer.count)))
                let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, wanted) }
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw POSIXError(.EIO) }
                buffer.withUnsafeBytes {
                    let bytes = UnsafeRawBufferPointer(rebasing: $0[0..<n])
                    whole.update(bufferPointer: bytes)
                    piece.update(bufferPointer: bytes)
                }
                left -= Int64(n)
                done += Int64(n)
                progress(Double(done) / Double(max(total, 1)))
            }
            hashes.append(hex(piece))
        }
        return (hex(whole), hashes)
    }

    static func hex(_ hasher: Insecure.MD5) -> String {
        hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Really free bytes. Deliberately ignores "purgeable" space, which can't be counted on.
    static func freeSpace(at url: URL) -> Int64 {
        var info = statfs()
        guard statfs(url.path, &info) == 0 else { return 0 }
        return Int64(info.f_bavail) * Int64(info.f_bsize)
    }

    /// True while another process is still writing the file (Finder copy, browser download).
    static func isBeingWritten(_ url: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-F", "a", "--", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return true } // can't tell, so wait
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return output.split(separator: "\n").contains { $0 == "aw" || $0 == "au" }
    }

    /// Megabits of picture in each second of the film, from the real packet sizes.
    static func measureBitrate(of path: String, ffprobe: URL) throws -> [Double] {
        let process = Process()
        process.executableURL = ffprobe
        process.arguments = ["-v", "error", "-select_streams", "v:0", "-show_entries", "packet=pts_time,dts_time,size",
                             "-of", "compact=p=0", "file:" + path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CloudError("ffprobe couldn’t read the film.") }

        var bytes: [Int] = []
        for line in output.split(separator: "\n") {
            var pts: Double?, dts: Double?, size: Int?
            for field in line.split(separator: "|") {
                let pair = field.split(separator: "=", maxSplits: 1)
                guard pair.count == 2 else { continue }
                switch pair[0] {
                case "pts_time": pts = Double(pair[1])
                case "dts_time": dts = Double(pair[1])
                case "size": size = Int(pair[1])
                default: break
                }
            }
            guard let time = pts ?? dts, let size, time >= 0, time < 86_400 else { continue }
            let second = Int(time)
            if second >= bytes.count { bytes += Array(repeating: 0, count: second - bytes.count + 1) }
            bytes[second] += size
        }
        return bytes.map { (Double($0) * 8 / 100_000).rounded() / 10 }
    }
}

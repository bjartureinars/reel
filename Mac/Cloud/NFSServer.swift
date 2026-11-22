import Darwin
import Foundation

/// One read-only file shown on the Reel cloud disk.
struct DiskFile: Equatable {
    /// Stable for the life of the film (it becomes the NFS handle and inode number).
    let id: UInt64
    let folder: String
    let name: String
    let size: Int64
    let modified: Date
}

/// Supplies the cloud disk's contents. Called from many threads at once; `read` may block.
protocol DiskSource: AnyObject {
    func files() -> [DiskFile]
    func read(_ file: DiskFile, offset: Int64, count: Int) throws -> Data
}

/// A minimal read-only NFSv3 server on 127.0.0.1, mounted with the NFS client built into macOS.
///
/// Why a disk and not URLs: Jellyfin only throttles remuxes (and reads MKV keyframes for exact seeking)
/// when the input is a file. With a URL it would write a 50 GB remux to disk as fast as Google delivers it.
/// This needs no kernel extension, no admin rights and no third-party software.
final class NFSServer {
    private let source: DiskSource
    private let folders: [String]
    private let started = Date()
    private var listener: Int32 = -1
    private(set) var port: UInt16 = 0

    private static let rootID: UInt64 = 1
    private static let mountProgram: UInt32 = 100_005
    private static let nfsProgram: UInt32 = 100_003
    private static let maxRead = 1_048_576

    private enum Status: UInt32 {
        case ok = 0, noEntry = 2, io = 5, notDirectory = 20, isDirectory = 21, readOnly = 30, stale = 70
    }

    private enum Node {
        case root
        case folder(Int)
        case file(DiskFile)
    }

    init(source: DiskSource, folders: [String]) {
        self.source = source
        self.folders = folders
    }

    // MARK: Lifecycle

    func start() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1") // never reachable from the network
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length) == 0 && listen(fd, 8) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        guard ok else { close(fd); throw POSIXError(.EADDRNOTAVAIL) }
        listener = fd
        port = UInt16(bigEndian: address.sin_port)
        Thread.detachNewThread { [self] in
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 {
                    if errno == EINTR || errno == ECONNABORTED { continue }
                    return
                }
                Thread.detachNewThread { [self] in serve(client) }
            }
        }
    }

    func stop() {
        guard listener >= 0 else { return }
        shutdown(listener, SHUT_RDWR)
        close(listener)
        listener = -1
    }

    // MARK: Connection

    private final class Connection {
        let fd: Int32
        private let lock = NSLock()
        private let slots = DispatchSemaphore(value: 32)
        private let queue = DispatchQueue(label: "reel.nfs", qos: .userInitiated, attributes: .concurrent)
        private let pending = DispatchGroup()

        init(fd: Int32) {
            self.fd = fd
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
        }

        /// Requests run concurrently: one slow read from Google mustn't stall a directory listing.
        func perform(_ work: @escaping () -> Void) {
            slots.wait()
            queue.async(group: pending) { [slots] in
                work()
                slots.signal()
            }
        }

        func send(_ payload: Data) {
            var header = UInt32(0x8000_0000 | UInt32(payload.count)).bigEndian
            var packet = Data(bytes: &header, count: 4)
            packet.append(payload)
            lock.lock()
            defer { lock.unlock() }
            packet.withUnsafeBytes { raw in
                var sent = 0
                while sent < raw.count {
                    let n = Darwin.write(fd, raw.baseAddress! + sent, raw.count - sent)
                    if n < 0 && errno == EINTR { continue }
                    if n <= 0 { return }
                    sent += n
                }
            }
        }

        func receive(_ count: Int) -> Data? {
            var data = Data(count: count)
            let ok = data.withUnsafeMutableBytes { raw -> Bool in
                var got = 0
                while got < count {
                    let n = Darwin.read(fd, raw.baseAddress! + got, count - got)
                    if n < 0 && errno == EINTR { continue }
                    if n <= 0 { return false }
                    got += n
                }
                return true
            }
            return ok ? data : nil
        }

        func finish() {
            pending.wait()
            close(fd)
        }
    }

    private func serve(_ fd: Int32) {
        let connection = Connection(fd: fd)
        defer { connection.finish() }
        var record = Data()
        while let header = connection.receive(4) {
            let mark = header.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            let size = Int(mark & 0x7fff_ffff)
            guard size > 0, record.count + size <= 4 * Self.maxRead, let body = connection.receive(size) else { return }
            record.append(body)
            guard mark & 0x8000_0000 != 0 else { continue }
            let request = record
            record = Data()
            connection.perform { [self] in
                if let reply = handle(request) { connection.send(reply) }
            }
        }
    }

    // MARK: RPC

    private func handle(_ request: Data) -> Data? {
        var input = XDRReader(request)
        guard let xid = input.u32(), input.u32() == 0, input.u32() == 2,
              let program = input.u32(), let version = input.u32(), let procedure = input.u32(),
              input.u32() != nil, input.opaque() != nil,    // credentials
              input.u32() != nil, input.opaque() != nil     // verifier
        else { return nil }

        var out = XDRWriter()
        out.u32(xid)
        out.u32(1)  // reply
        out.u32(0)  // accepted
        out.u32(0); out.u32(0)  // empty verifier

        var body = XDRWriter()
        let understood: Bool
        switch (program, version) {
        case (Self.mountProgram, 3): understood = mount(procedure, &body)
        case (Self.nfsProgram, 3): understood = nfs(procedure, &input, &body)
        default:
            out.u32(1)  // program unavailable
            return out.data
        }
        out.u32(understood ? 0 : 3)
        if understood { out.data.append(body.data) }
        return out.data
    }

    private func mount(_ procedure: UInt32, _ out: inout XDRWriter) -> Bool {
        switch procedure {
        case 0, 3, 4: return true
        case 1:
            out.u32(0)
            out.handle(Self.rootID)
            out.u32(1); out.u32(1)  // one auth flavour: AUTH_SYS
            return true
        case 2, 5:
            out.bool(false)
            return true
        default: return false
        }
    }

    private func node(_ id: UInt64) -> Node? {
        if id == Self.rootID { return .root }
        if id >= 2, id < UInt64(2 + folders.count) { return .folder(Int(id - 2)) }
        return source.files().first { $0.id == id }.map(Node.file)
    }

    private func children(of id: UInt64, _ node: Node) -> [(name: String, id: UInt64, node: Node)]? {
        switch node {
        case .file: return nil
        case .root:
            return [(".", id, node), ("..", id, node)]
                + folders.enumerated().map { ($0.element, UInt64(2 + $0.offset), Node.folder($0.offset)) }
        case .folder(let index):
            return [(".", id, node), ("..", Self.rootID, Node.root)]
                + source.files().filter { $0.folder == folders[index] }
                    .sorted { $0.id < $1.id }
                    .map { ($0.name, $0.id, Node.file($0)) }
        }
    }

    private func attributes(_ id: UInt64, _ node: Node, _ out: inout XDRWriter) {
        let size: Int64, modified: Date
        switch node {
        case .file(let file):
            out.u32(1); out.u32(0o444); out.u32(1)
            size = file.size
            modified = file.modified
        case .root, .folder:
            out.u32(2); out.u32(0o555); out.u32(2)
            size = 4096
            // A changing mtime makes the client notice added and removed films.
            modified = source.files().map(\.modified).max() ?? started
        }
        out.u32(getuid()); out.u32(getgid())
        out.u64(UInt64(size)); out.u64(0)   // takes no space on this Mac
        out.u32(0); out.u32(0)
        out.u64(0x5245_454C)
        out.u64(id)
        for _ in 0..<3 { out.time(modified) }
    }

    private func optionalAttributes(_ id: UInt64, _ node: Node?, _ out: inout XDRWriter) {
        out.bool(node != nil)
        if let node { attributes(id, node, &out) }
    }

    private func noChanges(_ out: inout XDRWriter) {
        out.bool(false); out.bool(false)
    }

    private func nfs(_ procedure: UInt32, _ input: inout XDRReader, _ out: inout XDRWriter) -> Bool {
        if procedure == 0 { return true }
        switch procedure {
        case 2, 7...13, 21:   // anything that writes
            out.u32(Status.readOnly.rawValue); noChanges(&out)
            return true
        case 14:
            out.u32(Status.readOnly.rawValue); noChanges(&out); noChanges(&out)
            return true
        case 15:
            out.u32(Status.readOnly.rawValue); out.bool(false); noChanges(&out)
            return true
        default: break
        }

        guard let id = input.handle() else { return false }
        guard let node = node(id) else {
            out.u32(Status.stale.rawValue)
            if procedure != 1 { out.bool(false) }
            return true
        }

        switch procedure {
        case 1: // GETATTR
            out.u32(0)
            attributes(id, node, &out)

        case 3: // LOOKUP
            guard let raw = input.opaque(), let name = String(data: raw, encoding: .utf8) else { return false }
            guard let entries = children(of: id, node) else {
                out.u32(Status.notDirectory.rawValue); out.bool(false)
                return true
            }
            let wanted = name.precomposedStringWithCanonicalMapping
            if let found = entries.first(where: { $0.name.precomposedStringWithCanonicalMapping == wanted }) {
                out.u32(0)
                out.handle(found.id)
                optionalAttributes(found.id, found.node, &out)
            } else {
                out.u32(Status.noEntry.rawValue)
            }
            optionalAttributes(id, node, &out)

        case 4: // ACCESS: read, look up and execute (search) only
            guard let wanted = input.u32() else { return false }
            out.u32(0)
            optionalAttributes(id, node, &out)
            out.u32(wanted & 0x23)

        case 5: // READLINK
            out.u32(Status.io.rawValue)
            optionalAttributes(id, node, &out)

        case 6: // READ
            guard let offset = input.u64(), let count = input.u32() else { return false }
            guard case .file(let file) = node else {
                out.u32(Status.isDirectory.rawValue); out.bool(false)
                return true
            }
            let start = Int64(clamping: offset)
            let wanted = Int(min(max(0, file.size - start), Int64(min(Int(count), Self.maxRead))))
            do {
                let data = wanted > 0 ? try source.read(file, offset: start, count: wanted) : Data()
                // A short read would look like end-of-file to ffmpeg and end the film early.
                guard data.count == wanted else { throw POSIXError(.EIO) }
                out.u32(0)
                optionalAttributes(id, node, &out)
                out.u32(UInt32(data.count))
                out.bool(start + Int64(data.count) >= file.size)
                out.opaque(data)
            } catch {
                out.u32(Status.io.rawValue)
                optionalAttributes(id, node, &out)
            }

        case 16, 17: // READDIR, READDIRPLUS
            guard let cookie = input.u64(), input.u64() != nil, let first = input.u32() else { return false }
            let plus = procedure == 17
            guard let limit = plus ? input.u32() : first else { return false }
            guard let entries = children(of: id, node) else {
                out.u32(Status.notDirectory.rawValue); out.bool(false)
                return true
            }
            out.u32(0)
            optionalAttributes(id, node, &out)
            out.u64(0)
            var index = Int(min(cookie, UInt64(entries.count)))
            while index < entries.count {
                let entry = entries[index]
                var item = XDRWriter()
                item.bool(true)
                item.u64(entry.id)
                item.opaque(Data(entry.name.utf8))
                item.u64(UInt64(index + 1))
                if plus {
                    optionalAttributes(entry.id, entry.node, &item)
                    item.bool(true)
                    item.handle(entry.id)
                }
                if out.data.count + item.data.count + 16 > Int(limit) { break }
                out.data.append(item.data)
                index += 1
            }
            out.bool(false)
            out.bool(index >= entries.count)

        case 18: // FSSTAT
            out.u32(0)
            optionalAttributes(id, node, &out)
            let used = UInt64(source.files().reduce(0) { $0 + $1.size })
            out.u64(used + (1 << 40)); out.u64(1 << 40); out.u64(1 << 40)
            out.u64(1_000_000); out.u64(900_000); out.u64(900_000)
            out.u32(0)

        case 19: // FSINFO
            out.u32(0)
            optionalAttributes(id, node, &out)
            let max = UInt32(Self.maxRead)
            out.u32(max); out.u32(max); out.u32(4096)
            out.u32(max); out.u32(max); out.u32(4096)
            out.u32(65536)
            out.u64(1 << 62)
            out.u32(1); out.u32(0)
            out.u32(0x08)

        case 20: // PATHCONF
            out.u32(0)
            optionalAttributes(id, node, &out)
            out.u32(1); out.u32(255)
            out.bool(true); out.bool(true); out.bool(false); out.bool(true)

        default: return false
        }
        return true
    }
}

// MARK: - XDR

private struct XDRReader {
    private let bytes: [UInt8]
    private var position = 0

    init(_ data: Data) { bytes = [UInt8](data) }

    mutating func u32() -> UInt32? {
        guard position + 4 <= bytes.count else { return nil }
        defer { position += 4 }
        return bytes[position..<position + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }

    mutating func u64() -> UInt64? {
        guard let high = u32(), let low = u32() else { return nil }
        return UInt64(high) << 32 | UInt64(low)
    }

    mutating func opaque() -> Data? {
        guard let length = u32().map(Int.init) else { return nil }
        let padded = (length + 3) & ~3
        guard position + padded <= bytes.count else { return nil }
        defer { position += padded }
        return Data(bytes[position..<position + length])
    }

    mutating func handle() -> UInt64? {
        guard let data = opaque(), data.count == 8 else { return nil }
        return data.reduce(0) { $0 << 8 | UInt64($1) }
    }
}

private struct XDRWriter {
    var data = Data()

    mutating func u32(_ value: UInt32) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    mutating func u64(_ value: UInt64) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    mutating func bool(_ value: Bool) { u32(value ? 1 : 0) }

    mutating func opaque(_ value: Data) {
        u32(UInt32(value.count))
        data.append(value)
        let padding = (4 - value.count % 4) % 4
        if padding > 0 { data.append(Data(count: padding)) }
    }

    mutating func handle(_ id: UInt64) {
        u32(8)
        u64(id)
    }

    mutating func time(_ date: Date) {
        u32(UInt32(clamping: Int64(date.timeIntervalSince1970)))
        u32(0)
    }
}

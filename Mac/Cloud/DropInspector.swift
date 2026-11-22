import Darwin
import Foundation

/// Something in the drop folder that is waiting for an OK. It isn't in the library and is never uploaded or deleted.
struct PendingFilm: Identifiable, Equatable {
    enum State: Equatable {
        /// May pass by itself: still settling or being checked.
        case waiting(String)
        case blocked(String)
        case ready
    }

    let path: String
    let stamp: FileStamp?
    let folder: String
    let name: String
    let size: Int64
    var state: State

    var id: String { path }
}

/// Works out what in the drop folder is a film, and whether it looks finished. Only ever reads.
///
/// A file that has stopped changing isn't necessarily finished: download apps create files at full size, fill them
/// in out of order, close them between writes and can pause for hours. Hence the OK, and these checks before it.
enum DropInspector {
    private static let extensions: Set<String> =
        ["mkv", "mp4", "m4v", "mov", "avi", "ts", "m2ts", "mts", "webm", "wmv", "mpg", "mpeg"]
    private static let unfinishedSuffixes =
        [".part", ".!ut", ".!qb", ".!bt", ".aria2", ".crdownload", ".download", ".reelpart"]

    static func scan(_ root: URL) -> [PendingFilm] {
        guard let names = FileManager.default.enumerator(atPath: root.path) else { return [] }
        var files: [String] = []
        var discs = Set<String>()
        var unfinished: [String] = []

        for case let relative as String in names {
            let base = (relative as NSString).lastPathComponent
            let isFolder = names.fileAttributes?[.type] as? FileAttributeType == .typeDirectory
            if base.hasPrefix(".") {
                if isFolder { names.skipDescendants() }
                continue
            }
            if unfinishedSuffixes.contains(where: { base.lowercased().hasSuffix($0) }) { unfinished.append(relative) }
            let parts = relative.split(separator: "/").map(String.init)
            // Under Home Videos, BDMV is how camcorders store separate recordings, so it isn't one film.
            if folder(of: relative) == "Films", let index = parts.firstIndex(where: { $0.lowercased() == "bdmv" }),
               isFolder || index < parts.count - 1 {
                discs.insert(parts[..<index].joined(separator: "/"))
                continue
            }
            if !isFolder, extensions.contains((relative as NSString).pathExtension.lowercased()) { files.append(relative) }
        }

        func isInside(_ relative: String, _ disc: String) -> Bool {
            disc.isEmpty ? relative.lowercased().hasPrefix("bdmv/") : relative.hasPrefix(disc + "/")
        }

        var found: [PendingFilm] = []
        for relative in files.sorted() where !discs.contains(where: { isInside(relative, $0) }) {
            let path = root.appendingPathComponent(relative).path
            guard let stamp = FileStamp(path: path) else { continue } // symlinks are never followed
            let name = (relative as NSString).lastPathComponent
            let home = folder(of: relative)
            var problem: String?
            if home == "Films", name.range(of: #"^\d{5}( \(\d+\))?\.(m2ts|mts)$"#,
                                           options: [.regularExpression, .caseInsensitive]) != nil {
                problem = "This is a numbered piece of a Blu-ray. Put the whole disc folder here, or give the file the film’s name."
            } else if unfinished.contains(where: { $0.hasPrefix(relative + ".") || relative.hasPrefix($0 + "/") }) {
                problem = "A download app marks this as unfinished."
            } else {
                problem = emptyOrSparse(path, size: stamp.size)
            }
            found.append(PendingFilm(path: path, stamp: stamp, folder: home, name: name, size: stamp.size,
                                     state: problem.map { .blocked($0) } ?? .ready))
        }
        for disc in discs.sorted() {
            let marked = unfinished.contains { isInside($0, disc) }
            found.append(film(onDisc: disc, in: root, marked: marked))
        }
        return found
    }

    private static func folder(of relative: String) -> String {
        let first = relative.split(separator: "/").first.map(String.init) ?? ""
        return first.caseInsensitiveCompare("Home Videos") == .orderedSame ? "Home Videos" : "Films"
    }

    private static func emptyOrSparse(_ path: String, size: Int64) -> String? {
        guard size > 0 else { return "The file is empty." }
        var info = stat()
        guard lstat(path, &info) == 0 else { return "Reel can’t read this file." }
        let compressed = info.st_flags & UInt32(UF_COMPRESSED) != 0
        if !compressed, Int64(info.st_blocks) * 512 < size { return "It isn’t finished: parts of the file are still empty." }
        return nil
    }

    // MARK: Blu-ray folders

    /// A disc is one film: its biggest clip, by the sizes in the disc's own index. Going by the files present
    /// would promote an extra whenever the film itself is missing, still downloading or already uploaded.
    private static func film(onDisc disc: String, in root: URL, marked: Bool) -> PendingFilm {
        let home = disc.isEmpty ? root : root.appendingPathComponent(disc)
        let bdmv = home.appendingPathComponent("BDMV")
        let title = self.title(disc.isEmpty ? "Blu-ray Film" : home.lastPathComponent)

        func blocked(_ reason: String, size: Int64 = 0) -> PendingFilm {
            PendingFilm(path: home.path, stamp: nil, folder: "Films", name: title, size: size, state: .blocked(reason))
        }

        let sizes = declaredSizes(bdmv.appendingPathComponent("CLIPINF"))
        guard let main = sizes.max(by: { $0.value < $1.value }), main.value > 0 else {
            return blocked("The disc’s index is missing or unfinished, so Reel can’t tell which clip is the film.")
        }
        let playlists = playlists(bdmv.appendingPathComponent("PLAYLIST"))
        guard playlists.contains(where: { $0.contains(main.key) }) else {
            return blocked("The disc’s playlists are missing or unfinished, so Reel can’t tell which clip is the film.")
        }
        let longest = playlists.map { Set($0).reduce(Int64(0)) { $0 + (sizes[$1] ?? 0) } }.max() ?? 0
        guard Double(longest) <= Double(main.value) * 1.15 else {
            return blocked("This disc splits the film across several clips, which Reel can’t join.")
        }
        let file = bdmv.appendingPathComponent("STREAM/\(main.key).m2ts")
        guard let stamp = FileStamp(path: file.path) else {
            return blocked("The film itself isn’t in this disc folder. Reel won’t upload the menus and extras.", size: main.value)
        }

        var problem: String?
        if marked {
            problem = "A download app marks part of this disc as unfinished."
        } else if stamp.size != main.value {
            problem = "It isn’t finished: the disc says the film is \(main.value.formatted(.byteCount(style: .file))), and the file is \(stamp.size.formatted(.byteCount(style: .file)))."
        } else {
            problem = emptyOrSparse(file.path, size: stamp.size)
        }
        return PendingFilm(path: file.path, stamp: stamp, folder: "Films", name: title + ".m2ts", size: stamp.size,
                           state: problem.map { .blocked($0) } ?? .ready)
    }

    /// Each clip's exact size: its count of 192-byte packets from the .clpi index.
    private static func declaredSizes(_ folder: URL) -> [String: Int64] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var sizes: [String: Int64] = [:]
        for file in files where file.pathExtension.lowercased() == "clpi" {
            guard let bytes = (try? Data(contentsOf: file)).map({ [UInt8]($0) }), bytes.count >= 60,
                  bytes.starts(with: Array("HDMV".utf8)) else { continue }
            sizes[file.deletingPathExtension().lastPathComponent] = Int64(number(bytes, at: 56, length: 4)) * 192
        }
        return sizes
    }

    /// The clips in each .mpls playlist.
    private static func playlists(_ folder: URL) -> [[String]] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { file -> [String]? in
            guard file.pathExtension.lowercased() == "mpls", let bytes = (try? Data(contentsOf: file)).map({ [UInt8]($0) }),
                  bytes.count >= 12, bytes.starts(with: Array("MPLS".utf8)) else { return nil }
            let start = number(bytes, at: 8, length: 4)
            guard start + 10 <= bytes.count else { return nil }
            var at = start + 10
            var clips: [String] = []
            for _ in 0..<number(bytes, at: start + 6, length: 2) {
                guard at + 7 <= bytes.count else { return nil }
                clips.append(String(decoding: bytes[(at + 2)..<(at + 7)], as: UTF8.self))
                at += 2 + number(bytes, at: at, length: 2)
            }
            return clips
        }
    }

    private static func number(_ bytes: [UInt8], at index: Int, length: Int) -> Int {
        bytes[index..<(index + length)].reduce(0) { $0 << 8 | Int($1) }
    }

    /// "Skyfall.2012.1080p.BluRay…" becomes "Skyfall (2012)", which Jellyfin looks up correctly.
    static func title(_ folder: String) -> String {
        let text = folder.replacingOccurrences(of: "[._]", with: " ", options: .regularExpression)
        guard let expression = try? NSRegularExpression(pattern: #"^(.+)[ \-(\[]((?:19|20)\d\d)(?=[ \-)\]]|$)"#),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let name = Range(match.range(at: 1), in: text), let year = Range(match.range(at: 2), in: text) else {
            return text
        }
        return "\(text[name].trimmingCharacters(in: CharacterSet(charactersIn: " -([")) ) (\(text[year]))"
    }

    // MARK: Gaps

    /// Reads the whole file looking for stretches that were never filled in. nil means none were found.
    static func gap(in path: String, progress: (Double) -> Void = { _ in }) throws -> String? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)
        let total = lseek(fd, 0, SEEK_END)
        guard total > 0 else { return "The file is empty." }

        let block = 64 << 10
        // Transport streams never have 64 KB of zeros. Other containers can reserve a little blank space.
        let transport = ["ts", "m2ts", "mts"].contains((path as NSString).pathExtension.lowercased())
        let limit = transport ? 1 : 16
        var buffer = [UInt8](repeating: 0, count: 4 << 20)
        var offset: Int64 = 0
        var run = 0
        while offset < total {
            try Task.checkCancellation()
            let wanted = Int(min(Int64(buffer.count), total - offset))
            var found: String?
            try buffer.withUnsafeMutableBytes { raw in
                let base = raw.baseAddress!
                var got = 0
                while got < wanted {
                    let n = pread(fd, base + got, wanted - got, offset + Int64(got))
                    if n < 0 && errno == EINTR { continue }
                    guard n > 0 else { throw POSIXError(.EIO) }
                    got += n
                }
                if offset == 0, isZero(base, min(wanted, 4096)) {
                    found = "It isn’t finished: the start of the file is still empty."
                    return
                }
                if offset + Int64(wanted) == total {
                    let tail = min(wanted, block)
                    if isZero(base + wanted - tail, tail) {
                        found = "It isn’t finished: the end of the file is still empty."
                        return
                    }
                }
                var at = 0
                while at < wanted {
                    let length = min(block, wanted - at)
                    run = length == block && isZero(base + at, length) ? run + 1 : 0
                    if run >= limit {
                        let percent = Int(Double(offset + Int64(at)) / Double(total) * 100)
                        found = "It isn’t finished: there’s an empty gap \(percent)% of the way through."
                        return
                    }
                    at += length
                }
            }
            if let found { return found }
            offset += Int64(wanted)
            progress(Double(offset) / Double(total))
        }
        return nil
    }

    private static func isZero(_ start: UnsafeMutableRawPointer, _ count: Int) -> Bool {
        guard count > 0, start.load(as: UInt8.self) == 0 else { return false }
        return count == 1 || memcmp(start, start + 1, count - 1) == 0
    }
}

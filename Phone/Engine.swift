import CoreGraphics
import Foundation
import Network

/// A track the film has, as Reel shows it.
struct Track: Identifiable, Hashable {
    let id: Int
    let kind: ReelKind
    let name: String
    let detail: String
    let language: String?
    let isDefault: Bool
    let isForced: Bool
    let isCommentary: Bool
    let playable: Bool
    let untouched: Bool
    let lossless: Bool
    let range: ReelRange
    let width: Int
    let height: Int
    let channels: Int
    let codec: String
    let frameRate: Double
}

/// One subtitle change, kept in Swift memory.
struct Cue {
    let start: Double
    let end: Double?
    let text: String?
    let image: CGImage?
    let frame: CGRect      // in canvas pixels
    let canvas: CGSize
}

/// Collects subtitle cues as the engine meets them.
final class CueStore: @unchecked Sendable {
    private let lock = NSLock()
    private var cues: [Cue] = []

    func add(_ cue: Cue, continues: Bool) {
        lock.lock()
        defer { lock.unlock() }
        // A repeat after a seek replaces what was there.
        if !continues { cues.removeAll { abs($0.start - cue.start) < 0.01 } }
        cues.append(cue)
        cues.sort { $0.start < $1.start }
        if cues.count > 4000 { cues.removeFirst(cues.count - 4000) }
    }

    func clear() {
        lock.lock()
        cues = []
        lock.unlock()
    }

    /// The rectangles of the cue on screen at `time`.
    func showing(at time: Double) -> [Cue] {
        lock.lock()
        defer { lock.unlock() }
        guard let last = cues.lastIndex(where: { $0.start <= time + 0.02 }) else { return [] }
        let start = cues[last].start
        let group = cues.filter { abs($0.start - start) < 0.01 && ($0.image != nil || $0.text != nil) }
        return group.filter { cue in cue.end.map { time < $0 } ?? true }
    }
}

/// The phone's engine wrapped for Swift. Not thread-safe: `Playback` uses it from one queue.
final class EngineMedia {
    private let pointer: OpaquePointer
    let reader: FilmReader
    private let readerBox: Unmanaged<ReaderBox>
    let duration: Double
    let tracks: [Track]
    let cues = CueStore()

    private final class ReaderBox {
        let reader: FilmReader
        init(_ reader: FilmReader) { self.reader = reader }
    }

    init(reader: FilmReader, languages: [String: String]) throws {
        self.reader = reader
        let box = Unmanaged.passRetained(ReaderBox(reader))
        readerBox = box
        var error: Int32 = 0
        let read: ReelRead = { context, offset, buffer, length in
            let reader = Unmanaged<ReaderBox>.fromOpaque(context!).takeUnretainedValue().reader
            return Int32(reader.read(offset, into: buffer!, count: Int(length)))
        }
        guard let media = reel_open(read, box.toOpaque(), reader.size, &error) else {
            box.release()
            throw EngineError(code: error)
        }
        pointer = media
        duration = reel_duration(media)
        var found: [Track] = []
        var soundNumber = 0, subtitleNumber = 0
        for index in 0..<reel_stream_count(media) {
            var s = ReelStream()
            guard reel_stream(media, index, &s) else { continue }
            let codec = Self.text(&s.codec)
            let profile = Self.text(&s.profile)
            var language = Self.text(&s.language).nilIfEmpty
            if language == nil || language == "und", s.pid > 0 { language = languages[String(s.pid)] }
            let title = Self.text(&s.title).nilIfEmpty
            let languageName = language.flatMap { Locale.current.localizedString(forLanguageCode: $0) }
            let name: String
            var detail = ""
            switch s.kind {
            case ReelKindAudio:
                soundNumber += 1
                detail = Self.soundFormat(codec, profile, Int(s.channels))
                name = [languageName, title.flatMap { $0.localizedCaseInsensitiveContains(detail) ? nil : $0 }]
                    .compactMap { $0 }.joined(separator: " – ").nilIfEmpty ?? "Sound \(soundNumber)"
            case ReelKindSubtitle:
                subtitleNumber += 1
                name = [languageName, title.flatMap { $0 == languageName ? nil : $0 }].compactMap { $0 }
                    .joined(separator: " – ").nilIfEmpty ?? "Subtitles \(subtitleNumber)"
                detail = s.isForced ? "Forced" : ""
            default:
                name = codec.uppercased()
            }
            found.append(Track(id: Int(s.index), kind: s.kind, name: name, detail: detail, language: language,
                               isDefault: s.isDefault, isForced: s.isForced, isCommentary: s.isCommentary,
                               playable: s.playable, untouched: s.untouched, lossless: s.lossless, range: s.range,
                               width: Int(s.width), height: Int(s.height), channels: Int(s.channels), codec: codec,
                               frameRate: s.frameRate))
        }
        tracks = found
    }

    deinit {
        reel_close(pointer)
        readerBox.release()
    }

    var video: Track? { tracks.first { $0.kind == ReelKindVideo } }
    var sounds: [Track] { tracks.filter { $0.kind == ReelKindAudio && $0.playable } }
    var subtitles: [Track] { tracks.filter { $0.kind == ReelKindSubtitle && $0.playable } }

    /// The default sound: the film's own choice unless it's commentary, else the first that isn't.
    var defaultSound: Track? {
        sounds.first { $0.isDefault && !$0.isCommentary } ?? sounds.first { !$0.isCommentary } ?? sounds.first
    }

    func cancel() {
        reel_cancel(pointer)
        reader.cancel()
    }

    func select(sound: Int?, subtitles: Int?) throws {
        cues.clear()
        let context = Unmanaged.passUnretained(cues).toOpaque()
        let handler: ReelCueHandler = { context, cue in
            guard let context, let cue else { return }
            let store = Unmanaged<CueStore>.fromOpaque(context).takeUnretainedValue()
            let c = cue.pointee
            var image: CGImage?
            if let rgba = c.rgba, c.width > 0, c.height > 0 {
                let data = Data(bytes: rgba, count: Int(c.width * c.height * 4))
                if let provider = CGDataProvider(data: data as CFData) {
                    image = CGImage(width: Int(c.width), height: Int(c.height), bitsPerComponent: 8, bitsPerPixel: 32,
                                    bytesPerRow: Int(c.width) * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
                }
            }
            let text = c.text.map { EngineMedia.plainText(String(cString: $0)) }
            store.add(Cue(start: c.start, end: c.end >= 0 ? c.end : nil, text: text, image: image,
                          frame: CGRect(x: Int(c.x), y: Int(c.y), width: Int(c.width), height: Int(c.height)),
                          canvas: CGSize(width: Int(c.canvasWidth), height: Int(c.canvasHeight))), continues: c.continues)
        }
        let result = reel_select(pointer, Int32(sound ?? -1), Int32(subtitles ?? -1), handler, context)
        if result < 0 { throw EngineError(code: result) }
    }

    var segmentCount: Int { Int(reel_segment_count(pointer)) }
    func segmentDuration(_ index: Int) -> Double { reel_segment_duration(pointer, Int32(index)) }

    func segment(_ index: Int, wantInit: Bool) throws -> (initial: Data?, data: Data, info: ReelSegmentInfo) {
        var initPointer: UnsafeMutablePointer<UInt8>?
        var dataPointer: UnsafeMutablePointer<UInt8>?
        var initSize: Int32 = 0, dataSize: Int32 = 0
        var info = ReelSegmentInfo()
        let result = withUnsafeMutablePointer(to: &initPointer) { initOut in
            reel_segment(pointer, Int32(index), wantInit ? initOut : nil, &initSize, &dataPointer, &dataSize, &info)
        }
        if result < 0 { throw EngineError(code: result) }
        defer {
            reel_free(initPointer)
            reel_free(dataPointer)
        }
        let initial = initPointer.map { Data(bytes: $0, count: Int(initSize)) }
        return (initial, Data(bytes: dataPointer!, count: Int(dataSize)), info)
    }

    private static func text<T>(_ tuple: inout T) -> String {
        withUnsafeBytes(of: &tuple) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    static func soundFormat(_ codec: String, _ profile: String, _ channels: Int) -> String {
        let layout: String
        switch channels {
        case 1: layout = "Mono"
        case 2: layout = "Stereo"
        case 6: layout = "5.1"
        case 8: layout = "7.1"
        default: layout = "\(channels) ch"
        }
        let name: String
        switch codec {
        case "dts": name = profile.isEmpty ? "DTS" : profile
        case "truehd": name = "Dolby TrueHD"
        case "ac3": name = "Dolby Digital"
        case "eac3": name = "Dolby Digital Plus"
        case "aac": name = "AAC"
        case "flac": name = "FLAC"
        case "alac": name = "Apple Lossless"
        case "pcm_bluray", "pcm_s16le", "pcm_s24le": name = "PCM"
        default: name = codec.uppercased()
        }
        return "\(name) \(layout)"
    }

    fileprivate static func plainText(_ text: String) -> String {
        text.replacingOccurrences(of: #"\{[^}]*\}"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct EngineError: LocalizedError {
    let code: Int32

    var errorDescription: String? {
        var buffer = [CChar](repeating: 0, count: 200)
        reel_error_text(code, &buffer, 200)
        let text = String(cString: buffer)
        switch text {
        case _ where text.contains("Stream not found"):
            return "This film’s picture is in a format iPhone can’t play without converting it. Download a Medium or Low copy instead."
        case _ where text.contains("Input/output"):
            return "Reel couldn’t read the film from Google Drive. Check your connection and try again."
        default:
            return "Reel couldn’t play this film (\(text))."
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Turns a film into HLS for AVPlayer, made on demand on this phone and served only to this app on 127.0.0.1.
final class StreamServer: @unchecked Sendable {
    struct Stats {
        var filmMegabits: Double = 0
        var segment = 0
    }

    private let media: EngineMedia
    private let queue = DispatchQueue(label: "reel.engine", qos: .userInitiated)
    private let lock = NSLock()
    private var listener: NWListener?
    private let token = UUID().uuidString
    private(set) var port: UInt16 = 0
    private var version = 0
    private var startSegment = 0
    private var initData: Data?
    private var cache: [Int: Data] = [:]
    private var order: [Int] = []
    private var prefetching = false
    private var stopped = false
    private var statsValue = Stats()
    var onError: (Error) -> Void = { _ in }

    init(media: EngineMedia) {
        self.media = media
    }

    var stats: Stats {
        lock.lock()
        defer { lock.unlock() }
        return statsValue
    }

    func start() async throws {
        let parameters = NWParameters.tcp
        // Bound to the loopback address, so nothing else on the network can reach it.
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        self.listener = listener
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false
            listener.stateUpdateHandler = { [weak listener] state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    self.port = listener?.port?.rawValue ?? 0
                    continuation.resume()
                case .failed(let error):
                    resumed = true
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: DispatchQueue(label: "reel.http"))
        }
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        listener?.cancel()
        media.cancel()
    }

    /// A new choice of sound or subtitles gets a new address, so AVPlayer can't mix old segments in.
    func select(sound: Int?, subtitles: Int?, from seconds: Double) throws -> URL {
        var begin = 0, elapsed = 0.0
        for index in 0..<media.segmentCount {
            if elapsed + media.segmentDuration(index) > seconds { begin = index; break }
            elapsed += media.segmentDuration(index)
        }
        try queue.sync {
            try media.select(sound: sound, subtitles: subtitles)
        }
        lock.lock()
        version += 1
        startSegment = begin
        initData = nil
        cache = [:]
        order = []
        let current = version
        lock.unlock()
        return URL(string: "http://127.0.0.1:\(port)/\(token)/\(current)/film.m3u8")!
    }

    private var playlist: String {
        var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-PLAYLIST-TYPE:VOD", "#EXT-X-INDEPENDENT-SEGMENTS"]
        let longest = (0..<media.segmentCount).map(media.segmentDuration).max() ?? 4
        lines.append("#EXT-X-TARGETDURATION:\(Int(longest.rounded(.up)) + 1)")
        lines.append("#EXT-X-MAP:URI=\"init.mp4\"")
        for index in 0..<media.segmentCount {
            lines.append(String(format: "#EXTINF:%.3f,", media.segmentDuration(index)))
            lines.append("\(index).m4s")
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Segments

    private func remember(_ index: Int, _ data: Data) {
        cache[index] = data
        order.removeAll { $0 == index }
        order.append(index)
        while order.count > 4 { cache[order.removeFirst()] = nil }
    }

    /// Made on the engine queue, so one film is only ever read in one place at a time.
    private func produce(_ index: Int, version wanted: Int) throws -> Data {
        lock.lock()
        if let data = cache[index], version == wanted { lock.unlock(); return data }
        lock.unlock()
        return try queue.sync {
            lock.lock()
            if let data = cache[index], version == wanted { lock.unlock(); return data }
            guard version == wanted, !stopped else { lock.unlock(); throw CancellationError() }
            let needInit = initData == nil
            lock.unlock()
            let made = try media.segment(index, wantInit: needInit)
            lock.lock()
            if version == wanted {
                if let initial = made.initial, initData == nil { initData = initial }
                remember(index, made.data)
                if made.info.duration > 0 {
                    statsValue.filmMegabits = Double(made.info.sourceBytes) * 8 / made.info.duration / 1_000_000
                }
                statsValue.segment = index
            }
            lock.unlock()
            return made.data
        }
    }

    private func initSegment(version wanted: Int) throws -> Data {
        lock.lock()
        if let initData, version == wanted { lock.unlock(); return initData }
        let first = startSegment
        lock.unlock()
        _ = try produce(first, version: wanted)
        lock.lock()
        defer { lock.unlock() }
        guard let initData else { throw CancellationError() }
        return initData
    }

    /// Keeps one segment ready ahead of the player.
    private func prefetch(after index: Int, version wanted: Int) {
        lock.lock()
        guard !prefetching, index + 1 < media.segmentCount, cache[index + 1] == nil else { lock.unlock(); return }
        prefetching = true
        lock.unlock()
        // Not on the engine queue itself: produce() waits on it.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            _ = try? self?.produce(index + 1, version: wanted)
            self?.lock.lock()
            self?.prefetching = false
            self?.lock.unlock()
        }
    }

    // MARK: HTTP

    private func accept(_ connection: NWConnection) {
        connection.start(queue: DispatchQueue(label: "reel.http.connection"))
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                let rest = Data(buffer[end.upperBound...])
                DispatchQueue.global(qos: .userInitiated).async {
                    self.respond(connection, head) { keepAlive in
                        if keepAlive { self.receive(connection, buffer: rest) } else { connection.cancel() }
                    }
                }
            } else if complete || error != nil || buffer.count > 65536 {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    private func respond(_ connection: NWConnection, _ head: String, then: @escaping (Bool) -> Void) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        let headers = Dictionary(lines.dropFirst().compactMap { line -> (String, String)? in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            return (line[..<colon].lowercased(), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }, uniquingKeysWith: { a, _ in a })
        guard parts.count >= 2, parts[0] == "GET" || parts[0] == "HEAD" else {
            return send(connection, 405, "text/plain", Data(), head: false, then: then)
        }
        let path = parts[1].split(separator: "/").map(String.init)
        guard path.count == 3, path[0] == token, let wanted = Int(path[1]) else {
            return send(connection, 404, "text/plain", Data(), head: false, then: then)
        }
        let isHead = parts[0] == "HEAD"
        do {
            let file = path[2]
            if file == "film.m3u8" {
                send(connection, 200, "application/vnd.apple.mpegurl", Data(playlist.utf8), head: isHead, then: then)
            } else if file == "init.mp4" {
                send(connection, 200, "video/mp4", try initSegment(version: wanted), head: isHead, range: headers["range"], then: then)
            } else if file.hasSuffix(".m4s"), let index = Int(file.dropLast(4)), index >= 0, index < media.segmentCount {
                let data = try produce(index, version: wanted)
                prefetch(after: index, version: wanted)
                send(connection, 200, "video/iso.segment", data, head: isHead, range: headers["range"], then: then)
            } else {
                send(connection, 404, "text/plain", Data(), head: false, then: then)
            }
        } catch is CancellationError {
            send(connection, 410, "text/plain", Data(), head: false, then: then)
        } catch {
            onError(error)
            send(connection, 503, "text/plain", Data(error.localizedDescription.utf8), head: false, then: then)
        }
    }

    private func send(_ connection: NWConnection, _ status: Int, _ type: String, _ body: Data, head: Bool,
                      range: String? = nil, then: @escaping (Bool) -> Void) {
        var status = status
        var body = body
        var extra = ""
        if status == 200, let range, range.hasPrefix("bytes="), let dash = range.firstIndex(of: "-") {
            let from = Int(range[range.index(range.startIndex, offsetBy: 6)..<dash]) ?? 0
            let to = Int(range[range.index(after: dash)...]) ?? body.count - 1
            if from < body.count, to >= from {
                let end = min(to, body.count - 1)
                extra = "Content-Range: bytes \(from)-\(end)/\(body.count)\r\n"
                body = body.subdata(in: from..<(end + 1))
                status = 206
            }
        }
        let reason = [200: "OK", 206: "Partial Content", 404: "Not Found", 405: "Method Not Allowed",
                      410: "Gone", 503: "Service Unavailable"][status] ?? "Error"
        var response = Data(("HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
            + "Accept-Ranges: bytes\r\nCache-Control: no-store\r\n\(extra)Connection: keep-alive\r\n\r\n").utf8)
        if !head { response.append(body) }
        connection.send(content: response, completion: .contentProcessed { error in then(error == nil) })
    }
}

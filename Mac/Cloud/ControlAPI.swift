import Foundation

/// The small API the Apple TV uses next to Jellyfin (port `Reel.controlPort`).
@MainActor
final class ControlAPI {
    private unowned let server: ServerManager
    private var http: MiniHTTP?
    private var trusted: [String: Date] = [:]

    init(server: ServerManager) {
        self.server = server
    }

    func start() async throws {
        guard http == nil else { return }
        let listener = try MiniHTTP(port: UInt16(Reel.controlPort), loopbackOnly: false) { [weak self] request in
            await self?.handle(request) ?? .error(503, "Reel Server is stopping.")
        }
        try await listener.start()
        http = listener
    }

    func stop() {
        http?.stop()
        http = nil
    }

    private func handle(_ request: HTTPRequest) async -> HTTPResponse {
        if request.method == "GET", request.path == "/v1/master" { return await master(request) }

        guard await isAuthorized(request.headers["authorization"]) else {
            return .error(401, "Connect this Apple TV to Reel again.")
        }
        // /v1/films/{Jellyfin item id}[/action]
        let parts = request.path.split(separator: "/").map(String.init)
        guard parts.count >= 3, parts[0] == "v1", parts[1] == "films",
              !parts[2].isEmpty, parts[2].allSatisfy({ $0.isHexDigit || $0 == "-" }) else { return .error(404, "Not found") }
        guard let film = await server.cloudFilm(itemID: parts[2]) else { return .error(404, "Not a Google Drive film") }

        let store = server.cloud
        let action = parts.count > 3 ? parts[3] : ""
        do {
            switch (request.method, action) {
            case ("GET", ""): break
            case ("GET", "bitrate"): return .json(store.bitrates(film.id))
            case ("POST", "play"):
                guard let source = request.value("source").flatMap(PlaybackSource.init(rawValue:)) else {
                    return .error(400, "Unknown source")
                }
                try store.prepare(film.id, source: source)
            case ("POST", "download"): try store.download(film.id)
            case ("POST", "cancel"): store.cancelDownload(film.id)
            default: return .error(404, "Not found")
            }
            return .json(store.status(store.film(film.id) ?? film))
        } catch {
            return .error(409, error.localizedDescription)
        }
    }

    /// Anyone Jellyfin accepts is accepted here, so there's no second pairing.
    private func isAuthorized(_ header: String?) async -> Bool {
        guard let header, header.hasPrefix("MediaBrowser") else { return false }
        if let until = trusted[header], until > Date() { return true }
        var request = URLRequest(url: server.client.url("/Users/Me"))
        request.setValue(header, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
        trusted = trusted.filter { $0.value > Date() }
        trusted[header] = Date().addingTimeInterval(300)
        return true
    }

    /// Jellyfin adds a tone-mapped H.264 variant to every HDR master playlist, and AVPlayer sometimes picks it,
    /// which turns a 4K HDR remux into a live re-encode. This serves the same playlist without that variant.
    /// The wrapped URL carries its own ApiKey, which Jellyfin checks.
    private func master(_ request: HTTPRequest) async -> HTTPResponse {
        guard let relative = request.value("u"), relative.lowercased().hasPrefix("/videos/"), !relative.contains(".."),
              let url = URL(string: "http://127.0.0.1:\(Reel.port)\(relative)"),
              url.host == "127.0.0.1", url.port == Reel.port, url.path.lowercased().hasSuffix("/master.m3u8"),
              let host = request.headers["host"]?.split(separator: ":").first,
              host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }),
              let base = URL(string: "http://\(host):\(Reel.port)\(relative)") else {
            return .error(400, "Bad playlist address")
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let status = (response as? HTTPURLResponse)?.statusCode, status == 200 else {
                return .error(502, "Jellyfin didn’t return a playlist.")
            }
            let playlist = MasterPlaylist.originalOnly(String(decoding: data, as: UTF8.self), base: base)
            return HTTPResponse(contentType: "application/vnd.apple.mpegurl", body: Data(playlist.utf8))
        } catch {
            return .error(502, error.localizedDescription)
        }
    }
}

enum MasterPlaylist {
    static func originalOnly(_ text: String, base: URL) -> String {
        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        let hasHDR = lines.contains {
            $0.hasPrefix("#EXT-X-STREAM-INF") && ($0.contains("VIDEO-RANGE=PQ") || $0.contains("VIDEO-RANGE=HLG"))
        }
        var kept: [String] = []
        var dropNextAddress = false
        for line in lines {
            if line.hasPrefix("#EXT-X-STREAM-INF") {
                dropNextAddress = hasHDR && line.contains("VIDEO-RANGE=SDR")
                if !dropNextAddress { kept.append(line) }
            } else if !line.hasPrefix("#") {
                if dropNextAddress {
                    dropNextAddress = false
                } else {
                    kept.append(absolute(line, base))
                }
            } else if let start = line.range(of: "URI=\""),
                      let end = line.range(of: "\"", range: start.upperBound..<line.endIndex) {
                let address = absolute(String(line[start.upperBound..<end.lowerBound]), base)
                kept.append(line[..<start.upperBound] + address + line[end.lowerBound...])
            } else {
                kept.append(line)
            }
        }
        return kept.joined(separator: "\n") + "\n"
    }

    private static func absolute(_ address: String, _ base: URL) -> String {
        URL(string: address, relativeTo: base)?.absoluteString ?? address
    }
}

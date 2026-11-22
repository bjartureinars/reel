import Foundation

/// Talks to Reel Server's own API on the Mac, with the token Reel already has for Jellyfin.
struct CloudClient {
    let jellyfin: JellyfinClient

    private struct Failure: Decodable { let error: String }

    private func address(_ path: String, _ query: [URLQueryItem] = []) -> URL? {
        guard var parts = URLComponents(url: jellyfin.baseURL, resolvingAgainstBaseURL: false) else { return nil }
        parts.port = Reel.controlPort
        parts.path = path
        parts.queryItems = query.isEmpty ? nil : query
        // A literal "+" in a query is read as a space by some parsers.
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return parts.url
    }

    private func send(_ method: String, _ path: String, _ query: [URLQueryItem] = []) async throws -> (Int, Data) {
        guard let url = address(path, query) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 8
        request.setValue(jellyfin.authorization, forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    private static func failure(_ status: Int, _ data: Data) -> JellyfinError {
        let message = (try? JSONDecoder().decode(Failure.self, from: data))?.error ?? "Your Mac returned \(status)."
        return JellyfinError(status: status, message: message)
    }

    /// nil for films in the ordinary local library.
    func status(_ itemID: String) async throws -> FilmStatus? {
        let (status, data) = try await send("GET", "/v1/films/\(itemID)")
        if status == 404 { return nil }
        guard status == 200 else { throw Self.failure(status, data) }
        return try JSONDecoder().decode(FilmStatus.self, from: data)
    }

    @discardableResult
    func perform(_ action: String, _ itemID: String, _ query: [URLQueryItem] = []) async throws -> FilmStatus {
        let (status, data) = try await send("POST", "/v1/films/\(itemID)/\(action)", query)
        guard status == 200 else { throw Self.failure(status, data) }
        return try JSONDecoder().decode(FilmStatus.self, from: data)
    }

    /// Megabits of picture in each second of the film; empty if it hasn't been measured.
    func bitrates(_ itemID: String) async -> [Double] {
        guard let (status, data) = try? await send("GET", "/v1/films/\(itemID)/bitrate"), status == 200,
              let values = try? JSONDecoder().decode([Double].self, from: data) else { return [] }
        return values
    }

    /// The HLS master playlist without Jellyfin's tone-mapped SDR variant.
    /// nil if Reel Server isn't answering, so playback can fall back to Jellyfin's own playlist.
    func originalOnlyPlaylist(for url: URL) async -> URL? {
        guard url.path.lowercased().hasSuffix("/master.m3u8"),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let relative = parts.percentEncodedPath + (parts.percentEncodedQuery.map { "?\($0)" } ?? "")
        guard let wrapped = address("/v1/master", [.init("u", relative)]) else { return nil }
        var request = URLRequest(url: wrapped)
        request.timeoutInterval = 15
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return wrapped
    }
}

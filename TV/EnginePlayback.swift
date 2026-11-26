import Foundation

/// Names the device in the shared engine's messages.
enum Device {
    static let name = "Apple TV"
}

/// Plays a Dolby Vision profile 7 film (UHD Blu-ray) as Dolby Vision. Jellyfin can only send such a film's HDR10
/// part, so Apple TV reads the original from the Mac itself and Reel's engine turns its picture into profile 8.1,
/// the kind Apple TV shows, as it plays. The sound is copied or made Apple Lossless, as on iPhone.
@MainActor
final class EnginePlayback {
    let url: URL
    /// The same stream without the playlist that describes it, in case Apple TV turns that description down.
    let fallbackURL: URL
    private let server: StreamServer

    private init(url: URL, server: StreamServer) {
        self.url = url
        fallbackURL = url.deletingLastPathComponent().appendingPathComponent("film.m3u8")
        self.server = server
    }

    static func needed(for source: MediaSource) -> Bool {
        source.mediaStreams?.first { $0.type == "Video" }?.dvProfile == 7
    }

    static func start(itemID: String, source: MediaSource, client: JellyfinClient, from seconds: Double,
                      onError: @escaping (Error) -> Void) async throws -> EnginePlayback {
        var query: [URLQueryItem] = [.init("static", "true"), .init("mediaSourceId", source.id)]
        if let tag = source.eTag { query.append(.init("Tag", tag)) }
        let file = client.url("/Videos/\(itemID)/stream", query, withKey: true)
        let reader = try await MacReader.open(file)
        let media = try await Task.detached(priority: .userInitiated) {
            try EngineMedia(reader: reader, languages: [:])
        }.value
        let server = StreamServer(media: media)
        server.onError = { error in Task { @MainActor in onError(error) } }
        try await server.start()
        let sound = media.defaultSound
        let url = try await Task.detached { try server.select(sound: sound?.id, subtitles: nil, from: seconds, master: true) }.value
        return EnginePlayback(url: url, server: server)
    }

    func stop() {
        server.stop()
    }
}

/// Reads the original film from the Mac in byte ranges, through Jellyfin's direct file link.
enum MacReader {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.httpMaximumConnectionsPerHost = 8
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    static func open(_ url: URL) async throws -> RangeReader {
        // The first byte's answer says how big the whole file is.
        let (_, response) = try await get(url, from: 0, count: 1)
        guard let range = response.value(forHTTPHeaderField: "Content-Range"),
              let total = range.split(separator: "/").last.flatMap({ Int64($0) }), total > 0 else {
            throw JellyfinError(status: response.statusCode, message: "Your Mac didn’t say how big the film is.")
        }
        return RangeReader(size: total, isPermanent: { error in
            ((error as? JellyfinError)?.status).map { $0 == 401 || $0 == 403 || $0 == 404 } ?? false
        }, fetch: { offset, count in
            let (data, _) = try await get(url, from: offset, count: count)
            return data
        })
    }

    private static func get(_ url: URL, from offset: Int64, count: Int) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.setValue("bytes=\(offset)-\(offset + Int64(count) - 1)", forHTTPHeaderField: "Range")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw JellyfinError(status: 0, message: "No answer from your Mac.")
        }
        guard http.statusCode == 206, data.count == count else {
            throw JellyfinError(status: http.statusCode, message: "Your Mac sent \(data.count) of \(count) bytes (\(http.statusCode)).")
        }
        return (data, http)
    }
}

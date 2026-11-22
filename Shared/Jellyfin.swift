import Foundation

/// Constants shared by Reel Server (Mac) and Reel (Apple TV).
enum Reel {
    static let bonjourType = "_reel._tcp"
    static let port = 8096
    /// Reel Server's own API (Google Drive films, HDR playlist).
    static let controlPort = 8097
    static let ticksPerSecond: Double = 10_000_000
}

struct JellyfinError: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { message }
    var isUnauthorized: Bool { status == 401 }
}

/// A small, dependency-free client for the parts of the Jellyfin 12 API that Reel uses.
/// Authenticates with the current `Authorization: MediaBrowser …` header; media and image URLs carry
/// the `ApiKey` query parameter, because AVPlayer can't send headers.
final class JellyfinClient: @unchecked Sendable {
    let baseURL: URL
    var token: String?
    let deviceName: String
    let deviceId: String
    static let clientName = "Reel"
    static let clientVersion = "1.0"

    private let session: URLSession

    init(baseURL: URL, token: String? = nil, deviceName: String, deviceId: String) {
        self.baseURL = baseURL
        self.token = token
        self.deviceName = deviceName
        self.deviceId = deviceId
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    var authorization: String {
        var parts = [
            "Client=\"\(Self.clientName)\"",
            "Device=\"\(Self.headerSafe(deviceName))\"",
            "DeviceId=\"\(deviceId)\"",
            "Version=\"\(Self.clientVersion)\"",
        ]
        if let token { parts.append("Token=\"\(token)\"") }
        return "MediaBrowser " + parts.joined(separator: ", ")
    }

    /// Header values must be ASCII; Jellyfin URL-decodes them.
    private static func headerSafe(_ s: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 -_.()")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? "Reel"
    }

    // MARK: URLs

    func url(_ path: String, _ query: [URLQueryItem] = [], withKey: Bool = false) -> URL {
        var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        var items = query
        if withKey, let token { items.append(URLQueryItem(name: "ApiKey", value: token)) }
        comps.queryItems = items.isEmpty ? nil : items
        return comps.url!
    }

    /// Turns a server-relative URL (like a TranscodingUrl) into an absolute one that carries ApiKey.
    func absolute(_ relative: String) -> URL? {
        guard var comps = URLComponents(string: relative) else { return nil }
        var items = (comps.queryItems ?? []).filter { !["api_key", "apikey"].contains($0.name.lowercased()) }
        if let token { items.append(URLQueryItem(name: "ApiKey", value: token)) }
        comps.queryItems = items
        guard let rel = comps.url, let abs = URL(string: rel.absoluteString, relativeTo: baseURL) else { return nil }
        return abs.absoluteURL
    }

    func imageURL(for item: Item, type: String = "Primary", maxWidth: Int) -> URL? {
        guard let tag = item.imageTags?[type] else { return nil }
        return url("/Items/\(item.id)/Images/\(type)",
                   [.init(name: "maxWidth", value: "\(maxWidth)"), .init(name: "quality", value: "90"),
                    .init(name: "tag", value: tag)], withKey: true)
    }

    func backdropURL(for item: Item, maxWidth: Int) -> URL? {
        if let tag = item.backdropImageTags?.first {
            return url("/Items/\(item.id)/Images/Backdrop/0",
                       [.init(name: "maxWidth", value: "\(maxWidth)"), .init(name: "quality", value: "90"),
                        .init(name: "tag", value: tag)], withKey: true)
        }
        // Home videos have no backdrop; their extracted frame (Primary/Thumb) makes a fine one.
        return imageURL(for: item, type: "Thumb", maxWidth: maxWidth) ?? imageURL(for: item, maxWidth: maxWidth)
    }

    // MARK: Requests

    @discardableResult
    func send(_ method: String, _ path: String, query: [URLQueryItem] = [], json: Any? = nil,
              timeout: TimeInterval? = nil) async throws -> Data {
        var request = URLRequest(url: url(path, query))
        request.httpMethod = method
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let timeout { request.timeoutInterval = timeout }
        if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw JellyfinError(status: 0, message: "No response from the server.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8)?.prefix(300) ?? ""
            throw JellyfinError(status: http.statusCode, message: "Server returned \(http.statusCode). \(body)")
        }
        return data
    }

    func get<T: Decodable>(_ path: String, _ query: [URLQueryItem] = [], as type: T.Type = T.self) async throws -> T {
        try Self.decoder.decode(T.self, from: try await send("GET", path, query: query))
    }

    func post<T: Decodable>(_ path: String, _ query: [URLQueryItem] = [], json: Any? = nil,
                            as type: T.Type = T.self) async throws -> T {
        try Self.decoder.decode(T.self, from: try await send("POST", path, query: query, json: json))
    }

    /// Jellyfin uses PascalCase JSON keys; Swift properties are camelCase.
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .custom { keys in
            let raw = keys.last!.stringValue
            return AnyKey(raw.prefix(1).lowercased() + raw.dropFirst())
        }
        return d
    }()

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ s: String) { stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    // MARK: Common calls

    func publicInfo() async throws -> PublicSystemInfo { try await get("/System/Info/Public") }

    func me() async throws -> UserDto { try await get("/Users/Me") }

    func items(userId: String, parentId: String? = nil, types: String = "Movie,Video",
               sortBy: String = "SortName", descending: Bool = false, search: String? = nil,
               limit: Int? = nil) async throws -> [Item] {
        var q: [URLQueryItem] = [
            .init(name: "userId", value: userId), .init(name: "recursive", value: "true"),
            .init(name: "includeItemTypes", value: types), .init(name: "sortBy", value: sortBy),
            .init(name: "sortOrder", value: descending ? "Descending" : "Ascending"),
            .init(name: "fields", value: "Overview,MediaStreams,Path,DateCreated,Genres,PrimaryImageAspectRatio"),
            .init(name: "enableImageTypes", value: "Primary,Backdrop,Thumb"),
        ]
        if let parentId { q.append(.init(name: "parentId", value: parentId)) }
        if let search { q.append(.init(name: "searchTerm", value: search)) }
        if let limit { q.append(.init(name: "limit", value: "\(limit)")) }
        let page: ItemsPage = try await get("/Items", q)
        return page.items
    }

    func item(_ id: String, userId: String) async throws -> Item {
        try await get("/Items/\(id)", [.init(name: "userId", value: userId)])
    }
}

// MARK: - Models

struct PublicSystemInfo: Decodable {
    let serverName: String?
    let version: String?
    let id: String?
    let startupWizardCompleted: Bool?
}

struct UserDto: Decodable {
    let id: String
    let name: String?
}

struct AuthResult: Decodable {
    let user: UserDto
    let accessToken: String
    let serverId: String?
}

struct QuickConnectState: Decodable {
    let secret: String
    let code: String
    let authenticated: Bool?
}

struct ItemsPage: Decodable {
    let items: [Item]
    let totalRecordCount: Int?
}

struct UserData: Decodable {
    let playbackPositionTicks: Int64?
    let playedPercentage: Double?
    let played: Bool?
    let isFavorite: Bool?
    let lastPlayedDate: String?
}

struct MediaStream: Decodable {
    let type: String?
    let codec: String?
    let width: Int?
    let height: Int?
    let videoRangeType: String?
    let channels: Int?
    let displayTitle: String?
    let language: String?
    let profile: String?
    let index: Int?
}

struct MediaSource: Decodable {
    let id: String
    let container: String?
    let supportsDirectPlay: Bool?
    let supportsDirectStream: Bool?
    let transcodingUrl: String?
    let eTag: String?
    let mediaStreams: [MediaStream]?
}

struct PlaybackInfoResponse: Decodable {
    let mediaSources: [MediaSource]
    let playSessionId: String?
    let errorCode: String?
}

struct VirtualFolder: Decodable {
    let name: String
    let locations: [String]?
    let collectionType: String?
    let itemId: String?
}

struct ScheduledTask: Decodable {
    let key: String?
    let state: String?
    let currentProgressPercentage: Double?
}

struct SessionInfo: Decodable, Identifiable {
    let id: String
    let deviceName: String?
    let client: String?
    let nowPlayingItem: Item?
    let playState: PlayState?
    let transcodingInfo: TranscodingInfo?

    struct PlayState: Decodable {
        let isPaused: Bool?
        let positionTicks: Int64?
        let playMethod: String?
    }

    struct TranscodingInfo: Decodable {
        let isVideoDirect: Bool?
        let bitrate: Int?
        let isAudioDirect: Bool?
        let videoCodec: String?
        let audioCodec: String?
    }

    /// Plain-language description of how the picture is reaching the TV.
    var qualityDescription: String {
        switch playState?.playMethod {
        case "DirectPlay": return "Direct play — original file"
        case "DirectStream":
            return "Original picture, repackaged for Apple TV"
        default:
            guard let t = transcodingInfo else { return "Streaming" }
            if t.isVideoDirect == true {
                return t.isAudioDirect == true ? "Original picture and sound" : "Original picture, sound converted to \(t.audioCodec?.uppercased() ?? "a supported format")"
            }
            return "Picture is being converted"
        }
    }
}

struct Item: Decodable, Identifiable, Hashable {
    let id: String
    let name: String?
    let type: String?
    let productionYear: Int?
    let runTimeTicks: Int64?
    let overview: String?
    let officialRating: String?
    let communityRating: Double?
    let imageTags: [String: String]?
    let backdropImageTags: [String]?
    let userData: UserData?
    let mediaStreams: [MediaStream]?
    let path: String?
    let dateCreated: String?
    let genres: [String]?
    let collectionType: String?
    let primaryImageAspectRatio: Double?

    static func == (a: Item, b: Item) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    var title: String { name ?? "Untitled" }

    var runtimeText: String? {
        guard let t = runTimeTicks, t > 0 else { return nil }
        let minutes = Int(Double(t) / Reel.ticksPerSecond / 60)
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(max(1, minutes)) min"
    }

    var resumeSeconds: Double {
        guard let t = userData?.playbackPositionTicks, t > 0, userData?.played != true else { return 0 }
        return Double(t) / Reel.ticksPerSecond
    }

    var progress: Double? {
        guard resumeSeconds > 0, let p = userData?.playedPercentage else { return nil }
        return min(max(p / 100, 0), 1)
    }

    var remainingText: String? {
        guard let total = runTimeTicks, resumeSeconds > 0 else { return nil }
        let left = Int((Double(total) / Reel.ticksPerSecond - resumeSeconds) / 60)
        return left >= 60 ? "\(left / 60) h \(left % 60) min left" : "\(max(1, left)) min left"
    }

    var videoStream: MediaStream? { mediaStreams?.first { $0.type == "Video" } }
    var audioStream: MediaStream? { mediaStreams?.first { $0.type == "Audio" } }

    /// Badges shown on the detail page: resolution, dynamic range, sound.
    var badges: [String] {
        var out: [String] = []
        if let w = videoStream?.width {
            if w >= 3200 { out.append("4K") } else if w >= 1900 { out.append("HD") }
        }
        switch videoStream?.videoRangeType ?? "" {
        case let r where r.hasPrefix("DOVI"): out.append("Dolby Vision")
        case "HDR10Plus": out.append("HDR10+")
        case "HDR10": out.append("HDR10")
        case "HLG": out.append("HLG")
        default: break
        }
        if let a = audioStream {
            if (a.displayTitle ?? "").localizedCaseInsensitiveContains("atmos") || (a.profile ?? "").localizedCaseInsensitiveContains("atmos") {
                out.append("Dolby Atmos")
            } else if let c = a.channels, c >= 8 { out.append("7.1") } else if let c = a.channels, c >= 6 { out.append("5.1") }
        }
        return out
    }

    var isHomeVideo: Bool { type == "Video" }
}

extension URLQueryItem {
    init(_ name: String, _ value: String) { self.init(name: name, value: value) }
}

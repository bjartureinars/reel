import Foundation

struct DriveFile: Decodable {
    let id: String
    let name: String?
    let size: String?
    let md5Checksum: String?
    let trashed: Bool?
    let modifiedTime: String?
    let appProperties: [String: String]?

    var byteCount: Int64? { size.flatMap { Int64($0) } }
}

struct DriveQuota: Equatable {
    let email: String?
    let used: Int64
    let limit: Int64?

    var free: Int64? { limit.map { max(0, $0 - used) } }
}

struct DriveError: LocalizedError {
    let status: Int
    let reason: String?
    let detail: String?

    var isTransient: Bool {
        status == 408 || status == 429 || status >= 500
            || ["rateLimitExceeded", "userRateLimitExceeded"].contains(reason ?? "")
    }

    var errorDescription: String? {
        switch reason {
        case "storageQuotaExceeded": return "Google Drive is full."
        case "downloadQuotaExceeded": return "Google has paused downloads of this film for up to 24 hours."
        case "cannotDownloadAbusiveFile": return "Google flagged this file and won’t let Reel download it."
        case "accessNotConfigured", "SERVICE_DISABLED":
            return "The Google Drive API is switched off in your Google Cloud project. Switch it on, then try again."
        default: return "Google Drive returned \(status). \(detail ?? "")"
        }
    }
}

/// The parts of Drive API v3 that Reel uses. No SDK.
final class DriveClient: @unchecked Sendable {
    typealias TokenProvider = @Sendable (_ rejected: String?) async throws -> String

    enum UploadState {
        case received(Int64)
        case done(DriveFile)
        case expired
    }

    private let api: URL
    private let uploadAPI: URL
    private let token: TokenProvider
    private let session: URLSession
    /// Separate sessions on purpose: one URLSession multiplexes every request onto a single HTTP/2 connection,
    /// and one connection is the speed limit a fast upload exists to get around.
    private let lanes: [URLSession]
    static let laneCount = 8
    private static let fileFields = "id,name,size,md5Checksum,trashed,modifiedTime,appProperties"

    init(api: URL = URL(string: "https://www.googleapis.com/drive/v3")!,
         uploadAPI: URL = URL(string: "https://www.googleapis.com/upload/drive/v3")!,
         token: @escaping TokenProvider) {
        self.api = api
        self.uploadAPI = uploadAPI
        self.token = token
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpMaximumConnectionsPerHost = 16
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 1800
        session = URLSession(configuration: config, delegate: KeepStatus(), delegateQueue: nil)
        lanes = (0..<Self.laneCount).map { _ in URLSession(configuration: config, delegate: KeepStatus(), delegateQueue: nil) }
    }

    /// URLSession treats Drive's "308 Resume Incomplete" as a redirect; hand it back as a response.
    private final class KeepStatus: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(response.statusCode == 308 ? nil : request)
        }
    }

    // MARK: Requests

    private func perform(_ make: () -> URLRequest, body: Data? = nil, accept: Set<Int> = [200],
                         attempts: Int = 5, lane: Int? = nil) async throws -> (Data, HTTPURLResponse) {
        let session = lane.map { lanes[$0] } ?? self.session
        var rejected: String?
        var attempt = 0
        while true {
            attempt += 1
            do {
                let current = try await token(rejected)
                var request = make()
                request.setValue("Bearer \(current)", forHTTPHeaderField: "Authorization")
                let (data, response) = body == nil
                    ? try await session.data(for: request)
                    : try await session.upload(for: request, from: body!)
                guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                if accept.contains(http.statusCode) { return (data, http) }
                if http.statusCode == 401, rejected == nil {
                    rejected = current
                    continue
                }
                throw Self.error(http.statusCode, data)
            } catch {
                let retry = (error as? DriveError)?.isTransient
                    ?? (error as? URLError).map { $0.code != .cancelled }
                    ?? false
                guard retry, attempt < attempts else { throw error }
                let delay = min(pow(2, Double(attempt - 1)), 16) * Double.random(in: 0.8...1.2)
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    private static func error(_ status: Int, _ data: Data) -> DriveError {
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let error = body?["error"] as? [String: Any]
        let first = (error?["errors"] as? [[String: Any]])?.first
        return DriveError(status: status, reason: first?["reason"] as? String, detail: error?["message"] as? String)
    }

    private func url(_ base: URL, _ path: String, _ query: [String: String]) -> URL {
        var parts = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        parts.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        return parts.url!
    }

    private func request(_ method: String, _ url: URL, json: [String: Any]? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let json {
            request.httpBody = try? JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    // MARK: Account and files

    func quota() async throws -> DriveQuota {
        struct About: Decodable {
            struct User: Decodable { let emailAddress: String? }
            struct Storage: Decodable { let limit: String?; let usage: String? }
            let user: User?
            let storageQuota: Storage?
        }
        let target = url(api, "about", ["fields": "user(emailAddress),storageQuota(limit,usage)"])
        let about = try JSONDecoder().decode(About.self, from: try await perform { request("GET", target) }.0)
        return DriveQuota(email: about.user?.emailAddress,
                          used: about.storageQuota?.usage.flatMap { Int64($0) } ?? 0,
                          limit: about.storageQuota?.limit.flatMap { Int64($0) })
    }

    private func list(_ query: String) async throws -> [DriveFile] {
        struct Page: Decodable { let files: [DriveFile]; let nextPageToken: String? }
        var all: [DriveFile] = []
        var next: String?
        repeat {
            var parameters = ["q": query, "pageSize": "200", "spaces": "drive",
                              "fields": "nextPageToken,files(\(Self.fileFields))"]
            parameters["pageToken"] = next
            let target = url(api, "files", parameters)
            let page = try JSONDecoder().decode(Page.self, from: try await perform { request("GET", target) }.0)
            all += page.files
            next = page.nextPageToken
        } while next != nil
        return all
    }

    func films() async throws -> [DriveFile] {
        try await list("trashed=false and appProperties has { key='reel' and value='film' }")
    }

    /// Pieces from fast uploads.
    func parts() async throws -> [DriveFile] {
        try await list("trashed=false and appProperties has { key='reel' and value='part' }")
    }

    /// The "Reel" folder in My Drive, created on first use.
    func folder() async throws -> String {
        if let found = try await list("trashed=false and appProperties has { key='reel' and value='folder' }").first {
            return found.id
        }
        let target = url(api, "files", ["fields": "id"])
        let body: [String: Any] = ["name": "Reel", "mimeType": "application/vnd.google-apps.folder",
                                   "appProperties": ["reel": "folder"]]
        let data = try await perform { request("POST", target, json: body) }.0
        return try JSONDecoder().decode(DriveFile.self, from: data).id
    }

    func file(_ id: String) async throws -> DriveFile {
        let target = url(api, "files/\(id)", ["fields": Self.fileFields])
        return try JSONDecoder().decode(DriveFile.self, from: try await perform { request("GET", target) }.0)
    }

    /// Moves the file to Drive's Bin, where it can be restored for 30 days.
    func trash(_ id: String) async throws {
        let target = url(api, "files/\(id)", ["fields": "id"])
        do {
            _ = try await perform { request("PATCH", target, json: ["trashed": true]) }
        } catch let error as DriveError where error.status == 404 {
            return
        }
    }

    // MARK: Reading

    func read(_ id: String, offset: Int64, count: Int, attempts: Int = 5) async throws -> Data {
        guard count > 0 else { return Data() }
        let target = url(api, "files/\(id)", ["alt": "media"])
        let range = "bytes=\(offset)-\(offset + Int64(count) - 1)"
        let (data, response) = try await perform({
            var request = request("GET", target)
            request.setValue(range, forHTTPHeaderField: "Range")
            // Ranges address the stored bytes, so compression must stay off.
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            return request
        }, accept: [200, 206], attempts: attempts)
        guard data.count == count, response.statusCode == 206 || offset == 0 else {
            throw DriveError(status: 502, reason: nil, detail: "Google sent the wrong part of the file.")
        }
        return data
    }

    // MARK: Resumable upload

    func beginUpload(name: String, size: Int64, parent: String, properties: [String: String]) async throws -> URL {
        let target = url(uploadAPI, "files", ["uploadType": "resumable", "fields": Self.fileFields])
        let body: [String: Any] = ["name": name, "parents": [parent], "appProperties": properties,
                                   "mimeType": "application/octet-stream"]
        let (_, response) = try await perform {
            var request = request("POST", target, json: body)
            request.setValue("\(size)", forHTTPHeaderField: "X-Upload-Content-Length")
            request.setValue("application/octet-stream", forHTTPHeaderField: "X-Upload-Content-Type")
            return request
        }
        guard let location = response.value(forHTTPHeaderField: "Location").flatMap({ URL(string: $0) }) else {
            throw CloudError("Google didn’t open an upload.")
        }
        return location
    }

    func uploadState(_ upload: URL, size: Int64, lane: Int? = nil) async throws -> UploadState {
        try await put(upload, body: Data(), range: "bytes */\(size)", lane: lane)
    }

    func sendChunk(_ upload: URL, data: Data, offset: Int64, size: Int64, lane: Int? = nil) async throws -> UploadState {
        try await put(upload, body: data, range: "bytes \(offset)-\(offset + Int64(data.count) - 1)/\(size)", lane: lane)
    }

    private func put(_ upload: URL, body: Data, range: String, lane: Int?) async throws -> UploadState {
        let (data, response) = try await perform({
            var request = URLRequest(url: upload)
            request.httpMethod = "PUT"
            request.timeoutInterval = 120
            request.setValue(range, forHTTPHeaderField: "Content-Range")
            return request
        }, body: body, accept: [200, 201, 308, 404, 410], lane: lane)
        switch response.statusCode {
        case 200, 201:
            return .done(try JSONDecoder().decode(DriveFile.self, from: data))
        case 308:
            let last = response.value(forHTTPHeaderField: "Range")?.split(separator: "-").last.flatMap { Int64($0) }
            return .received(last.map { $0 + 1 } ?? 0)
        default:
            return .expired
        }
    }
}

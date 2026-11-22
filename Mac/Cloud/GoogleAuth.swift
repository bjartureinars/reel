import AppKit
import CryptoKit
import Foundation

struct CloudError: LocalizedError {
    let message: String
    var needsSignIn = false

    init(_ message: String, needsSignIn: Bool = false) {
        self.message = message
        self.needsSignIn = needsSignIn
    }

    var errorDescription: String? { message }
}

/// The "Desktop app" OAuth client file that Google Cloud Console lets you download.
struct GoogleClientKey: Codable {
    let clientID: String
    let clientSecret: String

    init(file: Data) throws {
        struct File: Decodable {
            struct Installed: Decodable {
                let client_id: String
                let client_secret: String
            }
            let installed: Installed?
        }
        guard let installed = (try? JSONDecoder().decode(File.self, from: file))?.installed else {
            throw CloudError("That isn’t a Desktop app key. In Google Cloud, create an OAuth client with the type “Desktop app” and choose the file it downloads.")
        }
        clientID = installed.client_id
        clientSecret = installed.client_secret
    }
}

/// Google sign-in for installed apps: system browser, loopback redirect, PKCE.
/// The only scope is `drive.file`, so Reel can't see anything in Drive that it didn't upload itself.
actor GoogleAuth {
    private static let scope = "https://www.googleapis.com/auth/drive.file"
    private static let keyAccount = "google.client"
    private static let tokenAccount = "google.refresh"

    private struct TokenResponse: Decodable {
        let access_token: String?
        let refresh_token: String?
        let expires_in: Double?
        let scope: String?
        let error: String?
        let error_description: String?
    }

    private var access: (token: String, expires: Date)?
    private var refreshing: Task<String, Error>?

    nonisolated var hasKey: Bool { Keychain.get(Self.keyAccount) != nil }
    nonisolated var isSignedIn: Bool { Keychain.get(Self.tokenAccount) != nil }

    func importKey(from url: URL) throws {
        let key = try GoogleClientKey(file: Data(contentsOf: url))
        Keychain.set(String(decoding: try JSONEncoder().encode(key), as: UTF8.self), for: Self.keyAccount)
        signOut()
    }

    func signOut() {
        access = nil
        refreshing = nil
        Keychain.set(nil, for: Self.tokenAccount)
    }

    private func storedKey() throws -> GoogleClientKey {
        guard let json = Keychain.get(Self.keyAccount),
              let key = try? JSONDecoder().decode(GoogleClientKey.self, from: Data(json.utf8)) else {
            throw CloudError("Choose your Google key file first.", needsSignIn: true)
        }
        return key
    }

    func signIn() async throws {
        let key = try storedKey()
        let verifier = Self.randomString()
        let state = Self.randomString()
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))

        let (results, sink) = AsyncStream<Result<String, CloudError>>.makeStream()
        let server = try MiniHTTP(port: 0, loopbackOnly: true) { request in
            guard request.path == "/", request.value("state") == state else {
                return HTTPResponse(status: 404, contentType: "text/plain")
            }
            let message: String
            if let code = request.value("code") {
                sink.yield(.success(code))
                message = "Almost done. Go back to Reel Server."
            } else {
                sink.yield(.failure(CloudError("Google sign-in was cancelled.")))
                message = "Sign-in was cancelled."
            }
            return HTTPResponse(contentType: "text/plain; charset=utf-8", body: Data(message.utf8))
        }
        let redirect = "http://127.0.0.1:\(try await server.start())"
        defer { server.stop() }
        let timeout = Task {
            try await Task.sleep(nanoseconds: 600_000_000_000)
            sink.yield(.failure(CloudError("Sign-in timed out. Try again.")))
        }
        defer { timeout.cancel() }

        var page = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        page.queryItems = [
            .init("client_id", key.clientID), .init("redirect_uri", redirect), .init("response_type", "code"),
            .init("scope", Self.scope), .init("access_type", "offline"), .init("prompt", "consent select_account"),
            .init("state", state), .init("code_challenge", challenge), .init("code_challenge_method", "S256"),
        ]
        let url = page.url!
        await MainActor.run { _ = NSWorkspace.shared.open(url) }

        var received: Result<String, CloudError>?
        for await result in results {
            received = result
            break
        }
        guard let received else { throw CancellationError() }
        let response = try await requestToken([
            "client_id": key.clientID, "client_secret": key.clientSecret, "code": try received.get(),
            "code_verifier": verifier, "grant_type": "authorization_code", "redirect_uri": redirect,
        ])
        guard response.scope?.contains("drive.file") == true else {
            throw CloudError("Reel wasn’t given access to Drive. Sign in again and allow Google Drive access.")
        }
        guard let token = response.access_token, let refresh = response.refresh_token else {
            throw CloudError("Google didn’t return a sign-in token. Try again.")
        }
        Keychain.set(refresh, for: Self.tokenAccount)
        access = (token, Date().addingTimeInterval((response.expires_in ?? 3600) - 120))
    }

    /// `rejected` is a token Google just refused, so it won't be handed out again.
    func token(rejected: String? = nil) async throws -> String {
        if let access, access.expires > Date(), access.token != rejected { return access.token }
        if let refreshing { return try await refreshing.value }
        let task = Task { try await refresh() }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
    }

    private func refresh() async throws -> String {
        let key = try storedKey()
        guard let refresh = Keychain.get(Self.tokenAccount) else {
            throw CloudError("Sign in to Google Drive in Reel Server.", needsSignIn: true)
        }
        let response = try await requestToken([
            "client_id": key.clientID, "client_secret": key.clientSecret,
            "refresh_token": refresh, "grant_type": "refresh_token",
        ])
        guard let token = response.access_token else { throw CloudError("Google didn’t return an access token.") }
        access = (token, Date().addingTimeInterval((response.expires_in ?? 3600) - 120))
        return token
    }

    private func requestToken(_ fields: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = Data(fields.map {
            "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&").utf8)
        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(TokenResponse.self, from: data)
        if response.error == "invalid_grant" {
            signOut()
            throw CloudError("Google sign-in expired. Sign in again in Reel Server.", needsSignIn: true)
        }
        if let error = response.error {
            throw CloudError("Google sign-in failed: \(response.error_description ?? error)")
        }
        return response
    }

    private static func randomString() -> String {
        var generator = SystemRandomNumberGenerator()
        return base64URL(Data((0..<48).map { _ in UInt8.random(in: 0...255, using: &generator) }))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

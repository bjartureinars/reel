import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

/// Google sign-in for the iPhone: Google's own page in a secure browser sheet, PKCE, no secret in the app.
/// The only permission asked for is `drive.file`, so Reel sees just the files Reel itself put in Drive.
@MainActor
final class GoogleAccount: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    static let clientID = "170270400386-fajjl8hjvg2v1bc9t0s4p6lkoiv5tok3.apps.googleusercontent.com"
    private static let scheme = "com.googleusercontent.apps.170270400386-fajjl8hjvg2v1bc9t0s4p6lkoiv5tok3"
    private static let redirect = scheme + ":/oauth2redirect"
    private static let scope = "https://www.googleapis.com/auth/drive.file"
    private static let refreshAccount = "phone.google.refresh"

    @Published private(set) var isSignedIn = Keychain.get(GoogleAccount.refreshAccount) != nil
    @Published var email: String? = UserDefaults.standard.string(forKey: "google.email") {
        didSet { UserDefaults.standard.set(email, forKey: "google.email") }
    }

    let tokens = TokenSource(refreshAccount: GoogleAccount.refreshAccount, clientID: GoogleAccount.clientID)
    private var session: ASWebAuthenticationSession?

    override init() {
        super.init()
        tokens.onSignedOut = { [weak self] in Task { @MainActor in self?.isSignedIn = false } }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
        }
    }

    func signIn() async throws {
        let verifier = Self.random()
        let state = Self.random()
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        var page = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        page.queryItems = [
            .init(name: "client_id", value: Self.clientID), .init(name: "redirect_uri", value: Self.redirect),
            .init(name: "response_type", value: "code"), .init(name: "scope", value: Self.scope),
            .init(name: "state", value: state), .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"), .init(name: "prompt", value: "select_account"),
        ]
        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: page.url!, callbackURLScheme: Self.scheme) { url, error in
                if let url { continuation.resume(returning: url) } else {
                    continuation.resume(throwing: error ?? CloudError("Sign-in was cancelled."))
                }
            }
            session.presentationContextProvider = self
            self.session = session
            session.start()
        }
        session = nil
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard items.first(where: { $0.name == "state" })?.value == state else { throw CloudError("Sign-in didn’t match. Try again.") }
        guard let code = items.first(where: { $0.name == "code" })?.value else {
            throw CloudError(items.first(where: { $0.name == "error" })?.value == "access_denied"
                             ? "Reel needs access to its films in Google Drive. Try again and allow it." : "Google sign-in failed.")
        }
        let response = try await TokenSource.request([
            "client_id": Self.clientID, "code": code, "code_verifier": verifier,
            "grant_type": "authorization_code", "redirect_uri": Self.redirect,
        ])
        guard response.scope?.contains("drive.file") == true else {
            throw CloudError("Reel wasn’t given access to Google Drive. Sign in again and tick the Drive box.")
        }
        guard let access = response.access_token, let refresh = response.refresh_token else {
            throw CloudError("Google didn’t return a sign-in. Try again.")
        }
        await tokens.store(refresh: refresh, access: access, expires: response.expires_in ?? 3600)
        isSignedIn = true
    }

    func signOut() async {
        await tokens.forget()
        email = nil
        isSignedIn = false
    }

    private static func random() -> String {
        var bytes = [UInt8](repeating: 0, count: 48)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// Hands out access tokens, refreshing them when needed. Safe from any thread.
actor TokenSource {
    struct Response: Decodable {
        let access_token: String?
        let refresh_token: String?
        let expires_in: Double?
        let scope: String?
        let error: String?
        let error_description: String?
    }

    private let refreshAccount: String
    private let clientID: String
    private var access: (token: String, expires: Date)?
    private var refreshing: Task<String, Error>?
    nonisolated(unsafe) var onSignedOut: () -> Void = {}

    init(refreshAccount: String, clientID: String) {
        self.refreshAccount = refreshAccount
        self.clientID = clientID
    }

    func store(refresh: String, access token: String, expires: Double) {
        Keychain.set(refresh, for: refreshAccount)
        access = (token, Date().addingTimeInterval(expires - 120))
    }

    func forget() {
        if let refresh = Keychain.get(refreshAccount) {
            var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("token=\(refresh)".utf8)
            URLSession.shared.dataTask(with: request).resume()
        }
        Keychain.set(nil, for: refreshAccount)
        access = nil
        refreshing = nil
    }

    func token(rejected: String? = nil) async throws -> String {
        if let access, access.expires > Date(), access.token != rejected { return access.token }
        if let refreshing { return try await refreshing.value }
        let task = Task { try await refresh() }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
    }

    private func refresh() async throws -> String {
        guard let refresh = Keychain.get(refreshAccount) else {
            throw CloudError("Sign in to Google Drive.", needsSignIn: true)
        }
        let response = try await Self.request(["client_id": clientID, "refresh_token": refresh, "grant_type": "refresh_token"])
        if response.error == "invalid_grant" {
            Keychain.set(nil, for: refreshAccount)
            access = nil
            onSignedOut()
            throw CloudError("Your Google sign-in expired. Sign in again.", needsSignIn: true)
        }
        guard let token = response.access_token else {
            throw CloudError("Google sign-in failed: \(response.error_description ?? response.error ?? "no token")")
        }
        access = (token, Date().addingTimeInterval((response.expires_in ?? 3600) - 120))
        return token
    }

    static func request(_ fields: [String: String]) async throws -> Response {
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
        return try JSONDecoder().decode(Response.self, from: data)
    }
}

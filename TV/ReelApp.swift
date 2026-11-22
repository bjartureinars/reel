import SwiftUI
import UIKit

enum Theme {
    /// Projector-lamp gold: the one brand color, used for progress and selection marks only.
    static let gold = Color(red: 0.96, green: 0.73, blue: 0.29)   // #F5BA4A on dark: 10.6:1 on black
}

@main
struct ReelApp: App {
    @StateObject private var session = AppSession()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .preferredColorScheme(.dark)
                .tint(Theme.gold)
        }
    }
}

/// Holds the connection to the Reel server on the Mac.
@MainActor
final class AppSession: ObservableObject {
    enum Phase { case launching, connect, ready }

    @Published var phase: Phase = .launching
    @Published private(set) var client: JellyfinClient?
    @Published private(set) var userId: String?
    @Published private(set) var serverName: String?
    @Published var playbackError: String?
    @Published var actionError: String?
    /// Bumped after playback so shelves refresh their progress.
    @Published var libraryVersion = 0

    private let defaults = UserDefaults.standard

    init() {
        Task { await restore() }
    }

    static var deviceName: String { UIDevice.current.name }

    private func restore() async {
        guard let urlString = defaults.string(forKey: "server.url"), let url = URL(string: urlString),
              let token = Keychain.get("tv.token"), let userId = defaults.string(forKey: "user.id") else {
            phase = .connect
            return
        }
        let candidate = JellyfinClient(baseURL: url, token: token, deviceName: Self.deviceName, deviceId: DeviceIdentity.id)
        do {
            _ = try await candidate.me()
            activate(candidate, userId: userId, name: defaults.string(forKey: "server.name"))
        } catch let error as JellyfinError where error.isUnauthorized {
            phase = .connect
        } catch {
            // The Mac may have a new address; look it up by name on the network and keep the sign-in.
            if let bonjourName = defaults.string(forKey: "server.bonjour"),
               let found = await ServerBrowser.findOnce(named: bonjourName, timeout: 5) {
                let moved = JellyfinClient(baseURL: found.url, token: token, deviceName: Self.deviceName, deviceId: DeviceIdentity.id)
                if (try? await moved.me()) != nil {
                    defaults.set(found.url.absoluteString, forKey: "server.url")
                    activate(moved, userId: userId, name: defaults.string(forKey: "server.name"))
                    return
                }
            }
            phase = .connect
        }
    }

    func signedIn(url: URL, auth: AuthResult, serverName: String, bonjourName: String) {
        defaults.set(url.absoluteString, forKey: "server.url")
        defaults.set(bonjourName, forKey: "server.bonjour")
        defaults.set(serverName, forKey: "server.name")
        defaults.set(auth.user.id, forKey: "user.id")
        Keychain.set(auth.accessToken, for: "tv.token")
        let c = JellyfinClient(baseURL: url, token: auth.accessToken, deviceName: Self.deviceName, deviceId: DeviceIdentity.id)
        activate(c, userId: auth.user.id, name: serverName)
    }

    private func activate(_ client: JellyfinClient, userId: String, name: String?) {
        self.client = client
        self.userId = userId
        self.serverName = name
        phase = .ready
    }

    func signOut() {
        if let client { Task { try? await client.send("POST", "/Sessions/Logout") } }
        Keychain.set(nil, for: "tv.token")
        defaults.removeObject(forKey: "user.id")
        client = nil
        userId = nil
        phase = .connect
    }
}

struct RootView: View {
    @EnvironmentObject private var session: AppSession

    var body: some View {
        switch session.phase {
        case .launching:
            ProgressView().controlSize(.large)
        case .connect:
            ConnectView()
        case .ready:
            MainTabs()
                .alert("Can’t Play This Video", isPresented: Binding(
                    get: { session.playbackError != nil }, set: { if !$0 { session.playbackError = nil } })
                ) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(session.playbackError ?? "")
                }
                .background {
                    // A second alert needs its own view.
                    Color.clear.alert("Can’t Do That", isPresented: Binding(
                        get: { session.actionError != nil }, set: { if !$0 { session.actionError = nil } })
                    ) {
                        Button("OK", role: .cancel) {}
                    } message: {
                        Text(session.actionError ?? "")
                    }
                }
        }
    }
}

struct MainTabs: View {
    var body: some View {
        TabView {
            NavigationStack { HomeView() }
                .tabItem { Text("Home") }
            NavigationStack { LibraryGrid(collectionType: "movies", title: "Films") }
                .tabItem { Text("Films") }
            NavigationStack { LibraryGrid(collectionType: "homevideos", title: "Home Videos") }
                .tabItem { Text("Home Videos") }
            NavigationStack { SearchView() }
                .tabItem { Image(systemName: "magnifyingglass").accessibilityLabel("Search") }
            NavigationStack { SettingsView() }
                .tabItem { Image(systemName: "gearshape").accessibilityLabel("Settings") }
        }
    }
}

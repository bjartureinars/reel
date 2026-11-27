#if os(iOS)
import BackgroundTasks
#endif
import Network
import SwiftUI

#if os(iOS)
final class AppDelegate: NSObject, UIApplicationDelegate {
    static let refreshTask = "com.bjartur.reel.phone.refresh"

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Orientation.mask
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        MainActor.assumeIsolated {
            AppModel.shared.downloads.backgroundCompletion = completionHandler
        }
    }

    /// A scene delegate only to hear about Home Screen quick actions.
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                      options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshTask, using: nil) { task in
            Task { @MainActor in
                let app = AppModel.shared
                await app.library.refresh()
                await app.downloads.topUp()
                app.scheduleRefresh()
                task.setTaskCompleted(success: true)
            }
        }
        return true
    }
}

final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let item = connectionOptions.shortcutItem else { return }
        Task { @MainActor in
            // Opened by a quick action: let the first screen appear before acting on it.
            try? await Task.sleep(nanoseconds: 600_000_000)
            AppModel.shared.perform(item)
        }
    }

    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        MainActor.assumeIsolated { AppModel.shared.perform(shortcutItem) }
        completionHandler(true)
    }
}

#endif

enum AppTab: Hashable {
    case home, films, shows, downloads, settings, search
}

/// Everything the screens share.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let account = GoogleAccount()
    let library: Library
    let downloads = DownloadCenter()
    let player = PlayerModel()
    @Published private(set) var onCellular = false
    @Published private(set) var online = true
    @Published var cellularPrompt: (film: Film, seconds: Double)?
    @Published var notice: String?
    @Published var tab: AppTab = .home
    @AppStorage("streamOverCellular") var streamOverCellular = false
    private let monitor = NWPathMonitor()

    private init() {
        library = Library(tokens: account.tokens)
        downloads.attach(library: library)
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.online = path.status == .satisfied
                self?.onCellular = path.isExpensive
            }
        }
        monitor.start(queue: DispatchQueue(label: "reel.network"))
    }

    /// Plays a download if there is one, otherwise streams the original from Google Drive.
    func play(_ film: Film, from seconds: Double? = nil, forceStream: Bool = false, confirmedCellular: Bool = false) {
        let start = seconds ?? library.resumeSeconds(film)
        if !forceStream, let download = downloads.download(for: film), download.state == .ready {
            player.play(film, from: start, source: .download(download.quality), library: library, downloads: downloads)
            return
        }
        guard online else {
            notice = "You’re offline. Download films to watch them without a connection."
            return
        }
        if onCellular, !streamOverCellular, !confirmedCellular {
            cellularPrompt = (film, start)
            return
        }
        player.play(film, from: start, source: .stream, library: library, downloads: downloads)
    }

    /// Starts a download from a menu or a season; what goes wrong shows as a notice.
    func download(_ film: Film, quality: CopyQuality = .original) {
        Task {
            do { try await downloads.start(film, quality: quality) } catch { notice = error.localizedDescription }
        }
    }

    #if os(iOS)
    // MARK: Home Screen quick actions

    /// Resume what you were watching, plus Search and Downloads (home-screen-quick-actions.md: high-value tasks).
    func updateQuickActions() {
        var items: [UIApplicationShortcutItem] = []
        if let film = library.continueWatching.first {
            let left = film.seconds.map { "\(max(0, $0 - library.resumeSeconds(film)).runtimeText) left" }
            items.append(UIApplicationShortcutItem(type: "resume", localizedTitle: "Resume \(film.episode?.show ?? film.title)",
                                                   localizedSubtitle: [film.episodeLabel, left].compactMap { $0 }.joined(separator: " · "),
                                                   icon: UIApplicationShortcutIcon(systemImageName: "play.fill"),
                                                   userInfo: ["id": film.id as NSString]))
        }
        items.append(UIApplicationShortcutItem(type: "search", localizedTitle: "Search", localizedSubtitle: nil,
                                               icon: UIApplicationShortcutIcon(systemImageName: "magnifyingglass")))
        items.append(UIApplicationShortcutItem(type: "downloads", localizedTitle: "Downloads", localizedSubtitle: nil,
                                               icon: UIApplicationShortcutIcon(systemImageName: "arrow.down.circle")))
        UIApplication.shared.shortcutItems = items
    }

    func perform(_ item: UIApplicationShortcutItem) {
        switch item.type {
        case "resume":
            if let id = item.userInfo?["id"] as? String, let film = library.film(id) {
                tab = .home
                play(film)
            }
        case "search": tab = .search
        case "downloads": tab = .downloads
        default: break
        }
    }

    func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: AppDelegate.refreshTask)
        request.earliestBeginDate = Date().addingTimeInterval(15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    #endif

    /// While the Mac makes a copy, check on it every 30 seconds.
    func keepChecking() async {
        while !Task.isCancelled {
            await library.refresh()
            await downloads.topUp()
            let waiting = downloads.downloads.values.contains { $0.state == .waitingForMac || $0.state == .downloading }
            try? await Task.sleep(nanoseconds: waiting ? 30_000_000_000 : 300_000_000_000)
        }
    }
}

#if os(iOS)
@main
struct ReelPhoneApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var app = AppModel.shared
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .environmentObject(app.account)
                .environmentObject(app.library)
                .environmentObject(app.downloads)
                .preferredColorScheme(.dark)
                .tint(Theme.gold)
        }
        .onChange(of: phase) { _, phase in
            switch phase {
            case .background:
                app.player.save(push: true)
                app.updateQuickActions()
                app.scheduleRefresh()
                Task { await app.downloads.topUp() }
            case .active:
                Task { await app.downloads.topUp() }
            default:
                break
            }
        }
    }
}

#endif

struct RootView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var account: GoogleAccount
    @EnvironmentObject private var library: Library
    @ObservedObject private var player = AppModel.shared.player
    #if os(macOS)
    @ObservedObject private var compare = CompareModel.shared
    #endif

    var body: some View {
        Group {
            if account.isSignedIn || !library.films.isEmpty {
                MainTabs()
                    .task(id: account.isSignedIn) {
                        guard account.isSignedIn else { return }
                        await app.keepChecking()
                    }
            } else {
                SignInView()
            }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $player.isPresented, onDismiss: { player.close() }) {
            PlayerView(model: player)
        }
        #else
        // On the Mac the film fills the window, like Apple's TV app; full screen is the window's own (⌃⌘F).
        .overlay {
            if player.isPresented {
                PlayerView(model: player)
                    .transition(.opacity)
                    .onDisappear { player.close() }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: player.isPresented)
        .overlay {
            if compare.isPresented {
                CompareView(model: compare)
                    .transition(.opacity)
                    .onDisappear { compare.close() }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: compare.isPresented)
        .toolbar(player.isPresented || compare.isPresented ? .hidden : .automatic, for: .windowToolbar)
        #endif
        .alert("Stream Over Mobile Data?", isPresented: Binding(get: { app.cellularPrompt != nil },
                                                                set: { if !$0 { app.cellularPrompt = nil } })) {
            Button("Play") {
                if let prompt = app.cellularPrompt { app.play(prompt.film, from: prompt.seconds, confirmedCellular: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Reel streams the original film, which can use 15–25 GB an hour. You can allow this in Settings.")
        }
        .alert("Reel", isPresented: Binding(get: { app.notice != nil }, set: { if !$0 { app.notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(app.notice ?? "")
        }
    }
}

struct MainTabs: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var downloads: DownloadCenter

    var body: some View {
        TabView(selection: $app.tab) {
            Tab("Home", systemImage: "house.fill", value: AppTab.home) {
                NavigationStack { HomeView() }
            }
            Tab("Films", systemImage: "film.stack.fill", value: AppTab.films) {
                NavigationStack { LibraryView() }
            }
            Tab("TV Shows", systemImage: "tv.fill", value: AppTab.shows) {
                NavigationStack { ShowsView() }
            }
            Tab("Downloads", systemImage: "arrow.down.circle.fill", value: AppTab.downloads) {
                NavigationStack { DownloadsView() }
            }
            .badge(downloads.downloads.values.filter { $0.state != .ready }.count)
            // iPhone has room for five tabs without a More tab; its Settings open from Home.
            // The Mac keeps settings in its Settings window (⌘,).
            if Device.isPad && !Device.isMac {
                Tab("Settings", systemImage: "gearshape.fill", value: AppTab.settings) {
                    NavigationStack { SettingsView() }
                }
            }
            Tab(value: AppTab.search, role: .search) {
                NavigationStack { SearchView() }
            }
        }
        // A sidebar on iPad, which can be hidden; the usual tab bar on iPhone.
        .tabViewStyle(.sidebarAdaptable)
    }
}

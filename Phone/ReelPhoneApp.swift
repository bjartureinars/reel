import BackgroundTasks
import Network
import SwiftUI

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

    func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: AppDelegate.refreshTask)
        request.earliestBeginDate = Date().addingTimeInterval(15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

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

struct RootView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var account: GoogleAccount
    @EnvironmentObject private var library: Library
    @ObservedObject private var player = AppModel.shared.player

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
        .fullScreenCover(isPresented: $player.isPresented, onDismiss: { player.close() }) {
            PlayerView(model: player)
        }
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
    @EnvironmentObject private var downloads: DownloadCenter

    var body: some View {
        TabView {
            Tab("Home", systemImage: "house.fill") {
                NavigationStack { HomeView() }
            }
            Tab("Library", systemImage: "film.stack.fill") {
                NavigationStack { LibraryView() }
            }
            Tab("Downloads", systemImage: "arrow.down.circle.fill") {
                NavigationStack { DownloadsView() }
            }
            .badge(downloads.downloads.values.filter { $0.state != .ready }.count)
            Tab("Settings", systemImage: "gearshape.fill") {
                NavigationStack { SettingsView() }
            }
            Tab(role: .search) {
                NavigationStack { SearchView() }
            }
        }
    }
}

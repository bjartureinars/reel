import SwiftUI

/// Reel for Mac: the same library, player and downloads as Reel for iPhone and iPad, streaming the original film
/// straight from Google Drive, in a Mac window with a sidebar, menus and keyboard control.
@main
struct ReelMacApp: App {
    @StateObject private var app = AppModel.shared
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        Window("Reel", id: "main") {
            RootView()
                .environmentObject(app)
                .environmentObject(app.account)
                .environmentObject(app.library)
                .environmentObject(app.downloads)
                .preferredColorScheme(.dark)
                .tint(Theme.gold)
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1280, height: 820)
        .commands { ReelCommands(app: app, player: app.player) }
        .onChange(of: phase) { _, phase in
            switch phase {
            case .background, .inactive:
                app.player.save(push: true)
                Task { await app.downloads.topUp() }
            case .active:
                Task { await app.downloads.topUp() }
            @unknown default:
                break
            }
        }

        Settings {
            NavigationStack { SettingsView() }
                .environmentObject(app)
                .environmentObject(app.account)
                .environmentObject(app.library)
                .environmentObject(app.downloads)
                .preferredColorScheme(.dark)
                .tint(Theme.gold)
                .frame(width: 560, height: 640)
        }
    }
}

/// Every command in the menu bar, as on any Mac app: sections, refreshing, and the player's controls.
struct ReelCommands: Commands {
    @ObservedObject var app: AppModel
    @ObservedObject var player: PlayerModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandMenu("Go") {
            Button("Home") { app.tab = .home }.keyboardShortcut("1")
            Button("Films") { app.tab = .films }.keyboardShortcut("2")
            Button("TV Shows") { app.tab = .shows }.keyboardShortcut("3")
            Button("Downloads") { app.tab = .downloads }.keyboardShortcut("4")
            Divider()
            Button("Search") { app.tab = .search }.keyboardShortcut("f")
            Divider()
            Button("Refresh Library") { Task { await app.library.refresh() } }.keyboardShortcut("r")
        }
        CommandMenu("Playback") {
            Button(player.playing ? "Pause" : "Play") { player.togglePlay() }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(!player.isPresented)
            Button("Back 10 Seconds") { player.skip(-10) }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(!player.isPresented)
            Button("Forward 10 Seconds") { player.skip(10) }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(!player.isPresented)
            Divider()
            if let next = player.nextEpisode {
                Button("Next Episode") { player.playNext() }
                    .keyboardShortcut(.rightArrow, modifiers: [.command])
                    .help("Plays \(next.episodeLabel ?? next.title)")
            }
            Button("Stop Playing") { player.isPresented = false }
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(!player.isPresented)
        }
    }
}

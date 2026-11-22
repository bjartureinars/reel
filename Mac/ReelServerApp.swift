import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

@main
struct ReelServerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var server: ServerManager

    init() { _server = ObservedObject(wrappedValue: ServerManager.shared) }

    var body: some Scene {
        Window("Reel", id: "main") {
            ContentView(server: server)
        }
        .defaultSize(width: 1120, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Films…") { addWithPanel(.films) }
                    .keyboardShortcut("o")
                Button("Add Home Videos…") { addWithPanel(.homeVideos) }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandMenu("Server") {
                Button("Scan Library Now") { Task { await server.rescan() } }
                    .keyboardShortcut("r")
                    .disabled(server.state != .running)
                Button("Restart Server") { Task { await server.restart() } }
                Divider()
                Button("Open Jellyfin Dashboard") { NSWorkspace.shared.open(server.webDashboardURL) }
                    .disabled(server.state != .running)
                Button("Show Library in Finder") { NSWorkspace.shared.open(server.libraryRoot) }
                Button("Show Server Logs") { NSWorkspace.shared.open(server.logsDir) }
            }
        }

        MenuBarExtra {
            MenuBarContent(server: server)
        } label: {
            Image(systemName: server.isStreaming ? "play.tv.fill" : "play.tv")
                .accessibilityLabel(server.isStreaming ? "Reel, streaming" : "Reel")
        }

        Settings {
            SettingsView(server: server)
        }
    }
}

@MainActor
func addWithPanel(_ kind: LibraryKind) {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = true
    panel.allowedContentTypes = [.movie, .folder]
    panel.prompt = "Add to \(kind.rawValue)"
    switch ServerManager.shared.addMode {
    case .move: panel.message = "Choose films or folders. They’ll move to Google Drive and be deleted from this Mac once Google’s copy is verified."
    case .copy: panel.message = "Choose films or folders. A copy goes to Google Drive. Your originals stay where they are."
    case .link: panel.message = "Choose films or folders. They’ll be linked into the library and stay on this Mac."
    }
    guard panel.runModal() == .OK else { return }
    ServerManager.shared.add(panel.urls, to: kind)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await ServerManager.shared.start() }
    }

    /// Closing the window keeps the server running from the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        ServerManager.shared.stop()
    }
}

// MARK: - Menu bar

struct MenuBarContent: View {
    @ObservedObject var server: ServerManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(statusLine)
        ForEach(server.sessions) { s in
            Text("▶︎ \(s.nowPlayingItem?.title ?? "") on \(s.deviceName ?? "Apple TV")")
        }
        Divider()
        Button("Open Reel") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Add Films…") { NSApp.activate(ignoringOtherApps: true); addWithPanel(.films) }
        Divider()
        Button("Quit Reel Server") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var statusLine: String {
        switch server.state {
        case .running: return server.isStreaming ? "Streaming to \(server.sessions.count) device\(server.sessions.count == 1 ? "" : "s")" : "Server running"
        case .starting: return "Server starting…"
        case .missing: return "Jellyfin isn't installed"
        case .failed: return "Server stopped"
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var server: ServerManager
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var copied = false

    var body: some View {
        Form {
            Section("General") {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
                Toggle("Keep this Mac awake while streaming", isOn: $server.keepAwakeWhileStreaming)
                Text("A sleeping Mac stops the stream. The display can still sleep.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Adding Films") {
                Picker("When you add a file", selection: $server.addMode) {
                    ForEach(AddMode.allCases) { Text($0.label).tag($0) }
                }
                Text(modeExplanation).font(.caption).foregroundStyle(.secondary)
                LabeledContent("Library folder") {
                    Button("Show in Finder") { NSWorkspace.shared.open(server.libraryRoot) }
                }
            }
            Section("Server") {
                LabeledContent("Address", value: server.lanAddress.map { "http://\($0):\(Reel.port)" } ?? "Not on a network")
                LabeledContent("Jellyfin", value: server.version ?? "–")
                LabeledContent("Administrator", value: server.adminName)
                LabeledContent("Password") {
                    Button(copied ? "Copied" : "Copy Password") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(server.adminPassword, forType: .string)
                        copied = true
                    }
                }
                Text("Use these to sign in to the Jellyfin dashboard for advanced settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var modeExplanation: String {
        switch server.addMode {
        case .move: return "Files move into the drop folder and wait for your OK under Google Drive. Then they upload, and are permanently deleted from this Mac once Google’s copy is verified."
        case .copy: return "Keeps your original. The copy waits for your OK under Google Drive, then uploads. Needs free space for that copy until the upload finishes."
        case .link: return "Uses no space, but the film stops playing if you move or delete the original."
        }
    }
}

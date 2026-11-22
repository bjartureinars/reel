import SwiftUI
import UniformTypeIdentifiers

/// Google Drive: setup, account, and what's happening to each film.
struct CloudView: View {
    @ObservedObject var server: ServerManager
    @ObservedObject var cloud: CloudStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if cloud.connected {
                    AccountBox(server: server, cloud: cloud)
                } else {
                    ConnectBox(server: server)
                }
                if let problem = server.cloudProblem ?? cloud.problem {
                    HStack(alignment: .firstTextBaseline) {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                        Spacer()
                        Button("Try Again") { cloud.retry() }
                    }
                }
                if cloud.connected { SpeedBox(cloud: cloud) }
                DropFolderBox(folder: cloud.paths.drop)
                if !cloud.pending.isEmpty {
                    Text("Waiting for Your OK").font(.title2.weight(.semibold))
                    ForEach(cloud.pending) { PendingRow(cloud: cloud, item: $0) }
                }
                if !cloud.films.isEmpty {
                    Text("Films").font(.title2.weight(.semibold))
                    ForEach(cloud.films) { FilmRow(cloud: cloud, film: $0) }
                }
            }
            .padding(28)
            .frame(maxWidth: 780, alignment: .leading)
        }
        .navigationTitle("Google Drive")
    }
}

private struct SpeedBox: View {
    @ObservedObject var cloud: CloudStore

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Faster Uploads", systemImage: "bolt.fill").font(.headline)
                    Spacer()
                    Toggle("Faster Uploads", isOn: $cloud.fasterUploads)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                Text("Uses up to \(DriveClient.laneCount) connections at once, so it takes much more of your Wi-Fi. It eases off while a film plays.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Films over 2 GB are stored in Drive as 1 GB pieces. They stream and download normally in Reel, but won’t play on Google Drive’s website. Turn it off to carry on as a single file from where that left off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if cloud.fasterUploads, let film = cloud.films.first(where: { !$0.verified }), !cloud.canSpeedUp(film) {
                    Text("The current film is too small or too far along to gain from this, so it’s finishing as a single file.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct DropFolderBox: View {
    let folder: URL

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Label("Drop Folder", systemImage: "tray.and.arrow.down").font(.headline)
                Text("Put films in \((folder.path as NSString).abbreviatingWithTildeInPath). Nothing happens to one until you approve it here. Then it appears on your Apple TV, and Reel uploads it to Google Drive, checks Google’s copy against the original and permanently deletes the original from this Mac. Don’t use this folder as a download app’s save location. Put home videos in a “Home Videos” folder inside it.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Drop Folder") { NSWorkspace.shared.open(folder) }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct AccountBox: View {
    @ObservedObject var server: ServerManager
    @ObservedObject var cloud: CloudStore
    @State private var confirmSignOut = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Label("Connected to Google Drive", systemImage: "checkmark.icloud").font(.headline)
                if let quota = cloud.quota {
                    if let email = quota.email { Text(email).foregroundStyle(.secondary) }
                    if let limit = quota.limit, limit > 0 {
                        ProgressView(value: min(Double(quota.used) / Double(limit), 1))
                        Text("\(quota.used.formatted(.byteCount(style: .file))) of \(limit.formatted(.byteCount(style: .file))) used")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Button("Sign Out…") { confirmSignOut = true }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .alert("Sign out of Google Drive?", isPresented: $confirmSignOut) {
            Button("Sign Out", role: .destructive) { Task { await server.signOutOfGoogle() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Films in Google Drive can’t be played until you sign in again. Nothing is deleted.")
        }
    }
}

private struct ConnectBox: View {
    @ObservedObject var server: ServerManager
    @State private var hasKey = false
    @State private var working = false
    @State private var error: String?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                Label("Connect Google Drive", systemImage: "icloud").font(.headline)
                Text("Google requires a private app to have its own key. You make it once, for free, in the Google account that has your Drive storage. Reel can only see files it uploaded itself.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Step(number: 1, text: "Create a new project just for Reel, check that the top bar shows it, and enable the Google Drive API.",
                     link: "https://console.cloud.google.com/flows/enableapi?apiid=drive.googleapis.com")
                Step(number: 2, text: "Press Get Started. App name: Reel. Audience: External. Then under Branding add a home page link, a privacy policy link and their domain. Google won’t publish without them.",
                     link: "https://console.cloud.google.com/auth/overview")
                Step(number: 3, text: "Under Audience press Publish App. Otherwise Google signs Reel out every 7 days.",
                     link: "https://console.cloud.google.com/auth/audience")
                Step(number: 4, text: "Create a client with the type Desktop app and press Download JSON before closing that window. Google shows the key only once.",
                     link: "https://console.cloud.google.com/auth/clients")
                Step(number: 5, text: "Choose that file here, then sign in.", link: nil)
                HStack {
                    Button(hasKey ? "Replace Key File…" : "Choose Key File…", action: chooseKey)
                        .disabled(working)
                    Button(action: signIn) {
                        if working { Text("Waiting for your browser…") } else { Text("Sign In with Google") }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasKey || working)
                    if hasKey { Label("Key saved", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                }
                if let error {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { hasKey = server.google.hasKey }
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.prompt = "Use Key"
        panel.message = "Choose the client_secret….json file you downloaded from Google Cloud."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await server.google.importKey(from: url)
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
            hasKey = server.google.hasKey
        }
    }

    private func signIn() {
        working = true
        error = nil
        Task {
            do {
                try await server.signInToGoogle()
            } catch {
                self.error = error.localizedDescription
            }
            working = false
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

private struct Step: View {
    let number: Int
    let text: String
    let link: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number).").monospacedDigit().foregroundStyle(.secondary)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let link, let url = URL(string: link) {
                Link("Open", destination: url)
                    .accessibilityLabel("Open step \(number) in Google Cloud")
            }
        }
    }
}

private struct PendingRow: View {
    @ObservedObject var cloud: CloudStore
    let item: PendingFilm
    @State private var error: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .frame(width: 22)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                if item.size > 0 {
                    Text(item.size.formatted(.byteCount(style: .file))).font(.caption).foregroundStyle(.secondary)
                }
                Text(explanation).font(.caption).foregroundStyle(tint).fixedSize(horizontal: false, vertical: true)
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                HStack {
                    if item.state == .ready {
                        Button("Upload, Then Delete Original") {
                            do {
                                try cloud.approve(item)
                            } catch {
                                self.error = error.localizedDescription
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
                    }
                }
                .controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var explanation: String {
        switch item.state {
        case .waiting(let reason), .blocked(let reason): return reason
        case .ready: return "No gaps found. Approve it only if you know it has finished downloading or copying."
        }
    }

    private var symbol: String {
        switch item.state {
        case .waiting: return "clock"
        case .blocked: return "exclamationmark.triangle.fill"
        case .ready: return "checkmark.circle"
        }
    }

    private var tint: Color {
        switch item.state {
        case .waiting: return .secondary
        case .blocked: return .orange
        case .ready: return .primary
        }
    }
}

private struct FilmRow: View {
    @ObservedObject var cloud: CloudStore
    let film: CloudFilm

    var body: some View {
        let status = cloud.status(film)
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol(status.phase))
                .frame(width: 22)
                .foregroundStyle(status.phase == .local ? Color.secondary : Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(film.name).lineLimit(1).truncationMode(.middle)
                Text(line(status)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                if let progress = status.progress { ProgressView(value: progress).controlSize(.small) }
                if let error = status.error {
                    HStack(alignment: .firstTextBaseline) {
                        Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                        Button("Retry") { cloud.retry() }.controlSize(.small)
                    }
                }
            }
            Spacer(minLength: 0)
            if status.phase == .downloaded {
                Button("Remove Download") { cloud.offload(film.id) }
                    .controlSize(.small)
                    .help("Frees the space on this Mac. The film stays in Google Drive.")
            } else if status.phase == .downloading {
                Button("Cancel") { cloud.cancelDownload(film.id) }.controlSize(.small)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func line(_ status: FilmStatus) -> String {
        var parts = [status.detail, status.size.formatted(.byteCount(style: .file))]
        if let speed = status.megabitsPerSecond { parts.append("\(Int(speed)) Mbps") }
        if let left = status.secondsLeft { parts.append("\(max(1, Int(left / 60))) min left") }
        return parts.joined(separator: " · ")
    }

    private func symbol(_ phase: FilmStatus.Phase) -> String {
        switch phase {
        case .local: return "arrow.up.circle"
        case .cloud: return "cloud.fill"
        case .downloading: return "arrow.down.circle"
        case .downloaded: return "internaldrive.fill"
        }
    }
}

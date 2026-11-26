import SwiftUI

/// The detail page's controls. A Google Drive film offers Stream and Download to Mac; other films just play.
struct FilmActions: View {
    let item: Item
    /// For a film with several versions, the one these buttons play and download (the default version).
    var version: String? = nil
    @EnvironmentObject private var session: AppSession
    @State private var status: FilmStatus?
    @State private var loaded = false
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let status {
                VStack(alignment: .leading, spacing: 10) {
                    Label(line(status), systemImage: symbol(status.phase))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    if status.phase == .downloading, let progress = status.progress {
                        ProgressView(value: progress).frame(width: 700)
                    }
                    if let error = status.error {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .frame(maxWidth: 1100, alignment: .leading)
                    }
                }
            }
            HStack(spacing: 24) {
                if loaded {
                    buttons
                } else {
                    ProgressView()
                }
            }
            .padding(.top, 6)
            .focusSection()
        }
        .task(id: "\(item.id)-\(version ?? "")") { await poll() }
    }

    @ViewBuilder private var buttons: some View {
        switch status?.phase {
        case nil, .local:
            PlayButtons(item: item)
        case .cloud:
            playButton(.stream, title: "Stream")
            Button { act("download") } label: {
                Label("Download to Mac", systemImage: "arrow.down.circle")
            }
            .disabled(working)
            startOver(.stream)
        case .downloading:
            playButton(.stream, title: "Stream Now")
            Button { act("cancel") } label: {
                Label("Cancel Download", systemImage: "xmark")
            }
            .disabled(working)
        case .downloaded:
            playButton(.mac, title: "Play from Mac")
            playButton(.stream, title: "Stream")
            startOver(.mac)
        }
    }

    private func playButton(_ source: PlaybackSource, title: String) -> some View {
        Button { play(item.resumeSeconds, source) } label: {
            Label(title, systemImage: source == .mac ? "play.fill" : "icloud.fill")
        }
    }

    @ViewBuilder private func startOver(_ source: PlaybackSource) -> some View {
        if item.resumeSeconds > 0 {
            Button { play(0, source) } label: {
                Label("Start Over", systemImage: "arrow.counterclockwise")
            }
        }
    }

    private func play(_ seconds: Double, _ source: PlaybackSource) {
        Task { await PlaybackController.shared.play(item, from: seconds, session: session, source: source, version: version) }
    }

    private func act(_ action: String) {
        guard let client = session.client else { return }
        working = true
        Task {
            do {
                status = try await CloudClient(jellyfin: client).perform(action, version ?? item.id)
            } catch {
                session.actionError = error.localizedDescription
            }
            working = false
        }
    }

    private func poll() async {
        guard let client = session.client else { return }
        let cloud = CloudClient(jellyfin: client)
        while !Task.isCancelled {
            do {
                let latest = try await cloud.status(version ?? item.id)
                status = latest
                loaded = true
                if latest == nil { return } // an ordinary library film; nothing to watch
            } catch {
                loaded = true
            }
            try? await Task.sleep(nanoseconds: status?.phase == .downloading ? 1_000_000_000 : 3_000_000_000)
        }
    }

    private func line(_ status: FilmStatus) -> String {
        var parts = [status.detail, status.size.formatted(.byteCount(style: .file))]
        if let speed = status.megabitsPerSecond { parts.append("\(Int(speed)) Mbps") }
        if let left = status.secondsLeft {
            parts.append(left < 60 ? "less than a minute left" : "\(Int(left / 60)) min left")
        }
        return parts.joined(separator: "  ·  ")
    }

    private func symbol(_ phase: FilmStatus.Phase) -> String {
        switch phase {
        case .local, .downloaded: return "internaldrive"
        case .cloud: return "icloud"
        case .downloading: return "arrow.down.circle"
        }
    }
}

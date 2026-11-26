import AppKit
import SwiftUI

/// The Add Magnet Link and Add Torrent windows, shown over the main window.
struct TorrentSheets: ViewModifier {
    @ObservedObject var torrents: TorrentStore

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $torrents.askingForLink) { MagnetLinkSheet(torrents: torrents) }
            .sheet(item: Binding(get: { torrents.choosing.map(ChoosingID.init) }, set: { torrents.choosing = $0?.id })) { choice in
                AddTorrentSheet(torrents: torrents, jobID: choice.id)
            }
    }

    private struct ChoosingID: Identifiable { let id: UUID }
}

// MARK: - Pasting a link

private struct MagnetLinkSheet: View {
    @ObservedObject var torrents: TorrentStore
    @State private var link = ""
    @Environment(\.dismiss) private var dismiss

    private var valid: Bool { link.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("magnet:?") }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Magnet Link").font(.title2.weight(.bold))
            Text("Paste a magnet link. Reel gets the torrent’s file list first; nothing downloads until you choose what to keep.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("magnet:?xt=urn:btih:…", text: $link, axis: .vertical)
                .lineLimit(3...5)
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospaced())
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Continue") {
                    let text = link
                    dismiss()
                    torrents.open(text)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!valid)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear {
            // A magnet link already on the clipboard is almost certainly the one.
            if let copied = NSPasteboard.general.string(forType: .string), copied.lowercased().hasPrefix("magnet:?") { link = copied }
        }
    }
}

// MARK: - Choosing what to download

private struct AddTorrentSheet: View {
    @ObservedObject var torrents: TorrentStore
    let jobID: UUID
    @State private var selected: Set<Int> = []
    @State private var asShow = false
    @State private var showAll = false
    @State private var problem: String?
    @State private var prepared = false
    @State private var isDefaultHandler = MagnetHandler.isDefault

    private var job: TorrentJob? { torrents.job(jobID) }
    private var files: [TorrentFile] {
        let all = (job?.files ?? []).sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return showAll ? all : all.filter(\.isVideo)
    }
    private var chosen: [TorrentFile] { (job?.files ?? []).filter { selected.contains($0.index) }.sorted { $0.path < $1.path } }
    private var total: Int64 { chosen.reduce(0) { $0 + $1.size } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add Torrent").font(.title2.weight(.bold))
                Text(job?.name ?? "").font(.headline).lineLimit(2).truncationMode(.middle)
            }
            if job?.phase == .details {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Getting the torrent’s details…")
                        if let live = torrents.live[jobID] {
                            Text(live.peers == 1 ? "1 peer" : "\(live.peers) peers").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 160)
                Text("This usually takes a few seconds, longer for torrents with few people sharing them.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Picker("Add to", selection: $asShow) {
                    Text("Films").tag(false)
                    Text("TV Shows").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
                List {
                    ForEach(files) { file in
                        Toggle(isOn: Binding(get: { selected.contains(file.index) },
                                             set: { on in if on { selected.insert(file.index) } else { selected.remove(file.index) } })) {
                            HStack {
                                Text(file.path).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(file.size.formatted(.byteCount(style: .file))).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                    }
                }
                .frame(minHeight: 160, maxHeight: 280)
                if (job?.files.count ?? 0) > files.count || showAll {
                    Toggle("Show files that aren’t videos", isOn: $showAll).controlSize(.small)
                }
                Text(summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let problem = problem ?? job?.problem {
                Text(problem).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if !isDefaultHandler {
                    Button("Open Magnet Links with Reel Server") {
                        MagnetHandler.makeDefault { isDefaultHandler = $0 }
                    }
                    .help("Clicking a magnet link in your browser then opens this window")
                }
                Spacer()
                Button("Cancel", role: .cancel) { torrents.cancel(jobID) }
                    .keyboardShortcut(.cancelAction)
                Button(chosen.count > 1 ? "Download \(chosen.count) to Google Drive" : "Download to Google Drive") {
                    do { try torrents.approve(jobID, files: chosen, asShow: asShow) } catch { problem = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(job?.phase != .choosing || chosen.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 620)
        .onChange(of: job?.phase) { _, _ in prepare() }
        .onAppear { prepare() }
    }

    private var summary: String {
        guard !chosen.isEmpty else { return "Choose what to keep." }
        let window = TorrentStore.windowParts()
        return "\(chosen.count == 1 ? "1 file" : "\(chosen.count) files"), \(total.formatted(.byteCount(style: .file))), "
            + "downloaded in 1 GB parts straight to Google Drive. At most about \(window + 1) GB is on this Mac at a time. "
            + "Each part is checked twice, against the torrent and against Google’s copy, before it’s deleted here."
    }

    /// Picks the obvious choice: every episode of a season pack, otherwise the biggest video.
    private func prepare() {
        guard !prepared, let job, job.phase == .choosing else { return }
        prepared = true
        let videos = job.files.filter(\.isVideo)
        let episodes = videos.filter(\.looksLikeEpisode)
        if episodes.count >= 2 {
            asShow = true
            // Bonus material is left for him to tick if he wants it.
            selected = Set(episodes.filter { !TorrentStore.isExtra($0) }.map(\.index))
        } else if let biggest = videos.max(by: { $0.size < $1.size }) {
            asShow = biggest.looksLikeEpisode
            selected = [biggest.index]
        }
    }
}

/// Makes Reel Server the app that opens magnet links. macOS asks before changing it.
enum MagnetHandler {
    static var isDefault: Bool {
        guard let url = URL(string: "magnet:?xt=urn:btih:0"),
              let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return false }
        return app.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    static func makeDefault(_ done: @escaping @MainActor (Bool) -> Void) {
        NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: "magnet") { _ in
            Task { @MainActor in done(isDefault) }
        }
    }
}

// MARK: - On the Google Drive page

struct TorrentList: View {
    @ObservedObject var torrents: TorrentStore
    @State private var confirmCancel: TorrentJob?

    var body: some View {
        if !torrents.jobs.isEmpty {
            HStack {
                Text("Torrents").font(.title2.weight(.semibold))
                Spacer()
                if torrents.jobs.contains(where: { $0.phase == .done }) {
                    Button("Clear Finished") { torrents.clearFinished() }
                }
            }
            ForEach(torrents.jobs) { job in
                TorrentRow(job: job, live: torrents.live[job.id]) {
                    if job.phase == .choosing || job.phase == .details { torrents.choosing = job.id } else { confirmCancel = job }
                }
            }
            .alert("Stop “\(confirmCancel?.name ?? "")”?", isPresented: Binding(get: { confirmCancel != nil },
                                                                              set: { if !$0 { confirmCancel = nil } })) {
                Button("Stop Download", role: .destructive) { if let job = confirmCancel { torrents.cancel(job.id) } }
                Button("Keep Downloading", role: .cancel) {}
            } message: {
                Text("What it has sent to Google Drive so far is deleted. Anything already in your library stays.")
            }
        }
    }
}

private struct TorrentRow: View {
    let job: TorrentJob
    let live: TorrentLive?
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title2).foregroundStyle(tint).frame(width: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(job.name).lineLimit(1).truncationMode(.middle)
                if job.phase == .working, job.totalSize > 0 {
                    ProgressView(value: Double(progressBytes), total: Double(job.totalSize))
                        .accessibilityLabel("In Google Drive")
                        .accessibilityValue("\(Int(Double(progressBytes) / Double(job.totalSize) * 100)) percent")
                }
                Text(line).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                if let problem = job.problem, job.phase != .done {
                    Text(problem).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            switch job.phase {
            case .details, .choosing: Button("Choose Files…", action: action).controlSize(.small)
            case .working: Button("Stop…", action: action).controlSize(.small)
            default: EmptyView()
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// Whole parts in Drive plus what's on its way, so 1 GB parts don't leave the bar standing still.
    private var progressBytes: Int64 { job.uploadedBytes + (live?.sending.values.reduce(0, +) ?? 0) }

    private var line: String {
        let mbit = { (bytes: Int) in String(format: "%.0f Mbit/s", Double(bytes) * 8 / 1_000_000) }
        switch job.phase {
        case .details: return "Getting the torrent’s details…"
        case .choosing: return "Waiting for you to choose files"
        case .done: return job.items.count == 1 ? "In your library" : "\(job.items.count) files in your library"
        case .failed: return "Couldn’t continue"
        case .working:
            let size = job.totalSize.formatted(.byteCount(style: .file))
            var parts = ["\(progressBytes.formatted(.byteCount(style: .file))) of \(size) in Google Drive"]
            if job.items.count > 1, let current = job.current, let index = job.items.firstIndex(of: current) {
                parts.append("file \(index + 1) of \(job.items.count)")
            }
            if let live {
                if live.downloadRate > 0 || live.peers > 0 {
                    parts.append("downloading \(mbit(live.downloadRate)) from \(live.peers) \(live.peers == 1 ? "peer" : "peers")")
                } else {
                    parts.append("looking for people sharing it")
                }
                if live.uploadToDrive > 0 { parts.append("to Drive \(mbit(live.uploadToDrive))") }
            }
            return parts.joined(separator: " · ")
        }
    }

    private var symbol: String {
        switch job.phase {
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        default: return "arrow.down.circle"
        }
    }

    private var tint: Color {
        switch job.phase {
        case .done: return .green
        case .failed: return .orange
        default: return .secondary
        }
    }
}

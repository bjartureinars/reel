import SwiftUI
import UniformTypeIdentifiers

enum SidebarItem: Hashable {
    case library(LibraryKind)
    case appleTV
    case googleDrive
}

struct ContentView: View {
    @ObservedObject var server: ServerManager
    @State private var selection: SidebarItem? = .library(.films)
    @State private var showPairing = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Library") {
                    ForEach(LibraryKind.allCases) { kind in
                        Label(kind.rawValue, systemImage: kind.symbol)
                            .badge(server.libraries[kind]?.count ?? 0)
                            .tag(SidebarItem.library(kind))
                    }
                }
                Section("Streaming") {
                    Label("Apple TV", systemImage: "appletv")
                        .badge(server.sessions.count)
                        .tag(SidebarItem.appleTV)
                    DriveSidebarLabel(cloud: server.cloud)
                        .tag(SidebarItem.googleDrive)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
            .safeAreaInset(edge: .bottom) { ServerStatusFooter(server: server) }
        } detail: {
            Group {
                switch server.state {
                case .running:
                    switch selection ?? .library(.films) {
                    case .library(let kind): LibraryView(server: server, kind: kind)
                    case .appleTV: AppleTVView(server: server)
                    case .googleDrive: CloudView(server: server, cloud: server.cloud)
                    }
                default:
                    ServerStateView(server: server)
                }
            }
            .frame(minWidth: 560, minHeight: 420)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    if case .library(let kind) = selection { addWithPanel(kind) } else { addWithPanel(.films) }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .help("Add films or folders (⌘O)")
                .disabled(server.state != .running)

                Button {
                    showPairing = true
                } label: {
                    Label("Connect Apple TV", systemImage: "appletv.badge.checkmark")
                }
                .help("Connect an Apple TV with the code it shows")
                .disabled(server.state != .running)
            }
        }
        .sheet(isPresented: $showPairing) { PairingSheet(server: server) }
    }
}

// MARK: - Status

private struct ServerStatusFooter: View {
    @ObservedObject var server: ServerManager

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.medium))
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch server.state {
        case .running: return .green
        case .starting: return .orange
        case .missing, .failed: return .red
        }
    }

    private var title: String {
        switch server.state {
        case .running: return server.scanProgress != nil ? "Scanning library…" : "Server running"
        case .starting: return "Starting…"
        case .missing: return "Jellyfin missing"
        case .failed: return "Server stopped"
        }
    }

    private var detail: String? {
        guard server.state == .running else { return nil }
        if let p = server.scanProgress { return "\(Int(p * 100))%" }
        return server.lanAddress.map { "\($0):\(Reel.port)" }
    }
}

struct ServerStateView: View {
    @ObservedObject var server: ServerManager

    var body: some View {
        VStack(spacing: 16) {
            switch server.state {
            case .starting(let message):
                ProgressView().controlSize(.large)
                Text(message).font(.title3).multilineTextAlignment(.center)
            case .missing:
                Image(systemName: "shippingbox").font(.system(size: 48)).foregroundStyle(.secondary)
                Text("Jellyfin isn't installed yet").font(.title2.weight(.semibold))
                Text("Run the Reel setup script once. It downloads Jellyfin 12.4 from jellyfin.org and installs it for Reel.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 420)
                Button("Try Again") { Task { await server.start() } }
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle").font(.system(size: 48)).foregroundStyle(.orange)
                Text("The server stopped").font(.title2.weight(.semibold))
                Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 460)
                    .textSelection(.enabled)
                HStack {
                    Button("Show Logs") { NSWorkspace.shared.open(server.logsDir) }
                    Button("Restart Server") { Task { await server.restart() } }
                        .buttonStyle(.borderedProminent)
                }
            case .running:
                EmptyView()
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Library

struct LibraryView: View {
    @ObservedObject var server: ServerManager
    let kind: LibraryKind
    @State private var targeted = false
    @State private var pendingRemoval: Item?

    private var items: [Item] { server.libraries[kind] ?? [] }
    private var isFilm: Bool { kind == .films }

    var body: some View {
        ZStack {
            if items.isEmpty {
                EmptyLibrary(kind: kind, mode: server.addMode)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: isFilm ? 150 : 230, maximum: isFilm ? 200 : 320),
                                                 spacing: 20)], spacing: 24) {
                        ForEach(items) { item in
                            LibraryCard(item: item, imageURL: server.posterURL(for: item, kind: kind), isFilm: isFilm)
                                .contextMenu {
                                    if let path = item.path {
                                        Button("Show in Finder") {
                                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                                        }
                                    }
                                    Divider()
                                    Button("Remove from Library…", role: .destructive) { pendingRemoval = item }
                                }
                        }
                    }
                    .padding(24)
                }
            }
            if targeted {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay {
                        Label(dropHint, systemImage: "arrow.down.circle.fill")
                            .font(.title2.weight(.semibold))
                            .padding(.horizontal, 20).padding(.vertical, 12)
                            .background(.regularMaterial, in: Capsule())
                    }
                    .padding(12)
                    .allowsHitTesting(false)
            }
        }
        .navigationTitle(kind.rawValue)
        .navigationSubtitle(subtitle)
        .dropDestination(for: URL.self) { urls, _ in
            server.add(urls, to: kind)
            return !urls.isEmpty
        } isTargeted: { targeted = $0 }
        .safeAreaInset(edge: .bottom) {
            if !server.transfers.isEmpty { TransfersBar(server: server) }
        }
        .alert("Remove “\(pendingRemoval?.title ?? "")” from the library?", isPresented: Binding(
            get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })
        ) {
            Button("Remove", role: .destructive) {
                if let item = pendingRemoval { Task { await server.removeFromLibrary(item) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It disappears from your Apple TV. A film on this Mac goes to the Trash. A film in Google Drive goes to Drive’s Bin, where it can be restored for 30 days.")
        }
    }

    private var subtitle: String {
        let n = items.count
        return n == 0 ? "" : "\(n) \(isFilm ? (n == 1 ? "film" : "films") : (n == 1 ? "video" : "videos"))"
    }

    private var dropHint: String {
        switch server.addMode {
        case .move: return "Drop to move in, then approve under Google Drive"
        case .copy: return "Drop to copy in, then approve under Google Drive"
        case .link: return "Drop to add to \(kind.rawValue)"
        }
    }
}

/// Counts what's waiting for an OK, since films don't appear in the library until then.
private struct DriveSidebarLabel: View {
    @ObservedObject var cloud: CloudStore

    var body: some View {
        Label("Google Drive", systemImage: "icloud").badge(cloud.pending.count)
    }
}

private struct EmptyLibrary: View {
    let kind: LibraryKind
    let mode: AddMode

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: kind == .films ? "film.stack" : "video.badge.plus")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(kind == .films ? "Drag films here" : "Drag home videos here")
                .font(.title.weight(.semibold))
            Text(kind == .films
                 ? "Reel finds posters and details automatically. 4K HDR and Dolby Vision files stream to your Apple TV at full quality."
                 : "Clips, family videos, anything without a poster. Reel uses a frame from each video as its picture.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 440)
            Button(kind == .films ? "Add Films…" : "Add Home Videos…") { addWithPanel(kind) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 6)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct LibraryCard: View {
    let item: Item
    let imageURL: URL?
    let isFilm: Bool
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AsyncImage(url: imageURL) { phase in
                if let image = phase.image {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        LinearGradient(colors: [Color(white: 0.22), Color(white: 0.12)], startPoint: .top, endPoint: .bottom)
                        Image(systemName: isFilm ? "film" : "video")
                            .font(.system(size: 28, weight: .light))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }
            }
            .aspectRatio(isFilm ? 2.0 / 3.0 : 16.0 / 9.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if let badge = item.badges.first(where: { $0 == "4K" }) {
                    Text(badge)
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .foregroundStyle(Color(red: 0.96, green: 0.73, blue: 0.29))  // projector gold, 10.6:1 on black
                        .padding(6)
                }
            }
            .shadow(color: .black.opacity(hovering ? 0.3 : 0.12), radius: hovering ? 10 : 4, y: hovering ? 5 : 2)
            .scaleEffect(hovering && !reduceMotion ? 1.03 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hovering)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.callout.weight(.semibold)).lineLimit(1)
                Text(detailLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .onHover { hovering = $0 }
        .help(item.path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? item.title)
        .accessibilityElement(children: .combine)
    }

    private var detailLine: String {
        var parts: [String] = []
        if let y = item.productionYear, isFilm { parts.append(String(y)) }
        if let r = item.runtimeText { parts.append(r) }
        parts.append(contentsOf: item.badges.filter { $0 != "4K" && $0 != "HD" }.prefix(1))
        return parts.joined(separator: " · ")
    }
}

private struct TransfersBar: View {
    @ObservedObject var server: ServerManager

    var body: some View {
        VStack(spacing: 8) {
            ForEach(server.transfers) { t in
                HStack(spacing: 10) {
                    Image(systemName: t.failed != nil ? "exclamationmark.triangle.fill" : t.done ? "checkmark.circle.fill" : "arrow.down.doc")
                        .foregroundStyle(t.failed != nil ? Color.orange : t.done ? Color.green : Color.secondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(t.name).font(.callout).lineLimit(1).truncationMode(.middle)
                        if let error = t.failed {
                            Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        } else if t.done {
                            Text("Added. Reel is fetching its details.").font(.caption).foregroundStyle(.secondary)
                        } else if let p = t.progress {
                            ProgressView(value: p).controlSize(.small)
                        } else {
                            ProgressView().progressViewStyle(.linear).controlSize(.small)
                        }
                    }
                    if t.failed != nil {
                        Button("Dismiss") { server.dismissTransfer(t.id) }.controlSize(.small)
                    }
                }
            }
        }
        .padding(12)
        .background(.bar)
    }
}

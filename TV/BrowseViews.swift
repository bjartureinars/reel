import SwiftUI

// MARK: - Home

struct HomeView: View {
    @EnvironmentObject private var session: AppSession
    @State private var resume: [Item] = []
    @State private var latestFilms: [Item] = []
    @State private var latestHome: [Item] = []
    @State private var loaded = false
    @State private var loadError: String?

    private var hero: Item? { resume.first ?? latestFilms.first }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 56) {
                if let hero {
                    HeroBanner(item: hero)
                } else if loaded {
                    EmptyHome(error: loadError)
                }
                if !resume.isEmpty {
                    Shelf(title: "Continue Watching") {
                        ForEach(resume) { WideCard(item: $0, playsDirectly: true) }
                    }
                }
                if !latestFilms.isEmpty {
                    Shelf(title: "Recently Added Films") {
                        ForEach(latestFilms) { PosterCard(item: $0) }
                    }
                }
                if !latestHome.isEmpty {
                    Shelf(title: "Home Videos") {
                        ForEach(latestHome) { WideCard(item: $0, playsDirectly: false) }
                    }
                }
            }
            .padding(.bottom, 80)
        }
        .ignoresSafeArea(edges: .top)
        .navigationDestination(for: Item.self) { DetailView(summary: $0) }
        .task(id: session.libraryVersion) { await load() }
    }

    private func load() async {
        guard let client = session.client, let userId = session.userId else { return }
        do {
            let fields = URLQueryItem("fields", "Overview,MediaStreams,Genres")
            let page: ItemsPage = try await client.get("/UserItems/Resume", [
                .init("userId", userId), .init("mediaTypes", "Video"), .init("limit", "12"), fields,
                .init("enableImageTypes", "Primary,Backdrop,Thumb"),
            ])
            resume = page.items
            let views: ItemsPage = try await client.get("/UserViews", [.init("userId", userId)])
            for view in views.items {
                let latest: [Item] = try await client.get("/Items/Latest", [
                    .init("userId", userId), .init("parentId", view.id), .init("limit", "16"), fields,
                    .init("enableImageTypes", "Primary,Backdrop,Thumb"),
                ])
                if view.collectionType == "movies" { latestFilms = latest }
                if view.collectionType == "homevideos" { latestHome = latest }
            }
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        loaded = true
    }
}

private struct EmptyHome: View {
    let error: String?

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: error == nil ? "film.stack" : "wifi.exclamationmark")
                .font(.system(size: 90, weight: .light))
                .foregroundStyle(.secondary)
            Text(error == nil ? "Your library is empty" : "Can’t reach your Mac").font(.title2.weight(.semibold))
            Text(error == nil
                 ? "Drag films into Reel Server on your Mac. They appear here a moment later."
                 : "Check that Reel Server is open on your Mac and that it isn’t asleep.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 1000)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 260)
    }
}

/// Full-bleed backdrop with the next thing to watch: the signature of the app.
private struct HeroBanner: View {
    let item: Item
    @EnvironmentObject private var session: AppSession

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            BackdropImage(item: item, width: 1920)
                .frame(height: 820)
                .clipped()
                .overlay {
                    LinearGradient(stops: [.init(color: .clear, location: 0.35), .init(color: .black, location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                }
                .overlay {
                    LinearGradient(colors: [.black.opacity(0.75), .clear], startPoint: .leading, endPoint: .center)
                }
            VStack(alignment: .leading, spacing: 18) {
                Text(item.resumeSeconds > 0 ? "CONTINUE WATCHING" : "NEW IN YOUR LIBRARY")
                    .font(.caption.weight(.bold))
                    .tracking(2)
                    .foregroundStyle(Theme.gold)
                Text(item.title)
                    .font(.system(size: 72, weight: .bold))
                    .lineLimit(2)
                    .frame(maxWidth: 1100, alignment: .leading)
                    .shadow(color: .black.opacity(0.6), radius: 12, y: 4)
                MetaLine(item: item)
                if let overview = item.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(2)
                        .frame(maxWidth: 900, alignment: .leading)
                        .shadow(color: .black.opacity(0.6), radius: 8, y: 2)
                }
                HStack(spacing: 24) {
                    PlayButtons(item: item)
                    NavigationLink(value: item) {
                        Label("Details", systemImage: "info.circle")
                    }
                }
                .padding(.top, 8)
            }
            .padding(.horizontal, 90)
            .padding(.bottom, 40)
        }
        .focusSection()
    }
}

// MARK: - Shelves and cards

struct Shelf<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(title)
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 90)
                .accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 48) { content }
                    .padding(.horizontal, 90)
                    .padding(.vertical, 30)
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }
}

struct PosterCard: View {
    let item: Item
    var width: CGFloat = 260
    @EnvironmentObject private var session: AppSession

    var body: some View {
        NavigationLink(value: item) {
            RemoteImage(url: session.client?.imageURL(for: item, maxWidth: Int(width * 2)), symbol: "film")
                .frame(width: width, height: width * 1.5)
        }
        .buttonStyle(.card)
        .accessibilityLabel(item.title)
        .overlay(alignment: .bottom) {
            Text(item.title)
                .font(.caption)
                .lineLimit(1)
                .frame(width: width)
                .offset(y: 46)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.bottom, 46)
    }
}

/// 16:9 card for Continue Watching and home videos, with an inline progress bar.
/// Continue Watching cards play straight away; long-press offers Play from Beginning.
struct WideCard: View {
    let item: Item
    let playsDirectly: Bool
    var width: CGFloat = 480
    @EnvironmentObject private var session: AppSession

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Group {
                if playsDirectly {
                    Button { play(from: item.resumeSeconds) } label: { artwork }
                        .contextMenu {
                            Button("Play from Beginning", systemImage: "arrow.counterclockwise") { play(from: 0) }
                        }
                } else {
                    NavigationLink(value: item) { artwork }
                }
            }
            .buttonStyle(.card)
            .accessibilityLabel([item.title, item.remainingText].compactMap { $0 }.joined(separator: ", "))
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.callout.weight(.medium)).lineLimit(1)
                if let left = item.remainingText {
                    Text(left).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: width, alignment: .leading)
            .accessibilityHidden(true)
        }
    }

    private var artwork: some View {
        RemoteImage(url: session.client?.backdropURL(for: item, maxWidth: Int(width * 2)), symbol: "video")
            .frame(width: width, height: width * 9 / 16)
            .overlay(alignment: .bottom) {
                if let p = item.progress {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.3))
                            Capsule().fill(Theme.gold).frame(width: geo.size.width * p)
                        }
                    }
                    .frame(height: 6)
                    .padding(16)
                }
            }
    }

    private func play(from seconds: Double) {
        Task { await PlaybackController.shared.play(item, from: seconds, session: session) }
    }
}

struct RemoteImage: View {
    let url: URL?
    let symbol: String

    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.25))) { phase in
            if let image = phase.image {
                image.resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinearGradient(colors: [Color(white: 0.2), Color(white: 0.1)], startPoint: .top, endPoint: .bottom)
                    Image(systemName: symbol).font(.system(size: 50, weight: .light)).foregroundStyle(.white.opacity(0.35))
                }
            }
        }
    }
}

struct BackdropImage: View {
    let item: Item
    let width: Int
    @EnvironmentObject private var session: AppSession

    var body: some View {
        RemoteImage(url: session.client?.backdropURL(for: item, maxWidth: width), symbol: "film")
    }
}

struct MetaLine: View {
    let item: Item

    var body: some View {
        HStack(spacing: 18) {
            let parts = [item.productionYear.map { String($0) }, item.officialRating, item.runtimeText].compactMap { $0 }
            if !parts.isEmpty {
                Text(parts.joined(separator: "  ·  ")).foregroundStyle(.white.opacity(0.8))
            }
            ForEach(item.badges, id: \.self) { badge in
                Text(badge)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(.white.opacity(0.6), lineWidth: 1.5))
            }
        }
        .font(.callout)
    }
}

/// Resume / Play buttons. The default-focused control on the hero and detail pages.
struct PlayButtons: View {
    let item: Item
    @EnvironmentObject private var session: AppSession

    var body: some View {
        if item.resumeSeconds > 0 {
            Button { play(item.resumeSeconds) } label: {
                Label("Resume", systemImage: "play.fill")
            }
            Button { play(0) } label: {
                Label("Start Over", systemImage: "arrow.counterclockwise")
            }
        } else {
            Button { play(0) } label: {
                Label("Play", systemImage: "play.fill")
            }
        }
    }

    private func play(_ seconds: Double) {
        Task { await PlaybackController.shared.play(item, from: seconds, session: session) }
    }
}

// MARK: - Detail

struct DetailView: View {
    let summary: Item
    @EnvironmentObject private var session: AppSession
    @State private var full: Item?

    private var item: Item { full ?? summary }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            BackdropImage(item: item, width: 1920)
                .ignoresSafeArea()
                .overlay {
                    LinearGradient(stops: [.init(color: .black.opacity(0.1), location: 0), .init(color: .black.opacity(0.95), location: 0.9)],
                                   startPoint: .top, endPoint: .bottom)
                        .ignoresSafeArea()
                }
                .overlay {
                    LinearGradient(colors: [.black.opacity(0.8), .clear], startPoint: .leading, endPoint: .trailing)
                        .ignoresSafeArea()
                }
            if item.type != "Video" {
                RemoteImage(url: session.client?.imageURL(for: item, maxWidth: 800), symbol: "film")
                    .frame(width: 360, height: 540)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
                    .padding(.trailing, 90)
                    .padding(.bottom, 70)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 22) {
                Text(item.title)
                    .font(.system(size: 76, weight: .bold))
                    .lineLimit(2)
                    .frame(maxWidth: 1200, alignment: .leading)
                    .shadow(color: .black.opacity(0.6), radius: 12, y: 4)
                MetaLine(item: item)
                if let genres = item.genres, !genres.isEmpty {
                    Text(genres.prefix(3).joined(separator: ", ")).foregroundStyle(.secondary)
                }
                if let overview = item.overview, !overview.isEmpty {
                    Text(overview)
                        .lineLimit(4)
                        .frame(maxWidth: 1100, alignment: .leading)
                }
                if let left = item.remainingText {
                    Text(left).font(.callout).foregroundStyle(Theme.gold)
                }
                FilmActions(item: item)
                    .padding(.top, 10)
            }
            .padding(.horizontal, 90)
            .padding(.bottom, 70)
        }
        .task(id: session.libraryVersion) {
            guard let client = session.client, let userId = session.userId else { return }
            full = try? await client.item(summary.id, userId: userId)
        }
    }
}

// MARK: - Library grid

struct LibraryGrid: View {
    let collectionType: String
    let title: String
    @EnvironmentObject private var session: AppSession
    @State private var items: [Item] = []
    @State private var loaded = false
    @State private var sort: Sort = .added

    enum Sort: String, CaseIterable, Identifiable {
        case added = "Recently Added", title = "Title", year = "Year"
        var id: String { rawValue }
        var key: (String, Bool) {
            switch self {
            case .added: return ("DateCreated,SortName", true)
            case .title: return ("SortName", false)
            case .year: return ("ProductionYear,SortName", true)
            }
        }
    }

    private var isFilm: Bool { collectionType == "movies" }

    var body: some View {
        ScrollView {
            Picker("Sort", selection: $sort) {
                ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 900)
            .padding(.top, 20)
            if loaded && items.isEmpty {
                Text(isFilm ? "No films yet. Drag some into Reel Server on your Mac." : "No home videos yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 300)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(isFilm ? 260 : 480), spacing: 48),
                                     count: isFilm ? 6 : 3), spacing: isFilm ? 70 : 60) {
                ForEach(items) { item in
                    if isFilm { PosterCard(item: item) } else { WideCard(item: item, playsDirectly: false) }
                }
            }
            .padding(.horizontal, 90)
            .padding(.vertical, 40)
        }
        .navigationTitle(title)
        .navigationDestination(for: Item.self) { DetailView(summary: $0) }
        .task(id: "\(sort.rawValue)-\(session.libraryVersion)") { await load() }
    }

    private func load() async {
        guard let client = session.client, let userId = session.userId else { return }
        let views: ItemsPage? = try? await client.get("/UserViews", [.init("userId", userId)])
        guard let view = views?.items.first(where: { $0.collectionType == collectionType }) else { loaded = true; return }
        let (sortBy, desc) = sort.key
        items = (try? await client.items(userId: userId, parentId: view.id, types: isFilm ? "Movie,Video" : "Video,Movie",
                                         sortBy: sortBy, descending: desc)) ?? []
        loaded = true
    }
}

// MARK: - Search

struct SearchView: View {
    @EnvironmentObject private var session: AppSession
    @State private var query = ""
    @State private var results: [Item] = []

    var body: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(260), spacing: 48), count: 6), spacing: 70) {
                ForEach(results) { PosterCard(item: $0) }
            }
            .padding(.horizontal, 90)
        }
        .searchable(text: $query, prompt: "Films and home videos")
        .navigationDestination(for: Item.self) { DetailView(summary: $0) }
        .task(id: query) {
            guard query.count >= 2, let client = session.client, let userId = session.userId else { results = []; return }
            try? await Task.sleep(nanoseconds: 300_000_000)  // debounce typing
            guard !Task.isCancelled else { return }
            results = (try? await client.items(userId: userId, search: query, limit: 60)) ?? []
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject private var session: AppSession
    @State private var confirmSignOut = false
    @AppStorage(BitrateMonitor.preferenceKey) private var showBitrate = true

    var body: some View {
        List {
            Section("Server") {
                LabeledContent("Mac", value: session.serverName ?? "–")
                LabeledContent("Address", value: session.client?.baseURL.host ?? "–")
            }
            Section("Playback") {
                LabeledContent("Quality", value: "Original")
                Toggle("Show Live Bitrate", isOn: $showBitrate)
                Text("Reel sends the original picture, including 4K, HDR10 and Dolby Vision. Sound formats Apple TV can’t decode, like DTS, are converted to Dolby Digital Plus. Turn on Match Content in Settings → Video and Audio so your TV switches to HDR automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Disconnect from This Mac", role: .destructive) { confirmSignOut = true }
            }
        }
        .navigationTitle("Settings")
        .frame(maxWidth: 1200)
        .confirmationDialog("Disconnect from \(session.serverName ?? "this Mac")?", isPresented: $confirmSignOut) {
            Button("Disconnect", role: .destructive) { session.signOut() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You’ll need a new code from your Mac to connect again.")
        }
    }
}

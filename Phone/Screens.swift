import SwiftUI

// MARK: - Sign in

struct SignInView: View {
    @EnvironmentObject private var account: GoogleAccount
    @EnvironmentObject private var library: Library
    @State private var working = false
    @State private var problem: String?

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Image("Reel")
                .resizable()
                .scaledToFit()
                .frame(width: 120, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 27, style: .continuous))
                .shadow(color: Theme.gold.opacity(0.35), radius: 40)
                .accessibilityHidden(true)
            Text("Reel")
                .font(.largeTitle.weight(.bold))
                .padding(.top, 24)
            Text("Your films from Google Drive, in their original quality, anywhere.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
                .padding(.horizontal, 32)
            Spacer()
            VStack(spacing: 14) {
                if let problem {
                    Text(problem).font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center)
                }
                Button {
                    working = true
                    Task {
                        do {
                            try await account.signIn()
                            await library.refresh()
                        } catch {
                            if (error as NSError).code != 1 { problem = error.localizedDescription }
                        }
                        working = false
                    }
                } label: {
                    if working { ProgressView().tint(.black) } else { Text("Sign In with Google") }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(working)
                Text("Use the Google account Reel Server uploads to. Reel can only see the films it put in your Drive.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .frame(maxWidth: 520)
    }
}

// MARK: - Home

struct HomeView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var downloads: DownloadCenter
    @State private var showingSettings = false

    private var hero: Film? { library.continueWatching.first ?? library.movies.first ?? library.nextUp.first }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if let hero {
                    HeroBanner(film: hero)
                } else {
                    EmptyLibrary()
                }
                if let problem = library.problem {
                    Label(problem, systemImage: "wifi.exclamationmark")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                }
                if !library.continueWatching.isEmpty {
                    Shelf(title: "Continue Watching") {
                        ForEach(library.continueWatching) { WideCard(film: $0, playsDirectly: true) }
                    }
                }
                if !library.nextUp.isEmpty {
                    Shelf(title: "Next Up") {
                        ForEach(library.nextUp) { WideCard(film: $0, playsDirectly: true) }
                    }
                }
                if !library.shows.isEmpty {
                    Shelf(title: "TV Shows") {
                        ForEach(library.shows.prefix(20)) { ShowCard(show: $0) }
                    }
                }
                if !library.movies.isEmpty {
                    Shelf(title: "Recently Added") {
                        ForEach(library.movies.prefix(20)) { PosterCard(film: $0) }
                    }
                }
                ForEach(library.genreRows, id: \.genre) { row in
                    Shelf(title: row.genre) {
                        ForEach(row.films.prefix(20)) { PosterCard(film: $0) }
                    }
                }
                if !library.myList.isEmpty {
                    Shelf(title: "My List") {
                        ForEach(library.myList) { PosterCard(film: $0) }
                    }
                }
                let saved = library.films.filter { downloads.download(for: $0)?.state == .ready }
                if !saved.isEmpty {
                    Shelf(title: "On This \(Device.name)") {
                        ForEach(saved) { PosterCard(film: $0) }
                    }
                }
            }
            .padding(.bottom, 24)
        }
        .ignoresSafeArea(edges: .top)
        .overlay(alignment: .topTrailing) {
            if !Device.isPad {
                Button { showingSettings = true } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.black.opacity(0.35), in: Circle())
                }
                .accessibilityLabel("Settings")
                .padding(.trailing, 16)
            }
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                SettingsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Done") { showingSettings = false } }
                    }
            }
        }
        .navigationDestination(for: Film.self) { FilmDetailView(film: $0) }
        .navigationDestination(for: Show.self) { ShowDetailView(show: $0) }
        .refreshable { await library.refresh() }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
    }
}

private struct HeroBanner: View {
    let film: Film
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var library: Library
    @Environment(\.reelSizeClass) private var sizeClass

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Artwork(url: film.backdropURL)
                .frame(height: sizeClass == .regular ? 620 : 460)
                .frame(maxWidth: .infinity)
                .clipped()
                .overlay {
                    LinearGradient(stops: [.init(color: .black.opacity(0.35), location: 0), .init(color: .clear, location: 0.25),
                                           .init(color: .clear, location: 0.45), .init(color: .black, location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 10) {
                Text(library.resumeSeconds(film) > 0 ? "CONTINUE WATCHING" : "NEW IN YOUR LIBRARY")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.gold)
                Text(film.episode?.show ?? film.title)
                    .font(.largeTitle.weight(.bold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                if let label = film.episodeLabel {
                    Text("\(label): \(film.title)").font(.headline).foregroundStyle(.white.opacity(0.9))
                }
                HStack(spacing: 10) {
                    if !film.metaLine.isEmpty { Text(film.metaLine).font(.subheadline).foregroundStyle(.secondary) }
                    Badges(film: film)
                }
                HStack(spacing: 12) {
                    Button { app.play(film) } label: {
                        Label(library.resumeSeconds(film) > 0 ? "Resume" : "Play", systemImage: "play.fill")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    NavigationLink(value: film) {
                        Label("Details", systemImage: "info.circle")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: sizeClass == .regular ? 560 : nil, alignment: .leading)
            .padding(.horizontal, Metrics.margin(sizeClass == .regular))
            .padding(.bottom, sizeClass == .regular ? 12 : 0)
        }
    }
}

private struct EmptyLibrary: View {
    @EnvironmentObject private var library: Library

    var body: some View {
        VStack(spacing: 14) {
            if library.loading {
                ProgressView().controlSize(.large)
                Text("Looking in Google Drive…").foregroundStyle(.secondary)
            } else {
                Image(systemName: "film.stack").font(.system(size: 56, weight: .light)).foregroundStyle(.secondary)
                Text("No Films Yet").font(.title2.weight(.semibold))
                Text("Films appear here once Reel Server on your Mac has uploaded and checked them. Keep Reel Server open for a minute after it finishes.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(32)
        .padding(.top, 120)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Library

struct LibraryView: View {
    @EnvironmentObject private var library: Library
    @AppStorage("library.sort") private var sort = Sort.added.rawValue
    @State private var genre: String?
    @Environment(\.reelSizeClass) private var sizeClass
    private var regular: Bool { sizeClass == .regular }

    enum Sort: String, CaseIterable, Identifiable {
        case added = "Recently Added", title = "Title", year = "Year"
        var id: String { rawValue }
    }

    private var shown: [Film] {
        var films = library.movies
        if let genre { films = films.filter { $0.info?.genres.contains(genre) == true } }
        switch Sort(rawValue: sort) ?? .added {
        case .added: return films.sorted { $0.addedAt > $1.addedAt }
        case .title: return films.sorted { $0.sortTitle.localizedStandardCompare($1.sortTitle) == .orderedAscending }
        case .year: return films.sorted { ($0.info?.year ?? 0) > ($1.info?.year ?? 0) }
        }
    }

    var body: some View {
        ScrollView {
            if shown.isEmpty {
                ContentUnavailableView("No Films", systemImage: "film",
                                       description: Text(genre == nil ? "Add them with Reel Server on your Mac." : "Nothing in \(genre!)."))
                    .padding(.top, 80)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Metrics.gridPoster(regular) - 4), spacing: regular ? 18 : 12)],
                      spacing: regular ? 26 : 18) {
                ForEach(shown) { PosterCard(film: $0, width: Metrics.gridPoster(regular)) }
            }
            .padding(Metrics.margin(regular))
        }
        .navigationTitle("Films")
        .navigationDestination(for: Film.self) { FilmDetailView(film: $0) }
        .refreshable { await library.refresh() }
        .toolbar {
            ToolbarItem(placement: .reelTrailing) {
                Menu {
                    Picker("Sort By", selection: $sort) {
                        ForEach(Sort.allCases) { Text($0.rawValue).tag($0.rawValue) }
                    }
                    if !library.genres.isEmpty {
                        Picker("Genre", selection: $genre) {
                            Text("All Genres").tag(String?.none)
                            ForEach(library.genres, id: \.self) { Text($0).tag(String?.some($0)) }
                        }
                    }
                } label: {
                    Label("Sort and Filter", systemImage: "line.3.horizontal.decrease")
                }
            }
        }
    }
}

// MARK: - Search

struct SearchView: View {
    @EnvironmentObject private var library: Library
    @State private var query = ""
    @AppStorage("recentSearches") private var recentText = ""

    /// The last searches, newest first. Kept on this device only, and easy to clear (searching.md).
    private var recent: [String] { recentText.split(separator: "\n").map(String.init) }

    private func remember(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return }
        recentText = ([trimmed] + recent.filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame })
            .prefix(8).joined(separator: "\n")
    }
    @Environment(\.reelSizeClass) private var sizeClass
    private var regular: Bool { sizeClass == .regular }

    var body: some View {
        ScrollView {
            if query.isEmpty {
                if !recent.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Recent Searches").font(.title3.weight(.bold)).accessibilityAddTraits(.isHeader)
                            Spacer()
                            Button("Clear") { recentText = "" }
                        }
                        ForEach(recent, id: \.self) { text in
                            Button { query = text } label: {
                                Label(text, systemImage: "clock.arrow.circlepath")
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding([.horizontal, .top], 16)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("Genres").font(.title3.weight(.bold)).accessibilityAddTraits(.isHeader)
                    FlowLayout(spacing: 8) {
                        ForEach(library.genres, id: \.self) { genre in
                            Button(genre) { query = genre }
                                .buttonStyle(.bordered)
                                .tint(.white)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            } else {
                let results = library.search(query)
                let shows = library.searchShows(query)
                if results.isEmpty && shows.isEmpty {
                    ContentUnavailableView.search(text: query).padding(.top, 60)
                }
                if !shows.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: Metrics.gridPoster(regular) - 4), spacing: regular ? 18 : 12)],
                              spacing: regular ? 26 : 18) {
                        ForEach(shows) { ShowCard(show: $0, width: Metrics.gridPoster(regular)) }
                    }
                    .padding([.horizontal, .top], Metrics.margin(regular))
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: Metrics.gridPoster(regular) - 4), spacing: regular ? 18 : 12)],
                          spacing: regular ? 26 : 18) {
                    ForEach(results) { PosterCard(film: $0, width: Metrics.gridPoster(regular)) }
                }
                .padding(Metrics.margin(regular))
            }
        }
        .navigationTitle("Search")
        .searchable(text: $query, prompt: "Films, shows, people, genres")
        .onSubmit(of: .search) { remember(query) }
        // Opening something found counts as a search worth remembering, as does picking a genre.
        .onChange(of: query) { _, text in
            if library.genres.contains(text) { remember(text) }
        }
        .onDisappear { if !query.isEmpty, !library.search(query).isEmpty || !library.searchShows(query).isEmpty { remember(query) } }
        .navigationDestination(for: Film.self) { FilmDetailView(film: $0) }
        .navigationDestination(for: Show.self) { ShowDetailView(show: $0) }
    }
}

/// Wraps genre buttons onto as many lines as they need.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal.width ?? 320, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, point) in arrange(bounds.width, subviews).points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        var points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += line + spacing; line = 0 }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x)
        }
        return (CGSize(width: widest, height: y + line), points)
    }
}

// MARK: - Downloads

struct DownloadsView: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var downloads: DownloadCenter

    private var items: [(Film, Download)] {
        downloads.downloads.values.sorted { $0.added > $1.added }.compactMap { d in library.film(d.id).map { ($0, d) } }
    }

    var body: some View {
        List {
            if items.isEmpty {
                ContentUnavailableView("No Downloads", systemImage: "arrow.down.circle",
                                       description: Text("Download films to watch them without a connection. Tap Download on any film."))
                    .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(items, id: \.1.id) { film, download in
                        NavigationLink(value: film) { DownloadRow(film: film, download: download) }
                            .swipeActions {
                                Button(role: .destructive) { downloads.remove(download) } label: {
                                    Label(download.state == .ready ? "Delete" : "Cancel", systemImage: "trash")
                                }
                            }
                    }
                } footer: {
                    Text("Reel uses \(downloads.usedSpace.fileSize). \(Folders.freeSpace.fileSize) free on this \(Device.name).")
                }
            }
        }
        .navigationTitle("Downloads")
        .navigationDestination(for: Film.self) { FilmDetailView(film: $0) }
    }
}

struct DownloadRow: View {
    let film: Film
    let download: Download
    @EnvironmentObject private var downloads: DownloadCenter
    @EnvironmentObject private var library: Library

    var body: some View {
        HStack(spacing: 12) {
            Artwork(url: film.posterURL)
                .frame(width: 54, height: 81)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(film.fullTitle).font(.headline).lineLimit(2)
                Text("\(download.quality.title) · \(download.size.fileSize)").font(.subheadline).foregroundStyle(.secondary)
                DownloadStatus(film: film, download: download)
            }
        }
        .padding(.vertical, 4)
    }
}

/// One line saying where a download has got to.
struct DownloadStatus: View {
    let film: Film
    let download: Download
    @EnvironmentObject private var downloads: DownloadCenter
    @EnvironmentObject private var library: Library

    var body: some View {
        switch download.state {
        case .ready:
            Label("Downloaded", systemImage: "checkmark.circle.fill").font(.footnote).foregroundStyle(Theme.gold)
        case .checking:
            Label("Checking every byte…", systemImage: "checkmark.shield").font(.footnote).foregroundStyle(.secondary)
        case .failed:
            Label(download.problem ?? "Download failed.", systemImage: "exclamationmark.triangle.fill")
                .font(.footnote).foregroundStyle(.orange)
        case .waitingForMac:
            let progress = library.requests[film.id]?[download.quality]?.progress
            VStack(alignment: .leading, spacing: 4) {
                Text(macLine(progress)).font(.footnote).foregroundStyle(.secondary)
                if let value = progress?.progress { ProgressView(value: value).tint(Theme.gold) }
            }
        case .downloading:
            let received = downloads.received(download)
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: Double(received), total: Double(max(download.size, 1))).tint(Theme.gold)
                Text(downloadLine(received)).font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    private func macLine(_ progress: CopyProgress?) -> String {
        switch progress?.phase {
        case .making: return "Your Mac is making the \(download.quality.title) copy"
        case .uploading: return "Your Mac is uploading the \(download.quality.title) copy"
        case .ready: return "Starting download"
        case .failed: return progress?.detail ?? "Your Mac couldn’t make it."
        default: return "Waiting for your Mac. Keep Reel Server open."
        }
    }

    private func downloadLine(_ received: Int64) -> String {
        var line = "\(received.fileSize) of \(download.size.fileSize)"
        if let speed = downloads.speed[download.id], speed > 0.5 {
            line += String(format: " · %.0f Mbps", speed)
            let left = Double(download.size - received) * 8 / (speed * 1_000_000)
            if left.isFinite, left > 0 { line += " · \(left.runtimeText) left" }
        }
        return line
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var account: GoogleAccount
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var downloads: DownloadCenter
    @AppStorage("downloadQuality") private var downloadQuality = "original"
    @AppStorage("showBitrate") private var showBitrate = false
    @AppStorage("subtitleLanguage") private var subtitleLanguage = ""
    @State private var confirmSignOut = false
    @State private var confirmDeleteAll = false

    var body: some View {
        Form {
            Section {
                if account.isSignedIn {
                    LabeledContent("Google Drive", value: account.email ?? "Signed in")
                    if let last = library.lastRefresh {
                        LabeledContent("Updated", value: last.formatted(.relative(presentation: .named)))
                    }
                } else {
                    Button("Sign In with Google") {
                        Task {
                            await attempt("Signing in with Google") { try await account.signIn() }
                            await library.refresh()
                        }
                    }
                }
            } header: {
                Text("Account")
            } footer: {
                Text("Films and shows stream straight from Google. Your Mac only needs to be on to add them and make smaller downloads.")
            }

            Section {
                LabeledContent("Streaming Quality", value: "Original")
                if !Device.isMac { Toggle("Stream Over Mobile Data", isOn: $app.streamOverCellular) }
                Toggle("Show Live Bitrate", isOn: $showBitrate)
                Picker("Subtitles", selection: $subtitleLanguage) {
                    Text("Off").tag("")
                    ForEach(["eng", "ice", "dan", "nor", "swe", "ger", "fre", "spa"], id: \.self) { code in
                        Text(Locale.current.localizedString(forLanguageCode: code) ?? code).tag(code)
                    }
                }
            } header: {
                Text("Playback")
            } footer: {
                Text("Reel always streams the original picture, untouched. Sound \(Device.name) can’t play, like DTS-HD, becomes Apple Lossless on the \(Device.name), with nothing lost. Streaming 4K uses 15–25 GB an hour.")
            }

            Section {
                Picker("Download Quality", selection: $downloadQuality) {
                    Text("Original").tag("original")
                    Text("Custom").tag("custom")
                }
                if !Device.isMac {
                    Toggle("Download Over Mobile Data", isOn: Binding(get: { downloads.overCellular }, set: { downloads.setCellular($0) }))
                }
                LabeledContent("Used by Downloads", value: downloads.usedSpace.fileSize)
                LabeledContent("Free on \(Device.name)", value: Folders.freeSpace.fileSize)
                if !downloads.downloads.isEmpty {
                    Button("Delete All Downloads", role: .destructive) { confirmDeleteAll = true }
                }
            } header: {
                Text("Downloads")
            } footer: {
                Text((downloadQuality == "original"
                     ? "Downloads are the exact original file."
                     : "Each time you download, choose Original, Medium (1080p) or Low (720p). Your Mac makes Medium and Low copies the first time someone asks, which takes about 45 minutes per film."))
            }

            Section("About") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                Link("Privacy Policy", destination: URL(string: "https://reel-515510.web.app/privacy")!)
                NavigationLink("Acknowledgements") { Acknowledgements() }
            }

            if account.isSignedIn {
                Section {
                    Button("Sign Out", role: .destructive) { confirmSignOut = true }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .task {
            if account.email == nil, account.isSignedIn, let quota = try? await library.drive.quota() { account.email = quota.email }
        }
        .confirmationDialog("Sign out of Google?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { Task { await account.signOut() } }
        } message: {
            Text("Downloaded films stay on this \(Device.name) and keep playing.")
        }
        .confirmationDialog("Delete all downloads?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
            Button("Delete \(downloads.usedSpace.fileSize)", role: .destructive) {
                downloads.downloads.values.forEach(downloads.remove)
            }
        } message: {
            Text("The films stay in Google Drive. You can download them again.")
        }
    }
}

private struct Acknowledgements: View {
    var body: some View {
        ScrollView {
            Text("""
            Reel plays films with parts of FFmpeg 8.1.3 (libavformat, libavcodec, libavutil, libswresample), © the FFmpeg developers, used under the GNU Lesser General Public License, version 2.1 or later. Its source is at ffmpeg.org, and the exact build steps are in Reel's source (Tools/build-ffmpeg.sh).

            Film details and artwork come from your own Jellyfin server, run by Reel Server on your Mac.
            """)
            .padding()
        }
        .navigationTitle("Acknowledgements")
    }
}

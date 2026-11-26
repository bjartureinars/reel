import SwiftUI

// MARK: - All shows

struct ShowsView: View {
    @EnvironmentObject private var library: Library
    @AppStorage("shows.sort") private var sort = Sort.added.rawValue
    @Environment(\.reelSizeClass) private var sizeClass
    private var regular: Bool { sizeClass == .regular }

    enum Sort: String, CaseIterable, Identifiable {
        case added = "Recently Added", title = "Title"
        var id: String { rawValue }
    }

    private var shown: [Show] {
        switch Sort(rawValue: sort) ?? .added {
        case .added: return library.shows
        case .title: return library.shows.sorted { $0.sortTitle.localizedStandardCompare($1.sortTitle) == .orderedAscending }
        }
    }

    var body: some View {
        ScrollView {
            if shown.isEmpty {
                ContentUnavailableView("No TV Shows", systemImage: "tv",
                                       description: Text("Put a show’s folder in the TV shows folder on your Mac and approve it in Reel Server."))
                    .padding(.top, 80)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Metrics.gridPoster(regular) - 4), spacing: regular ? 18 : 12)],
                      spacing: regular ? 26 : 18) {
                ForEach(shown) { ShowCard(show: $0, width: Metrics.gridPoster(regular)) }
            }
            .padding(Metrics.margin(regular))
        }
        .navigationTitle("TV Shows")
        .navigationDestination(for: Show.self) { ShowDetailView(show: $0) }
        .navigationDestination(for: Film.self) { FilmDetailView(film: $0) }
        .refreshable { await library.refresh() }
        .toolbar {
            ToolbarItem(placement: .reelTrailing) {
                Menu {
                    Picker("Sort By", selection: $sort) {
                        ForEach(Sort.allCases) { Text($0.rawValue).tag($0.rawValue) }
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
            }
        }
    }
}

struct ShowCard: View {
    let show: Show
    var fixedWidth: CGFloat?
    @Environment(\.reelSizeClass) private var sizeClass
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var library: Library

    init(show: Show, width: CGFloat? = nil) {
        self.show = show
        fixedWidth = width
    }

    private var width: CGFloat { fixedWidth ?? Metrics.poster(sizeClass == .regular) }

    var body: some View {
        NavigationLink(value: show) {
            VStack(alignment: .leading, spacing: 6) {
                Artwork(url: show.posterURL, symbol: "tv")
                    .frame(width: width, height: width * 1.5)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text(show.title)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: width, alignment: .leading)
            }
        }
        .accessibilityLabel("\(show.title), \(show.episodes.count == 1 ? "1 episode" : "\(show.episodes.count) episodes")")
        .buttonStyle(.plain)
        .reelContextMenu {
            if let next = library.nextEpisode(of: show) {
                let label = next.episodeLabel ?? ""
                Button(library.resumeSeconds(next) > 0 ? "Resume \(label)" : "Play \(label)", systemImage: "play.fill") {
                    app.play(next)
                }
            }
        } preview: {
            VStack(alignment: .leading, spacing: 0) {
                Artwork(url: show.backdropURL, symbol: "tv").frame(width: 320, height: 180)
                VStack(alignment: .leading, spacing: 4) {
                    Text(show.title).font(.headline)
                    Text(show.metaLine).font(.caption).foregroundStyle(.secondary)
                    if let overview = show.details?.overview {
                        Text(overview).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
                .padding(12)
            }
            .frame(width: 320, alignment: .leading)
            .background(Color(white: 0.11))
        }
    }
}

// MARK: - One show

struct ShowDetailView: View {
    let show: Show
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var library: Library
    @State private var season: Int?
    @State private var expanded = false
    @State private var confirmSeasonDownload = false
    @State private var confirmSeasonRemoval = false
    @EnvironmentObject private var downloads: DownloadCenter
    @AppStorage("downloadQuality") private var downloadQuality = "original"
    @Environment(\.reelSizeClass) private var sizeClass
    private var regular: Bool { sizeClass == .regular }

    /// The latest from the library, so progress and new episodes show up while the page is open.
    private var current: Show { library.show(show.id) ?? show }
    private var chosenSeason: Int { season ?? library.nextEpisode(of: current)?.episode?.season ?? current.seasons.first ?? 1 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                VStack(alignment: .leading, spacing: 16) {
                    if let next = library.nextEpisode(of: current) { playButton(next) }
                    if let overview = current.details?.overview {
                        Text(overview)
                            .lineLimit(expanded ? nil : 3)
                            .onTapGesture { withAnimation { expanded.toggle() } }
                            .accessibilityHint(expanded ? "" : "Double-tap to read more")
                    }
                    HStack {
                        if current.seasons.count > 1 {
                            seasonPicker
                        } else {
                            Text(Self.name(chosenSeason)).font(.title3.weight(.bold)).accessibilityAddTraits(.isHeader)
                        }
                        Spacer()
                        seasonDownloadButton
                    }
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(current.episodes(in: chosenSeason)) { EpisodeRow(film: $0) }
                    }
                }
                .frame(maxWidth: regular ? Metrics.readableWidth : nil, alignment: .leading)
                .padding(.horizontal, Metrics.margin(regular))
                let similar = library.similar(to: current)
                if !similar.isEmpty {
                    Shelf(title: "More Like This") {
                        ForEach(similar) { ShowCard(show: $0) }
                    }
                    .padding(.top, 8)
                }
            }
            .padding(.bottom, 32)
        }
        .ignoresSafeArea(edges: .top)
        .reelClearNavigationBar()
        .navigationDestination(for: Film.self) { FilmDetailView(film: $0) }
    }

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            Artwork(url: current.backdropURL, symbol: "tv")
                .frame(height: regular ? 480 : 300)
                .frame(maxWidth: .infinity)
                .clipped()
                .overlay {
                    LinearGradient(stops: [.init(color: .black.opacity(0.4), location: 0), .init(color: .clear, location: 0.3),
                                           .init(color: .black, location: 1)], startPoint: .top, endPoint: .bottom)
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(current.title)
                    .font(.largeTitle.weight(.bold))
                    .lineLimit(3)
                    .minimumScaleFactor(0.75)
                    .accessibilityAddTraits(.isHeader)
                if !current.metaLine.isEmpty {
                    Text(current.metaLine).font(.subheadline).foregroundStyle(.secondary)
                }
                if let genres = current.details?.genres, !genres.isEmpty {
                    Text(genres.prefix(3).joined(separator: ", ")).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: regular ? Metrics.readableWidth : nil, alignment: .leading)
            .padding(.horizontal, Metrics.margin(regular))
        }
    }

    private func playButton(_ next: Film) -> some View {
        let resume = library.resumeSeconds(next)
        let label = next.episodeLabel ?? ""
        let isFirst = next.id == current.episodes.first?.id && !library.state(next).watched
        return VStack(alignment: .leading, spacing: 6) {
            Button { app.play(next) } label: {
                Label(resume > 0 ? "Resume \(label)" : isFirst ? "Play" : "Play \(label)", systemImage: "play.fill")
            }
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityHint("Plays \(next.title)")
            Text(resume > 0 ? "\(next.title), \(((next.seconds ?? 0) - resume).runtimeText) left" : "\(label): \(next.title)")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var seasonPicker: some View {
        Menu {
            Picker("Season", selection: Binding(get: { chosenSeason }, set: { season = $0 })) {
                ForEach(current.seasons, id: \.self) { Text(Self.name($0)).tag($0) }
            }
        } label: {
            HStack(spacing: 6) {
                Text(Self.name(chosenSeason)).font(.title3.weight(.bold))
                Image(systemName: "chevron.down").font(.footnote.weight(.bold))
            }
            .foregroundStyle(.primary)
        }
        .accessibilityLabel("Season, \(Self.name(chosenSeason))")
    }

    static func name(_ season: Int) -> String { season == 0 ? "Specials" : "Season \(season)" }

    // MARK: Downloading a season

    private var seasonEpisodes: [Film] { current.episodes(in: chosenSeason) }
    private var notDownloaded: [Film] { seasonEpisodes.filter { downloads.download(for: $0) == nil } }

    /// Downloads every episode of the season not already on this device; once they all are, removes them.
    @ViewBuilder private var seasonDownloadButton: some View {
        let missing = notDownloaded
        Button {
            if missing.isEmpty { confirmSeasonRemoval = true } else { confirmSeasonDownload = true }
        } label: {
            Label(missing.isEmpty ? "Downloaded" : "Download Season",
                  systemImage: missing.isEmpty ? "arrow.down.circle.fill" : "arrow.down.circle")
                .font(.subheadline.weight(.semibold))
                .frame(minHeight: 44)
        }
        .confirmationDialog(downloadTitle(missing), isPresented: $confirmSeasonDownload, titleVisibility: .visible) {
            let qualities: [CopyQuality] = downloadQuality == "custom" ? CopyQuality.allCases : [.original]
            ForEach(qualities) { quality in
                Button(qualityLabel(quality, missing)) {
                    for film in missing { app.download(film, quality: quality) }
                }
            }
        } message: {
            Text("Episodes download one after another and stay on this \(Device.name) until you remove them.")
        }
        .confirmationDialog("Remove the Downloads of \(Self.name(chosenSeason))?", isPresented: $confirmSeasonRemoval,
                            titleVisibility: .visible) {
            Button("Remove \(seasonEpisodes.count) Downloads", role: .destructive) {
                for film in seasonEpisodes { if let download = downloads.download(for: film) { downloads.remove(download) } }
            }
        } message: {
            Text("The episodes stay in Google Drive.")
        }
    }

    private func downloadTitle(_ missing: [Film]) -> String {
        missing.count == 1 ? "Download 1 Episode?" : "Download \(missing.count) Episodes?"
    }

    private func qualityLabel(_ quality: CopyQuality, _ films: [Film]) -> String {
        let size = films.reduce(Int64(0)) { $0 + $1.estimatedSize(quality) }
        return quality == .original ? "Original · \(size.fileSize)" : "\(quality.title) · about \(size.fileSize)"
    }
}

/// An episode: a still with progress, its number and name, length and what it's about. Tapping plays it;
/// the details page (for downloading, sound and subtitles) is a tap on the information button.
struct EpisodeRow: View {
    let film: Film
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var downloads: DownloadCenter
    @Environment(\.reelSizeClass) private var sizeClass

    private var stillWidth: CGFloat { sizeClass == .regular ? 220 : 150 }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button { app.play(film) } label: {
                Artwork(url: film.backdropURL, symbol: "tv")
                    .frame(width: stillWidth, height: stillWidth * 9 / 16)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(alignment: .bottom) {
                        if let progress = library.progress(film) { ProgressLine(value: progress).padding(6) }
                    }
                    .overlay {
                        Image(systemName: "play.fill")
                            .font(.body)
                            .foregroundStyle(.white)
                            .padding(10)
                            .background(.black.opacity(0.45), in: Circle())
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play \(film.episodeLabel ?? ""), \(film.title)")

            VStack(alignment: .leading, spacing: 3) {
                Text(film.episode.map { "\($0.number). \(film.title)" } ?? film.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                    if downloads.download(for: film)?.state == .ready {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.caption)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.black, Theme.gold)
                            .accessibilityLabel("Downloaded")
                    }
                }
                if let overview = film.info?.overview {
                    Text(overview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            NavigationLink(value: film) {
                Image(systemName: "info.circle").font(.title3).frame(width: 44, height: 44)
            }
            .accessibilityLabel("Details for \(film.title)")
        }
        .reelContextMenu { FilmMenu(film: film) } preview: { FilmPreview(film: film) }
    }

    private var detail: String {
        let resume = library.resumeSeconds(film)
        if resume > 0, let total = film.seconds { return "\((total - resume).runtimeText) left" }
        return [film.seconds?.runtimeText, library.state(film).watched ? "Watched" : nil].compactMap { $0 }.joined(separator: " · ")
    }
}

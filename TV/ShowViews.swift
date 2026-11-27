import SwiftUI

// MARK: - Where a card leads

/// Films open their detail page. A show, or any episode of it, opens the show's page: episodes are chosen there.
struct ItemDestination: View {
    let item: Item

    var body: some View {
        if item.isSeries {
            ShowView(showID: item.id, summary: item)
        } else if item.isEpisode, let show = item.seriesId {
            ShowView(showID: show, summary: nil, season: item.parentIndexNumber)
        } else {
            DetailView(summary: item)
        }
    }
}

// MARK: - A show

struct ShowView: View {
    let showID: String
    let summary: Item?
    var season: Int?

    @EnvironmentObject private var session: AppSession
    @State private var show: Item?
    @State private var seasons: [Item] = []
    @State private var chosenSeason: String?
    @State private var episodes: [Item] = []
    @State private var next: Item?
    @State private var loaded = false

    private var item: Item? { show ?? summary }

    var body: some View {
        ZStack {
            if let item {
                BackdropImage(item: item, width: 1920)
                    .ignoresSafeArea()
                    .overlay {
                        LinearGradient(stops: [.init(color: .black.opacity(0.15), location: 0), .init(color: .black.opacity(0.92), location: 0.6),
                                               .init(color: .black, location: 1)], startPoint: .top, endPoint: .bottom)
                            .ignoresSafeArea()
                    }
                    .overlay {
                        LinearGradient(colors: [.black.opacity(0.75), .clear], startPoint: .leading, endPoint: .trailing)
                            .ignoresSafeArea()
                    }
                    .accessibilityHidden(true)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 44) {
                    if let item { header(item) }
                    if seasons.count > 1 { seasonPicker }
                    episodeShelf
                }
                .padding(.top, 330)
                .padding(.bottom, 80)
            }
        }
        .task(id: session.libraryVersion) { await load() }
        .task(id: chosenSeason) { await loadEpisodes() }
    }

    private func header(_ item: Item) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(item.title)
                .font(.system(size: 76, weight: .bold))
                .lineLimit(2)
                .frame(maxWidth: 1200, alignment: .leading)
                .shadow(color: .black.opacity(0.6), radius: 12, y: 4)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 18) {
                let parts = [item.productionYear.map { String($0) }, item.officialRating, seasonsText].compactMap { $0 }
                Text(parts.joined(separator: "  ·  ")).foregroundStyle(.white.opacity(0.8))
                if let genres = item.genres, !genres.isEmpty {
                    Text(genres.prefix(3).joined(separator: ", ")).foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            if let overview = item.overview, !overview.isEmpty {
                Text(overview)
                    .lineLimit(3)
                    .frame(maxWidth: 1100, alignment: .leading)
            }
            if let next {
                HStack(spacing: 24) {
                    Button { play(next, from: next.resumeSeconds) } label: {
                        Label(playTitle(next), systemImage: "play.fill")
                    }
                    if next.resumeSeconds > 0 {
                        Button { play(next, from: 0) } label: {
                            Label("Start Over", systemImage: "arrow.counterclockwise")
                        }
                    }
                }
                .padding(.top, 8)
                if next.resumeSeconds == 0, let title = next.episodeLabel {
                    Text("\(title): \(next.title)").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 90)
        .focusSection()
    }

    private var seasonsText: String? {
        seasons.isEmpty ? nil : seasons.count == 1 ? "1 Season" : "\(seasons.count) Seasons"
    }

    private func playTitle(_ episode: Item) -> String {
        let label = episode.episodeLabel ?? ""
        if episode.resumeSeconds > 0 { return "Resume \(label)" }
        let isFirst = episode.id == episodes.first?.id && seasons.first?.id == chosenSeason
        return isFirst && episode.userData?.played != true ? "Play" : "Play \(label)"
    }

    private var seasonPicker: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 20) {
                ForEach(seasons) { season in
                    Button {
                        chosenSeason = season.id
                    } label: {
                        Text(season.title)
                            .fontWeight(chosenSeason == season.id ? .bold : .regular)
                            .foregroundStyle(chosenSeason == season.id ? Theme.gold : .primary)
                    }
                    .accessibilityAddTraits(chosenSeason == season.id ? .isSelected : [])
                }
            }
            .padding(.horizontal, 90)
            .padding(.vertical, 10)
        }
        .scrollClipDisabled()
        .focusSection()
    }

    private var episodeShelf: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 48) {
                ForEach(episodes) { EpisodeCard(episode: $0) }
            }
            .padding(.horizontal, 90)
            .padding(.vertical, 30)
        }
        .scrollClipDisabled()
        .focusSection()
        .overlay {
            if loaded && episodes.isEmpty {
                Text("No episodes yet.").foregroundStyle(.secondary)
            }
        }
    }

    private func play(_ episode: Item, from seconds: Double) {
        Task { await PlaybackController.shared.play(episode, from: seconds, session: session) }
    }

    private func load() async {
        guard let client = session.client, let userId = session.userId else { return }
        show = try? await client.item(showID, userId: userId)
        let found: ItemsPage? = try? await client.get("/Shows/\(showID)/Seasons", [.init("userId", userId)])
        seasons = found?.items ?? []
        let upNext: ItemsPage? = try? await client.get("/Shows/NextUp", [
            .init("userId", userId), .init("seriesId", showID), .init("limit", "1"), .init("enableResumable", "true"),
            .init("fields", "Overview,MediaStreams"), .init("enableUserData", "true"),
        ])
        next = upNext?.items.first
        // Open on the season asked for, else the one with the next episode, else the first.
        let wanted = season ?? next?.parentIndexNumber
        let pick = seasons.first { $0.indexNumber == wanted } ?? seasons.first
        if chosenSeason == nil || !seasons.contains(where: { $0.id == chosenSeason }) {
            chosenSeason = pick?.id
        } else {
            await loadEpisodes()
        }
        loaded = true
    }

    private func loadEpisodes() async {
        guard let client = session.client, let userId = session.userId, let chosenSeason else { return }
        let page: ItemsPage? = try? await client.get("/Shows/\(showID)/Episodes", [
            .init("userId", userId), .init("seasonId", chosenSeason), .init("fields", "Overview,MediaStreams"),
            .init("enableUserData", "true"), .init("enableImageTypes", "Primary,Backdrop,Thumb"),
        ])
        episodes = page?.items ?? []
        // Nothing watched yet: the first episode is next.
        if next == nil, let first = episodes.first, seasons.first?.id == chosenSeason { next = first }
    }
}

// MARK: - An episode

/// A still from the episode with its number, name, length and what it's about. Selecting it plays it.
struct EpisodeCard: View {
    let episode: Item
    var width: CGFloat = 480
    @EnvironmentObject private var session: AppSession

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { play(from: episode.resumeSeconds) } label: { still }
                .buttonStyle(.card)
                .contextMenu {
                    if episode.resumeSeconds > 0 {
                        Button("Play from Beginning", systemImage: "arrow.counterclockwise") { play(from: 0) }
                    }
                    if episode.userData?.played == true {
                        Button("Mark as Unwatched", systemImage: "eye.slash") { mark(watched: false) }
                    } else {
                        Button("Mark as Watched", systemImage: "eye") { mark(watched: true) }
                    }
                }
                .accessibilityLabel(accessibilityText)
            VStack(alignment: .leading, spacing: 6) {
                Text(numberedTitle).font(.callout.weight(.semibold)).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                if let overview = episode.overview, !overview.isEmpty {
                    Text(overview).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            .frame(width: width, alignment: .leading)
            .accessibilityHidden(true)
        }
    }

    private var numberedTitle: String {
        episode.indexNumber.map { "\($0). \(episode.title)" } ?? episode.title
    }

    private var detail: String {
        if let left = episode.remainingText { return left }
        let parts = [episode.runtimeText, episode.userData?.played == true ? "Watched" : nil].compactMap { $0 }
        return parts.joined(separator: " · ")
    }

    private var accessibilityText: String {
        [episode.episodeLabel, episode.title, detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private var still: some View {
        RemoteImage(url: session.client?.stillURL(for: episode, maxWidth: Int(width * 2)), symbol: "tv")
            .frame(width: width, height: width * 9 / 16)
            .overlay(alignment: .bottom) {
                if let p = episode.progress {
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
            .overlay(alignment: .topTrailing) {
                if episode.userData?.played == true {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.black, Theme.gold)
                        .padding(14)
                        .accessibilityHidden(true)
                }
            }
    }

    private func play(from seconds: Double) {
        Task { await PlaybackController.shared.play(episode, from: seconds, session: session) }
    }

    private func mark(watched: Bool) {
        guard let client = session.client, let userId = session.userId else { return }
        Task {
            await attempt("Marking an episode watched") { _ = try await client.send(watched ? "POST" : "DELETE", "/UserPlayedItems/\(episode.id)", query: [.init("userId", userId)]) }
            session.libraryVersion += 1
        }
    }
}

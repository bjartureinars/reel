import SwiftUI

/// Artwork saved on the phone, decoded off the main thread.
struct Artwork: View {
    let url: URL
    var symbol = "film"

    @State private var image: UIImage?

    private static let cache = NSCache<NSString, UIImage>()

    var body: some View {
        // The file is rewritten when the poster is changed in Reel Server, so its date is part of the key.
        let key = "\(url.path)#\(Self.modified(url))"
        // Takes whatever size it is given and fills it, rather than growing to the picture's own shape.
        Color.clear
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    LinearGradient(colors: [Color(white: 0.2), Color(white: 0.1)], startPoint: .top, endPoint: .bottom)
                    Image(systemName: symbol)
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
            .clipped()
            .task(id: key) {
            if let cached = Self.cache.object(forKey: key as NSString) { image = cached; return }
            let path = url.path
            let loaded = await Task.detached(priority: .utility) { UIImage(contentsOfFile: path)?.preparingForDisplay() }.value
            if let loaded {
                Self.cache.setObject(loaded, forKey: key as NSString)
                withAnimation(.easeOut(duration: 0.2)) { image = loaded }
            }
        }
    }

    private static func modified(_ url: URL) -> TimeInterval {
        let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        return date?.timeIntervalSince1970 ?? 0
    }
}

struct PosterCard: View {
    let film: Film
    var fixedWidth: CGFloat?

    @EnvironmentObject private var library: Library
    @EnvironmentObject private var downloads: DownloadCenter
    @Environment(\.reelSizeClass) private var sizeClass

    init(film: Film, width: CGFloat? = nil) {
        self.film = film
        fixedWidth = width
    }

    private var width: CGFloat { fixedWidth ?? Metrics.poster(sizeClass == .regular) }

    var body: some View {
        NavigationLink(value: film) {
            VStack(alignment: .leading, spacing: 6) {
                Artwork(url: film.posterURL)
                    .frame(width: width, height: width * 1.5)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(alignment: .bottom) {
                        if let progress = library.progress(film) { ProgressLine(value: progress).padding(8) }
                    }
                    .overlay(alignment: .topTrailing) {
                        if downloads.download(for: film)?.state == .ready {
                            Image(systemName: "arrow.down.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.black, Theme.gold)
                                .font(.body)
                                .padding(6)
                                .accessibilityHidden(true)
                        }
                    }
                    .reelHoverLift()
                Text(film.episodeLabel.map { "\(film.episode?.show ?? "") \($0)" } ?? film.title)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: width, alignment: .leading)
            }
        }
        // The label goes on the link itself, so VoiceOver (and on the Mac, any accessibility press) opens the film.
        .accessibilityLabel(accessibilityText)
        .buttonStyle(.plain)
        .reelContextMenu { FilmMenu(film: film) } preview: { FilmPreview(film: film) }
    }

    private var accessibilityText: String {
        var parts = [film.fullTitle]
        if let year = film.info?.year { parts.append(String(year)) }
        if downloads.download(for: film)?.state == .ready { parts.append("Downloaded") }
        if let p = library.progress(film) { parts.append("\(Int(p * 100)) percent watched") }
        return parts.joined(separator: ", ")
    }
}

/// 16:9 card: Continue Watching.
struct WideCard: View {
    let film: Film
    var playsDirectly = false

    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var library: Library
    @Environment(\.reelSizeClass) private var sizeClass

    private var width: CGFloat { Metrics.wide(sizeClass == .regular) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if playsDirectly {
                    Button { app.play(film) } label: { artwork }
                        .reelContextMenu {
                            FilmMenu(film: film, inContinueWatching: true)
                            Section { NavigationLink(value: film) { Label("Details", systemImage: "info.circle") } }
                        } preview: { FilmPreview(film: film) }
                } else {
                    NavigationLink(value: film) { artwork }
                        .reelContextMenu { FilmMenu(film: film) } preview: { FilmPreview(film: film) }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel([cardTitle, episodeLine, remaining].compactMap { $0 }.joined(separator: ", "))
            .accessibilityHint(playsDirectly ? "Resumes playing" : "")
            VStack(alignment: .leading, spacing: 2) {
                Text(cardTitle).font(.subheadline.weight(.medium)).lineLimit(1)
                if let episodeLine { Text(episodeLine).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                if let remaining { Text(remaining).font(.caption).foregroundStyle(.secondary) }
            }
            .frame(width: width, alignment: .leading)
            .accessibilityHidden(true)
        }
    }

    /// An episode is named by its show, with the episode underneath.
    private var cardTitle: String { film.episode?.show ?? film.title }
    private var episodeLine: String? { film.episodeLabel.map { "\($0) · \(film.title)" } }

    private var remaining: String? {
        let at = library.resumeSeconds(film)
        guard at > 0, let total = film.seconds else { return nil }
        return "\((total - at).runtimeText) left"
    }

    private var artwork: some View {
        Artwork(url: film.backdropURL, symbol: film.isEpisode ? "tv" : "film")
            .frame(width: width, height: width * 9 / 16)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .bottomLeading) {
                if let progress = library.progress(film) {
                    ProgressLine(value: progress).padding(10)
                }
            }
            .overlay {
                if playsDirectly {
                    Image(systemName: "play.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .padding(14)
                        .background(.black.opacity(0.45), in: Circle())
                }
            }
            .reelHoverLift()
    }
}

struct ProgressLine: View {
    let value: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.35))
                Capsule().fill(Theme.gold).frame(width: geometry.size.width * value)
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

struct Shelf<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    @Environment(\.reelSizeClass) private var sizeClass

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title3.weight(.bold))
                .padding(.horizontal, Metrics.margin(sizeClass == .regular))
                .accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: sizeClass == .regular ? 18 : 12) { content }
                    .padding(.horizontal, Metrics.margin(sizeClass == .regular))
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
    }
}

struct Badges: View {
    let film: Film

    var body: some View {
        HStack(spacing: 6) {
            ForEach(film.badges, id: \.self) { badge in
                Text(badge)
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.white.opacity(0.6), lineWidth: 1))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The gold button: the one most likely action on a screen.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(Theme.gold.opacity(configuration.isPressed ? 0.75 : 1),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(Color.white.opacity(configuration.isPressed ? 0.25 : 0.15),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - The same quick actions wherever a film or episode appears

/// A long-press menu that's the same on every card (context-menus.md: support context menus consistently).
/// Play comes first; the one destructive action, if any, comes last.
struct FilmMenu: View {
    let film: Film
    /// Offers Remove from Continue Watching.
    var inContinueWatching = false

    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var downloads: DownloadCenter
    @AppStorage("downloadQuality") private var downloadQuality = "original"

    var body: some View {
        let resume = library.resumeSeconds(film)
        let state = library.state(film)
        Section {
            Button(resume > 0 ? "Resume" : "Play", systemImage: "play.fill") { app.play(film) }
            if resume > 0 {
                Button("Play from Beginning", systemImage: "arrow.counterclockwise") { app.play(film, from: 0) }
            }
        }
        Section {
            if !film.isEpisode {
                Button(state.favorite ? "Remove from My List" : "Add to My List",
                       systemImage: state.favorite ? "minus.circle" : "plus.circle") {
                    library.update(film) { $0.favorite.toggle() }
                }
            }
            Button(state.watched ? "Mark as Unwatched" : "Mark as Watched", systemImage: state.watched ? "eye.slash" : "eye") {
                library.update(film) {
                    $0.watched.toggle()
                    $0.position = 0
                }
            }
            downloadItem
        }
        if inContinueWatching && resume > 0 {
            Section {
                Button("Remove from Continue Watching", systemImage: "xmark.circle", role: .destructive) {
                    library.update(film) { $0.position = 0 }
                }
            }
        }
    }

    @ViewBuilder private var downloadItem: some View {
        if let download = downloads.download(for: film) {
            if download.state == .ready {
                Button("Remove Download", systemImage: "trash", role: .destructive) { downloads.remove(download) }
            } else {
                Button("Cancel Download", systemImage: "stop.circle") { downloads.remove(download) }
            }
        } else if downloadQuality == "custom" {
            Menu("Download", systemImage: "arrow.down.circle") {
                ForEach(CopyQuality.allCases) { quality in
                    Button("\(quality.title) · \(quality == .original ? "" : "about ")\(film.estimatedSize(quality).fileSize)") {
                        app.download(film, quality: quality)
                    }
                }
            }
        } else {
            Button("Download", systemImage: "arrow.down.circle") { app.download(film) }
        }
    }
}

/// What a long press shows above the menu: the picture, name and a line about it.
struct FilmPreview: View {
    let film: Film

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Artwork(url: film.backdropURL, symbol: film.isEpisode ? "tv" : "film")
                .frame(width: 320, height: 180)
            VStack(alignment: .leading, spacing: 4) {
                if let episode = film.episode, let label = film.episodeLabel {
                    Text("\(episode.show) · \(label)").font(.caption.weight(.semibold)).foregroundStyle(Theme.gold)
                }
                Text(film.title).font(.headline).lineLimit(2)
                if !film.metaLine.isEmpty { Text(film.metaLine).font(.caption).foregroundStyle(.secondary) }
                if let overview = film.info?.overview {
                    Text(overview).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            .padding(12)
        }
        .frame(width: 320, alignment: .leading)
        .background(Color(white: 0.11))
    }
}

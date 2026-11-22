import SwiftUI

/// Artwork saved on the phone, decoded off the main thread.
struct Artwork: View {
    let url: URL
    var symbol = "film"

    @State private var image: UIImage?

    private static let cache = NSCache<NSURL, UIImage>()

    var body: some View {
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
            .task(id: url) {
            if let cached = Self.cache.object(forKey: url as NSURL) { image = cached; return }
            let path = url.path
            let loaded = await Task.detached(priority: .utility) { UIImage(contentsOfFile: path)?.preparingForDisplay() }.value
            if let loaded {
                Self.cache.setObject(loaded, forKey: url as NSURL)
                withAnimation(.easeOut(duration: 0.2)) { image = loaded }
            }
        }
    }
}

struct PosterCard: View {
    let film: Film
    var width: CGFloat = 124

    @EnvironmentObject private var library: Library
    @EnvironmentObject private var downloads: DownloadCenter

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
                Text(film.title)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: width, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
    }

    private var accessibilityText: String {
        var parts = [film.title]
        if let year = film.info?.year { parts.append(String(year)) }
        if downloads.download(for: film)?.state == .ready { parts.append("Downloaded") }
        if let p = library.progress(film) { parts.append("\(Int(p * 100)) percent watched") }
        return parts.joined(separator: ", ")
    }
}

/// 16:9 card: Continue Watching and home videos.
struct WideCard: View {
    let film: Film
    var width: CGFloat = 260
    var playsDirectly = false

    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var library: Library

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if playsDirectly {
                    Button { app.play(film) } label: { artwork }
                        .contextMenu {
                            Button("Play from Beginning", systemImage: "arrow.counterclockwise") { app.play(film, from: 0) }
                            NavigationLink(value: film) { Label("Details", systemImage: "info.circle") }
                        }
                } else {
                    NavigationLink(value: film) { artwork }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel([film.title, remaining].compactMap { $0 }.joined(separator: ", "))
            .accessibilityHint(playsDirectly ? "Resumes playing" : "")
            VStack(alignment: .leading, spacing: 2) {
                Text(film.title).font(.subheadline.weight(.medium)).lineLimit(1)
                if let remaining { Text(remaining).font(.caption).foregroundStyle(.secondary) }
            }
            .frame(width: width, alignment: .leading)
            .accessibilityHidden(true)
        }
    }

    private var remaining: String? {
        let at = library.resumeSeconds(film)
        guard at > 0, let total = film.seconds else { return nil }
        return "\((total - at).runtimeText) left"
    }

    private var artwork: some View {
        Artwork(url: film.backdropURL, symbol: film.isHomeVideo ? "video" : "film")
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title3.weight(.bold))
                .padding(.horizontal, 16)
                .accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) { content }
                    .padding(.horizontal, 16)
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

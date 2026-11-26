import SwiftUI

struct FilmDetailView: View {
    let film: Film
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var downloads: DownloadCenter
    @AppStorage("downloadQuality") private var downloadQuality = "original"
    @State private var choosingQuality = false
    @State private var confirmDelete = false
    @State private var expanded = false
    @State private var problem: String?
    @Environment(\.reelSizeClass) private var sizeClass
    private var regular: Bool { sizeClass == .regular }

    private var current: Film { library.film(film.id) ?? film }
    private var state: WatchState { library.state(current) }
    private var download: Download? { downloads.download(for: current) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                VStack(alignment: .leading, spacing: 16) {
                    playButtons
                    actionRow
                    if let download, download.state != .ready {
                        DownloadStatus(film: current, download: download)
                            .padding(12)
                            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    if let tagline = current.info?.tagline {
                        Text(tagline).font(.headline).italic()
                    }
                    if let overview = current.info?.overview {
                        Text(overview)
                            .lineLimit(expanded ? nil : 4)
                            .onTapGesture { withAnimation { expanded.toggle() } }
                            .accessibilityHint(expanded ? "" : "Double-tap to read more")
                    }
                    VersionsAndExtras(film: current)
                    people
                    facts
                }
                .frame(maxWidth: regular ? Metrics.readableWidth : nil, alignment: .leading)
                .padding(.horizontal, Metrics.margin(regular))
                related
                    .padding(.top, 8)
            }
            .padding(.bottom, 32)
        }
        .ignoresSafeArea(edges: .top)
        .reelClearNavigationBar()
        .confirmationDialog("Download Quality", isPresented: $choosingQuality, titleVisibility: .visible) {
            ForEach(CopyQuality.allCases) { quality in
                Button(qualityLabel(quality)) { start(quality) }
            }
        } message: {
            Text("Medium and Low are made by your Mac the first time, which takes about 45 minutes. They download straight from Google after that.")
        }
        .confirmationDialog("Remove Download?", isPresented: $confirmDelete, titleVisibility: .visible) {
            if let download {
                Button(download.state == .ready ? "Remove \(download.size.fileSize)" : "Cancel Download", role: .destructive) {
                    downloads.remove(download)
                }
            }
        } message: {
            Text("The film stays in Google Drive.")
        }
        .alert("Can’t Download", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
    }

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            Artwork(url: current.backdropURL, symbol: current.isHomeVideo ? "video" : "film")
                .frame(height: regular ? 480 : 300)
                .frame(maxWidth: .infinity)
                .clipped()
                .overlay {
                    LinearGradient(stops: [.init(color: .black.opacity(0.4), location: 0), .init(color: .clear, location: 0.3),
                                           .init(color: .black, location: 1)], startPoint: .top, endPoint: .bottom)
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                if let episode = current.episode, let label = current.episodeLabel {
                    Text("\(episode.show) · \(label)").font(.headline).foregroundStyle(Theme.gold)
                }
                Text(current.title)
                    .font(.largeTitle.weight(.bold))
                    .lineLimit(3)
                    .minimumScaleFactor(0.75)
                    .accessibilityAddTraits(.isHeader)
                HStack(spacing: 10) {
                    if !current.metaLine.isEmpty { Text(current.metaLine).font(.subheadline).foregroundStyle(.secondary) }
                    Badges(film: current)
                }
                if let genres = current.info?.genres, !genres.isEmpty {
                    Text(genres.prefix(3).joined(separator: ", ")).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: regular ? Metrics.readableWidth : nil, alignment: .leading)
            .padding(.horizontal, Metrics.margin(regular))
        }
    }

    private var playButtons: some View {
        VStack(spacing: 10) {
            let resume = library.resumeSeconds(current)
            Button { app.play(current) } label: {
                Label(resume > 0 ? "Resume" : "Play", systemImage: "play.fill")
            }
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityHint(download?.state == .ready ? "Plays the copy on this \(Device.name)" : "Streams the original from Google Drive")
            if resume > 0, let total = current.seconds {
                HStack {
                    ProgressLine(value: resume / total)
                    Text("\((total - resume).runtimeText) left").font(.caption).foregroundStyle(.secondary)
                }
                Button { app.play(current, from: 0) } label: {
                    Label("Play from Beginning", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            if download?.state == .ready && download?.quality != .original {
                Button("Stream Original Instead") { app.play(current, forceStream: true) }
                    .font(.subheadline)
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 0) {
            ActionButton(title: downloadTitle, symbol: downloadSymbol) { downloadTapped() }
            ActionButton(title: "My List", symbol: state.favorite ? "checkmark" : "plus") {
                library.update(current) { $0.favorite.toggle() }
            }
            .accessibilityValue(state.favorite ? "Added" : "Not added")
            ActionButton(title: state.watched ? "Watched" : "Mark Watched", symbol: state.watched ? "eye.fill" : "eye") {
                library.update(current) {
                    $0.watched.toggle()
                    $0.position = 0
                }
            }
        }
    }

    private var downloadTitle: String {
        switch download?.state {
        case .ready: return "Downloaded"
        case .downloading, .checking: return "Downloading"
        case .waitingForMac: return "Waiting"
        case .failed: return "Try Again"
        case nil: return "Download"
        }
    }

    private var downloadSymbol: String {
        switch download?.state {
        case .ready: return "arrow.down.circle.fill"
        case .downloading, .checking, .waitingForMac: return "stop.circle"
        case .failed: return "arrow.clockwise.circle"
        case nil: return "arrow.down.circle"
        }
    }

    private func downloadTapped() {
        if let download {
            if download.state == .failed { Task { await downloads.retry(current) } } else { confirmDelete = true }
            return
        }
        if downloadQuality == "custom" { choosingQuality = true } else { start(.original) }
    }

    private func qualityLabel(_ quality: CopyQuality) -> String {
        let size = current.estimatedSize(quality)
        switch quality {
        case .original: return "Original · \(size.fileSize)"
        default:
            let ready = library.copies[current.id]?[quality] != nil
            return "\(quality.title) · about \(size.fileSize)\(ready ? "" : " · made on your Mac")"
        }
    }

    private func start(_ quality: CopyQuality) {
        Task {
            do {
                try await downloads.start(current, quality: quality)
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    @ViewBuilder private var people: some View {
        let cast = current.info?.people.filter { $0.kind == "Actor" } ?? []
        let directors = current.info?.people.filter { $0.kind == "Director" }.map(\.name) ?? []
        if !directors.isEmpty {
            LabeledContent("Director", value: directors.joined(separator: ", ")).font(.subheadline)
        }
        if !cast.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Cast").font(.title3.weight(.bold)).accessibilityAddTraits(.isHeader)
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 16) {
                        ForEach(cast, id: \.self) { person in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(person.name).font(.subheadline.weight(.medium))
                                if let role = person.role, !role.isEmpty {
                                    Text(role).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .frame(width: 120, alignment: .leading)
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    /// For a film, others like it; for an episode, the rest of its season.
    @ViewBuilder private var related: some View {
        if let episode = current.episode, let show = library.show(episode.showID) {
            let others = show.episodes(in: episode.season).filter { $0.id != current.id }
            if !others.isEmpty {
                Shelf(title: "More from \(show.title)") {
                    ForEach(others) { WideCard(film: $0) }
                }
            }
        } else {
            let similar = library.similar(to: current)
            if !similar.isEmpty {
                Shelf(title: "More Like This") {
                    ForEach(similar) { PosterCard(film: $0) }
                }
            }
        }
    }

    private var facts: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("About This File").font(.title3.weight(.bold)).accessibilityAddTraits(.isHeader)
            if let sound = current.info?.sound { LabeledContent("Sound", value: sound) }
            LabeledContent("Original", value: current.size.fileSize)
            if let studio = current.info?.studio { LabeledContent("Studio", value: studio) }
            if let score = current.info?.score { LabeledContent("Rating", value: String(format: "%.1f / 10", score)) }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
}

private struct ActionButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.title2).frame(height: 28)
                Text(title).font(.caption)
            }
            .frame(maxWidth: .infinity, minHeight: 56)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(title)
        .buttonStyle(.plain)
    }
}

// MARK: - Versions and extras

/// Below the description: the film's other versions and its bonus material, as in the TV app.
private struct VersionsAndExtras: View {
    let film: Film
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var library: Library
    @State private var tab = Tab.versions

    enum Tab: String, CaseIterable, Identifiable {
        case versions = "Versions", extras = "Extras"
        var id: String { rawValue }
    }

    var body: some View {
        let versions = library.versions(of: film)
        let extras = library.extras(of: film)
        let tabs = Tab.allCases.filter { $0 == .versions ? !versions.isEmpty : !extras.isEmpty }
        if !tabs.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                if tabs.count > 1 {
                    Picker("Show", selection: $tab) {
                        ForEach(tabs) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } else {
                    Text(tabs[0].rawValue).font(.title3.weight(.bold)).accessibilityAddTraits(.isHeader)
                }
                switch tabs.count > 1 ? tab : tabs[0] {
                case .versions:
                    ForEach(versions) { VersionRow(film: $0) }
                case .extras:
                    ForEach(extras) { ExtraRow(film: $0) }
                }
            }
            .padding(.vertical, 4)
            .onAppear { if !tabs.contains(tab), let first = tabs.first { tab = first } }
        }
    }
}

/// A version: its name and picture, and whether Play uses it. Tapping plays it; holding offers downloading.
private struct VersionRow: View {
    let film: Film
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var library: Library

    var body: some View {
        let version = film.info?.filmVersion
        Button { app.play(film) } label: {
            HStack(spacing: 12) {
                Image(systemName: version?.isDefault == true ? "checkmark.circle.fill" : "play.circle")
                    .font(.title2)
                    .foregroundStyle(version?.isDefault == true ? Theme.gold : .secondary)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(version?.label ?? film.title).font(.headline)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Badges(film: film)
            }
            .padding(12)
            .frame(minHeight: 56)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { FilmMenu(film: film) }
        .accessibilityLabel([version?.label, version?.isDefault == true ? "default version" : nil, detail]
            .compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint("Plays this version")
    }

    private var detail: String {
        let resume = library.resumeSeconds(film)
        return [film.info?.filmVersion?.isDefault == true ? "Default" : nil,
                resume > 0 ? "\(((film.seconds ?? 0) - resume).runtimeText) left" : film.seconds?.runtimeText,
                film.size.fileSize].compactMap { $0 }.joined(separator: " · ")
    }
}

/// A trailer or other extra: a still, its name, kind and length. Tapping plays it.
private struct ExtraRow: View {
    let film: Film
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var library: Library
    @Environment(\.reelSizeClass) private var sizeClass

    var body: some View {
        Button { app.play(film) } label: {
            HStack(alignment: .top, spacing: 12) {
                Artwork(url: film.backdropURL, symbol: "sparkles.tv")
                    .frame(width: sizeClass == .regular ? 200 : 140, height: (sizeClass == .regular ? 200 : 140) * 9 / 16)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(alignment: .bottom) {
                        if let progress = library.progress(film) { ProgressLine(value: progress).padding(6) }
                    }
                VStack(alignment: .leading, spacing: 3) {
                    Text(film.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                    Text([film.info?.extra?.kind.title, film.seconds?.runtimeText].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { FilmMenu(film: film) }
        .accessibilityLabel("\(film.title), \(film.info?.extra?.kind.title ?? "Extra")")
        .accessibilityHint("Plays it")
    }
}

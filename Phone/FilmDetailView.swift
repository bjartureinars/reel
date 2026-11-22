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
                    people
                    facts
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 32)
        }
        .ignoresSafeArea(edges: .top)
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
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
                .frame(height: 300)
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
                HStack(spacing: 10) {
                    if !current.metaLine.isEmpty { Text(current.metaLine).font(.subheadline).foregroundStyle(.secondary) }
                    Badges(film: current)
                }
                if let genres = current.info?.genres, !genres.isEmpty {
                    Text(genres.prefix(3).joined(separator: ", ")).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var playButtons: some View {
        VStack(spacing: 10) {
            let resume = library.resumeSeconds(current)
            Button { app.play(current) } label: {
                Label(resume > 0 ? "Resume" : "Play", systemImage: "play.fill")
            }
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityHint(download?.state == .ready ? "Plays the copy on this iPhone" : "Streams the original from Google Drive")
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
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
    }
}

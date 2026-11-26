import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// MARK: - What Jellyfin offers

/// A film that Jellyfin's film databases think a file might be.
struct FilmMatch: Identifiable {
    let id = UUID()
    let name: String
    let year: Int?
    let overview: String?
    let imageURL: URL?
    let source: String?
    /// Exactly what Jellyfin sent: choosing a match sends it back unchanged.
    let raw: [String: Any]
}

/// A poster or backdrop from the film databases.
struct ArtworkChoice: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    let thumbnail: URL
    let width: Int?
    let height: Int?
    let language: String?
    let source: String?
}

enum ArtworkKind: String {
    case poster = "Primary"
    case backdrop = "Backdrop"

    var noun: String { self == .poster ? "Poster" : "Backdrop" }
    var aspect: CGFloat { self == .poster ? 2.0 / 3.0 : 16.0 / 9.0 }
}

extension ServerManager {
    func isInDrive(_ item: Item) -> Bool { item.path?.hasPrefix(cloud.paths.mount.path + "/") == true }

    /// Films matching the year come first, but other years are always included: the year Jellyfin guessed
    /// from a file name is often wrong, and a wrong year would otherwise hide the right film.
    func findMatches(for item: Item, name: String, year: Int?) async throws -> [FilmMatch] {
        func search(_ year: Int?) async throws -> [[String: Any]] {
            var info: [String: Any] = ["Name": name]
            if let year { info["Year"] = year }
            let data = try await client.send("POST", "/Items/RemoteSearch/\(item.isSeries ? "Series" : "Movie")", json: [
                "SearchInfo": info, "ItemId": item.id, "IncludeDisabledProviders": false,
            ] as [String: Any], timeout: 60)
            return (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
        }
        var results = try await search(nil)
        if let year {
            let sameYear = ((try? await search(year)) ?? []).filter { $0["ProductionYear"] as? Int == year }
            let key = { (r: [String: Any]) in "\(r["Name"] ?? "")|\(r["ProductionYear"] ?? "")" }
            let first = Set(sameYear.map(key))
            results = sameYear + results.filter { !first.contains(key($0)) }
        }
        return results.map { result in
            FilmMatch(name: result["Name"] as? String ?? "Untitled",
                      year: result["ProductionYear"] as? Int,
                      overview: result["Overview"] as? String,
                      imageURL: (result["ImageUrl"] as? String).flatMap(URL.init(string:)),
                      source: result["SearchProviderName"] as? String,
                      raw: result)
        }
    }

    /// Replaces the film's title, details, poster and backdrop with the chosen match.
    func apply(_ match: FilmMatch, to item: Item) async throws -> Item {
        try await client.send("POST", "/Items/RemoteSearch/Apply/\(item.id)", query: [.init("replaceAllImages", "true")],
                              json: match.raw, timeout: 180)
        // Jellyfin can finish fetching the new details just after it answers.
        guard let userId = currentUserId else { return item }
        var latest = item
        for _ in 0..<12 {
            if let fresh = try? await client.item(item.id, userId: userId) {
                latest = fresh
                if fresh.name != item.name || fresh.productionYear != item.productionYear
                    || fresh.imageTags != item.imageTags { break }
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        await refreshLibraries()
        return latest
    }

    func artworkChoices(for item: Item, kind: ArtworkKind, allLanguages: Bool) async throws -> [ArtworkChoice] {
        let data = try await client.send("GET", "/Items/\(item.id)/RemoteImages", query: [
            .init("type", kind.rawValue), .init("limit", "100"), .init("includeAllLanguages", allLanguages ? "true" : "false"),
        ], timeout: 60)
        let images = ((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["Images"] as? [[String: Any]]) ?? []
        var seen = Set<URL>()
        return images.compactMap { image in
            guard let url = (image["Url"] as? String).flatMap(URL.init(string:)), seen.insert(url).inserted else { return nil }
            return ArtworkChoice(url: url,
                                 thumbnail: (image["ThumbnailUrl"] as? String).flatMap(URL.init(string:)) ?? url,
                                 width: image["Width"] as? Int, height: image["Height"] as? Int,
                                 language: image["Language"] as? String, source: image["ProviderName"] as? String)
        }
    }

    func use(_ choice: ArtworkChoice, as kind: ArtworkKind, for item: Item) async throws -> Item {
        let before = try await backdropTags(item)
        try await client.send("POST", "/Items/\(item.id)/RemoteImages/Download", query: [
            .init("type", kind.rawValue), .init("imageUrl", choice.url.absoluteString),
        ], timeout: 120)
        if kind == .backdrop { try await keepOnlyNewBackdrop(item, before: before) }
        return await reload(item)
    }

    /// Uses a picture from this Mac. It's sent as a JPEG no bigger than it needs to be.
    func upload(_ file: URL, as kind: ArtworkKind, for item: Item) async throws -> Item {
        let jpeg = try await Task.detached { try Self.jpeg(from: file, maxPixels: kind == .poster ? 3000 : 3840) }.value
        let before = try await backdropTags(item)
        let path = "/Items/\(item.id)/Images/\(kind.rawValue)"
        do {
            try await client.send("POST", path, body: jpeg, contentType: "image/jpeg")
        } catch let error as JellyfinError where error.status >= 400 && !error.isUnauthorized {
            // Older Jellyfin versions only take the picture written out as base64 text.
            try await client.send("POST", path, body: jpeg.base64EncodedData(), contentType: "image/jpeg")
        }
        if kind == .backdrop { try await keepOnlyNewBackdrop(item, before: before) }
        return await reload(item)
    }

    private func reload(_ item: Item) async -> Item {
        await refreshLibraries()
        guard let userId = currentUserId, let fresh = try? await client.item(item.id, userId: userId) else { return item }
        return fresh
    }

    private func images(_ item: Item) async throws -> [[String: Any]] {
        let data = try await client.send("GET", "/Items/\(item.id)/Images")
        return (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
    }

    private func backdropTags(_ item: Item) async throws -> Set<String> {
        Set(try await images(item).filter { $0["ImageType"] as? String == "Backdrop" }.compactMap { $0["ImageTag"] as? String })
    }

    /// A new backdrop is added after the old ones, but the apps show the first, so the others go.
    private func keepOnlyNewBackdrop(_ item: Item, before: Set<String>) async throws {
        let backdrops = try await images(item).filter { $0["ImageType"] as? String == "Backdrop" }
        guard backdrops.contains(where: { ($0["ImageTag"] as? String).map { !before.contains($0) } ?? false }) else { return }
        let old = backdrops.filter { ($0["ImageTag"] as? String).map(before.contains) ?? false }
            .compactMap { $0["ImageIndex"] as? Int }
        // Highest first, so removing one doesn't move the others.
        for index in old.sorted(by: >) {
            try await client.send("DELETE", "/Items/\(item.id)/Images/Backdrop/\(index)")
        }
    }

    nonisolated static func jpeg(from file: URL, maxPixels: Int) throws -> Data {
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                       kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceThumbnailMaxPixelSize: maxPixels] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            throw CloudError("Reel can’t read that picture. Try a JPEG, PNG or HEIC file.")
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CloudError("Reel couldn’t prepare that picture.")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CloudError("Reel couldn’t prepare that picture.") }
        return data as Data
    }
}

// MARK: - The film window

struct ManagedFilm: Identifiable {
    let item: Item
    var page: FilmSheet.Page = .overview
    var id: String { item.id }
}

/// Everything you can do to one film: check its details, identify it, change its pictures, delete it.
struct FilmSheet: View {
    enum Page: Equatable {
        case overview, identify
        case artwork(ArtworkKind)
    }

    @ObservedObject var server: ServerManager
    @State private var item: Item
    @State private var page: Page
    @State private var confirmDelete = false
    @State private var episodes: [Item] = []
    @State private var tab: Tab = .details
    /// The film in Reel's catalog, found once: grouping moves it on the disk, so its path stops matching.
    @State private var filmID: UInt64?
    @Environment(\.dismiss) private var dismiss

    enum Tab: String, CaseIterable, Identifiable {
        case details = "Details", versions = "Versions", extras = "Extras"
        var id: String { rawValue }
    }

    /// Versions and extras are for films kept in Google Drive.
    private var hasTabs: Bool { !item.isSeries && (inDrive || filmID != nil) }

    private var noun: String { item.isSeries ? "Show" : "Film" }

    init(server: ServerManager, film: ManagedFilm) {
        self.server = server
        _item = State(initialValue: film.item)
        _page = State(initialValue: film.page)
        _filmID = State(initialValue: film.item.path.flatMap { server.cloud.film(atDiskPath: $0)?.id })
    }

    var body: some View {
        Group {
            switch page {
            case .overview:
                overview
            case .identify:
                IdentifyPage(server: server, item: item) { updated in
                    if let updated { item = updated }
                    page = .overview
                }
            case .artwork(let kind):
                ArtworkPage(server: server, item: item, kind: kind) { updated in
                    if let updated { item = updated }
                    page = .overview
                }
            }
        }
        .frame(width: 760, height: 580)
        .task(id: item.id) {
            if item.isSeries { episodes = await server.episodes(of: item) }
        }
    }

    private var inDrive: Bool { server.isInDrive(item) }

    private var details: some View {
            HStack(alignment: .top, spacing: 28) {
                VStack(spacing: 12) {
                    RemoteArtwork(url: server.client.imageURL(for: item, maxWidth: 500), symbol: "film")
                        .aspectRatio(ArtworkKind.poster.aspect, contentMode: .fit)
                        .frame(width: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .accessibilityLabel("Poster")
                    Button("Change Poster…") { page = .artwork(.poster) }
                }

                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title)
                            .font(.largeTitle.weight(.bold))
                            .lineLimit(2)
                            .textSelection(.enabled)
                        if !detailLine.isEmpty { Text(detailLine).foregroundStyle(.secondary) }
                    }
                    if let text = item.overview, !text.isEmpty {
                        ScrollView {
                            Text(text).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                        }
                        .frame(maxHeight: 130)
                    } else {
                        Text("No description yet. If Reel didn’t recognise this \(noun.lowercased()), identify it.")
                            .foregroundStyle(.secondary)
                    }
                    Button("Identify \(noun)…") { page = .identify }
                        .help("Choose which \(noun.lowercased()) this is, to get the right title, details and pictures")

                    Divider().padding(.vertical, 2)

                    HStack(alignment: .center, spacing: 14) {
                        RemoteArtwork(url: backdropURL, symbol: "photo")
                            .aspectRatio(ArtworkKind.backdrop.aspect, contentMode: .fit)
                            .frame(width: 192)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .accessibilityLabel("Backdrop")
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Backdrop").font(.headline)
                            Text("The wide picture behind the \(noun.lowercased()) on your Apple TV and iPhone.")
                                .font(.callout).foregroundStyle(.secondary)
                            Button("Change Backdrop…") { page = .artwork(.backdrop) }
                        }
                    }

                    if item.isSeries {
                        EpisodeList(episodes: episodes)
                    } else {
                        Spacer(minLength: 0)
                    }

                    LabeledContent("Stored in") { Text(inDrive ? "Google Drive" : "This Mac") }
                    if let path = item.path, !item.isSeries {
                        LabeledContent("File") {
                            Text((path as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        }
                    }
                }
            }
            .padding(28)
    }


    private var overview: some View {
        VStack(spacing: 0) {
            if hasTabs {
                Picker("Show", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 320)
                .padding(.top, 18)
            }
            switch tab {
            case .versions where hasTabs:
                VersionsPane(server: server, cloud: server.cloud, item: item, filmID: filmID).padding(28)
            case .extras where hasTabs:
                ExtrasPane(server: server, cloud: server.cloud, item: item, filmID: filmID).padding(28)
            default:
                details
            }

            Divider()
            HStack {
                Button(inDrive ? (item.isSeries ? "Delete Show from Google Drive…" : "Delete from Google Drive…") : "Move to Trash…",
                       role: .destructive) { confirmDelete = true }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .alert(deleteTitle, isPresented: $confirmDelete) {
            Button(inDrive ? "Delete" : "Move to Trash", role: .destructive) {
                let film = item
                Task { film.isSeries ? await server.removeShow(film) : await server.removeFromLibrary(film) }
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(inDrive
                 ? "It goes to Drive’s Bin, where it can be restored for 30 days. After that Google deletes it for good. It disappears from your Apple TV and iPhone."
                 : "It disappears from your Apple TV. You can put it back from the Trash.")
        }
    }

    private var deleteTitle: String {
        if item.isSeries {
            let count = episodes.count == 1 ? "its episode" : "all \(episodes.count) episodes"
            return inDrive ? "Delete “\(item.title)” and \(count) from Google Drive?" : "Move “\(item.title)” and \(count) to the Trash?"
        }
        return inDrive ? "Delete “\(item.title)” from Google Drive?" : "Move “\(item.title)” to the Trash?"
    }

    private var backdropURL: URL? {
        item.backdropImageTags?.isEmpty == false ? server.client.backdropURL(for: item, maxWidth: 640) : nil
    }

    private var detailLine: String {
        var parts: [String] = []
        if let year = item.productionYear { parts.append(String(year)) }
        if item.isSeries {
            let seasons = Set(episodes.compactMap(\.parentIndexNumber)).count
            if seasons > 0 { parts.append(seasons == 1 ? "1 season" : "\(seasons) seasons") }
            if !episodes.isEmpty { parts.append(episodes.count == 1 ? "1 episode" : "\(episodes.count) episodes") }
            return parts.joined(separator: " · ")
        }
        if let runtime = item.runtimeText { parts.append(runtime) }
        parts.append(contentsOf: item.badges.prefix(3))
        return parts.joined(separator: " · ")
    }
}

// MARK: - Identify

private struct IdentifyPage: View {
    @ObservedObject var server: ServerManager
    let item: Item
    let finish: (Item?) -> Void

    @State private var name: String
    @State private var year: String
    @State private var matches: [FilmMatch] = []
    @State private var selection: FilmMatch.ID?
    @State private var searching = false
    @State private var searched = false
    @State private var applying = false
    @State private var problem: String?

    init(server: ServerManager, item: Item, finish: @escaping (Item?) -> Void) {
        self.server = server
        self.item = item
        self.finish = finish
        _name = State(initialValue: item.title)
        _year = State(initialValue: item.productionYear.map(String.init) ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text(item.isSeries ? "Identify Show" : "Identify Film").font(.title2.weight(.bold))
                Text(item.isSeries
                     ? "Search for the show these episodes really belong to. Its title, details, episode names, poster and backdrop are replaced with the one you choose."
                     : "Search for the film this file really is. Its title, details, poster and backdrop are replaced with the one you choose.")
                    .foregroundStyle(.secondary)
                HStack {
                    TextField("Title", text: $name)
                    TextField("Year", text: $year)
                        .frame(width: 72)
                    Button("Search") { Task { await search() } }
                        .disabled(trimmedName.isEmpty || searching)
                }
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await search() } }
            }
            .padding([.horizontal, .top], 24)
            .padding(.bottom, 14)

            List(matches, selection: $selection) { match in
                MatchRow(match: match).tag(match.id)
            }
            .contextMenu(forSelectionType: FilmMatch.ID.self) { _ in
            } primaryAction: { ids in
                if let id = ids.first { apply(id) }
            }
            .overlay {
                if searching {
                    ProgressView("Searching…")
                } else if searched && matches.isEmpty {
                    ContentUnavailableView("No Matches", systemImage: "magnifyingglass",
                                           description: Text(problem ?? "Try fewer words, or leave the year empty."))
                }
            }
            .disabled(applying)

            Divider()
            HStack(spacing: 10) {
                if applying {
                    ProgressView().controlSize(.small)
                    Text("Getting the new details…").foregroundStyle(.secondary)
                } else if let problem, !matches.isEmpty {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).lineLimit(2)
                }
                Spacer()
                Button("Cancel") { finish(nil) }
                    .keyboardShortcut(.cancelAction)
                Button(item.isSeries ? "Use This Show" : "Use This Film") { apply(selection) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection == nil || applying)
            }
            .padding(16)
        }
        .task { await search() }
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func search() async {
        guard !trimmedName.isEmpty, !searching else { return }
        searching = true
        problem = nil
        defer { searching = false; searched = true }
        do {
            matches = try await server.findMatches(for: item, name: trimmedName,
                                                   year: Int(year.trimmingCharacters(in: .whitespaces)))
            selection = matches.first?.id
        } catch {
            matches = []
            problem = "The search didn’t work: \(error.localizedDescription)"
        }
    }

    private func apply(_ id: FilmMatch.ID?) {
        guard let match = matches.first(where: { $0.id == id }), !applying else { return }
        applying = true
        problem = nil
        Task {
            do {
                finish(try await server.apply(match, to: item))
            } catch {
                problem = "Reel couldn’t use that film: \(error.localizedDescription)"
                applying = false
            }
        }
    }
}

private struct MatchRow: View {
    let match: FilmMatch

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RemoteArtwork(url: match.imageURL, symbol: "film")
                .frame(width: 48, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(match.year.map { "\(match.name) (\($0))" } ?? match.name).font(.headline)
                if let overview = match.overview, !overview.isEmpty {
                    Text(overview).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                if let source = match.source { Text(source).font(.caption).foregroundStyle(.tertiary) }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Posters and backdrops

private struct ArtworkPage: View {
    enum Pick: Hashable {
        case file(URL)
        case online(ArtworkChoice)
    }

    @ObservedObject var server: ServerManager
    let item: Item
    let kind: ArtworkKind
    let finish: (Item?) -> Void

    @State private var choices: [ArtworkChoice] = []
    @State private var file: URL?
    @State private var pick: Pick?
    @State private var allLanguages = false
    @State private var loading = true
    @State private var saving = false
    @State private var problem: String?
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Choose a \(kind.noun)").font(.title2.weight(.bold))
                    Spacer()
                    Toggle("All Languages", isOn: $allLanguages)
                        .toggleStyle(.checkbox)
                        .help("Also show pictures made for other countries")
                }
                Text("Pick one from the film databases, or use your own picture: choose a file, or drag one here.")
                    .foregroundStyle(.secondary)
            }
            .padding([.horizontal, .top], 24)
            .padding(.bottom, 12)

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: kind == .poster ? 124 : 210), spacing: 16)], spacing: 18) {
                    if let file {
                        tile(.file(file), caption: "Your picture") {
                            if let image = NSImage(contentsOf: file) {
                                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                            }
                        }
                    }
                    ForEach(choices) { choice in
                        tile(.online(choice), caption: caption(choice)) {
                            RemoteArtwork(url: choice.thumbnail, symbol: "photo")
                        }
                    }
                }
                .padding(24)
            }
            .overlay {
                if loading && choices.isEmpty {
                    ProgressView("Finding pictures…")
                } else if !loading && choices.isEmpty && file == nil {
                    ContentUnavailableView("No Pictures Found", systemImage: "photo.on.rectangle",
                                           description: Text(problem ?? "Choose your own picture, or identify the film first."))
                }
            }
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                        .padding(10)
                        .allowsHitTesting(false)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first(where: { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true })
                else { return false }
                file = url
                pick = .file(url)
                return true
            } isTargeted: { dropTargeted = $0 }

            Divider()
            HStack(spacing: 10) {
                Button("Choose File…") { chooseFile() }
                if saving {
                    ProgressView().controlSize(.small)
                    Text("Saving…").foregroundStyle(.secondary)
                } else if let problem, !choices.isEmpty || file != nil {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).lineLimit(2)
                }
                Spacer()
                Button("Cancel") { finish(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("Use \(kind.noun)") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(pick == nil || saving)
            }
            .padding(16)
        }
        .task(id: allLanguages) { await load() }
    }

    private func tile<Content: View>(_ choice: Pick, caption: String, @ViewBuilder content: () -> Content) -> some View {
        let selected = pick == choice
        return Button {
            pick = choice
        } label: {
            VStack(spacing: 6) {
                Color.clear
                    .aspectRatio(kind.aspect, contentMode: .fit)
                    .overlay { content() }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 3)
                    }
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(selected ? .primary : .secondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(caption)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func caption(_ choice: ArtworkChoice) -> String {
        var parts: [String] = []
        if let w = choice.width, let h = choice.height { parts.append("\(w) × \(h)") }
        if let language = choice.language, !language.isEmpty { parts.append(language.uppercased()) }
        return parts.isEmpty ? (choice.source ?? "") : parts.joined(separator: " · ")
    }

    private func load() async {
        loading = true
        problem = nil
        defer { loading = false }
        do {
            choices = try await server.artworkChoices(for: item, kind: kind, allLanguages: allLanguages)
            if case .online(let chosen) = pick, !choices.contains(chosen) { pick = file.map(Pick.file) }
        } catch {
            choices = []
            problem = "The film databases didn’t answer: \(error.localizedDescription)"
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a picture to use as the \(kind.noun.lowercased())."
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        file = url
        pick = .file(url)
    }

    private func save() {
        guard let pick, !saving else { return }
        saving = true
        problem = nil
        Task {
            do {
                switch pick {
                case .file(let url): finish(try await server.upload(url, as: kind, for: item))
                case .online(let choice): finish(try await server.use(choice, as: kind, for: item))
                }
            } catch {
                problem = "Reel couldn’t save the \(kind.noun.lowercased()): \(error.localizedDescription)"
                saving = false
            }
        }
    }
}

/// A picture from a URL that fills the space it's given.
struct RemoteArtwork: View {
    let url: URL?
    var symbol = "film"

    var body: some View {
        Color.clear
            .overlay {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        ZStack {
                            LinearGradient(colors: [Color(white: 0.22), Color(white: 0.12)], startPoint: .top, endPoint: .bottom)
                            if phase.error != nil || url == nil {
                                Image(systemName: symbol)
                                    .font(.system(size: 22, weight: .light))
                                    .foregroundStyle(.white.opacity(0.45))
                            } else {
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                }
            }
            .clipped()
            // A picture wider than its frame mustn't catch clicks meant for the card next to it.
            .contentShape(Rectangle())
    }
}

/// A show's episodes in the film window: what's there, season by season.
private struct EpisodeList: View {
    let episodes: [Item]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Episodes").font(.headline)
            if episodes.isEmpty {
                Text("Looking for episodes…").font(.callout).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(episodes) { episode in
                            HStack(spacing: 8) {
                                Text(episode.episodeLabel ?? "").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                                    .frame(width: 56, alignment: .leading)
                                Text(episode.title).font(.callout).lineLimit(1)
                                Spacer()
                                if let runtime = episode.runtimeText {
                                    Text(runtime).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 120)
            }
        }
    }
}

// MARK: - Extras shows

extension ServerManager {
    /// "The office Extras" (a torrent's bonus material) isn't in any database, so it has no pictures: it borrows its
    /// show's poster and backdrop. Only fills in what's missing, so a picture he chooses himself stays.
    func dressExtrasShows() async {
        let shows = libraries[.shows] ?? []
        for extras in shows where extras.title.hasSuffix(" Extras") {
            let baseName = String(extras.title.dropLast(" Extras".count))
            guard let base = shows.first(where: { $0.title.caseInsensitiveCompare(baseName) == .orderedSame && $0.id != extras.id })
            else { continue }
            var changed = false
            if extras.imageTags?["Primary"] == nil, let tag = base.imageTags?["Primary"] {
                changed = await copyImage(from: base, to: extras, type: "Primary", tag: tag) || changed
            }
            if (extras.backdropImageTags ?? []).isEmpty, let tag = base.backdropImageTags?.first {
                changed = await copyImage(from: base, to: extras, type: "Backdrop", tag: tag) || changed
            }
            if changed { await refreshLibraries() }
        }
    }

    private func copyImage(from base: Item, to extras: Item, type: String, tag: String) async -> Bool {
        let source = client.url("/Items/\(base.id)/Images/\(type)\(type == "Backdrop" ? "/0" : "")",
                                [.init("tag", tag), .init("format", "Jpg"), .init("quality", "92")], withKey: true)
        guard let (data, response) = try? await URLSession.shared.data(from: source),
              (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { return false }
        let path = "/Items/\(extras.id)/Images/\(type)"
        do {
            try await client.send("POST", path, body: data, contentType: "image/jpeg")
        } catch {
            guard (try? await client.send("POST", path, body: data.base64EncodedData(), contentType: "image/jpeg")) != nil else { return false }
        }
        return true
    }
}

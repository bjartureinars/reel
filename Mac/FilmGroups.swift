import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Versions

/// The film's versions: which one Play uses, their names, adding and separating them.
struct VersionsPane: View {
    @ObservedObject var server: ServerManager
    @ObservedObject var cloud: CloudStore
    let item: Item
    /// The film in Reel's catalog. Its place on the disk changes when it's grouped; this doesn't.
    let filmID: UInt64?
    @State private var adding = false
    @State private var problem: String?

    private var film: CloudFilm? { filmID.flatMap { cloud.film($0) } }
    private var root: CloudFilm? { film.map { cloud.groupRoot($0) ?? $0 } }
    private var versions: [CloudFilm] { root.map { cloud.versions(of: $0.id) } ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Play uses the default version. The others are under Versions on your Apple TV, iPhone and iPad, and the film is listed once, with this poster.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if root == nil {
                Text("Versions are for films in Google Drive.").foregroundStyle(.secondary)
            } else {
                List {
                    ForEach(versions) { version in
                        VersionRow(cloud: cloud, film: version, isDefault: version.versionOf == nil, isOnly: versions.count == 1)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .frame(minHeight: 150)
                if let problem { Text(problem).font(.callout).foregroundStyle(.red) }
                HStack {
                    Button("Add Version…") { adding = true }
                    Spacer()
                }
            }
        }
        .sheet(isPresented: $adding) {
            if let root {
                LibraryFilmPicker(cloud: cloud, title: "Add a Version", excluding: root.id,
                                  prompt: "Choose the film that is another version of “\(item.title)”. It’s then listed only here.",
                                  action: "Add Version", labelField: true) { chosen, label in
                    do {
                        try cloud.addVersion(chosen.id, to: root.id, label: label, groupFolder: groupFolder(item),
                                             rootLabel: VersionGuess.label(for: root.name))
                        server.carryWatchState(from: item, to: root.id)
                        problem = nil
                    } catch {
                        problem = error.localizedDescription
                    }
                }
            }
        }
    }
}

private struct VersionRow: View {
    @ObservedObject var cloud: CloudStore
    let film: CloudFilm
    let isDefault: Bool
    let isOnly: Bool
    @State private var label = ""

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isDefault ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isDefault ? Color.accentColor : .secondary)
                .accessibilityLabel(isDefault ? "Default version" : "Other version")
            VStack(alignment: .leading, spacing: 2) {
                TextField("Name", text: $label)
                    .textFieldStyle(.plain)
                    .font(.headline)
                    .onSubmit { cloud.renameVersion(film.id, label: label) }
                    .accessibilityLabel("Version name")
                Text("\(film.name) · \(film.size.formatted(.byteCount(style: .file)))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if isDefault {
                Text("Default").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            } else {
                Button("Make Default") { cloud.makeDefault(film.id) }
            }
            if !isOnly {
                Button("Separate") { cloud.separate(film.id) }
                    .help("Take this version out: it becomes a film of its own in the library again")
            }
        }
        .padding(.vertical, 4)
        .onAppear { label = film.versionLabel ?? VersionGuess.label(for: film.name) }
        .onChange(of: film.versionLabel) { _, new in label = new ?? label }
    }
}

// MARK: - Extras

/// Trailers, behind the scenes and other bonus material of the film.
struct ExtrasPane: View {
    @ObservedObject var server: ServerManager
    @ObservedObject var cloud: CloudStore
    let item: Item
    let filmID: UInt64?
    @State private var fromLibrary = false
    @State private var problem: String?
    @State private var adding = 0

    private var film: CloudFilm? { filmID.flatMap { cloud.film($0) } }
    private var root: CloudFilm? { film.map { cloud.groupRoot($0) ?? $0 } }
    private var extras: [CloudFilm] { root.map { cloud.extras(of: $0.id) } ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Extras appear under Extras on your Apple TV, iPhone and iPad. Files from this Mac are copied to Google Drive; your originals stay where they are.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if root == nil {
                Text("Extras are for films in Google Drive.").foregroundStyle(.secondary)
            } else {
                if extras.isEmpty && adding == 0 {
                    VStack(spacing: 6) {
                        Image(systemName: "sparkles.tv").font(.largeTitle).foregroundStyle(.secondary)
                        Text("No extras yet").font(.headline)
                        Text("Add a trailer, behind-the-scenes footage, deleted scenes or interviews.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 150)
                } else {
                    List {
                        ForEach(extras) { ExtraRow(server: server, cloud: cloud, film: $0) }
                        if adding > 0 {
                            HStack { ProgressView().controlSize(.small); Text("Copying \(adding == 1 ? "1 file" : "\(adding) files")…") }
                        }
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
                    .frame(minHeight: 150)
                }
                if let problem { Text(problem).font(.callout).foregroundStyle(.red) }
                HStack {
                    Button("Add from This Mac…") { chooseFiles() }
                    Button("Add from Library…") { fromLibrary = true }
                        .help("Make a film already in your library an extra of this one")
                    Spacer()
                }
            }
        }
        .sheet(isPresented: $fromLibrary) {
            if let root {
                LibraryFilmPicker(cloud: cloud, title: "Add an Extra", excluding: root.id,
                                  prompt: "Choose the video that is an extra of “\(item.title)”. It’s then listed only here.",
                                  action: "Add Extra", labelField: false) { chosen, _ in
                    do {
                        let title = (chosen.name as NSString).deletingPathExtension
                        try cloud.makeExtra(chosen.id, of: root.id, kind: ExtraGuess.kind(for: chosen.name),
                                            title: ExtraGuess.title(for: title), groupFolder: groupFolder(item))
                        server.carryWatchState(from: item, to: root.id)
                        problem = nil
                    } catch {
                        problem = error.localizedDescription
                    }
                }
            }
        }
    }

    private func chooseFiles() {
        guard let root else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.prompt = "Add Extras"
        panel.message = "Choose trailers, behind-the-scenes footage or other bonus videos for “\(item.title)”."
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        adding += urls.count
        let first = extras.isEmpty
        Task {
            for url in urls {
                let name = url.deletingPathExtension().lastPathComponent
                do {
                    try await cloud.addExtra(from: url, to: root.id, kind: ExtraGuess.kind(for: name),
                                             title: ExtraGuess.title(for: name), groupFolder: groupFolder(item))
                } catch {
                    problem = "“\(url.lastPathComponent)”: \(error.localizedDescription)"
                }
                adding -= 1
            }
            if first { server.carryWatchState(from: item, to: root.id) }
        }
    }
}

private struct ExtraRow: View {
    @ObservedObject var server: ServerManager
    @ObservedObject var cloud: CloudStore
    let film: CloudFilm
    @State private var title = ""
    @State private var confirmDelete = false
    @State private var problem: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.title3).foregroundStyle(.secondary).frame(width: 24).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                TextField("Title", text: $title)
                    .textFieldStyle(.plain)
                    .font(.headline)
                    .onSubmit { cloud.editExtra(film.id, kind: film.extraKind ?? .other, title: title) }
                    .accessibilityLabel("Extra title")
                Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Picker("Kind", selection: Binding(get: { film.extraKind ?? .other },
                                              set: { cloud.editExtra(film.id, kind: $0, title: title) })) {
                ForEach(ExtraKind.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: 170)
            Menu {
                Button("Move to Films") { cloud.separate(film.id) }
                Divider()
                Button("Delete from Google Drive…", role: .destructive) { confirmDelete = true }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
            .accessibilityLabel("More")
        }
        .padding(.vertical, 4)
        .onAppear { title = film.extraTitle ?? (film.name as NSString).deletingPathExtension }
        .alert("Delete “\(title)” from Google Drive?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                Task {
                    do {
                        try await cloud.remove(film.id)
                    } catch {
                        logFailure("Deleting an extra", error)
                        problem = error.localizedDescription
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It goes to Drive’s Bin, where it can be restored for 30 days.")
        }
        .alert("Couldn’t Delete “\(title)”", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
    }

    private var status: String {
        let size = film.size.formatted(.byteCount(style: .file))
        return film.verified ? "\(size) · In Google Drive" : "\(size) · \(cloud.status(film).detail)"
    }

    private var symbol: String {
        switch film.extraKind ?? .other {
        case .trailer: return "film"
        case .behindTheScenes: return "video"
        case .featurette: return "star"
        case .deletedScene: return "scissors"
        case .interview: return "person.2"
        case .short: return "film.stack"
        case .other: return "sparkles"
        }
    }
}

// MARK: - Choosing a film from the library

private struct LibraryFilmPicker: View {
    @ObservedObject var cloud: CloudStore
    let title: String
    let excluding: UInt64
    let prompt: String
    let action: String
    let labelField: Bool
    let done: (CloudFilm, String) -> Void
    @State private var search = ""
    @State private var chosen: UInt64?
    @State private var label = ""
    @Environment(\.dismiss) private var dismiss

    private var candidates: [CloudFilm] {
        cloud.films.filter { film in
            film.folder == "Films" && film.id != excluding && film.versionOf == nil && film.extraOf == nil
                && (search.isEmpty || film.name.localizedCaseInsensitiveContains(search))
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title2.weight(.bold))
            Text(prompt).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Search", text: $search).textFieldStyle(.roundedBorder)
            List(candidates, selection: $chosen) { film in
                VStack(alignment: .leading, spacing: 2) {
                    Text(film.name).lineLimit(1).truncationMode(.middle)
                    Text(film.size.formatted(.byteCount(style: .file))).font(.caption).foregroundStyle(.secondary)
                }
                .tag(film.id)
            }
            .frame(minHeight: 220)
            if labelField {
                TextField("Version name, like 4K or Blu-ray", text: $label).textFieldStyle(.roundedBorder)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(action) {
                    if let id = chosen, let film = cloud.film(id) {
                        done(film, label.isEmpty ? VersionGuess.label(for: film.name) : label)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen == nil)
            }
        }
        .padding(24)
        .frame(width: 560, height: 520)
        // A search that leaves one film chooses it.
        .onChange(of: search) { _, _ in if candidates.count == 1 { chosen = candidates[0].id } }
        .onChange(of: chosen) { _, id in
            if labelField, let id, let film = cloud.film(id) { label = VersionGuess.label(for: film.name) }
        }
    }
}

// MARK: - Guesses from file names

/// "…2160p…" is the 4K version, "…BluRay.1080p…" the Blu-ray, and so on. Only a starting point; he can rename it.
enum VersionGuess {
    static func label(for name: String) -> String {
        let n = name.lowercased()
        var parts: [String] = []
        if n.contains("2160p") || n.contains("4k") || n.contains("uhd") { parts.append("4K") }
        else if n.contains("1080p") || n.contains("bluray") || n.contains("blu-ray") || n.contains("bdremux") { parts.append("Blu-ray") }
        else if n.contains("720p") { parts.append("HD") }
        else if n.contains("dvd") { parts.append("DVD") }
        if n.contains("extended") { parts.append("Extended") }
        if n.contains("director") { parts.append("Director’s Cut") }
        if n.contains("imax") { parts.append("IMAX") }
        if n.contains(".dv.") || n.contains("dolby vision") { parts.append("Dolby Vision") }
        return parts.isEmpty ? "Original" : parts.joined(separator: " ")
    }
}

enum ExtraGuess {
    static func kind(for name: String) -> ExtraKind {
        let n = name.lowercased()
        if n.contains("trailer") || n.contains("teaser") { return .trailer }
        if n.contains("behind") || n.contains("making") { return .behindTheScenes }
        if n.contains("deleted") { return .deletedScene }
        if n.contains("interview") { return .interview }
        if n.contains("featurette") { return .featurette }
        return .other
    }

    /// "the.making.of_lotr" → "The Making Of Lotr" is too much; dots and underscores become spaces and that's it.
    static func title(for name: String) -> String {
        name.replacingOccurrences(of: "[._]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }
}

/// The group's folder name for Jellyfin: "Title (Year)", so it identifies the film right.
func groupFolder(_ item: Item) -> String {
    item.productionYear.map { "\(item.title) (\($0))" } ?? item.title
}

// MARK: - Keeping watch progress when a film moves into its folder

extension ServerManager {
    /// Grouping moves the film on the cloud disk, and Jellyfin sees a new film there. Where you'd got to, watched and
    /// My List are copied over once the library has been scanned.
    func carryWatchState(from item: Item, to rootID: UInt64) {
        guard let data = item.userData,
              (data.playbackPositionTicks ?? 0) > 0 || data.played == true || data.isFavorite == true else { return }
        pendingWatchStates[rootID] = data
    }

    func applyPendingWatchStates() async {
        guard !pendingWatchStates.isEmpty, let userId = currentUserId else { return }
        for (rootID, data) in pendingWatchStates {
            guard let root = cloud.film(rootID) else { pendingWatchStates[rootID] = nil; continue }
            let folder = cloud.paths.mount.appendingPathComponent(cloud.place(root).folder).path
            guard let target = (libraries[.films] ?? []).first(where: {
                ($0.path.map { ($0 as NSString).deletingLastPathComponent } ?? "") == folder
            }) else { continue }
            var body: [String: Any] = ["Played": data.played ?? false, "IsFavorite": data.isFavorite ?? false]
            if let ticks = data.playbackPositionTicks { body["PlaybackPositionTicks"] = ticks }
            if (try? await client.send("POST", "/UserItems/\(target.id)/UserData", query: [.init("userId", userId)], json: body)) != nil {
                pendingWatchStates[rootID] = nil
            }
        }
    }
}

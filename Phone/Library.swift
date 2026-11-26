import Foundation
import SwiftUI

/// A film in Google Drive that Reel Server has checked and described.
struct Film: Identifiable, Hashable, Codable {
    let id: String
    let folder: String
    let fileName: String
    let size: Int64
    /// Drive files making up the original, with their MD5s.
    let pieces: [Piece]
    var info: FilmInfo?
    var addedAt: Date

    struct Piece: Hashable, Codable {
        let id: String
        let offset: Int64
        let size: Int64
        let md5: String?
    }

    static func == (a: Film, b: Film) -> Bool { a.id == b.id && a.info == b.info && a.pieces == b.pieces }
    func hash(into h: inout Hasher) { h.combine(id) }

    var remote: RemoteFile { RemoteFile(pieces: pieces.map { .init(id: $0.id, offset: $0.offset, size: $0.size) }) }
    var isHomeVideo: Bool { folder == "Home Videos" }
    var episode: EpisodeRef? { info?.episode }
    var isEpisode: Bool { episode != nil }
    /// Another version of a film, or bonus material: reached from the film's page, not listed on its own.
    var isListedElsewhere: Bool { info?.extra != nil || info?.filmVersion.map { !$0.isDefault } == true }
    /// The film this one's versions and extras hang off (its default version).
    var groupID: String { info?.filmVersion?.rootID ?? info?.extra?.rootID ?? id }

    /// "S1 E3", for an episode.
    var episodeLabel: String? { episode.map { "S\($0.season) E\($0.number)" } }

    /// The name to show where the film or episode stands alone: "Friends · S1 E1 · Pilot".
    var fullTitle: String {
        guard let episode, let label = episodeLabel else { return title }
        return "\(episode.show) · \(label) · \(title)"
    }

    var title: String {
        if let title = info?.extra?.title { return title }
        if let title = info?.title { return title }
        let base = (fileName as NSString).deletingPathExtension
        return base.replacingOccurrences(of: #"[._]"#, with: " ", options: .regularExpression)
    }

    var sortTitle: String { info?.sortTitle ?? title }
    var seconds: Double? { info?.seconds }
    var isHDR: Bool { (info?.hdr ?? "").contains("HDR") || (info?.hdr ?? "").hasPrefix("DOVI") || info?.hdr == "HLG" }
    var isUHD: Bool { (info?.width ?? 0) >= 3200 }

    var badges: [String] {
        var out: [String] = []
        if isUHD { out.append("4K") } else if (info?.width ?? 0) >= 1900 { out.append("HD") }
        switch info?.hdr ?? "" {
        case let r where r.hasPrefix("DOVI"): out.append("Dolby Vision")
        case "HDR10Plus": out.append("HDR10+")
        case "HDR10": out.append("HDR10")
        case "HLG": out.append("HLG")
        default: break
        }
        let sound = (info?.sound ?? "").lowercased()
        if sound.contains("atmos") { out.append("Dolby Atmos") }
        else if sound.contains("7.1") { out.append("7.1") }
        else if sound.contains("5.1") { out.append("5.1") }
        return out
    }

    var metaLine: String {
        [info?.year.map(String.init), info?.rating, seconds?.runtimeText].compactMap { $0 }.joined(separator: " · ")
    }

    func estimatedSize(_ quality: CopyQuality) -> Int64 {
        quality == .original ? size : quality.estimatedSize(seconds: seconds ?? 7200, hdr: isHDR, uhd: isUHD)
    }

    /// An episode uses its show's poster; its own picture is a still, in `backdropURL`.
    var posterURL: URL {
        if let episode { return Show.posterURL(episode.showID) }
        return Folders.artwork.appendingPathComponent("\(id)-poster.jpg")
    }
    var backdropURL: URL { Folders.artwork.appendingPathComponent("\(id)-backdrop.jpg") }
}

/// A TV show's details, without its pictures (those are files on the phone).
struct ShowDetails: Codable, Equatable {
    let showID: String
    let title: String
    let sortTitle: String?
    let year: Int?
    let rating: String?
    let overview: String?
    let genres: [String]
    let people: [FilmInfo.Person]
    let studio: String?

    init(_ info: ShowInfo) {
        showID = info.showID; title = info.title; sortTitle = info.sortTitle; year = info.year; rating = info.rating
        overview = info.overview; genres = info.genres; people = info.people; studio = info.studio
    }
}

/// A TV show with the episodes of it that are in Drive.
struct Show: Identifiable, Hashable {
    let id: String
    let details: ShowDetails?
    /// In order: season, then episode.
    let episodes: [Film]

    static func == (a: Show, b: Show) -> Bool { a.id == b.id && a.details == b.details && a.episodes == b.episodes }
    func hash(into h: inout Hasher) { h.combine(id) }

    var title: String { details?.title ?? episodes.first?.episode?.show ?? "TV Show" }
    var sortTitle: String { details?.sortTitle ?? title }
    var seasons: [Int] { Array(Set(episodes.compactMap { $0.episode?.season })).sorted() }
    func episodes(in season: Int) -> [Film] { episodes.filter { $0.episode?.season == season } }
    var addedAt: Date { episodes.map(\.addedAt).max() ?? .distantPast }

    var metaLine: String {
        let seasons = seasons.count
        return [details?.year.map(String.init), details?.rating, seasons == 1 ? "1 Season" : "\(seasons) Seasons"]
            .compactMap { $0 }.joined(separator: " · ")
    }

    static func posterURL(_ id: String) -> URL { Folders.artwork.appendingPathComponent("show-\(id)-poster.jpg") }
    static func backdropURL(_ id: String) -> URL { Folders.artwork.appendingPathComponent("show-\(id)-backdrop.jpg") }
    var posterURL: URL { Self.posterURL(id) }
    var backdropURL: URL { Self.backdropURL(id) }
}

/// A smaller copy in Drive, or the phone's request for one.
struct CopyFile: Hashable, Codable {
    let driveID: String
    let size: Int64
    let md5: String?
}

struct CopyRequest: Hashable {
    let driveID: String
    let filmID: String
    let quality: CopyQuality
    let progress: CopyProgress

    static func == (a: CopyRequest, b: CopyRequest) -> Bool { a.driveID == b.driveID && a.progress == b.progress }
    func hash(into h: inout Hasher) { h.combine(driveID) }
}

/// Everything Reel shows, from Google Drive, kept on the phone so it works offline.
@MainActor
final class Library: ObservableObject {
    @Published private(set) var films: [Film] = Store.load("films.json") ?? []
    @Published private(set) var showDetails: [String: ShowDetails] = Store.load("shows.json") ?? [:]
    @Published private(set) var copies: [String: [CopyQuality: CopyFile]] = Store.load("copies.json") ?? [:]
    @Published private(set) var requests: [String: [CopyQuality: CopyRequest]] = [:]
    @Published private(set) var watching: [String: WatchState] = [:]
    @Published private(set) var loading = false
    @Published var problem: String?
    @Published private(set) var lastRefresh: Date?

    let drive: DriveClient
    private var watchFiles: [String: String] = [:]
    private var pendingWatch: Set<String> = Store.load("watch-pending.json") ?? []
    private var refreshing: Task<Void, Never>?

    init(tokens: TokenSource) {
        drive = DriveClient(token: { rejected in try await tokens.token(rejected: rejected) })
        let saved: [String: StoredWatch] = Store.load("watching.json") ?? [:]
        watching = saved.mapValues(\.state)
    }

    func film(_ id: String) -> Film? { films.first { $0.id == id } }

    var movies: [Film] { films.filter { !$0.isHomeVideo && !$0.isEpisode && !$0.isListedElsewhere } }

    /// The default version first, then the others by name. Empty for a film with one version.
    func versions(of film: Film) -> [Film] {
        let group = films.filter { $0.info?.filmVersion?.rootID == film.groupID }
        guard group.count > 1 else { return [] }
        return group.sorted {
            let a = $0.info?.filmVersion, b = $1.info?.filmVersion
            return a?.isDefault != b?.isDefault ? a?.isDefault == true
                : (a?.label ?? "").localizedStandardCompare(b?.label ?? "") == .orderedAscending
        }
    }

    func extras(of film: Film) -> [Film] {
        films.filter { $0.info?.extra?.rootID == film.groupID }
            .sorted { ($0.info?.extra?.kind ?? .other, $0.title) < ($1.info?.extra?.kind ?? .other, $1.title) }
    }

    /// Every show with an episode in Drive, newest first.
    var shows: [Show] {
        Dictionary(grouping: films.filter(\.isEpisode)) { $0.episode?.showID ?? "" }
            .map { id, episodes in
                Show(id: id, details: showDetails[id], episodes: episodes.sorted {
                    ($0.episode?.season ?? 0, $0.episode?.number ?? 0) < ($1.episode?.season ?? 0, $1.episode?.number ?? 0)
                })
            }
            .sorted { $0.addedAt > $1.addedAt }
    }

    func show(_ id: String) -> Show? { shows.first { $0.id == id } }

    /// What to play next: the episode you're in the middle of, else the one after the last you finished,
    /// else the first.
    func nextEpisode(of show: Show) -> Film? {
        if let started = show.episodes.filter({ resumeSeconds($0) > 0 }).max(by: { state($0).updated < state($1).updated }) {
            return started
        }
        if let last = show.episodes.lastIndex(where: { state($0).watched }) {
            return show.episodes.indices.contains(last + 1) ? show.episodes[last + 1] : nil
        }
        return show.episodes.first
    }

    /// The episode after this one, in the same show.
    func episode(after film: Film) -> Film? {
        guard let id = film.episode?.showID, let show = show(id),
              let index = show.episodes.firstIndex(where: { $0.id == film.id }), index + 1 < show.episodes.count else { return nil }
        return show.episodes[index + 1]
    }

    /// The next episode of each show you've watched some of, apart from ones in Continue Watching.
    var nextUp: [Film] {
        shows.filter { $0.episodes.contains { state($0).watched } }
            .compactMap { nextEpisode(of: $0) }
            .filter { resumeSeconds($0) == 0 && !state($0).watched }
    }

    // MARK: Refreshing

    func refresh() async {
        if let refreshing { return await refreshing.value }
        let task = Task { await load() }
        refreshing = task
        await task.value
        refreshing = nil
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let files = try await drive.everything()
            try await apply(files)
            await pushWatching()
            problem = nil
            lastRefresh = Date()
        } catch is CancellationError {
        } catch let error as URLError where [.notConnectedToInternet, .networkConnectionLost, .timedOut].contains(error.code) {
            problem = "You’re offline. Downloaded films still play."
        } catch {
            problem = error.localizedDescription
        }
    }

    private func apply(_ files: [DriveFile]) async throws {
        var byKind: [String: [DriveFile]] = [:]
        for file in files { byKind[file.appProperties?[PhoneDrive.kind] ?? "", default: []].append(file) }

        // Films whose details Reel Server has published are the ones it has verified.
        let infos = Dictionary((byKind[PhoneDrive.info] ?? []).compactMap { f in f.appProperties?["id"].map { ($0, f) } },
                               uniquingKeysWith: { a, _ in a })
        var found: [Film] = []
        for file in byKind[PhoneDrive.film] ?? [] {
            guard let id = file.appProperties?["id"], infos[id] != nil, let size = file.byteCount, let name = file.name else { continue }
            found.append(Film(id: id, folder: file.appProperties?["folder"] ?? "Films", fileName: name, size: size,
                              pieces: [.init(id: file.id, offset: 0, size: size, md5: file.md5Checksum)], info: nil,
                              addedAt: Self.added(file)))
        }
        for film in Self.filmsInPieces(byKind[PhoneDrive.part] ?? []) where infos[film.id] != nil && !found.contains(where: { $0.id == film.id }) {
            found.append(film)
        }

        let old = Dictionary(films.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // Details that changed (or are new) are fetched 8 at a time: one by one, a first load of a big library took minutes.
        var stale: [(index: Int, driveID: String)] = []
        for index in found.indices {
            let id = found[index].id
            guard let file = infos[id] else { continue }
            let revision = file.appProperties?["rev"] ?? file.md5Checksum ?? ""
            if let previous = old[id]?.info, UserDefaults.standard.string(forKey: Self.revisionKey(id)) == revision {
                found[index].info = previous
            } else {
                stale.append((index, file.id))
            }
        }
        var fetched: [Int: Data] = [:]
        let drive = self.drive
        await withTaskGroup(of: (Int, Data?).self) { group in
            var next = 0
            func add() {
                guard next < stale.count else { return }
                let item = stale[next]
                next += 1
                group.addTask { (item.index, try? await drive.contents(item.driveID)) }
            }
            for _ in 0..<8 { add() }
            while let (index, data) = await group.next() {
                if let data { fetched[index] = data }
                add()
            }
        }
        for (index, _) in stale {
            let id = found[index].id
            let revision = infos[id].map { $0.appProperties?["rev"] ?? $0.md5Checksum ?? "" } ?? ""
            if let data = fetched[index], var info = try? JSONDecoder().decode(FilmInfo.self, from: data) {
                if let poster = info.poster { try? poster.write(to: found[index].posterURL, options: .atomic) }
                if let backdrop = info.backdrop { try? backdrop.write(to: found[index].backdropURL, options: .atomic) }
                // Everything else is kept as it came, so fields added later (like an episode's show) survive.
                info.poster = nil
                info.backdrop = nil
                found[index].info = info
                UserDefaults.standard.set(revision, forKey: Self.revisionKey(id))
            } else {
                found[index].info = old[id]?.info
            }
        }
        films = found.sorted { $0.addedAt > $1.addedAt }
        Store.save(films, as: "films.json")

        // Shows' details and pictures, rewritten only when Reel Server changes them.
        var newShows: [String: ShowDetails] = [:]
        for file in byKind[PhoneDrive.show] ?? [] {
            guard let id = file.appProperties?["id"] else { continue }
            let revision = file.appProperties?["rev"] ?? file.md5Checksum ?? ""
            if let previous = showDetails[id], UserDefaults.standard.string(forKey: "show.rev.\(id)") == revision {
                newShows[id] = previous
                continue
            }
            if let data = try? await drive.contents(file.id), let info = try? JSONDecoder().decode(ShowInfo.self, from: data) {
                if let poster = info.poster { try? poster.write(to: Show.posterURL(id), options: .atomic) }
                if let backdrop = info.backdrop { try? backdrop.write(to: Show.backdropURL(id), options: .atomic) }
                newShows[id] = ShowDetails(info)
                UserDefaults.standard.set(revision, forKey: "show.rev.\(id)")
            } else {
                newShows[id] = showDetails[id]
            }
        }
        showDetails = newShows
        Store.save(showDetails, as: "shows.json")

        var newCopies: [String: [CopyQuality: CopyFile]] = [:]
        for file in byKind[PhoneDrive.copy] ?? [] {
            guard let id = file.appProperties?["id"], let quality = file.appProperties?["quality"].flatMap(CopyQuality.init),
                  let size = file.byteCount else { continue }
            newCopies[id, default: [:]][quality] = CopyFile(driveID: file.id, size: size, md5: file.md5Checksum)
        }
        copies = newCopies
        Store.save(copies, as: "copies.json")

        var newRequests: [String: [CopyQuality: CopyRequest]] = [:]
        for file in byKind[PhoneDrive.request] ?? [] {
            guard let properties = file.appProperties, let id = properties["id"],
                  let quality = properties["quality"].flatMap(CopyQuality.init) else { continue }
            newRequests[id, default: [:]][quality] = CopyRequest(driveID: file.id, filmID: id, quality: quality,
                                                                 progress: CopyProgress(properties: properties))
        }
        requests = newRequests

        for file in byKind[PhoneDrive.watch] ?? [] {
            guard let id = file.appProperties?["id"], let remote = file.appProperties.flatMap(WatchState.init(properties:)) else { continue }
            watchFiles[id] = file.id
            if pendingWatch.contains(id) { continue }
            if remote.updated > (watching[id]?.updated ?? .distantPast) { watching[id] = remote }
        }
        saveWatching()
    }

    /// "2": details saved before episodes kept their show are read again once.
    private static func revisionKey(_ id: String) -> String { "info.rev2.\(id)" }

    private static func added(_ file: DriveFile) -> Date {
        if let text = file.appProperties?["modified"], let seconds = Double(text) { return Date(timeIntervalSince1970: seconds) }
        return file.modifiedTime.flatMap { ISO8601DateFormatter.drive.date(from: $0) } ?? .distantPast
    }

    /// A film uploaded in pieces, if every piece is there exactly once.
    static func filmsInPieces(_ files: [DriveFile]) -> [Film] {
        Dictionary(grouping: files) { $0.appProperties?["set"] ?? "" }.compactMap { set, files -> Film? in
            guard !set.isEmpty, let first = files.first?.appProperties, let id = first["id"],
                  let total = first["total"].flatMap(Int64.init), let count = first["count"].flatMap(Int.init),
                  count == files.count, let name = files[0].name,
                  let suffix = name.range(of: ".part", options: .backwards) else { return nil }
            let pieces = files.compactMap { file -> Film.Piece? in
                guard let offset = file.appProperties?["offset"].flatMap(Int64.init), let size = file.byteCount else { return nil }
                return .init(id: file.id, offset: offset, size: size, md5: file.md5Checksum)
            }.sorted { $0.offset < $1.offset }
            let remote = RemoteFile(pieces: pieces.map { .init(id: $0.id, offset: $0.offset, size: $0.size) })
            guard pieces.count == count, remote.covers(total) else { return nil }
            return Film(id: id, folder: first["folder"] ?? "Films", fileName: String(name[..<suffix.lowerBound]),
                        size: total, pieces: pieces, info: nil, addedAt: added(files[0]))
        }
    }

    // MARK: Watching

    private struct StoredWatch: Codable {
        let position: Double, watched: Bool, favorite: Bool, updated: Date
        var state: WatchState { WatchState(position: position, watched: watched, favorite: favorite, updated: updated) }
        init(_ s: WatchState) { position = s.position; watched = s.watched; favorite = s.favorite; updated = s.updated }
    }

    private func saveWatching() {
        Store.save(watching.mapValues(StoredWatch.init), as: "watching.json")
        Store.save(pendingWatch, as: "watch-pending.json")
    }

    func state(_ film: Film) -> WatchState { watching[film.id] ?? .empty }

    func resumeSeconds(_ film: Film) -> Double {
        let state = state(film)
        guard !state.watched, state.position > 30 else { return 0 }
        if let total = film.seconds, state.position > total - 120 { return 0 }
        return state.position
    }

    func progress(_ film: Film) -> Double? {
        let at = resumeSeconds(film)
        guard at > 0, let total = film.seconds, total > 0 else { return nil }
        return min(at / total, 1)
    }

    func update(_ film: Film, push: Bool = true, _ change: (inout WatchState) -> Void) {
        var state = state(film)
        change(&state)
        state.updated = Date()
        watching[film.id] = state
        pendingWatch.insert(film.id)
        saveWatching()
        if push { Task { await pushWatching() } }
    }

    /// Records where playback got to. Near the end counts as watched.
    func played(_ film: Film, at seconds: Double, duration: Double, push: Bool) {
        update(film, push: push) { state in
            if duration > 0, seconds > duration - max(120, duration * 0.04) {
                state.watched = true
                state.position = 0
            } else {
                state.position = seconds
                if seconds > 30 { state.watched = false }
            }
        }
    }

    func pushWatching() async {
        for id in pendingWatch {
            guard let state = watching[id] else { continue }
            do {
                if let file = watchFiles[id] {
                    try await drive.update(file, properties: state.properties(filmID: id))
                } else {
                    let file = try await drive.create(name: "Reel watch \(id)", parent: try await reelFolder(),
                                                      properties: state.properties(filmID: id), data: Data(), type: "text/plain")
                    watchFiles[id] = file.id
                }
                if watching[id] == state { pendingWatch.remove(id) }
            } catch {
                break
            }
        }
        saveWatching()
    }

    private var folderID: String?

    func reelFolder() async throws -> String {
        if let folderID { return folderID }
        let found = try await drive.folder()
        folderID = found
        return found
    }

    // MARK: Lists for the screens

    var continueWatching: [Film] {
        films.filter { resumeSeconds($0) > 0 }.sorted { state($0).updated > state($1).updated }
    }

    var myList: [Film] { films.filter { state($0).favorite } }

    func search(_ text: String) -> [Film] {
        let words = text.lowercased().split(separator: " ")
        guard !words.isEmpty else { return [] }
        return films.filter { film in
            guard !film.isEpisode, !film.isListedElsewhere else { return false }   // shows are found by searchShows
            let haystack = ([film.title, film.info?.overview ?? "", film.info?.studio ?? "", film.info?.year.map(String.init) ?? ""]
                + (film.info?.genres ?? []) + (film.info?.people.map(\.name) ?? [])).joined(separator: " ").lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    /// Films that share the most genres with this one, then the nearest in year.
    func similar(to film: Film, limit: Int = 12) -> [Film] {
        let genres = Set(film.info?.genres ?? [])
        guard !genres.isEmpty else { return [] }
        let year = film.info?.year ?? 0
        struct Scored { let film: Film; let shared: Int; let distance: Int }
        var scored: [Scored] = []
        for other in movies where other.id != film.id {
            let shared = Set(other.info?.genres ?? []).intersection(genres).count
            if shared > 0 { scored.append(Scored(film: other, shared: shared, distance: abs((other.info?.year ?? 0) - year))) }
        }
        scored.sort { $0.shared != $1.shared ? $0.shared > $1.shared : $0.distance < $1.distance }
        return scored.prefix(limit).map(\.film)
    }

    func similar(to show: Show, limit: Int = 12) -> [Show] {
        let genres = Set(show.details?.genres ?? [])
        guard !genres.isEmpty else { return [] }
        return shows.filter { $0.id != show.id }
            .map { ($0, Set($0.details?.genres ?? []).intersection(genres).count) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(limit).map(\.0)
    }

    /// Home's genre rows: the genres with enough films to fill a row, biggest first.
    var genreRows: [(genre: String, films: [Film])] {
        var byGenre: [String: [Film]] = [:]
        for film in movies {
            for genre in film.info?.genres ?? [] { byGenre[genre, default: []].append(film) }
        }
        var rows: [(genre: String, films: [Film])] = []
        for (genre, films) in byGenre where films.count >= 3 {
            rows.append((genre: genre, films: films.sorted { $0.addedAt > $1.addedAt }))
        }
        rows.sort { $0.films.count != $1.films.count ? $0.films.count > $1.films.count : $0.genre < $1.genre }
        return Array(rows.prefix(4))
    }

    func searchShows(_ text: String) -> [Show] {
        let words = text.lowercased().split(separator: " ")
        guard !words.isEmpty else { return [] }
        return shows.filter { show in
            let haystack = ([show.title, show.details?.overview ?? "", show.details?.studio ?? ""]
                + (show.details?.genres ?? []) + (show.details?.people.map(\.name) ?? [])).joined(separator: " ").lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    var genres: [String] {
        let all = movies.flatMap { $0.info?.genres ?? [] }
        return Array(Set(all)).sorted()
    }

    // MARK: Copies

    func requestCopy(_ film: Film, _ quality: CopyQuality) async throws {
        if requests[film.id]?[quality].map({ $0.progress.phase != .failed }) == true { return }
        if let old = requests[film.id]?[quality] { try? await drive.trash(old.driveID) }
        let properties = [PhoneDrive.kind: PhoneDrive.request, "id": film.id, "quality": quality.rawValue, "state": "waiting"]
        let file = try await drive.create(name: "Reel request \(film.title) (\(quality.title))", parent: try await reelFolder(),
                                          properties: properties, data: Data(), type: "text/plain")
        requests[film.id, default: [:]][quality] = CopyRequest(driveID: file.id, filmID: film.id, quality: quality,
                                                               progress: CopyProgress(phase: .waiting))
    }

    func cancelRequest(_ film: Film, _ quality: CopyQuality) async {
        guard let request = requests[film.id]?[quality] else { return }
        try? await drive.trash(request.driveID)
        requests[film.id]?[quality] = nil
    }

    func finishedRequest(_ film: Film, _ quality: CopyQuality) async {
        await cancelRequest(film, quality)
    }
}

extension ISO8601DateFormatter {
    static let drive: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

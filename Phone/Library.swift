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

    var title: String {
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

    var posterURL: URL { Folders.artwork.appendingPathComponent("\(id)-poster.jpg") }
    var backdropURL: URL { Folders.artwork.appendingPathComponent("\(id)-backdrop.jpg") }
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

    var movies: [Film] { films.filter { !$0.isHomeVideo } }
    var homeVideos: [Film] { films.filter(\.isHomeVideo) }

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
        for index in found.indices {
            let id = found[index].id
            guard let file = infos[id] else { continue }
            let revision = file.appProperties?["rev"] ?? file.md5Checksum ?? ""
            if let previous = old[id]?.info, UserDefaults.standard.string(forKey: "info.rev.\(id)") == revision {
                found[index].info = previous
                continue
            }
            if let data = try? await drive.contents(file.id), var info = try? JSONDecoder().decode(FilmInfo.self, from: data) {
                if let poster = info.poster { try? poster.write(to: found[index].posterURL, options: .atomic) }
                if let backdrop = info.backdrop { try? backdrop.write(to: found[index].backdropURL, options: .atomic) }
                info = FilmInfo(filmID: info.filmID, title: info.title, sortTitle: info.sortTitle, year: info.year,
                                rating: info.rating, seconds: info.seconds, overview: info.overview, tagline: info.tagline,
                                genres: info.genres, score: info.score, people: info.people, studio: info.studio,
                                hdr: info.hdr, width: info.width, sound: info.sound, languages: info.languages,
                                poster: nil, backdrop: nil)
                found[index].info = info
                UserDefaults.standard.set(revision, forKey: "info.rev.\(id)")
            } else {
                found[index].info = old[id]?.info
            }
        }
        films = found.sorted { $0.addedAt > $1.addedAt }
        Store.save(films, as: "films.json")

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
            let haystack = ([film.title, film.info?.overview ?? "", film.info?.studio ?? "", film.info?.year.map(String.init) ?? ""]
                + (film.info?.genres ?? []) + (film.info?.people.map(\.name) ?? [])).joined(separator: " ").lowercased()
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

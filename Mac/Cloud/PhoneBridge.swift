import CryptoKit
import Foundation
import os

/// Reel Server's half of Reel for iPhone. The phone streams from Google itself; through Drive, this keeps it
/// supplied with film details and artwork, makes the smaller copies it asks for, and keeps where you got to the
/// same on the phone and the Apple TV.
@MainActor
final class PhoneBridge: ObservableObject {
    struct Job: Equatable {
        let filmName: String
        let quality: CopyQuality
        var progress: CopyProgress
    }

    @Published private(set) var job: Job?
    @Published private(set) var lastProblem: String?

    private unowned let server: ServerManager
    private var loop: Task<Void, Never>?
    private var worker: Task<Void, Never>?
    private var workingOn: String?
    private var applied: [String: WatchState] = [:]
    private let log = Logger(subsystem: "com.bjartur.reel.server", category: "phone")

    private var cloud: CloudStore { server.cloud }
    private var drive: DriveClient { server.cloud.driveClient }

    init(server: ServerManager) {
        self.server = server
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                try? await Task.sleep(nanoseconds: 45_000_000_000)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        worker?.cancel()
        worker = nil
    }

    /// A film was removed from Reel: its details, copies, requests and viewing state go to Drive's Bin too.
    func forget(_ filmID: UInt64) async {
        guard let files = try? await drive.everything() else { return }
        for file in files where file.appProperties?["id"] == String(filmID)
            && [PhoneDrive.info, PhoneDrive.copy, PhoneDrive.request, PhoneDrive.watch].contains(file.appProperties?[PhoneDrive.kind] ?? "") {
            try? await drive.trash(file.id)
        }
    }

    // MARK: Each round

    private struct Item: Decodable {
        struct Person: Decodable { let name: String?; let role: String?; let type: String? }
        struct Studio: Decodable { let name: String? }
        struct Data: Decodable {
            let playbackPositionTicks: Int64?
            let played: Bool?
            let isFavorite: Bool?
            let lastPlayedDate: String?
        }

        struct Source: Decodable {
            let id: String?
            let path: String?
            let mediaStreams: [MediaStream]?
        }

        var id: String
        let type: String?
        var name: String?
        let sortName: String?
        let seriesName: String?
        let seriesId: String?
        let indexNumber: Int?
        let parentIndexNumber: Int?
        let productionYear: Int?
        let officialRating: String?
        let runTimeTicks: Int64?
        let overview: String?
        let taglines: [String]?
        let genres: [String]?
        let communityRating: Double?
        let people: [Person]?
        let studios: [Studio]?
        let imageTags: [String: String]?
        let backdropImageTags: [String]?
        var path: String?
        let userData: Data?
        var mediaStreams: [MediaStream]?
        let mediaSources: [Source]?
        let extraType: String?
    }

    private struct Page: Decodable { let items: [Item] }

    private func tick() async {
        guard server.state == .running, cloud.connected, let userId = server.currentUserId else { return }
        do {
            let files = try await drive.everything()
            let page: Page = try await server.client.get("/Items", [
                .init("userId", userId), .init("recursive", "true"), .init("includeItemTypes", "Movie,Video,Episode"),
                .init("fields", "Overview,Genres,People,Studios,Taglines,Path,MediaStreams,MediaSources,SortName"),
                .init("enableUserData", "true"), .init("enableImageTypes", "Primary,Backdrop,Thumb"),
            ])
            var items: [UInt64: Item] = [:]
            for item in page.items {
                // A film with versions is one item with a media source per version; each version is its own film
                // here, with the item's details and its own streams. A version's media source id is its own item.
                let sources = (item.mediaSources ?? []).filter { $0.path != nil }
                if sources.count > 1 {
                    for source in sources {
                        guard let path = source.path, let film = cloud.film(atDiskPath: path), film.verified else { continue }
                        var version = item
                        version.path = path
                        version.mediaStreams = source.mediaStreams ?? item.mediaStreams
                        if let id = source.id { version.id = id }
                        items[film.id] = version
                    }
                } else if let path = item.path, let film = cloud.film(atDiskPath: path), film.verified {
                    items[film.id] = item
                }
            }
            // Extras are items of their own, found through their film.
            for (filmID, item) in items {
                guard let film = cloud.film(filmID), let root = cloud.groupRoot(film), root.id == filmID,
                      !cloud.extras(of: root.id).isEmpty else { continue }
                for kind in ["SpecialFeatures", "LocalTrailers"] {
                    let found: [Item]? = try? await server.client.get("/Items/\(item.id)/\(kind)", [
                        .init("userId", userId), .init("fields", "Path,MediaStreams,Overview"),
                    ])
                    for extra in found ?? [] {
                        guard let path = extra.path, let film = cloud.film(atDiskPath: path), film.verified else { continue }
                        items[film.id] = extra
                    }
                }
            }
            try await publishInfo(items, files: files)
            try await publishShows(Set(items.values.compactMap(\.seriesId)), files: files, userId: userId)
            try await syncWatching(items, files: files, userId: userId)
            await handleRequests(files)
            lastProblem = nil
        } catch is CancellationError {
        } catch {
            lastProblem = error.localizedDescription
            log.error("\(error.localizedDescription, privacy: .public)")
        }
    }

    private func kind(_ file: DriveFile) -> String? { file.appProperties?[PhoneDrive.kind] }

    // MARK: Details and artwork

    private func publishInfo(_ items: [UInt64: Item], files: [DriveFile]) async throws {
        let existing = Dictionary(files.filter { kind($0) == PhoneDrive.info }.compactMap { file in
            file.appProperties?["id"].map { ($0, file) }
        }, uniquingKeysWith: { first, _ in first })
        var written = 0
        for (id, item) in items.sorted(by: { $0.key < $1.key }) {
            guard written < 4, let film = cloud.film(id) else { continue }
            let languages = discLanguages(size: film.size)
            let revision = Self.revision(item, languages: languages, group: groupKey(film))
            let current = existing[String(id)]
            if current?.appProperties?["rev"] == revision { continue }
            var info = try await makeInfo(id: id, item: item, languages: languages)
            if let root = cloud.groupRoot(film) {
                if film.extraOf != nil {
                    info.extra = ExtraRef(rootID: String(root.id), kind: film.extraKind ?? .other,
                                          title: film.extraTitle ?? info.title)
                } else if cloud.versions(of: root.id).count > 1 {
                    info.filmVersion = VersionRef(rootID: String(root.id), label: film.versionLabel ?? "Version",
                                              isDefault: film.versionOf == nil)
                }
            }
            let data = try JSONEncoder().encode(info)
            let properties = [PhoneDrive.kind: PhoneDrive.info, "id": String(id), "rev": revision]
            if let current {
                try await drive.replace(current.id, data: data, properties: properties)
            } else {
                try await drive.create(name: "\(info.title) (details).json", parent: try await cloud.reelFolder(),
                                       properties: properties, data: data)
            }
            written += 1
        }
    }

    /// What the phone needs to know about a film's group, so a change of default, label or kind rewrites it.
    private func groupKey(_ film: CloudFilm) -> String {
        guard let root = cloud.groupRoot(film) else { return "" }
        return [String(root.id), film.versionLabel ?? "", film.versionOf == nil ? "default" : "",
                film.extraKind?.rawValue ?? "", film.extraTitle ?? "", "\(cloud.versions(of: root.id).count)"].joined(separator: "/")
    }

    private static func revision(_ item: Item, languages: [String: String], group: String = "") -> String {
        let parts: [String] = [group,
            "\(PhoneDrive.infoVersion)", item.name ?? "", "\(item.productionYear ?? 0)", item.officialRating ?? "",
            item.overview ?? "", (item.genres ?? []).joined(separator: ","), item.imageTags?["Primary"] ?? "",
            item.backdropImageTags?.first ?? "", item.imageTags?["Thumb"] ?? "", "\(item.people?.count ?? 0)",
            "\(item.runTimeTicks ?? 0)", languages.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(),
            item.seriesId ?? "", item.seriesName ?? "", "\(item.parentIndexNumber ?? -1)", "\(item.indexNumber ?? -1)",
            // Unnumbered episodes take their season from the folder, so a move must rewrite them.
            item.type == "Episode" && item.parentIndexNumber == nil ? (item.path ?? "") : "",
        ]
        let digest = SHA256.hash(data: Data(parts.joined(separator: "|").utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private func image(_ itemID: String, type: String, tag: String?, width: Int) async -> Data? {
        guard let tag else { return nil }
        let url = server.client.url("/Items/\(itemID)/Images/\(type)", [
            .init("maxWidth", "\(width)"), .init("quality", "82"), .init("tag", tag), .init("format", "Jpg"),
        ], withKey: true)
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    private func makeInfo(id: UInt64, item: Item, languages: [String: String]) async throws -> FilmInfo {
        let video = item.mediaStreams?.first { $0.type == "Video" }
        let audio = item.mediaStreams?.first { $0.type == "Audio" }
        var people: [FilmInfo.Person] = []
        for person in item.people ?? [] {
            guard let name = person.name, let type = person.type, ["Actor", "Director", "Writer"].contains(type) else { continue }
            if type == "Actor", people.filter({ $0.kind == "Actor" }).count >= 15 { continue }
            people.append(.init(name: name, role: person.role, kind: type))
        }
        var episode: EpisodeRef?
        if item.type == "Episode", let showID = item.seriesId {
            // A file Jellyfin couldn't number still sits in a "Season NN" folder; its number may be in the name.
            let folderSeason = item.path.flatMap { CloudFilm.season(inFolder: ($0 as NSString).deletingLastPathComponent
                .components(separatedBy: "/").suffix(3).joined(separator: "/")) }
            let nameNumber = item.path.flatMap { path -> Int? in
                let name = (path as NSString).lastPathComponent
                guard let r = name.range(of: #"[Ee](\d{1,4})"#, options: .regularExpression) else { return nil }
                return Int(name[r].dropFirst())
            }
            episode = EpisodeRef(showID: showID, show: item.seriesName ?? "", season: item.parentIndexNumber ?? folderSeason ?? 1,
                                 number: item.indexNumber ?? nameNumber ?? 0)
        }
        let poster: Data?, backdrop: Data?
        if episode != nil || item.extraType != nil {
            // An episode's or extra's picture is a still from it; the show's (film's) art is elsewhere.
            poster = nil
            backdrop = await image(item.id, type: "Primary", tag: item.imageTags?["Primary"], width: 960)
        } else {
            poster = await image(item.id, type: "Primary", tag: item.imageTags?["Primary"], width: 600)
            var wide = await image(item.id, type: "Backdrop/0", tag: item.backdropImageTags?.first, width: 1600)
            if wide == nil { wide = await image(item.id, type: "Thumb", tag: item.imageTags?["Thumb"], width: 1600) }
            backdrop = wide
        }
        return FilmInfo(
            filmID: String(id), title: item.name ?? "Untitled", sortTitle: item.sortName, year: item.productionYear,
            rating: item.officialRating, seconds: item.runTimeTicks.map { Double($0) / Reel.ticksPerSecond },
            overview: item.overview, tagline: item.taglines?.first, genres: item.genres ?? [],
            score: item.communityRating, people: people, studio: item.studios?.first?.name,
            hdr: video?.videoRangeType, width: video?.width, sound: audio?.displayTitle,
            languages: languages, poster: poster, backdrop: backdrop, episode: episode)
    }

    // MARK: Shows

    /// One details file per show that has an episode in Drive. A show with none left loses its file.
    private func publishShows(_ shows: Set<String>, files: [DriveFile], userId: String) async throws {
        let existing = files.filter { kind($0) == PhoneDrive.show }
        // Never on an empty round: a moment when Jellyfin lists nothing mustn't empty the phone's shows.
        for file in existing where !shows.isEmpty && !shows.contains(file.appProperties?["id"] ?? "") {
            try? await drive.trash(file.id)
        }
        var written = 0
        for showID in shows.sorted() where written < 2 {
            guard let show: Item = try? await server.client.get("/Items/\(showID)", [.init("userId", userId)]) else { continue }
            let revision = Self.revision(show, languages: [:])
            let current = existing.first { $0.appProperties?["id"] == showID }
            if current?.appProperties?["rev"] == revision { continue }
            var people: [FilmInfo.Person] = []
            for person in show.people ?? [] {
                guard let name = person.name, let type = person.type, ["Actor", "Director", "Writer"].contains(type) else { continue }
                if type == "Actor", people.filter({ $0.kind == "Actor" }).count >= 15 { continue }
                people.append(.init(name: name, role: person.role, kind: type))
            }
            let info = ShowInfo(
                showID: showID, title: show.name ?? "Untitled", sortTitle: show.sortName, year: show.productionYear,
                rating: show.officialRating, overview: show.overview, genres: show.genres ?? [], people: people,
                studio: show.studios?.first?.name,
                poster: await image(showID, type: "Primary", tag: show.imageTags?["Primary"], width: 600),
                backdrop: await image(showID, type: "Backdrop/0", tag: show.backdropImageTags?.first, width: 1600))
            let data = try JSONEncoder().encode(info)
            let properties = [PhoneDrive.kind: PhoneDrive.show, "id": showID, "rev": revision]
            if let current {
                try await drive.replace(current.id, data: data, properties: properties)
            } else {
                try await drive.create(name: "\(info.title) (show details).json", parent: try await cloud.reelFolder(),
                                       properties: properties, data: data)
            }
            written += 1
        }
    }

    /// Blu-ray films keep their track languages in the disc's index. If the disc folder is still in the drop
    /// folder, the clip whose declared size matches the film is the one.
    private func discLanguages(size: Int64) -> [String: String] {
        // Remembered, because the disc folder is usually thrown away once the film is in Drive.
        let key = "phone.languages.\(size)"
        if let saved = UserDefaults.standard.dictionary(forKey: key) as? [String: String], !saved.isEmpty { return saved }
        let found = findDiscLanguages(size: size)
        if !found.isEmpty { UserDefaults.standard.set(found, forKey: key) }
        return found
    }

    private func findDiscLanguages(size: Int64) -> [String: String] {
        let root = cloud.paths.drop
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [:] }
        for case let url as URL in walker where url.pathExtension.lowercased() == "clpi" {
            guard let data = try? Data(contentsOf: url), data.count >= 60 else { continue }
            let bytes = [UInt8](data)
            let packets = bytes[56..<60].reduce(Int64(0)) { $0 << 8 | Int64($1) }
            if packets * 192 == size { return ClipLanguages.read(data) }
        }
        return [:]
    }

    // MARK: Where you got to

    private static let jellyfinDate: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        if let d = jellyfinDate.date(from: text) { return d }
        if let d = ISO8601DateFormatter().date(from: text) { return d }
        // Jellyfin sends seven fractional digits.
        let trimmed = text.replacingOccurrences(of: #"(\.\d{3})\d+"#, with: "$1", options: .regularExpression)
        return jellyfinDate.date(from: trimmed)
    }

    private func syncWatching(_ items: [UInt64: Item], files: [DriveFile], userId: String) async throws {
        let watches = Dictionary(files.filter { kind($0) == PhoneDrive.watch }.compactMap { file in
            file.appProperties?["id"].map { ($0, file) }
        }, uniquingKeysWith: { first, _ in first })
        for (id, item) in items {
            let key = String(id)
            let data = item.userData
            let here = WatchState(position: Double(data?.playbackPositionTicks ?? 0) / Reel.ticksPerSecond,
                                  watched: data?.played ?? false, favorite: data?.isFavorite ?? false,
                                  updated: Self.date(data?.lastPlayedDate) ?? .distantPast)
            let file = watches[key]
            let phone = file.flatMap { $0.appProperties.flatMap(WatchState.init(properties:)) }
            if let phone, !phone.matches(here), phone.updated > here.updated || phone.favorite != here.favorite,
               applied[key] != phone {
                // The phone's is newer. Favourites only ever change on the phone.
                let body: [String: Any] = [
                    "PlaybackPositionTicks": Int64(phone.position * Reel.ticksPerSecond),
                    "Played": phone.watched, "IsFavorite": phone.favorite,
                    "LastPlayedDate": Self.jellyfinDate.string(from: max(phone.updated, here.updated)),
                ]
                try await server.client.send("POST", "/UserItems/\(item.id)/UserData", query: [.init("userId", userId)], json: body)
                applied[key] = phone
            } else if here.updated > (phone?.updated ?? .distantPast), !(phone.map { here.matches($0) } ?? false) {
                // Watched on the Apple TV since.
                var state = here
                state.favorite = phone?.favorite ?? here.favorite
                if let file {
                    try await drive.update(file.id, properties: state.properties(filmID: key))
                } else {
                    _ = try await drive.create(name: "Reel watch \(key)", parent: try await cloud.reelFolder(),
                                               properties: state.properties(filmID: key), data: Data(), type: "text/plain")
                }
                applied[key] = state
            }
        }
    }

    // MARK: Smaller copies

    private func handleRequests(_ files: [DriveFile]) async {
        let copies = files.filter { kind($0) == PhoneDrive.copy }
        let requests = files.filter { kind($0) == PhoneDrive.request }
            .sorted { ($0.modifiedTime ?? "") < ($1.modifiedTime ?? "") }
        if let current = workingOn, !requests.contains(where: { $0.id == current }) {
            // The phone cancelled it.
            worker?.cancel()
        }
        guard worker == nil else { return }
        for request in requests {
            guard let properties = request.appProperties, let idText = properties["id"], let id = UInt64(idText),
                  let quality = properties["quality"].flatMap(CopyQuality.init(rawValue:)), quality != .original else { continue }
            let progress = CopyProgress(properties: properties)
            guard progress.phase == .waiting else { continue }
            guard let film = cloud.film(id), film.verified else {
                _ = try? await drive.update(request.id, properties: CopyProgress(phase: .failed, detail: "That film isn’t in Reel any more.").properties)
                continue
            }
            if let made = copies.first(where: { $0.appProperties?["id"] == idText && $0.appProperties?["quality"] == quality.rawValue }) {
                _ = try? await drive.update(request.id, properties: CopyProgress(phase: .ready, progress: 1, copyID: made.id).properties)
                continue
            }
            workingOn = request.id
            job = Job(filmName: film.name, quality: quality, progress: CopyProgress(phase: .making, progress: 0))
            worker = Task { [weak self] in
                await self?.makeCopy(of: film, quality: quality, request: request.id)
                guard let self else { return }
                self.worker = nil
                self.workingOn = nil
                self.job = nil
            }
            return
        }
    }

    private func report(_ request: String, _ progress: CopyProgress) async {
        job?.progress = progress
        do {
            try await drive.update(request, properties: progress.properties)
        } catch let error as DriveError where error.status == 404 {
            worker?.cancel()
        } catch {}
    }

    private func makeCopy(of film: CloudFilm, quality: CopyQuality, request: String) async {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Reel/phone-copies", isDirectory: true)
        let output = folder.appendingPathComponent("\(film.id)-\(quality.rawValue).mkv")
        defer { try? FileManager.default.removeItem(at: output) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let input = cloud.paths.mount.appendingPathComponent(film.folder).appendingPathComponent(film.name)
            let probe = try await Self.probe(input, tools: server.support)
            let needed = quality.estimatedSize(seconds: probe.seconds, hdr: probe.hdr, uhd: probe.width > 2000)
            let free = (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage ?? 0
            guard free > needed + CloudStore.spaceMargin else {
                throw CloudError("The Mac needs \((needed + CloudStore.spaceMargin).formatted(.byteCount(style: .file))) free to make this copy.")
            }
            try await encode(input, probe: probe, quality: quality, to: output, request: request)
            try Task.checkCancellation()

            await report(request, CopyProgress(phase: .uploading, progress: 0))
            let size = (try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.int64Value ?? 0
            let base = (film.name as NSString).deletingPathExtension
            let properties = [PhoneDrive.kind: PhoneDrive.copy, "id": String(film.id), "quality": quality.rawValue,
                              "seconds": String(format: "%.0f", probe.seconds)]
            let upload = try await drive.beginUpload(name: "\(base) (\(quality.title)).mkv", size: size,
                                                     parent: try await cloud.reelFolder(), properties: properties)
            var sent: Int64 = 0
            var done: DriveFile?
            var lastReport = Date()
            while done == nil {
                try Task.checkCancellation()
                let count = Int(min(Int64(32 << 20), size - sent))
                let chunk = try CloudFiles.read(output.path, offset: sent, count: count)
                switch try await drive.sendChunk(upload, data: chunk, offset: sent, size: size) {
                case .received(let next): sent = next
                case .done(let file): done = file
                case .expired: throw CloudError("Google ended the upload. Ask again on the iPhone.")
                }
                if Date().timeIntervalSince(lastReport) > 20 {
                    lastReport = Date()
                    await report(request, CopyProgress(phase: .uploading, progress: Double(sent) / Double(max(size, 1))))
                }
            }
            guard let file = done else { return }
            let path = output.path
            let local = try await Task.detached { try CloudFiles.md5(path).finalize() }.value
                .map { String(format: "%02x", $0) }.joined()
            guard file.md5Checksum?.lowercased() == local, file.byteCount == size else {
                try? await drive.trash(file.id)
                throw CloudError("Google’s copy didn’t match. Ask again on the iPhone.")
            }
            await report(request, CopyProgress(phase: .ready, progress: 1, copyID: file.id))
            log.notice("Made a \(quality.rawValue, privacy: .public) copy for iPhone")
        } catch is CancellationError {
        } catch {
            if Task.isCancelled { return }
            lastProblem = error.localizedDescription
            await report(request, CopyProgress(phase: .failed, detail: error.localizedDescription))
        }
    }

    struct Probe {
        let seconds: Double
        let hdr: Bool
        let width: Int
        let audio: Int?
        let audioChannels: Int
        let hevc: Bool
    }

    nonisolated private static func tool(_ name: String, in support: URL) -> URL {
        support.appendingPathComponent("Jellyfin.app/Contents/MacOS/\(name)")
    }

    nonisolated static func probe(_ input: URL, tools support: URL) async throws -> Probe {
        let output = try await run(tool("ffprobe", in: support), [
            "-v", "error", "-probesize", "40M", "-analyzeduration", "10M",
            "-show_entries", "format=duration:stream=index,codec_name,codec_type,width,color_transfer,channels:stream_disposition=default,comment:stream_tags=title",
            "-of", "json", input.path,
        ])
        struct Result: Decodable {
            struct Format: Decodable { let duration: String? }
            struct Stream: Decodable {
                let index: Int
                let codec_name: String?
                let codec_type: String?
                let width: Int?
                let color_transfer: String?
                let channels: Int?
                let disposition: [String: Int]?
                let tags: [String: String]?
            }
            let format: Format?
            let streams: [Stream]?
        }
        let result = try JSONDecoder().decode(Result.self, from: output)
        let streams = result.streams ?? []
        guard let video = streams.first(where: { $0.codec_type == "video" }),
              let seconds = result.format?.duration.flatMap(Double.init) else {
            throw CloudError("Reel couldn’t read the film to make a copy.")
        }
        let sounds = streams.filter { $0.codec_type == "audio" }
        let isCommentary: (Result.Stream) -> Bool = {
            $0.disposition?["comment"] == 1 || ($0.tags?["title"] ?? "").localizedCaseInsensitiveContains("commentary")
        }
        let main = sounds.first { $0.disposition?["default"] == 1 && !isCommentary($0) }
            ?? sounds.first { !isCommentary($0) } ?? sounds.first
        return Probe(seconds: seconds, hdr: ["smpte2084", "arib-std-b67"].contains(video.color_transfer ?? ""),
                     width: video.width ?? 1920, audio: main?.index, audioChannels: main?.channels ?? 2,
                     hevc: video.codec_name == "hevc")
    }

    nonisolated static func arguments(input: String, output: String, probe: Probe, quality: CopyQuality) -> [String] {
        let uhd = probe.width > 2000
        var arguments = ["-nostdin", "-y", "-v", "error", "-probesize", "40M", "-analyzeduration", "10M"]
        // Blu-ray H.264 decodes faster in software; the hardware decoder keeps failing on it and retrying.
        if probe.hevc { arguments += ["-hwaccel", "videotoolbox"] }
        arguments += ["-i", input, "-map", "0:v:0"]
        if let audio = probe.audio { arguments += ["-map", "0:\(audio)"] }
        arguments += ["-map", "0:s?", "-map_metadata", "0", "-map_chapters", "0"]
        let bitrate = quality.videoBitrate(hdr: probe.hdr, uhd: uhd)
        let scale = "scale=-2:'min(ih,\(quality.height))':flags=bicubic"
        arguments += ["-vf", probe.hdr ? scale + ",format=p010le" : scale + ",format=nv12",
                      "-c:v", "hevc_videotoolbox", "-profile:v", probe.hdr ? "main10" : "main",
                      "-b:v", "\(bitrate)", "-maxrate", "\(bitrate * 2)", "-bufsize", "\(bitrate * 3)"]
        if probe.hdr {
            arguments += ["-color_primaries", "bt2020", "-color_trc", "smpte2084", "-colorspace", "bt2020nc"]
        }
        let channels = quality == .medium ? min(probe.audioChannels, 6) : 2
        arguments += ["-c:a", "aac", "-b:a", "\(channels > 2 ? quality.audioBitrate : min(quality.audioBitrate, 192_000))",
                      "-ac", "\(channels)", "-metadata:s:a:0", "title=", "-c:s", "copy", "-max_muxing_queue_size", "4096",
                      "-progress", "pipe:1", "-f", "matroska", output]
        return arguments
    }

    private func encode(_ input: URL, probe: Probe, quality: CopyQuality, to output: URL, request: String) async throws {
        let process = Process()
        process.executableURL = Self.tool("ffmpeg", in: server.support)
        process.arguments = Self.arguments(input: input.path, output: output.path, probe: probe, quality: quality)
        process.qualityOfService = .utility
        let pipe = Pipe()
        let errors = Pipe()
        process.standardOutput = pipe
        process.standardError = errors
        try process.run()
        defer { if process.isRunning { process.terminate() } }

        var lastReport = Date.distantPast
        let total = probe.seconds
        for try await line in pipe.fileHandleForReading.bytes.lines {
            if Task.isCancelled {
                process.terminate()
                throw CancellationError()
            }
            guard line.hasPrefix("out_time_us="), let micro = Double(line.dropFirst(12)),
                  Date().timeIntervalSince(lastReport) > 20 else { continue }
            lastReport = Date()
            await report(request, CopyProgress(phase: .making, progress: min(micro / 1e6 / total, 0.999)))
        }
        process.waitUntilExit()
        try Task.checkCancellation()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .split(separator: "\n").last.map(String.init) ?? "exit \(process.terminationStatus)"
            throw CloudError("Making the copy failed: \(message)")
        }
    }

    nonisolated private static func run(_ tool: URL, _ arguments: [String]) async throws -> Data {
        try await Task.detached {
            let process = Process()
            process.executableURL = tool
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return data
        }.value
    }
}

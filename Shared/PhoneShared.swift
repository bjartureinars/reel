import Foundation

/// How Reel Server and Reel for iPhone talk: only through files in Google Drive, so the phone works anywhere and
/// the Mac only has to be on to make smaller copies and to refresh film details.
///
/// Every file Reel keeps in Drive has an app property `reel` saying what it is:
/// - `film` / `part`: a film, whole or in pieces (made by Reel Server's upload).
/// - `info`: a film's or episode's details and artwork as JSON (Reel Server writes it).
/// - `show`: a TV show's details and artwork as JSON, one per show (Reel Server writes it).
/// - `copy`: a smaller version of a film for downloading (Reel Server makes it when asked).
/// - `request`: the phone asking for a copy (the phone creates it, Reel Server reports progress on it).
/// - `watch`: where you got to, watched and My List, kept the same on the phone and the Apple TV.
enum PhoneDrive {
    static let kind = "reel"
    static let film = "film"
    static let part = "part"
    static let info = "info"
    static let show = "show"
    static let copy = "copy"
    static let request = "request"
    static let watch = "watch"

    /// Information files older than this format are rewritten.
    static let infoVersion = 1
}

enum CopyQuality: String, Codable, CaseIterable, Identifiable {
    case original, medium, low

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: return "Original"
        case .medium: return "Medium"
        case .low: return "Low"
        }
    }

    /// Picture bits per second, for sizes and the Mac's encoder.
    func videoBitrate(hdr: Bool, uhd: Bool) -> Int {
        switch self {
        case .original: return 0
        case .medium: return hdr || uhd ? 8_000_000 : 6_000_000
        case .low: return hdr || uhd ? 3_000_000 : 2_500_000
        }
    }

    var audioBitrate: Int { self == .medium ? 384_000 : 160_000 }
    var height: Int { self == .medium ? 1080 : 720 }

    func estimatedSize(seconds: Double, hdr: Bool, uhd: Bool) -> Int64 {
        Int64(seconds * Double(videoBitrate(hdr: hdr, uhd: uhd) + audioBitrate) / 8 * 1.03)
    }
}

/// A film's details and artwork, written by Reel Server from Jellyfin.
struct FilmInfo: Codable, Equatable {
    struct Person: Codable, Equatable, Hashable {
        let name: String
        let role: String?
        let kind: String
    }

    var version = PhoneDrive.infoVersion
    let filmID: String
    let title: String
    let sortTitle: String?
    let year: Int?
    let rating: String?
    let seconds: Double?
    let overview: String?
    let tagline: String?
    let genres: [String]
    let score: Double?
    let people: [Person]
    let studio: String?
    let hdr: String?
    let width: Int?
    let sound: String?
    /// Track languages the file itself doesn't record (Blu-ray discs keep them in their index), by MPEG-TS PID.
    let languages: [String: String]
    /// Pictures travel in the Drive file; the phone keeps them as files and drops them from its saved copy.
    var poster: Data?
    var backdrop: Data?
    /// For an episode: its show, season and number (its picture is a still from it, in `backdrop`). nil for a film.
    var episode: EpisodeRef? = nil
    /// For one of several versions of a film: which film, its name, and whether Play uses it.
    var filmVersion: VersionRef? = nil
    /// For bonus material: whose, and what kind.
    var extra: ExtraRef? = nil
}

struct VersionRef: Codable, Equatable, Hashable {
    /// The default version's film id; every version of the film has the same one.
    let rootID: String
    let label: String
    let isDefault: Bool
}

struct ExtraRef: Codable, Equatable, Hashable {
    let rootID: String
    let kind: ExtraKind
    let title: String
}

struct EpisodeRef: Codable, Equatable, Hashable {
    /// Jellyfin's id for the show; the `show` file with the same id describes it.
    let showID: String
    let show: String
    let season: Int
    let number: Int
}

/// A TV show's details and artwork, written by Reel Server from Jellyfin.
struct ShowInfo: Codable, Equatable {
    var version = PhoneDrive.infoVersion
    let showID: String
    let title: String
    let sortTitle: String?
    let year: Int?
    let rating: String?
    let overview: String?
    let genres: [String]
    let people: [FilmInfo.Person]
    let studio: String?
    let poster: Data?
    let backdrop: Data?
}

/// One film's viewing state. Stored as app properties of a small `watch` file, so one listing reads them all.
struct WatchState: Equatable {
    var position: Double
    var watched: Bool
    var favorite: Bool
    var updated: Date

    static let empty = WatchState(position: 0, watched: false, favorite: false, updated: .distantPast)

    init(position: Double, watched: Bool, favorite: Bool, updated: Date) {
        self.position = position
        self.watched = watched
        self.favorite = favorite
        self.updated = updated
    }

    init?(properties: [String: String]) {
        guard let at = properties["at"].flatMap(Double.init) else { return nil }
        position = properties["position"].flatMap(Double.init) ?? 0
        watched = properties["watched"] == "1"
        favorite = properties["favorite"] == "1"
        updated = Date(timeIntervalSince1970: at)
    }

    func properties(filmID: String) -> [String: String] {
        [PhoneDrive.kind: PhoneDrive.watch, "id": filmID, "position": String(format: "%.1f", position),
         "watched": watched ? "1" : "0", "favorite": favorite ? "1" : "0",
         "at": String(format: "%.3f", updated.timeIntervalSince1970)]
    }

    /// Same as far as anyone could tell.
    func matches(_ other: WatchState) -> Bool {
        abs(position - other.position) < 15 && watched == other.watched && favorite == other.favorite
    }
}

/// What the Mac says about a request, in the request file's app properties.
struct CopyProgress: Equatable {
    enum Phase: String { case waiting, making, uploading, ready, failed }

    let phase: Phase
    let progress: Double?
    let detail: String?
    let copyID: String?

    init(phase: Phase, progress: Double? = nil, detail: String? = nil, copyID: String? = nil) {
        self.phase = phase
        self.progress = progress
        self.detail = detail
        self.copyID = copyID
    }

    init(properties: [String: String]) {
        phase = properties["state"].flatMap(Phase.init(rawValue:)) ?? .waiting
        progress = properties["progress"].flatMap(Double.init)
        detail = properties["detail"]
        copyID = properties["copy"]
    }

    var properties: [String: String] {
        var out = ["state": phase.rawValue]
        if let progress { out["progress"] = String(format: "%.3f", progress) }
        if let detail { out["detail"] = String(detail.prefix(100)) }
        if let copyID { out["copy"] = copyID }
        return out
    }
}

/// Track languages from a Blu-ray clip index (.clpi), which M2TS files don't carry themselves.
enum ClipLanguages {
    static func read(_ data: Data) -> [String: String] {
        let b = [UInt8](data)
        func n(_ at: Int, _ length: Int) -> Int? {
            guard at >= 0, at + length <= b.count else { return nil }
            return b[at..<(at + length)].reduce(0) { $0 << 8 | Int($1) }
        }
        guard b.count > 40, b.starts(with: Array("HDMV".utf8)), let start = n(12, 4) else { return [:] }
        var out: [String: String] = [:]
        guard let sequences = n(start + 5, 1) else { return [:] }
        var at = start + 6
        for _ in 0..<sequences {
            guard let streams = n(at + 6, 1) else { break }
            at += 8
            for _ in 0..<streams {
                guard let pid = n(at, 2), let length = n(at + 2, 1), let type = n(at + 3, 1) else { return out }
                let info = at + 3
                var language: Int?
                switch type {
                case 0x03, 0x04, 0x80...0x86, 0xA1, 0xA2: language = info + 2
                case 0x90, 0x91: language = info + 1
                case 0x92: language = info + 2
                default: break
                }
                if let language, language + 3 <= info + length, language + 3 <= b.count,
                   let text = String(bytes: b[language..<(language + 3)], encoding: .ascii),
                   text.allSatisfy(\.isLetter) {
                    out[String(pid)] = text.lowercased()
                }
                at += 3 + length
            }
        }
        return out
    }
}

/// What kind of bonus material an extra is. `folder` is the subfolder name Jellyfin recognises as that kind.
enum ExtraKind: String, Codable, CaseIterable, Identifiable {
    case trailer, behindTheScenes, featurette, deletedScene, interview, short, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .trailer: return "Trailer"
        case .behindTheScenes: return "Behind the Scenes"
        case .featurette: return "Featurette"
        case .deletedScene: return "Deleted Scene"
        case .interview: return "Interview"
        case .short: return "Short"
        case .other: return "Extra"
        }
    }

    var folder: String {
        switch self {
        case .trailer: return "trailers"
        case .behindTheScenes: return "behind the scenes"
        case .featurette: return "featurettes"
        case .deletedScene: return "deleted scenes"
        case .interview: return "interviews"
        case .short: return "shorts"
        case .other: return "extras"
        }
    }

    /// Jellyfin's ExtraType for the kind, as the Apple TV sees it.
    init(jellyfin type: String?) {
        switch (type ?? "").lowercased() {
        case "trailer": self = .trailer
        case "behindthescenes": self = .behindTheScenes
        case "featurette": self = .featurette
        case "deletedscene": self = .deletedScene
        case "interview": self = .interview
        case "short": self = .short
        default: self = .other
        }
    }
}

extension ExtraKind: Comparable {
    static func < (a: ExtraKind, b: ExtraKind) -> Bool {
        (allCases.firstIndex(of: a) ?? 0) < (allCases.firstIndex(of: b) ?? 0)
    }
}

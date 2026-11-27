import CryptoKit
import Foundation
import os

/// Versions and extras of a film, and films that arrive from torrents.
extension CloudStore {
    // MARK: Versions and extras

    /// The default version of the group a film belongs to, or nil if it's on its own.
    func groupRoot(_ film: CloudFilm) -> CloudFilm? {
        if let root = film.versionOf ?? film.extraOf { return self.film(root) }
        return films.contains { $0.versionOf == film.id || $0.extraOf == film.id } ? film : nil
    }

    /// The default version first, then the others by name.
    func versions(of root: UInt64) -> [CloudFilm] {
        guard let first = self.film(root) else { return [] }
        return [first] + films.filter { $0.versionOf == root }
            .sorted { ($0.versionLabel ?? $0.name).localizedStandardCompare($1.versionLabel ?? $1.name) == .orderedAscending }
    }

    func extras(of root: UInt64) -> [CloudFilm] {
        films.filter { $0.extraOf == root }.sorted {
            ($0.extraKind ?? .other, $0.extraTitle ?? $0.name) < ($1.extraKind ?? .other, $1.extraTitle ?? $1.name)
        }
    }

    /// Where a film appears on the cloud disk. A film with versions or extras gets a folder of its own, laid out
    /// the way Jellyfin expects: "Title (Year)/Title (Year) - Label.mkv" for each version, and extras in
    /// "Title (Year)/trailers/…", "Title (Year)/behind the scenes/…" and so on.
    func place(_ film: CloudFilm) -> (folder: String, name: String) {
        guard film.folder == "Films", let root = groupRoot(film) else { return (film.folder, film.name) }
        let group = Self.safeName(root.groupFolder ?? (root.name as NSString).deletingPathExtension)
        let ext = (film.name as NSString).pathExtension
        let dot = ext.isEmpty ? "" : ".\(ext)"
        if film.extraOf != nil {
            let kind = film.extraKind ?? .other
            let title = Self.safeName(film.extraTitle ?? (film.name as NSString).deletingPathExtension)
            let siblings = extras(of: root.id).filter { ($0.extraKind ?? .other) == kind }
            let same = siblings.filter { Self.safeName($0.extraTitle ?? ($0.name as NSString).deletingPathExtension) == title }
            let number = same.count > 1 ? " (\((same.firstIndex { $0.id == film.id } ?? 0) + 1))" : ""
            return ("Films/\(group)/\(kind.folder)", "\(title)\(number)\(dot)")
        }
        let label = Self.safeName(film.versionLabel ?? (film.id == root.id ? "Default" : "Version"))
        let siblings = versions(of: root.id).filter { Self.safeName($0.versionLabel ?? "") == label }
        let number = siblings.count > 1 ? " \((siblings.firstIndex { $0.id == film.id } ?? 0) + 1)" : ""
        return ("Films/\(group)", "\(group) - \(label)\(number)\(dot)")
    }

    /// The name a film has on the cloud disk (what Jellyfin and the players see).
    func diskName(_ film: CloudFilm) -> String { place(film).name }

    nonisolated static func safeName(_ text: String) -> String {
        let cleaned = text.replacingOccurrences(of: #"[/:\\]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return cleaned.isEmpty ? "Film" : cleaned
    }

    /// Makes `id` another version of `root`. A film that had versions or extras of its own brings them along.
    func addVersion(_ id: UInt64, to root: UInt64, label: String, groupFolder: String, rootLabel: String) throws {
        guard let film = self.film(id), let main = self.film(root), id != root else { return }
        guard film.folder == "Films", main.folder == "Films" else { throw CloudError("Only films can have versions.") }
        guard main.versionOf == nil, main.extraOf == nil else { throw CloudError("Add versions to the film’s default version.") }
        for index in films.indices where films[index].versionOf == id || films[index].extraOf == id {
            if films[index].versionOf == id { films[index].versionOf = root } else { films[index].extraOf = root }
        }
        edit(root) {
            if $0.groupFolder == nil { $0.groupFolder = groupFolder }
            if $0.versionLabel == nil { $0.versionLabel = rootLabel }
        }
        edit(id) { $0.versionOf = root; $0.extraOf = nil; $0.versionLabel = label; $0.groupFolder = nil }
        commitList()
    }

    /// Play uses the default version, and the group is listed under it.
    func makeDefault(_ id: UInt64) {
        guard let film = self.film(id), let root = film.versionOf, let old = self.film(root) else { return }
        for index in films.indices {
            if films[index].versionOf == root, films[index].id != id { films[index].versionOf = id }
            if films[index].extraOf == root { films[index].extraOf = id }
        }
        edit(root) { $0.versionOf = id; $0.groupFolder = nil }
        edit(id) { $0.versionOf = nil; $0.groupFolder = old.groupFolder }
        commitList()
    }

    func renameVersion(_ id: UInt64, label: String) {
        let clean = label.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        edit(id) { $0.versionLabel = clean }
        commitList()
    }

    /// Takes a version out of its group: it becomes a film of its own again.
    func separate(_ id: UInt64) {
        guard let film = self.film(id) else { return }
        if film.versionOf == nil, let next = films.first(where: { $0.versionOf == id }) {
            makeDefault(next.id)
        }
        edit(id) { $0.versionOf = nil; $0.extraOf = nil; $0.extraKind = nil; $0.extraTitle = nil; $0.groupFolder = nil }
        commitList()
    }

    /// Makes a film already in the library an extra of `root`.
    func makeExtra(_ id: UInt64, of root: UInt64, kind: ExtraKind, title: String, groupFolder: String) throws {
        guard let film = self.film(id), let main = self.film(root), id != root else { return }
        guard main.folder == "Films", film.folder == "Films" else { throw CloudError("Only films can have extras.") }
        guard !films.contains(where: { $0.versionOf == id || $0.extraOf == id }) else {
            throw CloudError("“\(film.name)” has versions or extras of its own.")
        }
        if main.groupFolder == nil { edit(root) { $0.groupFolder = groupFolder } }
        edit(id) { $0.extraOf = root; $0.versionOf = nil; $0.extraKind = kind; $0.extraTitle = title; $0.groupFolder = nil }
        commitList()
    }

    func editExtra(_ id: UInt64, kind: ExtraKind, title: String) {
        let clean = title.trimmingCharacters(in: .whitespaces)
        edit(id) { $0.extraKind = kind; if !clean.isEmpty { $0.extraTitle = clean } }
        commitList()
    }

    /// An extra from anywhere on this Mac. Choosing it here is the approval; a copy goes in a hidden folder inside
    /// the drop folder and takes the usual way (upload, check, then the copy is deleted). The original stays.
    func addExtra(from file: URL, to root: UInt64, kind: ExtraKind, title: String, groupFolder: String) async throws {
        guard let main = self.film(root), main.folder == "Films" else { throw CloudError("Only films can have extras.") }
        let folder = paths.drop.appendingPathComponent(".reel-extras", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent("\(UUID().uuidString).\(file.pathExtension)")
        try await Task.detached(priority: .userInitiated) { try FileManager.default.copyItem(at: file, to: copy) }.value
        guard let stamp = FileStamp(path: copy.path) else { throw CloudError("Reel couldn’t read the copy.") }
        if quota?.free.map({ $0 < stamp.size }) == true { throw CloudError("Google Drive doesn’t have room for it.") }
        var film = CloudFilm(id: UInt64.random(in: 1 << 32..<1 << 62), folder: "Films",
                             name: uniqueName(file.lastPathComponent, in: "Films"), size: stamp.size,
                             modified: stamp.modified, originalPath: copy.path, originalStamp: stamp)
        film.approvedStamp = stamp
        film.extraOf = root
        film.extraKind = kind
        film.extraTitle = title
        if self.film(root)?.groupFolder == nil { edit(root) { $0.groupFolder = groupFolder } }
        films.append(film)
        commitList()
        startNextJob()
    }

    // MARK: From torrents

    /// A film or episode a torrent download put in Drive part by part. Every byte passed the torrent's own hash
    /// check and every part's MD5 matched Google's, so it arrives verified, like a finished Faster Upload.
    /// Sync may have found the complete set first; then it's already here.
    func adoptFromTorrent(id: UInt64, folder: String, name: String, size: Int64, parts: [UploadPart], partSet: String) {
        guard film(id) == nil, !discarded.contains(id) else { return }
        var film = CloudFilm(id: id, folder: folder, name: uniqueName(name, in: folder), size: size, modified: Date(),
                             verified: true)
        film.parts = parts
        film.partSet = partSet
        guard film.remote != nil else { return }
        films.append(film)
        commitList()
    }

    /// Gives a film a new folder and name (a torrent's episode under its real show, a disc clip under the film's
    /// title). The Drive files keep the new folder too, so a fresh install files it the same way.
    func refile(_ id: UInt64, folder: String, name: String) async {
        guard let film = film(id), film.folder != folder || film.name != name, Self.isKnownFolder(folder) else { return }
        let unique = film.folder == folder && film.name == name ? name : uniqueName(name, in: folder)
        edit(id) { $0.folder = folder; $0.name = unique }
        commitList()
        let files = (film.parts?.compactMap(\.driveID) ?? []) + [film.driveID].compactMap { $0 }
        for file in files { await attempt("Updating a file in Google Drive") { _ = try await drive.update(file, properties: ["folder": folder]) } }
    }

    func uniqueName(_ wanted: String, in folder: String) -> String {
        let url = URL(fileURLWithPath: wanted)
        let base = url.deletingPathExtension().lastPathComponent
        var name = wanted
        var number = 2
        while films.contains(where: { $0.folder == folder && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            name = "\(base) (\(number)).\(url.pathExtension)"
            number += 1
        }
        return name
    }
}

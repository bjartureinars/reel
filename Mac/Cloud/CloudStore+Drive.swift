import CryptoKit
import Foundation
import os

/// Keeping the catalog in step with what is in Google Drive.
extension CloudStore {
    // MARK: Drive

    func sync() async {
        lastSync = Date()
        do {
            quota = try await drive.quota()
            var changed = false
            for remote in try await drive.films() {
                guard let properties = remote.appProperties, let id = properties["id"].flatMap({ UInt64($0) }),
                      let size = remote.byteCount, let name = remote.name else { continue }
                // Films already known are left alone. Others were uploaded by an earlier install of Reel.
                guard !discarded.contains(id), film(id) == nil, !films.contains(where: { $0.driveID == remote.id }) else { continue }
                let folder = properties["folder"].flatMap { Self.isKnownFolder($0) ? $0 : nil } ?? "Films"
                let modified = properties["modified"].flatMap { Double($0) }.map(Date.init(timeIntervalSince1970:))
                films.append(CloudFilm(id: id, folder: folder, name: uniqueName(name, in: folder), size: size,
                                       modified: modified ?? Date(), driveID: remote.id, md5: remote.md5Checksum,
                                       verified: true))
                changed = true
            }
            for film in Self.filmsInPieces(try await drive.parts()) where self.film(film.id) == nil && !discarded.contains(film.id) {
                var film = film
                film.name = uniqueName(film.name, in: film.folder)
                films.append(film)
                changed = true
            }
            if changed { commitList() }
            problem = nil
        } catch {
            report(error, for: nil)
        }
    }

    /// Rebuilds films from fast-upload pieces. A set with anything missing, doubled or misplaced is ignored.
    nonisolated static func filmsInPieces(_ files: [DriveFile]) -> [CloudFilm] {
        Dictionary(grouping: files) { $0.appProperties?["set"] ?? "" }.compactMap { set, files -> CloudFilm? in
            guard !set.isEmpty, let first = files.first?.appProperties,
                  let id = first["id"].flatMap({ UInt64($0) }),
                  let total = first["total"].flatMap({ Int64($0) }),
                  let count = first["count"].flatMap({ Int($0) }), count == files.count,
                  let suffix = files[0].name?.range(of: ".part", options: .backwards),
                  let name = files[0].name.map({ String($0[..<suffix.lowerBound]) }) else { return nil }
            let parts = files.compactMap { file -> UploadPart? in
                guard let offset = file.appProperties?["offset"].flatMap({ Int64($0) }),
                      let size = file.byteCount else { return nil }
                return UploadPart(offset: offset, size: size, received: size, driveID: file.id)
            }.sorted { $0.offset < $1.offset }
            guard parts.count == count else { return nil }
            let folder = first["folder"].flatMap { Self.isKnownFolder($0) ? $0 : nil } ?? "Films"
            let modified = first["modified"].flatMap { Double($0) }.map(Date.init(timeIntervalSince1970:))
            var film = CloudFilm(id: id, folder: folder, name: name, size: total, modified: modified ?? Date(), verified: true)
            film.parts = parts
            film.partSet = set
            return film.remote == nil ? nil : film
        }
    }

    func report(_ error: Error, for id: UInt64?) {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
        log.error("\(error.localizedDescription, privacy: .public)")
        if (error as? CloudError)?.needsSignIn == true {
            connected = false
            problem = error.localizedDescription
        } else if let id {
            errors[id] = error.localizedDescription
            retryAfter[id] = Date().addingTimeInterval(60)
        } else {
            problem = error.localizedDescription
        }
    }
}

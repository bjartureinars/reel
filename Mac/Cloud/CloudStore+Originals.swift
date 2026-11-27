import CryptoKit
import Foundation
import os

/// The one place Reel deletes a film he dropped in. Read this before changing anything here.
///
/// An original is deleted only when every one of these holds, checked in this order, and any failure leaves it untouched:
/// 1. He approved it in Reel Server (`isApproved`), and the file is exactly as it was when he did (size and dates:
///    `approvedStamp == originalStamp == FileStamp(path:)`). MD5 only proves Google's copy equals the file, not that the
///    file was finished: an unfinished download must never be uploaded and deleted (the Skyfall incident, 2026-11-22).
/// 2. Google's pieces cover the whole film, every piece exists, isn't in the Bin, and its MD5 and size equal ours.
/// 3. Samples of every piece read back from Google byte for byte the same as the file.
/// 4. No app is writing to the file, the upload didn't change during the check, and the file still has its stamp.
/// 5. The catalog saying the film is in Drive is on disk first. Then `delete(_:ifStill:inside:)` renames the file aside,
///    checks the stamp once more, and only then unlinks it; it refuses anything outside the drop folders.
/// He chose automatic permanent deletion after these checks. Never weaken them, and never test with his real films.
extension CloudStore {
    // MARK: Check, then delete the original

    func checkAndDeleteOriginal(_ id: UInt64) async throws {
        guard let film = film(id), let remote = film.remote,
              let path = film.originalPath, let stamp = film.originalStamp else { return }
        jobs[id] = CloudJob(kind: .checking)
        updateActivity()
        guard film.isApproved else {
            throw CloudError("This film hasn’t been approved, so Reel didn’t delete it.")
        }
        guard stamp.size == film.size, FileStamp(path: path) == stamp else {
            throw CloudError("The original changed, so Reel didn’t delete it.")
        }
        guard remote.covers(film.size) else {
            throw CloudError("Google’s pieces don’t add up to the whole film. The original is untouched.")
        }

        let sizes = remote.pieces.map(\.size)
        let hashes = try await Task.detached(priority: .utility) { [weak self] in
            var shown = 0.0
            return try CloudFiles.digests(path, pieces: sizes) { fraction in
                guard fraction - shown >= 0.02 else { return }
                shown = fraction
                Task { @MainActor in
                    if self?.jobs[id]?.kind == .checking { self?.jobs[id]?.progress = fraction }
                }
            }
        }.value
        guard hashes.pieces.count == remote.pieces.count else {
            throw CloudError("Not every piece was checked. The original is untouched.")
        }

        for (index, piece) in remote.pieces.enumerated() {
            let copy: DriveFile
            do {
                copy = try await drive.file(piece.id)
            } catch let error as DriveError where error.status == 404 {
                forgetUpload(piece, of: id)
                throw CloudError("The film is missing from Google Drive, so it will upload again. The original is untouched.")
            }
            if copy.trashed == true {
                forgetUpload(piece, of: id)
                throw CloudError("The film is in Drive’s Bin, so it will upload again. The original is untouched.")
            }
            guard let theirHash = copy.md5Checksum, let theirSize = copy.byteCount else {
                throw CloudError("Google hasn’t reported a checksum yet. The original is untouched.")
            }
            guard theirHash.lowercased() == hashes.pieces[index], theirSize == piece.size else {
                mismatches[id, default: 0] += 1
                edit(id) { $0.verified = false }
                if mismatches[id]! < 3 {
                    try await drive.trash(piece.id)
                    forgetUpload(piece, of: id)
                } else {
                    retryAfter[id] = .distantFuture
                }
                throw CloudError("Google’s copy didn’t match. The original is untouched.")
            }
        }

        // A matching checksum doesn't prove Google will serve the file back, so fetch some of every piece.
        let sample = Int(min(1 << 20, film.size))
        let last = film.size - Int64(sample)
        let offsets = Set([0, last / 2, last] + remote.pieces.map { min($0.offset, last) })
        for offset in offsets.sorted() {
            let theirs = try await drive.read(remote, offset: offset, count: sample)
            let ours = try await Task.detached { try CloudFiles.read(path, offset: offset, count: sample) }.value
            guard theirs == ours else { throw CloudError("A part read back from Google didn’t match. The original is untouched.") }
        }

        let original = URL(fileURLWithPath: path)
        if await Task.detached(operation: { CloudFiles.isBeingWritten(original) }).value {
            throw CloudError("Another app is writing to the original, so Reel didn’t delete it.")
        }
        try Task.checkCancellation()
        guard let index = films.firstIndex(where: { $0.id == id }), films[index].remote == remote,
              films[index].approvedStamp == stamp else {
            throw CloudError("The upload changed during the check, so Reel didn’t delete the original.")
        }
        guard FileStamp(path: path) == stamp else {
            throw CloudError("The original changed during the check, so Reel didn’t delete it.")
        }
        films[index].verified = true
        films[index].md5 = hashes.whole
        films[index].source = .stream
        // The record of the Drive copy must be on disk before the original goes.
        try save()
        publishRoutes()
        try Self.delete(path, ifStill: stamp, inside: isInside(path, paths.shows) ? paths.shows : paths.drop)
        log.notice("Verified in Drive; deleted original \(path, privacy: .private)")
        edit(id) { $0.originalPath = nil; $0.originalStamp = nil }
    }

    func forgetUpload(_ piece: RemoteFile.Piece, of id: UInt64) {
        edit(id) { film in
            film.verified = false
            if film.driveID == piece.id {
                film.driveID = nil
                film.uploaded = nil
            } else if let index = film.parts?.firstIndex(where: { $0.driveID == piece.id }) {
                film.parts?[index].reset()
            }
        }
    }

    /// Renames first, so a file that appears at the same path meanwhile can't be the one that's deleted.
    func isInside(_ path: String, _ root: URL) -> Bool {
        let base = root.resolvingSymlinksInPath().path
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path.hasPrefix(base + "/")
    }

    nonisolated static func delete(_ path: String, ifStill stamp: FileStamp, inside root: URL) throws {
        let folder = URL(fileURLWithPath: path).deletingLastPathComponent().resolvingSymlinksInPath().path
        let base = root.resolvingSymlinksInPath().path
        guard folder == base || folder.hasPrefix(base + "/") else {
            throw CloudError("That file is outside the drop folder, so Reel won’t delete it.")
        }
        let doomed = folder + "/.reel-verified-\(UUID().uuidString)"
        guard rename(path, doomed) == 0 else { throw CloudError("Reel couldn’t remove the original.") }
        guard FileStamp(path: doomed) == stamp else {
            _ = renamex_np(doomed, path, UInt32(RENAME_EXCL))
            throw CloudError("The original changed, so Reel didn’t delete it.")
        }
        guard unlink(doomed) == 0 else {
            _ = renamex_np(doomed, path, UInt32(RENAME_EXCL))
            throw CloudError("Reel couldn’t delete the original.")
        }
    }
}

import CryptoKit
import Foundation
import os

/// Playing from Drive, downloading to this Mac, offloading and removing.
extension CloudStore {
    // MARK: Watching

    /// Called as a film is selected to play.
    func prepare(_ id: UInt64, source: PlaybackSource) throws {
        guard let film = film(id) else { throw CloudError("That film isn’t in the library.") }
        guard film.verified else { return } // still played from the drop folder
        switch source {
        case .mac:
            guard film.downloaded, FileStamp(path: downloadURL(id).path)?.size == film.size else {
                edit(id) { $0.downloaded = false; $0.source = .stream }
                throw CloudError("The film isn’t downloaded on your Mac.")
            }
        case .stream:
            guard connected else { throw CloudError("Reel Server isn’t signed in to Google Drive.") }
        }
        edit(id) { $0.source = source }
        // Watching something else makes room, but doesn't cancel a download that's on its way.
        for other in films where other.id != id && other.downloaded {
            offload(other.id)
        }
    }

    func download(_ id: UInt64) throws {
        guard let film = film(id), film.verified, film.remote != nil else {
            throw CloudError("The film is still on your Mac, so there’s nothing to download.")
        }
        guard !film.downloaded, downloadTasks[id] == nil else { return }
        guard connected else { throw CloudError("Reel Server isn’t signed in to Google Drive.") }

        let playing = namesPlaying()
        let others = films.filter { $0.id != id && $0.verified }
        let reclaimable = others
            .filter { $0.downloaded && !playing.contains(diskName($0)) }
            .reduce(0) { $0 + $1.size }
            + others.reduce(0) { $0 + (FileStamp(path: partialURL($1.id).path)?.size ?? 0) }
        let needed = film.size - (FileStamp(path: partialURL(id).path)?.size ?? 0) + Self.spaceMargin
        let available = CloudFiles.freeSpace(at: paths.downloads) + reclaimable
        // Check before offloading, so a download that can't fit doesn't cost the film already here.
        guard available >= needed else {
            throw CloudError("Not enough space on your Mac: this needs \(needed.formatted(.byteCount(style: .file))) and \(available.formatted(.byteCount(style: .file))) can be freed. You can still stream it.")
        }
        offloadOthers(keeping: id)
        errors[id] = nil
        jobs[id] = CloudJob(kind: .downloading)
        downloadTasks[id] = Task { [weak self] in
            do {
                try await self?.runDownload(film)
            } catch {
                self?.report(error, for: id)
            }
            guard let self else { return }
            self.jobs[id] = nil
            self.downloadTasks[id] = nil
            self.updateActivity()
        }
        updateActivity()
    }

    func runDownload(_ film: CloudFilm) async throws {
        guard let remote = film.remote else { return }
        let partial = partialURL(film.id)
        let drive = self.drive
        var hasher = Insecure.MD5()
        var offset: Int64 = 0
        if let existing = FileStamp(path: partial.path), existing.size <= film.size {
            hasher = try await Task.detached { try CloudFiles.md5(partial.path) }.value
            offset = existing.size
        } else {
            try Data().write(to: partial)
        }
        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }
        try handle.seekToEnd()

        let rate = RateMeter(done: offset, total: film.size)
        while offset < film.size {
            try Task.checkCancellation()
            let base = offset
            let parts = try await withThrowingTaskGroup(of: (Int, Data).self) { group -> [Data] in
                for part in 0..<Self.downloadStreams {
                    let start = base + Int64(part * Self.downloadChunk)
                    guard start < film.size else { break }
                    let count = Int(min(Int64(Self.downloadChunk), film.size - start))
                    group.addTask { (part, try await drive.read(remote, offset: start, count: count)) }
                }
                var received: [(Int, Data)] = []
                for try await part in group { received.append(part) }
                return received.sorted { $0.0 < $1.0 }.map(\.1)
            }
            let soFar = hasher
            hasher = try await Task.detached {
                var updated = soFar
                for data in parts {
                    try handle.write(contentsOf: data)
                    updated.update(data: data)
                }
                return updated
            }.value
            offset += parts.reduce(0) { $0 + Int64($1.count) }
            jobs[film.id] = rate.job(.downloading, done: offset)
        }
        try handle.synchronize()
        if let expected = film.md5?.lowercased(), expected != CloudFiles.hex(hasher) {
            try FileManager.default.removeItem(at: partial)
            throw CloudError("The download was damaged. Try again.")
        }
        if film.md5 == nil, remote.pieces.count > 1 {
            // A catalog rebuilt from Drive knows each piece's checksum, but not the whole film's.
            let sizes = remote.pieces.map(\.size)
            let ours = try await Task.detached { try CloudFiles.digests(partial.path, pieces: sizes).pieces }.value
            for (index, piece) in remote.pieces.enumerated() {
                let theirs = try await drive.file(piece.id).md5Checksum
                guard theirs?.lowercased() == ours[index] else {
                    try FileManager.default.removeItem(at: partial)
                    throw CloudError("The download was damaged. Try again.")
                }
            }
        }
        guard self.film(film.id)?.verified == true else { throw CancellationError() }
        let final = downloadURL(film.id)
        if FileManager.default.fileExists(atPath: final.path) { try FileManager.default.removeItem(at: final) }
        try FileManager.default.moveItem(at: partial, to: final)
        edit(film.id) { $0.downloaded = true; $0.source = .mac }
    }

    func cancelDownload(_ id: UInt64) {
        downloadTasks[id]?.cancel()
        removeIfPresent(partialURL(id))
        errors[id] = nil
    }

    func offload(_ id: UInt64) {
        guard let film = film(id), film.verified, !namesPlaying().contains(diskName(film)) else { return }
        downloadTasks[id]?.cancel()
        removeIfPresent(downloadURL(id))
        removeIfPresent(partialURL(id))
        if film.downloaded { edit(id) { $0.downloaded = false; $0.source = .stream } }
    }

    func offloadOthers(keeping id: UInt64) {
        for other in films where other.id != id && other.verified {
            offload(other.id)
        }
    }

    /// Removes a film from the library. Both copies stay recoverable: Drive's Bin and the Mac's Trash.
    func remove(_ id: UInt64) async throws {
        guard let film = film(id) else { return }
        guard !namesPlaying().contains(diskName(film)) else { throw CloudError("Stop playing the film first.") }
        // A default version hands the group to the next version; with none, its extras go with it.
        if film.versionOf == nil, film.extraOf == nil {
            if let next = films.first(where: { $0.versionOf == id }) {
                makeDefault(next.id)
                separate(id)
            } else {
                for extra in extras(of: id) { try await remove(extra.id) }
            }
        }
        if workingOn == id {
            worker?.cancel()
            await worker?.value
        }
        guard let film = self.film(id) else { return }
        for driveID in [film.driveID].compactMap({ $0 }) + (film.parts ?? []).compactMap(\.driveID) {
            try await drive.trash(driveID)
            disk.forget(driveID)
        }
        if let path = film.originalPath, FileManager.default.fileExists(atPath: path) {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
        }
        downloadTasks[id]?.cancel()
        for url in [downloadURL(id), partialURL(id), bitrateURL(id)] { removeIfPresent(url) }
        errors[id] = nil
        films.removeAll { $0.id == id }
        commitList()
        onRemoved(id)
    }
}

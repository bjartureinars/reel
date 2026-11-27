import CryptoKit
import Foundation
import os

/// Measure, then upload (whole, or in 1 GB parts with Faster Uploads).
extension CloudStore {
    // MARK: Pipeline: measure → upload → check → delete original

    func startNextJob() {
        guard worker == nil else { return }
        let waiting = films.filter { film in
            film.originalPath != nil && film.isApproved && (retryAfter[film.id] ?? .distantPast) < Date()
                && (connected || (!film.verified && !measured.contains(film.id)))
        }
        guard let next = waiting.first else { return }
        workingOn = next.id
        worker = Task { [weak self] in
            await self?.process(next.id)
            guard let self else { return }
            self.jobs[next.id] = nil
            self.workingOn = nil
            self.worker = nil
            self.updateActivity()
            if !Task.isCancelled { self.startNextJob() }
        }
        updateActivity()
    }

    func process(_ id: UInt64) async {
        do {
            guard let film = film(id), film.isApproved, let path = film.originalPath else { return }
            let original = URL(fileURLWithPath: path)
            if await Task.detached(operation: { CloudFiles.isBeingWritten(original) }).value {
                throw CloudError("Another app is writing to this film, so Reel hasn’t uploaded or deleted it.")
            }
            if !measured.contains(id) { await measure(film) }
            guard connected else { return }
            // Either method returns early when the other one should take over.
            while let current = self.film(id), current.remote == nil {
                try Task.checkCancellation()
                if shouldUploadInParts(current) { try await uploadInParts(id) } else { try await upload(id) }
            }
            try await checkAndDeleteOriginal(id)
            await discardUnusedUpload(id)
            errors[id] = nil
            quota = try? await drive.quota()
        } catch {
            report(error, for: id)
        }
    }

    func measure(_ film: CloudFilm) async {
        let output = bitrateURL(film.id)
        if !FileManager.default.fileExists(atPath: output.path), let path = film.originalPath, let probe = ffprobe() {
            jobs[film.id] = CloudJob(kind: .measuring)
            updateActivity()
            let values = try? await Task.detached(priority: .utility) {
                try CloudFiles.measureBitrate(of: path, ffprobe: probe)
            }.value
            if let values, let data = try? JSONEncoder().encode(values) {
                attempt("Saving the bitrate graph") { try data.write(to: output, options: .atomic) }
            }
            jobs[film.id] = nil
        }
        measured.insert(film.id)
    }

    func upload(_ id: UInt64) async throws {
        guard let film = film(id), let path = film.originalPath, let stamp = film.originalStamp else { return }
        jobs[id] = CloudJob(kind: .uploading)
        updateActivity()
        var session: URL
        var offset: Int64 = 0
        var resumed: DriveClient.UploadState = .expired
        if let saved = film.uploadURL { resumed = try await drive.uploadState(saved, size: film.size) }
        switch resumed {
        case .done(let file):
            edit(id) { $0.driveID = file.id; $0.uploadURL = nil }
            return
        case .received(let count):
            session = film.uploadURL!
            offset = count
            edit(id) { $0.uploaded = count }
        case .expired:
            let current = try await drive.quota()
            quota = current
            if let free = current.free, free < film.size {
                throw CloudError("Google Drive has \(free.formatted(.byteCount(style: .file))) free; this film needs \(film.size.formatted(.byteCount(style: .file))).")
            }
            if driveFolder == nil { driveFolder = try await drive.folder() }
            session = try await drive.beginUpload(
                name: film.name, size: film.size, parent: driveFolder!,
                properties: ["reel": "film", "id": "\(film.id)", "folder": film.folder,
                             "modified": "\(Int64(film.modified.timeIntervalSince1970))"])
            let url = session
            edit(id) { $0.uploadURL = url; $0.uploaded = 0 }
        }

        let rate = RateMeter(done: offset, total: film.size)
        while true {
            try Task.checkCancellation()
            guard FileStamp(path: path) == stamp else { throw CloudError("The file changed while it was uploading.") }
            if let current = self.film(id), shouldUploadInParts(current) { return }
            let from = offset
            let count = Int(min(Int64(Self.uploadChunk), film.size - from))
            let state: DriveClient.UploadState
            if count > 0 {
                let data = try await Task.detached { try CloudFiles.read(path, offset: from, count: count) }.value
                state = try await drive.sendChunk(session, data: data, offset: from, size: film.size)
            } else {
                state = try await drive.uploadState(session, size: film.size)
            }
            switch state {
            case .done(let file):
                edit(id) { $0.driveID = file.id; $0.uploadURL = nil }
                return
            case .received(let total):
                guard total > from || count == 0 else { throw CloudError("The upload stopped making progress.") }
                if count == 0 { try await Task.sleep(nanoseconds: 2_000_000_000) }
                offset = total
                edit(id) { $0.uploaded = total }
                jobs[id] = rate.job(.uploading, done: total)
            case .expired:
                edit(id) { $0.uploadURL = nil; $0.uploaded = nil }
                throw CloudError("The upload expired and will start again.")
            }
        }
    }

    // MARK: Fast upload

    /// Drive takes a file over one connection only, so a fast upload sends consecutive pieces as separate files.
    func shouldUploadInParts(_ film: CloudFilm) -> Bool {
        guard fasterUploads, film.driveID == nil, film.size > 2 * partSize else { return false }
        let single = film.uploaded ?? 0
        let pieces = film.parts?.reduce(0) { $0 + $1.received } ?? 0
        return pieces >= single && pieces > 0 || Double(single) < Self.switchLimit * Double(film.size)
    }

    /// Whether the switch can still change how this film uploads.
    func canSpeedUp(_ film: CloudFilm) -> Bool {
        guard !film.verified, film.driveID == nil, film.size > 2 * partSize else { return false }
        return film.parts != nil || Double(film.uploaded ?? 0) < Self.switchLimit * Double(film.size)
    }

    func uploadInParts(_ id: UInt64) async throws {
        guard var film = film(id), let path = film.originalPath, let stamp = film.originalStamp else { return }
        jobs[id] = CloudJob(kind: .uploading, connections: DriveClient.laneCount)
        updateActivity()
        if film.parts == nil {
            let planned = stride(from: Int64(0), to: film.size, by: Int64.Stride(partSize)).map {
                UploadPart(offset: $0, size: min(partSize, film.size - $0))
            }
            edit(id) { $0.parts = planned; $0.partSet = UUID().uuidString }
            film = self.film(id) ?? film
        }
        let sent = film.parts?.reduce(0) { $0 + $1.received } ?? 0
        let current = try await drive.quota()
        quota = current
        if let free = current.free, free < film.size - sent {
            throw CloudError("Google Drive has \(free.formatted(.byteCount(style: .file))) free; this film needs \((film.size - sent).formatted(.byteCount(style: .file))).")
        }
        if driveFolder == nil { driveFolder = try await drive.folder() }
        let folder = driveFolder!
        let rate = RateMeter(done: sent, total: film.size)
        claimed[id] = []
        defer { claimed[id] = nil }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for lane in 0..<DriveClient.laneCount {
                group.addTask { try await self.runLane(lane, id: id, path: path, stamp: stamp, folder: folder, rate: rate) }
            }
            try await group.waitForAll()
        }
    }

    var activeLanes: Int {
        namesPlaying().isEmpty ? DriveClient.laneCount : Self.lanesWhilePlaying
    }

    func runLane(_ lane: Int, id: UInt64, path: String, stamp: FileStamp, folder: String,
                         rate: RateMeter) async throws {
        var failures = 0
        while fasterUploads {
            try Task.checkCancellation()
            guard let parts = film(id)?.parts, parts.contains(where: { $0.driveID == nil }) else { return }
            guard lane < activeLanes,
                  let index = parts.indices.first(where: { parts[$0].driveID == nil && claimed[id]?.contains($0) != true })
            else {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                continue
            }
            claimed[id]?.insert(index)
            defer { claimed[id]?.remove(index) }
            do {
                try await sendPart(index, lane: lane, id: id, path: path, stamp: stamp, folder: folder, rate: rate)
                failures = 0
            } catch {
                // A dropped connection on one lane mustn't stop the other seven.
                let passing = (error as? DriveError)?.isTransient ?? (error as? URLError).map { $0.code != .cancelled } ?? false
                failures += 1
                guard passing, failures < 6 else { throw error }
                try await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    /// Sends one piece until it's done, or until this lane should stand down.
    func sendPart(_ index: Int, lane: Int, id: UInt64, path: String, stamp: FileStamp, folder: String,
                          rate: RateMeter) async throws {
        guard let film = film(id), let set = film.partSet, let parts = film.parts else { return }
        let part = parts[index]
        func finished(_ file: DriveFile) {
            edit(id) {
                $0.parts?[index].driveID = file.id
                $0.parts?[index].uploadURL = nil
                $0.parts?[index].received = part.size
            }
        }

        var state: DriveClient.UploadState = .expired
        if let saved = part.uploadURL { state = try await drive.uploadState(saved, size: part.size, lane: lane) }
        let session: URL
        var offset: Int64 = 0
        switch state {
        case .done(let file):
            return finished(file)
        case .received(let count):
            session = part.uploadURL!
            offset = count
        case .expired:
            let digits = "\(parts.count)".count
            let number = String(format: "%0\(digits)d", index + 1)
            session = try await drive.beginUpload(
                name: "\(film.name).part\(number)of\(parts.count)", size: part.size, parent: folder,
                properties: ["reel": "part", "id": "\(film.id)", "set": set, "folder": film.folder,
                             "offset": "\(part.offset)", "count": "\(parts.count)", "total": "\(film.size)",
                             "modified": "\(Int64(film.modified.timeIntervalSince1970))"])
            let url = session
            edit(id) { $0.parts?[index].uploadURL = url; $0.parts?[index].received = 0 }
        }

        while fasterUploads, lane < activeLanes {
            try Task.checkCancellation()
            guard FileStamp(path: path) == stamp else { throw CloudError("The file changed while it was uploading.") }
            let from = offset
            let count = Int(min(Int64(Self.partChunk), part.size - from))
            let result: DriveClient.UploadState
            if count > 0 {
                let data = try await Task.detached { try CloudFiles.read(path, offset: part.offset + from, count: count) }.value
                result = try await drive.sendChunk(session, data: data, offset: from, size: part.size, lane: lane)
            } else {
                result = try await drive.uploadState(session, size: part.size, lane: lane)
            }
            switch result {
            case .done(let file):
                finished(file)
            case .received(let total):
                guard total > from || count == 0 else { throw CloudError("The upload stopped making progress.") }
                if count == 0 { try await Task.sleep(nanoseconds: 2_000_000_000) }
                offset = total
                edit(id) { $0.parts?[index].received = total }
            case .expired:
                edit(id) { $0.parts?[index].reset() }
                return
            }
            let done = self.film(id)?.parts?.reduce(0) { $0 + $1.received } ?? 0
            var job = rate.job(.uploading, done: done)
            job.connections = activeLanes
            jobs[id] = job
            if case .done = result { return }
        }
    }

    /// Once verified, clears away whatever the other upload method left behind.
    func discardUnusedUpload(_ id: UInt64) async {
        guard let film = film(id), film.verified else { return }
        if film.driveID != nil, let parts = film.parts {
            for piece in parts.compactMap(\.driveID) {
                do { try await drive.trash(piece) } catch { return }
            }
            edit(id) { $0.parts = nil; $0.partSet = nil }
        }
        edit(id) { $0.uploadURL = nil; $0.uploaded = nil }
    }
}

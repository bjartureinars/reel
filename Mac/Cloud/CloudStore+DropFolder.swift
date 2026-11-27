import CryptoKit
import Foundation
import os

/// The drop folders: what is in them, and his approval, the only way a file gets in.
extension CloudStore {
    // MARK: Drop folder

    func scanDropFolder() async {
        guard !scanning else { return }
        scanning = true
        defer { scanning = false }
        let root = paths.drop, shows = paths.shows
        var found = await Task.detached { DropInspector.scan(root) + DropInspector.scan(shows, shows: true) }.value
        let now = Date()
        var seen: [String: (stamp: FileStamp, since: Date)] = [:]
        for item in found {
            guard let stamp = item.stamp else { continue }
            let before = unchangedSince[item.path]
            seen[item.path] = before?.stamp == stamp ? before : (stamp, now)
        }
        unchangedSince = seen

        for index in found.indices where found[index].state == .ready {
            let item = found[index]
            guard let stamp = item.stamp, let since = seen[item.path]?.since else { continue }
            if now.timeIntervalSince(since) < settleTime || abs(now.timeIntervalSince(stamp.modified)) < quietTime {
                found[index].state = .waiting("It changed recently, so Reel is waiting to see that it has stopped.")
                continue
            }
            let url = URL(fileURLWithPath: item.path)
            if await Task.detached(operation: { CloudFiles.isBeingWritten(url) }).value {
                found[index].state = .waiting("Another app is still writing it.")
            } else if let result = inspected[item.path], result.stamp == stamp {
                if let problem = result.problem { found[index].state = .blocked(problem) }
            } else {
                inspect(item.path, stamp)
                if let inspecting, inspecting.path == item.path {
                    found[index].state = .waiting("Checking for gaps, \(Int(inspecting.progress * 100))%")
                } else {
                    found[index].state = .waiting("Waiting to be checked for gaps.")
                }
            }
        }

        // No awaits from here on, so an approval can't land between reading the catalog and changing it.
        var changed = false
        var dropped: [UInt64] = []
        for index in films.indices {
            let film = films[index]
            guard let path = film.originalPath, workingOn != film.id else { continue }
            let current = FileStamp(path: path)
            if current == film.originalStamp { continue }
            if film.verified {
                films[index].originalPath = nil
                films[index].originalStamp = nil
                changed = true
            } else if current == nil, let moved = found.first(where: { $0.stamp != nil && $0.stamp == film.originalStamp }) {
                // Renamed or moved within the drop folder: still the file that was approved.
                films[index].originalPath = moved.path
                changed = true
            } else {
                // Changed or gone, so the OK no longer stands.
                dropped.append(film.id)
                changed = true
            }
        }
        if !dropped.isEmpty {
            do {
                try discard(dropped)
            } catch {
                problem = "Reel couldn’t save its catalog: \(error.localizedDescription)"
                return
            }
        }

        let known = Set(films.compactMap(\.originalPath))
        let waiting = found.filter { !known.contains($0.path) }
        if waiting != pending { pending = waiting }
        if changed { commitList() }
    }

    /// One whole-file read at a time.
    func inspect(_ path: String, _ stamp: FileStamp) {
        guard inspector == nil else { return }
        inspecting = (path, 0)
        inspector = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { [weak self] () -> Result<String?, Error> in
                var shown = 0.0
                return Result {
                    try DropInspector.gap(in: path) { fraction in
                        guard fraction - shown >= 0.02 else { return }
                        shown = fraction
                        Task { @MainActor in
                            if self?.inspecting?.path == path { self?.inspecting?.progress = fraction }
                        }
                    }
                }
            }.value
            guard let self else { return }
            self.inspecting = nil
            self.inspector = nil
            guard !Task.isCancelled, FileStamp(path: path) == stamp else { return }
            switch result {
            case .success(let problem): self.inspected[path] = (stamp, problem)
            case .failure(let error): self.inspected[path] = (stamp, "Reel couldn’t read it: \(error.localizedDescription)")
            }
            await self.scanDropFolder()
        }
    }

    /// The one way into the upload-and-delete pipeline. Called only from the button in Reel Server.
    func approve(_ item: PendingFilm) throws {
        guard let current = pending.first(where: { $0.path == item.path }), current.state == .ready,
              let stamp = item.stamp, current.stamp == stamp, FileStamp(path: item.path) == stamp,
              let check = inspected[item.path], check.stamp == stamp, check.problem == nil,
              !films.contains(where: { $0.originalPath == item.path }) else {
            throw CloudError("That file changed or hasn’t passed Reel’s checks, so nothing was uploaded.")
        }
        var film = CloudFilm(id: UInt64.random(in: 1 << 32..<1 << 62), folder: item.folder,
                             name: uniqueName(item.name, in: item.folder), size: stamp.size, modified: stamp.modified,
                             originalPath: item.path, originalStamp: stamp)
        film.approvedStamp = stamp
        films.append(film)
        pending.removeAll { $0.path == item.path }
        commitList()
        startNextJob()
    }

    /// Takes unverified films out of the library. Files on the Mac and in Drive are left as they are.
    func discard(_ ids: [UInt64]) throws {
        discarded.formUnion(ids)
        // On disk before the catalog forgets them, or a sync could bring them back as verified films.
        try JSONEncoder().encode(discarded).write(to: discardedURL, options: .atomic)
        films.removeAll { ids.contains($0.id) }
        for id in ids {
            errors[id] = nil
            retryAfter[id] = nil
        }
    }
}

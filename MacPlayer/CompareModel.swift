import AVFoundation
import Combine
import SwiftUI

/// One of the two versions being compared: its own engine, local stream and AVPlayer, as the normal player has.
@MainActor
final class CompareLane: ObservableObject, Identifiable {
    let id: Int
    let film: Film
    @Published private(set) var player: AVPlayer?
    @Published private(set) var video: Track?
    @Published private(set) var sound: Track?
    @Published private(set) var problem: String?
    @Published private(set) var filmMegabits: Double = 0
    @Published private(set) var networkMegabits: Double = 0

    private var server: StreamServer?
    private var throughput: Throughput?

    init(id: Int, film: Film) {
        self.id = id
        self.film = film
    }

    /// "4K" or "Blu-ray": the name Reel Server gave the version, else its title.
    var name: String { film.info?.filmVersion?.label ?? film.title }

    /// What the picture actually is, read from the file: "2160p HEVC Dolby Vision 8.1".
    var pictureLine: String {
        guard let video else { return "" }
        let size = video.width >= 3200 ? "2160p" : video.width >= 1900 ? "1080p" : "\(video.height)p"
        let range = video.dolbyVision == 8 ? " Dolby Vision 8.1" : video.dolbyVision == 5 ? " Dolby Vision"
            : video.range == ReelRangePQ ? " HDR10" : video.range == ReelRangeHLG ? " HLG" : " SDR"
        return "\(size) \(video.codec == "hevc" ? "HEVC" : video.codec == "h264" ? "H.264" : video.codec.uppercased())\(range)"
    }

    var duration: Double { player?.currentItem?.duration.seconds.nonNaN ?? film.seconds ?? 0 }

    func open(at seconds: Double, library: Library, downloads: DownloadCenter) async throws {
        let reader: FilmReader
        if let download = downloads.download(for: film), download.state == .ready {
            let local = download.reader
            throughput = local.throughput
            reader = local
        } else {
            let drive = DriveReader(remote: film.remote, size: film.size, drive: library.drive)
            throughput = drive.throughput
            reader = drive
        }
        let languages = film.info?.languages ?? [:]
        let media = try await Task.detached(priority: .userInitiated) {
            try EngineMedia(reader: reader, languages: languages)
        }.value
        try Task.checkCancellation()
        video = media.video
        let preferred = UserDefaults.standard.string(forKey: "soundLanguage")
        let sound = media.sounds.first { $0.language == preferred && !$0.isCommentary } ?? media.defaultSound
        self.sound = sound
        let server = StreamServer(media: media)
        server.onError = { [weak self] error in
            Task { @MainActor in if self?.problem == nil { self?.problem = error.localizedDescription } }
        }
        try await server.start()
        self.server = server
        let url = try await Task.detached { try server.select(sound: sound?.id, subtitles: nil, from: seconds) }.value
        try Task.checkCancellation()

        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 30
        let player = AVPlayer(playerItem: item)
        player.allowsExternalPlayback = false
        // Both players are started together at an exact host time, which needs this off.
        player.automaticallyWaitsToMinimizeStalling = false
        player.isMuted = true
        self.player = player
        try await ready(item)
    }

    /// Waits for AVPlayer to accept the stream.
    private func ready(_ item: AVPlayerItem) async throws {
        while item.status == .unknown {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        if item.status == .failed { throw item.error ?? CompareError.unplayable }
    }

    /// Enough is loaded around the current time to play on without stopping.
    var hasBuffer: Bool {
        guard let item = player?.currentItem else { return false }
        if item.isPlaybackBufferFull || item.isPlaybackLikelyToKeepUp { return true }
        let now = item.currentTime().seconds
        return item.loadedTimeRanges.map(\.timeRangeValue).contains { $0.start.seconds <= now + 0.1 && $0.end.seconds >= now + 4 }
    }

    func updateStats() {
        let film = server?.stats.filmMegabits ?? 0
        let network = throughput?.megabitsPerSecond ?? 0
        if abs(film - filmMegabits) > 0.5 { filmMegabits = film }
        if abs(network - networkMegabits) > 0.5 { networkMegabits = network }
    }

    func close() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        server?.stop()
        server = nil
    }
}

enum CompareError: LocalizedError {
    case unplayable
    var errorDescription: String? { "This version couldn’t be played." }
}

/// Two versions of a film, one above the other, kept frame-locked: both are started at the same host time, re-locked
/// after either one runs out of picture, and lined up exactly whenever playback pauses, so still frames compare 1:1.
@MainActor
final class CompareModel: ObservableObject {
    static let shared = CompareModel()

    @Published private(set) var lanes: [CompareLane] = []
    @Published var isPresented = false
    @Published private(set) var preparing = false
    @Published private(set) var buffering = false
    @Published private(set) var playing = false
    @Published private(set) var time: Double = 0
    @Published private(set) var duration: Double = 0
    @Published var problem: String?
    /// The lane the sound comes from (0 top, 1 bottom).
    @Published private(set) var soundLane = 0
    /// How far the bottom version's picture is shifted against the top's, for releases that start a little apart.
    @Published private(set) var offset: Double = 0

    private var wantsToPlay = false
    private var generation = 0
    private var monitor: Timer?
    private var opening: Task<Void, Never>?
    private var awake: NSObjectProtocol?

    /// One frame of the top version (24p unless the file says otherwise).
    private var frame: Double {
        let rate = lanes.first?.player?.currentItem?.tracks
            .first { $0.assetTrack?.mediaType == .video }?.currentVideoFrameRate ?? 0
        return rate > 1 ? 1 / Double(rate) : 1 / 23.976
    }

    func open(top: Film, bottom: Film, soundFrom: Int, at seconds: Double) {
        close()
        AppModel.shared.player.isPresented = false   // one film at a time
        lanes = [CompareLane(id: 0, film: top), CompareLane(id: 1, film: bottom)]
        soundLane = soundFrom
        offset = UserDefaults.standard.double(forKey: offsetKey(top, bottom))
        time = seconds
        duration = min(top.seconds ?? 0, bottom.seconds ?? 0)
        preparing = true
        problem = nil
        isPresented = true
        awake = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .userInitiated], reason: "Comparing versions")
        let library = AppModel.shared.library, downloads = AppModel.shared.downloads
        let lanes = self.lanes
        opening = Task {
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for lane in lanes {
                        let start = lane.id == 1 ? seconds + self.offset : seconds
                        group.addTask { try await lane.open(at: max(0, start), library: library, downloads: downloads) }
                    }
                    try await group.waitForAll()
                }
                try Task.checkCancellation()
                duration = lanes.map(\.duration).filter { $0 > 0 }.min() ?? duration
                applySound()
                preparing = false
                startMonitor()
                wantsToPlay = true
                await lock(at: seconds)
            } catch is CancellationError {
            } catch {
                problem = (lanes.compactMap(\.problem).first) ?? error.localizedDescription
                preparing = false
            }
        }
    }

    // MARK: Controls

    func togglePlay() {
        if wantsToPlay { pause() } else { play() }
    }

    func play() {
        guard !preparing else { return }
        wantsToPlay = true
        Task { await lock(at: time) }
    }

    func pause() {
        wantsToPlay = false
        generation += 1
        lanes.forEach { $0.player?.pause() }
        playing = false
        buffering = false
        // Line the bottom up exactly with the top's frame, so a paused picture compares like for like.
        guard let top = lanes.first?.player else { return }
        let now = top.currentTime().seconds
        if now.isFinite { time = now }
        align(at: time)
    }

    func seek(to seconds: Double) {
        let target = min(max(0, seconds), max(duration - 1, 0))
        time = target
        if wantsToPlay {
            Task { await lock(at: target) }
        } else {
            generation += 1
            align(at: target)
        }
    }

    func skip(_ seconds: Double) { seek(to: time + seconds) }

    /// Moves both pictures one frame forward or back (pauses first).
    func step(_ frames: Int) {
        if wantsToPlay { pause() }
        seek(to: time + Double(frames) * frame)
    }

    func soundFrom(_ lane: Int) {
        soundLane = lane
        applySound()
    }

    /// Shifts the bottom picture against the top by whole frames; remembered for this pair of versions.
    func nudge(frames: Int) {
        offset += Double(frames) * frame
        if abs(offset) < 0.001 { offset = 0 }
        if lanes.count == 2 { UserDefaults.standard.set(offset, forKey: offsetKey(lanes[0].film, lanes[1].film)) }
        if wantsToPlay { Task { await lock(at: time) } } else { align(at: time) }
    }

    func resetOffset() {
        offset = 0
        nudge(frames: 0)
    }

    func swapSound() { soundFrom(soundLane == 0 ? 1 : 0) }

    // MARK: Keeping the two in step

    private func applySound() {
        for lane in lanes { lane.player?.isMuted = lane.id != soundLane }
    }

    private func laneTime(_ lane: CompareLane, _ seconds: Double) -> Double {
        lane.id == 1 ? max(0, seconds + offset) : seconds
    }

    private func align(at seconds: Double) {
        for lane in lanes {
            lane.player?.seek(to: CMTime(seconds: laneTime(lane, seconds), preferredTimescale: 90_000),
                              toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    /// Stops both, puts both on the same frame, waits until both have picture to play, then starts both at one
    /// host time. Called to start, after seeking, and when the two drift apart (one of them ran out of picture).
    private func lock(at seconds: Double) async {
        generation += 1
        let mine = generation
        let players = lanes.compactMap(\.player)
        guard players.count == 2 else { return }
        players.forEach { $0.pause() }
        playing = false
        buffering = true
        time = seconds
        await withTaskGroup(of: Void.self) { group in
            for lane in lanes {
                guard let player = lane.player else { continue }
                let target = CMTime(seconds: laneTime(lane, seconds), preferredTimescale: 90_000)
                group.addTask { @MainActor in
                    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { _ in done.resume() }
                    }
                }
            }
        }
        // Up to a minute for both to have a few seconds of picture.
        for _ in 0..<600 {
            guard mine == generation else { return }
            if lanes.allSatisfy(\.hasBuffer) { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard mine == generation else { return }
        for player in players {
            _ = await player.preroll(atRate: 1)
        }
        guard mine == generation, wantsToPlay else { buffering = false; return }
        let clock = CMClockGetHostTimeClock()
        let start = CMTimeAdd(CMClockGetTime(clock), CMTime(seconds: 0.2, preferredTimescale: 1_000_000_000))
        for lane in lanes {
            lane.player?.setRate(1, time: CMTime(seconds: laneTime(lane, seconds), preferredTimescale: 90_000), atHostTime: start)
        }
        buffering = false
        playing = true
    }

    private func startMonitor() {
        monitor?.invalidate()
        monitor = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    private func check() {
        lanes.forEach { $0.updateStats() }
        guard lanes.count == 2, let top = lanes[0].player, let bottom = lanes[1].player else { return }
        let a = top.currentTime().seconds, b = bottom.currentTime().seconds - offset
        guard a.isFinite, b.isFinite else { return }
        guard wantsToPlay, !buffering else { return }
        time = a
        if a >= duration - 0.5 { pause(); return }
        let stalled = top.rate == 0 || bottom.rate == 0
        // About two frames apart, or one stopped for lack of picture: lock again from the one that's behind.
        if stalled || abs(a - b) > 0.08 {
            Task { await lock(at: min(a, b)) }
        }
    }

    func close() {
        opening?.cancel()
        opening = nil
        generation += 1
        wantsToPlay = false
        monitor?.invalidate()
        monitor = nil
        lanes.forEach { $0.close() }
        lanes = []
        playing = false
        buffering = false
        preparing = false
        if let awake { ProcessInfo.processInfo.endActivity(awake) }
        awake = nil
    }

    private func offsetKey(_ a: Film, _ b: Film) -> String { "compare.offset.\(a.id).\(b.id)" }
}

private extension Double {
    var nonNaN: Double? { isFinite && self > 0 ? self : nil }
}

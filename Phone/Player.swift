import AVFoundation
import AVKit
import MediaPlayer
import SwiftUI
import os

private let log = Logger(subsystem: "com.bjartur.reel.phone", category: "player")

/// Where a play reads from.
enum PlaySource: Equatable {
    case stream
    case download(CopyQuality)

    var label: String {
        switch self {
        case .stream: return "Streaming from Google Drive"
        case .download(let quality): return quality == .original ? "On this iPhone" : "On this iPhone, \(quality.title)"
        }
    }
}

/// Runs one film: engine, local server, AVPlayer, progress, subtitles and the bitrate panel.
@MainActor
final class PlayerModel: ObservableObject {
    @Published private(set) var film: Film?
    @Published private(set) var source: PlaySource = .stream
    @Published private(set) var player: AVPlayer?
    @Published private(set) var preparing = false
    @Published private(set) var buffering = false
    @Published private(set) var playing = false
    @Published private(set) var time: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var sounds: [Track] = []
    @Published private(set) var subtitleTracks: [Track] = []
    @Published private(set) var sound: Track?
    @Published private(set) var subtitles: Track?
    @Published private(set) var video: Track?
    @Published private(set) var cues: [Cue] = []
    @Published private(set) var stats = PanelStats()
    @Published var problem: String?
    @Published var isPresented = false

    struct PanelStats: Equatable {
        var filmMegabits: Double = 0
        var networkMegabits: Double = 0
        var bufferSeconds: Double = 0
        var stalls = 0
    }

    private var media: EngineMedia?
    private var server: StreamServer?
    private var throughput: Throughput?
    private var timeObserver: Any?
    private var notifications: [NSObjectProtocol] = []
    private var statusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var ticker: Timer?
    private var lastSaved = Date.distantPast
    private weak var library: Library?
    private var opening: Task<Void, Never>?

    // MARK: Opening

    func play(_ film: Film, from seconds: Double, source: PlaySource, library: Library, downloads: DownloadCenter) {
        close()
        self.film = film
        self.source = source
        self.library = library
        duration = film.seconds ?? 0
        time = seconds
        preparing = true
        isPresented = true
        problem = nil
        var reader: FilmReader
        switch source {
        case .stream:
            #if DEBUG
            // Simulator testing only: read the film from a file on the Mac instead of Google Drive.
            if let path = ProcessInfo.processInfo.environment["REEL_FILE_\(film.id)"] {
                let local = LocalReader(parts: [.init(url: URL(fileURLWithPath: path), offset: 0, size: film.size)])
                throughput = local.throughput
                reader = local
                break
            }
            #endif
            let drive = DriveReader(remote: film.remote, size: film.size, drive: library.drive)
            throughput = drive.throughput
            reader = drive
        case .download:
            guard let download = downloads.download(for: film), download.state == .ready else {
                problem = "That download isn’t finished yet."
                preparing = false
                return
            }
            let local = download.reader
            throughput = local.throughput
            reader = local
        }
        let languages = film.info?.languages ?? [:]
        let wanted = Preferences.trackChoice(for: film.id)
        opening = Task {
            do {
                let media = try await Task.detached(priority: .userInitiated) {
                    try EngineMedia(reader: reader, languages: languages)
                }.value
                try Task.checkCancellation()
                self.media = media
                self.video = media.video
                self.sounds = media.sounds
                self.subtitleTracks = media.subtitles
                self.duration = media.duration
                let sound = wanted.sound.flatMap { id in media.sounds.first { $0.id == id } } ?? Self.preferredSound(media)
                let subtitles: Track?
                switch wanted.subtitles {
                case .off: subtitles = nil
                case .track(let id): subtitles = media.subtitles.first { $0.id == id } ?? Self.preferredSubtitles(media, sound: sound)
                case .unset: subtitles = Self.preferredSubtitles(media, sound: sound)
                }
                let server = StreamServer(media: media)
                server.onError = { [weak self] error in
                    Task { @MainActor in self?.engineFailed(error) }
                }
                try await server.start()
                self.server = server
                try await self.load(sound: sound, subtitles: subtitles, at: seconds)
            } catch is CancellationError {
            } catch {
                self.problem = error.localizedDescription
                self.preparing = false
            }
        }
    }

    private static func preferredSound(_ media: EngineMedia) -> Track? {
        let preferred = UserDefaults.standard.string(forKey: "soundLanguage")
        if let preferred, let match = media.sounds.first(where: { $0.language == preferred && !$0.isCommentary }) { return match }
        return media.defaultSound
    }

    private static func preferredSubtitles(_ media: EngineMedia, sound: Track?) -> Track? {
        let wanted = UserDefaults.standard.string(forKey: "subtitleLanguage") ?? ""
        if !wanted.isEmpty, let match = media.subtitles.first(where: { $0.language == wanted && !$0.isForced }) { return match }
        // Forced subtitles translate foreign-language scenes for the language being heard.
        if let language = sound?.language, let forced = media.subtitles.first(where: { $0.isForced && $0.language == language }) {
            return forced
        }
        return nil
    }

    private func load(sound: Track?, subtitles: Track?, at seconds: Double) async throws {
        guard let server else { return }
        preparing = true
        let url = try await Task.detached { try server.select(sound: sound?.id, subtitles: subtitles?.id, from: seconds) }.value
        self.sound = sound
        self.subtitles = subtitles
        log.notice("Playing sound \(sound?.id ?? -1) subtitles \(subtitles?.id ?? -1) from \(seconds)")

        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 40
        item.externalMetadata = metadata()
        let player = self.player ?? AVPlayer()
        player.allowsExternalPlayback = false
        player.automaticallyWaitsToMinimizeStalling = true
        player.replaceCurrentItem(with: item)
        if self.player == nil {
            self.player = player
            observe(player)
        }
        statusObservation = item.observe(\.status) { [weak self] item, _ in
            Task { @MainActor in self?.statusChanged(item, start: seconds) }
        }
    }

    private func statusChanged(_ item: AVPlayerItem, start: Double) {
        switch item.status {
        case .readyToPlay where preparing:
            preparing = false
            let begin = { [weak self] in
                self?.player?.play()
                self?.updateNowPlaying()
            }
            if start > 1 {
                player?.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero,
                             toleranceAfter: .zero) { _ in Task { @MainActor in begin() } }
            } else {
                begin()
            }
        case .failed:
            preparing = false
            problem = item.error?.localizedDescription ?? "The film couldn’t be played."
        default:
            break
        }
    }

    private func engineFailed(_ error: Error) {
        guard problem == nil else { return }
        if (error as? EngineError) != nil || player?.currentItem?.status == .failed { problem = error.localizedDescription }
    }

    private func observe(_ player: AVPlayer) {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        UIApplication.shared.isIdleTimerDisabled = true
        let periodic = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
        timeObserver = periodic
        timeControlObservation = player.observe(\.timeControlStatus) { [weak self] player, _ in
            Task { @MainActor in
                self?.playing = player.timeControlStatus != .paused
                self?.buffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                self?.updateNowPlaying()
                if player.timeControlStatus == .paused { self?.save(push: true) }
            }
        }
        let end = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, (note.object as? AVPlayerItem) === self.player?.currentItem else { return }
                self.save(push: true, finished: true)
                self.isPresented = false
            }
        }
        notifications.append(end)
        setUpRemoteCommands()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateStats() }
        }
    }

    private func tick(_ seconds: Double) {
        guard seconds.isFinite, !preparing else { return }
        time = seconds
        let showing = media?.cues.showing(at: seconds) ?? []
        #if DEBUG
        if Int(seconds * 4) % 20 == 0 { log.debug("t=\(seconds) cues \(showing.count)") }
        #endif
        if showing.map(\.start) != cues.map(\.start) || showing.count != cues.count { cues = showing }
        if Date().timeIntervalSince(lastSaved) > 15 { save(push: false) }
    }

    private func updateStats() {
        guard let item = player?.currentItem else { return }
        var next = stats
        next.filmMegabits = server?.stats.filmMegabits ?? 0
        next.networkMegabits = throughput?.megabitsPerSecond ?? 0
        let now = item.currentTime().seconds
        next.bufferSeconds = item.loadedTimeRanges.map(\.timeRangeValue)
            .first { $0.start.seconds <= now + 0.5 && $0.end.seconds >= now }.map { $0.end.seconds - now } ?? 0
        next.stalls = item.accessLog()?.events.reduce(0) { $0 + $1.numberOfStalls } ?? 0
        if next != stats { stats = next }
    }

    // MARK: Controls

    func togglePlay() {
        guard let player else { return }
        if player.timeControlStatus == .paused { player.play() } else { player.pause() }
    }

    func seek(to seconds: Double) {
        let target = min(max(0, seconds), max(duration - 1, 0))
        time = target
        player?.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        updateNowPlaying()
    }

    func skip(_ seconds: Double) { seek(to: time + seconds) }

    func choose(sound: Track?) {
        guard sound != self.sound else { return }
        reload(sound: sound, subtitles: subtitles)
    }

    func choose(subtitles: Track?) {
        guard subtitles != self.subtitles else { return }
        // Text and picture subtitles are drawn here, not by AVPlayer, but the engine only reads the chosen track.
        reload(sound: sound, subtitles: subtitles)
    }

    /// Only choices made in the menu are remembered, so the Settings languages apply until then.
    private func reload(sound: Track?, subtitles: Track?) {
        if let film { Preferences.setTrackChoice(for: film.id, sound: sound?.id, subtitles: subtitles?.id) }
        let at = time
        Task {
            do {
                try await load(sound: sound, subtitles: subtitles, at: at)
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    func save(push: Bool, finished: Bool = false) {
        guard let film, let library, duration > 0 else { return }
        lastSaved = Date()
        library.played(film, at: finished ? duration : time, duration: duration, push: push)
    }

    func close() {
        opening?.cancel()
        if film != nil, !preparing { save(push: true) }
        player?.pause()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        notifications.forEach(NotificationCenter.default.removeObserver)
        notifications = []
        statusObservation = nil
        timeControlObservation = nil
        ticker?.invalidate()
        ticker = nil
        server?.stop()
        server = nil
        media = nil
        player = nil
        cues = []
        film = nil
        preparing = false
        UIApplication.shared.isIdleTimerDisabled = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: Lock screen and Control Centre

    private func metadata() -> [AVMetadataItem] {
        guard let film else { return [] }
        func item(_ id: AVMetadataIdentifier, _ value: NSCopying & NSObjectProtocol) -> AVMetadataItem {
            let m = AVMutableMetadataItem()
            m.identifier = id
            m.value = value
            m.extendedLanguageTag = "und"
            return m
        }
        var out = [item(.commonIdentifierTitle, film.title as NSString)]
        if let overview = film.info?.overview { out.append(item(.commonIdentifierDescription, overview as NSString)) }
        if let data = try? Data(contentsOf: film.posterURL) { out.append(item(.commonIdentifierArtwork, data as NSData)) }
        return out
    }

    private func updateNowPlaying() {
        guard let film else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: film.title,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: time,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
        ]
        if let image = UIImage(contentsOfFile: film.posterURL.path) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private var commandsReady = false

    private func setUpRemoteCommands() {
        guard !commandsReady else { return }
        commandsReady = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.player?.play() }; return .success }
        center.pauseCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.player?.pause() }; return .success }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.togglePlay() }; return .success }
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.preferredIntervals = [10]
        center.skipForwardCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.skip(10) }; return .success }
        center.skipBackwardCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.skip(-10) }; return .success }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            MainActor.assumeIsolated { self?.seek(to: event.positionTime) }
            return .success
        }
    }

    var sourceDescription: String {
        var parts = [source.label]
        if let video {
            let size = video.width >= 3200 ? "4K" : video.height >= 1000 ? "1080p" : "\(video.height)p"
            let range = video.range == ReelRangePQ ? " HDR10" : video.range == ReelRangeHLG ? " HLG" : ""
            parts.append("Original picture, \(size) \(video.codec == "hevc" ? "HEVC" : "H.264")\(range)")
        }
        if let sound {
            parts.append(sound.untouched ? "\(sound.detail), as on the disc"
                         : "\(sound.detail) → \(sound.lossless ? "Apple Lossless, bit for bit" : "Apple Lossless")")
        }
        return parts.joined(separator: "\n")
    }
}

/// Remembers the sound and subtitles chosen for each film.
enum Preferences {
    enum Subtitles { case unset, off, track(Int) }

    static func trackChoice(for film: String) -> (sound: Int?, subtitles: Subtitles) {
        let d = UserDefaults.standard
        let sound = d.object(forKey: "sound.\(film)") as? Int
        switch d.object(forKey: "subtitles.\(film)") as? Int {
        case nil: return (sound, .unset)
        case -1: return (sound, .off)
        case let id?: return (sound, .track(id))
        }
    }

    static func setTrackChoice(for film: String, sound: Int?, subtitles: Int?) {
        let d = UserDefaults.standard
        d.set(sound, forKey: "sound.\(film)")
        d.set(subtitles ?? -1, forKey: "subtitles.\(film)")
    }
}

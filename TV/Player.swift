import AVKit
import SwiftUI
import UIKit

/// What Apple TV 4K can play natively, sent to Jellyfin so it chooses the highest-quality path:
/// 1. Direct play for MP4/MOV with HEVC or H.264 (the original file, untouched).
/// 2. Otherwise (MKV, DTS, TrueHD…) an HLS remux: the video stream is copied bit-for-bit — 4K HDR10 and
///    Dolby Vision stay intact — and only unsupported audio is converted to Dolby Digital Plus.
enum DeviceProfile {
    static let maxBitrate = 200_000_000

    static var appleTV4K: [String: Any] {
        let directPlay: [[String: Any]] = [
            ["Container": "mp4,m4v,mov", "Type": "Video", "VideoCodec": "hevc,h264",
             "AudioCodec": "aac,ac3,eac3,alac,flac,mp3"],
        ]
        let transcoding: [[String: Any]] = [
            ["Container": "mp4", "Type": "Video", "Protocol": "hls", "Context": "Streaming",
             "VideoCodec": "hevc,h264", "AudioCodec": "eac3,ac3,aac", "MaxAudioChannels": "8",
             "MinSegments": 2, "BreakOnNonKeyFrames": true, "EnableSubtitlesInManifest": true],
        ]
        let hevcConditions: [[String: Any]] = [
            ["Condition": "EqualsAny", "Property": "VideoProfile", "Value": "main|main 10", "IsRequired": false],
            ["Condition": "EqualsAny", "Property": "VideoRangeType",
             "Value": "SDR|HDR10|HDR10Plus|HLG|DOVI|DOVIWithHDR10|DOVIWithHLG|DOVIWithSDR|DOVIWithHDR10Plus",
             "IsRequired": false],
        ]
        let h264Conditions: [[String: Any]] = [
            ["Condition": "EqualsAny", "Property": "VideoProfile",
             "Value": "high|main|baseline|constrained baseline", "IsRequired": false],
            ["Condition": "LessThanEqual", "Property": "VideoLevel", "Value": "52", "IsRequired": false],
            ["Condition": "EqualsAny", "Property": "VideoRangeType", "Value": "SDR", "IsRequired": false],
        ]
        let codecProfiles: [[String: Any]] = [
            ["Type": "Video", "Codec": "hevc", "Conditions": hevcConditions],
            ["Type": "Video", "Codec": "h264", "Conditions": h264Conditions],
        ]
        let subtitles: [[String: Any]] = [
            ["Format": "vtt", "Method": "Hls"],
            ["Format": "webvtt", "Method": "Hls"],
            ["Format": "mov_text", "Method": "Embed"],
        ]
        return [
            "Name": "Reel for Apple TV",
            "MaxStreamingBitrate": maxBitrate,
            "MaxStaticBitrate": maxBitrate,
            "DirectPlayProfiles": directPlay,
            "TranscodingProfiles": transcoding,
            "ContainerProfiles": [[String: Any]](),
            "CodecProfiles": codecProfiles,
            "SubtitleProfiles": subtitles,
            "ResponseProfiles": [[String: Any]](),
        ]
    }
}

/// Plays an item in the system player (familiar controls, subtitles and audio menus, Match Content)
/// and reports progress to Jellyfin so resume works everywhere.
@MainActor
final class PlaybackController: NSObject, AVPlayerViewControllerDelegate {
    static let shared = PlaybackController()

    private var player: AVPlayer?
    private var item: Item?
    private var session: AppSession?
    private var mediaSourceId = ""
    private var playSessionId: String?
    private var playMethod = "DirectPlay"
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private weak var playerViewController: AVPlayerViewController?
    private var stopped = true
    private var starting = false
    private let monitor = BitrateMonitor()

    /// With no `source`, a downloaded film plays from the Mac and other Drive films stream.
    func play(_ item: Item, from seconds: Double, session: AppSession, source wanted: PlaybackSource? = nil) async {
        guard !starting else { return }
        starting = true
        defer { starting = false }
        guard let client = session.client, let userId = session.userId else { return }
        if !stopped { finish() }
        do {
            let cloud = CloudClient(jellyfin: client)
            var sourceLabel = "Your Mac"
            // If Reel Server's API is unreachable, Jellyfin can still play the film.
            if let film = (try? await cloud.status(item.id)) ?? nil, film.phase != .local {
                let chosen = wanted ?? (film.phase == .downloaded ? .mac : .stream)
                try await cloud.perform("play", item.id, [.init("source", chosen.rawValue)])
                sourceLabel = chosen.label
            }
            let body: [String: Any] = [
                "UserId": userId,
                "DeviceProfile": DeviceProfile.appleTV4K,
                "MaxStreamingBitrate": DeviceProfile.maxBitrate,
                "EnableDirectPlay": true,
                "EnableDirectStream": true,
                "EnableTranscoding": true,
                "AllowVideoStreamCopy": true,
                "AllowAudioStreamCopy": true,
                "AutoOpenLiveStream": true,
                // No subtitles by default: burning in an image subtitle would force a full re-encode of 4K HDR.
                "SubtitleStreamIndex": -1,
            ]
            let info: PlaybackInfoResponse = try await client.post("/Items/\(item.id)/PlaybackInfo",
                                                                   [.init("userId", userId)], json: body)
            guard let source = info.mediaSources.first else {
                throw JellyfinError(status: 0, message: info.errorCode ?? "The server found nothing to play.")
            }
            let containers = Set((source.container ?? "").lowercased().split(separator: ",").map(String.init))
            let url: URL
            if source.supportsDirectPlay == true, !containers.isDisjoint(with: ["mp4", "m4v", "mov"]) {
                var q: [URLQueryItem] = [.init("static", "true"), .init("mediaSourceId", source.id)]
                if let tag = source.eTag { q.append(.init("Tag", tag)) }
                url = client.url("/Videos/\(item.id)/stream", q, withKey: true)
                playMethod = "DirectPlay"
            } else if let relative = source.transcodingUrl, let absolute = client.absolute(relative) {
                url = await cloud.originalOnlyPlaylist(for: absolute) ?? absolute
                playMethod = source.supportsDirectStream == true ? "DirectStream" : "Transcode"
            } else {
                throw JellyfinError(status: 0, message: "The server couldn’t prepare a stream for Apple TV.")
            }

            self.item = item
            self.session = session
            mediaSourceId = source.id
            playSessionId = info.playSessionId
            stopped = false

            let playerItem = AVPlayerItem(asset: AVURLAsset(url: url))
            playerItem.externalMetadata = metadata(for: item)
            playerItem.preferredForwardBufferDuration = 50  // rides out Wi-Fi dips and Blu-ray peaks
            let player = AVPlayer(playerItem: playerItem)
            self.player = player

            let vc = AVPlayerViewController()
            vc.player = player
            vc.delegate = self
            vc.appliesPreferredDisplayCriteriaAutomatically = true   // switch the TV to HDR / the film's frame rate
            playerViewController = vc
            BitrateOverlay.attach(monitor, to: vc)
            present(vc)
            // Summaries from shelves can lack stream details; the panel needs them.
            let detailed = (try? await client.item(item.id, userId: userId)) ?? item
            monitor.start(player: player, item: detailed, client: client, source: sourceLabel,
                          direct: playMethod == "DirectPlay")

            statusObservation = playerItem.observe(\.status, options: [.new]) { [weak self] observed, _ in
                Task { @MainActor in self?.itemStatusChanged(observed, startAt: seconds) }
            }
            endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                                 object: playerItem, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.dismissPlayer() }
            }
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 10, preferredTimescale: 1),
                                                          queue: .main) { [weak self] _ in
                Task { @MainActor in self?.report("/Sessions/Playing/Progress") }
            }
            Task { await loadArtwork(for: item, into: playerItem, client: client) }
            player.play()
        } catch {
            session.playbackError = error.localizedDescription
        }
    }

    private var didStart = false

    private func itemStatusChanged(_ playerItem: AVPlayerItem, startAt seconds: Double) {
        switch playerItem.status {
        case .readyToPlay where !didStart:
            didStart = true
            if seconds > 1 {
                player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
            }
            report("/Sessions/Playing")
        case .failed:
            let message = playerItem.error?.localizedDescription ?? "Playback failed."
            dismissPlayer()
            session?.playbackError = "\(message)\nIf this keeps happening, check that your Mac is awake and on the same network."
        default:
            break
        }
    }

    private func present(_ vc: UIViewController) {
        let root = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }
            .first
        var top = root
        while let presented = top?.presentedViewController { top = presented }
        top?.present(vc, animated: true)
    }

    private func dismissPlayer() {
        if let vc = playerViewController, vc.presentingViewController != nil {
            vc.dismiss(animated: true) { [weak self] in Task { @MainActor in self?.finish() } }
        } else {
            finish()
        }
    }

    // MARK: AVPlayerViewControllerDelegate

    nonisolated func playerViewControllerDidEndDismissalTransition(_ playerViewController: AVPlayerViewController) {
        Task { @MainActor in self.finish() }
    }

    // MARK: Reporting

    private var positionTicks: Int64 {
        guard let t = player?.currentTime().seconds, t.isFinite else { return 0 }
        return Int64(t * Reel.ticksPerSecond)
    }

    private func report(_ path: String) {
        guard !stopped, let item, let client = session?.client else { return }
        let body: [String: Any] = [
            "ItemId": item.id,
            "MediaSourceId": mediaSourceId,
            "PlaySessionId": playSessionId ?? "",
            "PlayMethod": playMethod,
            "CanSeek": true,
            "IsPaused": (player?.rate ?? 0) == 0,
            "PositionTicks": positionTicks,
        ]
        Task { try? await client.send("POST", path, json: body) }
    }

    /// Stops playback, tells the server where we stopped, and ends any remux on the Mac.
    private func finish() {
        guard !stopped else { return }
        report("/Sessions/Playing/Stopped")
        stopped = true
        didStart = false
        monitor.stop()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        statusObservation = nil
        player?.pause()
        player = nil
        if let client = session?.client, let playSessionId {
            let deviceId = client.deviceId
            Task { try? await client.send("DELETE", "/Videos/ActiveEncodings",
                                          query: [.init("deviceId", deviceId), .init("playSessionId", playSessionId)]) }
        }
        // Let the server record the position before shelves refresh.
        let session = self.session
        Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            session?.libraryVersion += 1
        }
    }

    // MARK: Info panel metadata

    private func metadata(for item: Item) -> [AVMetadataItem] {
        var out: [AVMetadataItem] = []
        func add(_ id: AVMetadataIdentifier, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            let m = AVMutableMetadataItem()
            m.identifier = id
            m.value = value as NSString
            m.extendedLanguageTag = "und"
            out.append(m)
        }
        add(.commonIdentifierTitle, item.title)
        add(.commonIdentifierDescription, item.overview)
        add(.iTunesMetadataContentRating, item.officialRating)
        if let year = item.productionYear { add(.quickTimeMetadataYear, String(year)) }
        return out
    }

    private func loadArtwork(for item: Item, into playerItem: AVPlayerItem, client: JellyfinClient) async {
        guard let url = client.imageURL(for: item, maxWidth: 600) ?? client.backdropURL(for: item, maxWidth: 800),
              let response = try? await URLSession.shared.data(from: url) else { return }
        let data = response.0
        let m = AVMutableMetadataItem()
        m.identifier = .commonIdentifierArtwork
        m.value = data as NSData
        m.dataType = kCMMetadataBaseDataType_JPEG as String
        m.extendedLanguageTag = "und"
        playerItem.externalMetadata.append(m)
    }
}

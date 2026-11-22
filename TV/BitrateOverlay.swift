import AVKit
import SwiftUI
import UIKit

/// Live numbers for the panel over the player.
@MainActor
final class BitrateMonitor: ObservableObject {
    static let preferenceKey = "showBitrate"
    static var isPreferred: Bool { UserDefaults.standard.object(forKey: preferenceKey) as? Bool ?? true }

    @Published private(set) var now: Double?
    /// True when `now` is the file's exact bitrate at this second, false when it's measured from what arrives.
    @Published private(set) var isExact = false
    @Published private(set) var average: Double?
    @Published private(set) var peak: Double?
    @Published private(set) var picture = "Checking…"
    @Published private(set) var converting = false
    @Published private(set) var source = ""
    @Published private(set) var network: Double?
    @Published private(set) var buffer: Double?
    @Published private(set) var stalls = 0
    @Published var visible = BitrateMonitor.isPreferred {
        didSet { UserDefaults.standard.set(visible, forKey: Self.preferenceKey) }
    }

    private var bitrates: [Double] = []
    private var task: Task<Void, Never>?
    private var arrivals: [(bytes: Int64, seconds: Double)] = []

    func start(player: AVPlayer, item: Item, client: JellyfinClient, source: String, direct: Bool) {
        stop()
        visible = Self.isPreferred
        self.source = source
        now = nil; average = nil; peak = nil; network = nil; buffer = nil
        stalls = 0
        converting = false
        picture = direct ? Self.originalDescription(item) : "Checking…"
        bitrates = []
        arrivals = []
        task = Task { [weak self, weak player] in
            let measured = await CloudClient(jellyfin: client).bitrates(item.id)
            if Task.isCancelled { return }
            self?.use(measured)
            var tick = 0
            while !Task.isCancelled {
                guard let self, let player else { return }
                self.sample(player)
                if !direct, tick % 5 == 0 { await self.checkPicture(item, client) }
                tick += 1
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func use(_ measured: [Double]) {
        bitrates = measured
        guard !measured.isEmpty else { return }
        average = measured.reduce(0, +) / Double(measured.count)
        peak = measured.max()
    }

    private func sample(_ player: AVPlayer) {
        guard let playerItem = player.currentItem else { return }
        let time = player.currentTime().seconds
        guard time.isFinite else { return }

        let ranges = playerItem.loadedTimeRanges.map(\.timeRangeValue)
        if let range = ranges.first(where: { $0.start.seconds <= time + 1 && $0.end.seconds >= time }) {
            buffer = max(0, range.end.seconds - time)
        } else {
            buffer = 0
        }

        let events = playerItem.accessLog()?.events ?? []
        stalls = events.reduce(0) { $0 + max(0, $1.numberOfStalls) }
        if let observed = events.last?.observedBitrate, observed > 0 { network = observed / 1_000_000 }

        let bytes = events.reduce(Int64(0)) { $0 + max(0, $1.numberOfBytesTransferred) }
        let seconds = events.reduce(0.0) { $0 + max(0, $1.segmentsDownloadedDuration) }
        if arrivals.last?.bytes != bytes { arrivals.append((bytes, seconds)) }
        if arrivals.count > 4 { arrivals.removeFirst() }

        // The measured figures describe the original, so they don't apply while the picture is re-encoded.
        let second = Int(time)
        if !converting, second >= 0, second < bitrates.count {
            now = bitrates[second]
            isExact = true
        } else if let first = arrivals.first, let last = arrivals.last, last.seconds - first.seconds > 1 {
            now = Double(last.bytes - first.bytes) * 8 / (last.seconds - first.seconds) / 1_000_000
            isExact = false
        }
    }

    /// Asks Jellyfin whether it's really copying the picture.
    private func checkPicture(_ item: Item, _ client: JellyfinClient) async {
        guard let sessions: [SessionInfo] = try? await client.get("/Sessions", [.init("deviceId", client.deviceId)]),
              let info = sessions.first(where: { $0.transcodingInfo != nil })?.transcodingInfo,
              let direct = info.isVideoDirect else { return }
        converting = !direct
        picture = direct
            ? Self.originalDescription(item)
            : "Converted to \(info.videoCodec?.uppercased() ?? "another format")"
    }

    private static func originalDescription(_ item: Item) -> String {
        guard let video = item.videoStream else { return "Original" }
        var parts = ["Original"]
        if let width = video.width { parts.append(width >= 3200 ? "4K" : width >= 1900 ? "1080p" : "\(width) wide") }
        if let codec = video.codec { parts.append(codec.uppercased()) }
        switch video.videoRangeType ?? "" {
        // Profile 7 remuxes play as their HDR10 base layer.
        case "DOVIWithEL", "DOVIWithELHDR10Plus": parts.append("HDR10")
        case let range where range.hasPrefix("DOVI"): parts.append("Dolby Vision")
        case "SDR", "Unknown", "": break
        case let range: parts.append(range)
        }
        return parts.joined(separator: " ")
    }
}

struct BitratePanel: View {
    @ObservedObject var monitor: BitrateMonitor

    var body: some View {
        if monitor.visible {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(monitor.now.map { String(format: "%.1f", $0) } ?? "–")
                        .font(.system(size: 54, weight: .bold, design: .rounded))
                    Text("Mbps").font(.callout.weight(.semibold))
                }
                .foregroundStyle(Theme.gold)
                Text(monitor.isExact ? "Picture bitrate, this second" : "Stream bitrate, last few seconds")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
                row("Picture", monitor.picture, warning: monitor.converting)
                if let average = monitor.average, let peak = monitor.peak {
                    row("Film", "\(Int(average)) average, \(Int(peak)) peak")
                }
                row("Source", monitor.source)
                if let network = monitor.network { row("Wi-Fi to TV", "\(Int(network)) Mbps") }
                if let buffer = monitor.buffer { row("Buffered", "\(Int(buffer)) s") }
                if monitor.stalls > 0 { row("Stalls", "\(monitor.stalls)", warning: true) }
            }
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(26)
            .frame(width: 640, alignment: .leading)
            .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .accessibilityElement(children: .combine)
        }
    }

    private func row(_ label: String, _ value: String, warning: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(label).foregroundStyle(.white.opacity(0.7)).frame(width: 170, alignment: .leading)
            Text(value).foregroundStyle(warning ? Color.orange : Color.white).fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption2)
    }
}

enum BitrateOverlay {
    /// Adds the panel over the video, and a button in the transport bar to hide or show it.
    @MainActor
    static func attach(_ monitor: BitrateMonitor, to player: AVPlayerViewController) {
        player.loadViewIfNeeded()
        guard let overlay = player.contentOverlayView else { return }
        let host = UIHostingController(rootView: BitratePanel(monitor: monitor))
        host.view.backgroundColor = .clear
        host.view.isUserInteractionEnabled = false
        host.sizingOptions = .intrinsicContentSize
        host.view.translatesAutoresizingMaskIntoConstraints = false
        player.addChild(host)
        overlay.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: overlay.topAnchor, constant: 60),
            host.view.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: -80),
        ])
        host.didMove(toParent: player)

        let toggle = UIAction(title: "Show or Hide Bitrate", image: UIImage(systemName: "speedometer")) { [weak monitor] _ in
            monitor?.visible.toggle()
        }
        player.transportBarCustomMenuItems = [toggle]
    }
}

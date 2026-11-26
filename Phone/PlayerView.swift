import AVFoundation
import AVKit
import SwiftUI

/// Full-screen playback. The picture is AVPlayer's; the controls are drawn here so they can offer every sound
/// and subtitle track in the film and draw Blu-ray subtitles, which AVPlayer can't.
struct PlayerView: View {
    @ObservedObject var model: PlayerModel
    @AppStorage("showBitrate") private var showBitrate = false
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var scrubbing: Double?
    @State private var fill = false
    @State private var pip: AVPictureInPictureController?
    @State private var skipFlash: (forward: Bool, id: UUID)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()
                if let player = model.player {
                    VideoSurface(player: player, fill: fill) { pip = $0 }
                        .ignoresSafeArea()
                        .accessibilityLabel(model.film?.fullTitle ?? "Video")
                }
                SubtitleLayer(cues: model.cues, video: videoRect(in: geometry.size), lifted: controlsVisible)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                tapAreas
                if model.preparing || model.buffering {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                        .accessibilityLabel(model.preparing ? "Opening film" : "Loading")
                }
                if let flash = skipFlash {
                    SkipFlash(forward: flash.forward)
                        .frame(maxWidth: .infinity, alignment: flash.forward ? .trailing : .leading)
                        .padding(.horizontal, 60)
                        .id(flash.id)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
                if controlsVisible || model.preparing {
                    controls
                        .transition(.opacity)
                }
                if showBitrate && !model.preparing {
                    BitratePanel(model: model)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(.top, controlsVisible ? 64 : 16)
                        .padding(.leading, 16)
                        .allowsHitTesting(false)
                }
            }
        }
        .statusBarHidden(!controlsVisible)
        .persistentSystemOverlays(controlsVisible ? .automatic : .hidden)
        .preferredColorScheme(.dark)
        .onAppear {
            Orientation.lock(landscape: true)
            scheduleHide()
        }
        .onDisappear { Orientation.lock(landscape: false) }
        .onChange(of: model.playing) { _, _ in scheduleHide() }
        .alert("Can’t Play This Film", isPresented: Binding(get: { model.problem != nil },
                                                           set: { if !$0 { model.problem = nil; close() } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.problem ?? "")
        }
    }

    private func videoRect(in size: CGSize) -> CGRect {
        let full = CGRect(origin: .zero, size: size)
        guard let video = model.video, video.width > 0, video.height > 0 else { return full }
        let aspect = CGSize(width: video.width, height: video.height)
        return fill ? full : AVMakeRect(aspectRatio: aspect, insideRect: full)
    }

    // MARK: Gestures

    private var tapAreas: some View {
        HStack(spacing: 0) {
            Color.clear.contentShape(Rectangle())
                .onTapGesture(count: 2) { skip(forward: false) }
                .onTapGesture { toggleControls() }
            Color.clear.contentShape(Rectangle())
                .onTapGesture(count: 2) { skip(forward: true) }
                .onTapGesture { toggleControls() }
        }
        .gesture(MagnifyGesture().onEnded { value in
            withAnimation(.easeInOut(duration: 0.2)) { fill = value.magnification > 1 }
        })
        .accessibilityHidden(true)
    }

    private func skip(forward: Bool) {
        model.skip(forward ? 10 : -10)
        let flash = (forward, UUID())
        withAnimation(.easeOut(duration: 0.15)) { skipFlash = flash }
        Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            if skipFlash?.id == flash.1 { withAnimation(.easeIn(duration: 0.2)) { skipFlash = nil } }
        }
    }

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.2)) { controlsVisible.toggle() }
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard controlsVisible, model.playing, !UIAccessibility.isVoiceOverRunning else { return }
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, scrubbing == nil else { return }
            withAnimation(.easeInOut(duration: 0.3)) { controlsVisible = false }
        }
    }

    private func close() {
        pip?.stopPictureInPicture()
        model.isPresented = false
    }

    // MARK: Controls

    private var controls: some View {
        ZStack {
            LinearGradient(stops: [.init(color: .black.opacity(0.65), location: 0), .init(color: .clear, location: 0.25),
                                   .init(color: .clear, location: 0.7), .init(color: .black.opacity(0.75), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            VStack(spacing: 0) {
                topBar
                Spacer()
                if !model.preparing { centreButtons }
                Spacer()
                if !model.preparing {
                    scrubber
                    bottomRow
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .foregroundStyle(.white)
    }

    private var topBar: some View {
        HStack(spacing: 6) {
            Button(action: close) {
                Image(systemName: "xmark").font(.title3.weight(.semibold)).frame(width: 44, height: 44)
            }
            .accessibilityLabel("Close")
            Text(model.film?.fullTitle ?? "")
                .font(.headline)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                AirPlayButton().frame(width: 44, height: 44).accessibilityLabel("AirPlay and Bluetooth")
                if pip != nil, AVPictureInPictureController.isPictureInPictureSupported() {
                    Button { pip?.startPictureInPicture() } label: {
                        Image(systemName: "pip.enter").font(.title3).frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Picture in Picture")
                }
                // Opening a menu keeps the controls (and so the menu) from fading away under it.
                TrackMenu(model: model)
                    .simultaneousGesture(TapGesture().onEnded { hideTask?.cancel() })
                Button { showBitrate.toggle() } label: {
                    Image(systemName: showBitrate ? "gauge.with.dots.needle.67percent" : "gauge.with.dots.needle.33percent")
                        .font(.title3).frame(width: 44, height: 44)
                }
                .accessibilityLabel(showBitrate ? "Hide Live Bitrate" : "Show Live Bitrate")
            }
            .disabled(model.preparing)
        }
    }

    private var centreButtons: some View {
        HStack(spacing: 56) {
            Button { model.skip(-10) } label: {
                Image(systemName: "gobackward.10").font(.system(size: 30, weight: .medium)).frame(width: 60, height: 60)
            }
            .accessibilityLabel("Back 10 Seconds")
            Button { model.togglePlay(); scheduleHide() } label: {
                Image(systemName: model.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 44, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 76, height: 76)
            }
            .accessibilityLabel(model.playing ? "Pause" : "Play")
            Button { model.skip(10) } label: {
                Image(systemName: "goforward.10").font(.system(size: 30, weight: .medium)).frame(width: 60, height: 60)
            }
            .accessibilityLabel("Forward 10 Seconds")
        }
        .shadow(color: .black.opacity(0.4), radius: 8)
    }

    /// Speed, and for an episode, the next one.
    private var bottomRow: some View {
        HStack(spacing: 20) {
            Menu {
                Picker("Speed", selection: Binding(get: { model.speed }, set: { model.setSpeed($0); scheduleHide() })) {
                    ForEach([Float(0.5), 0.75, 1, 1.25, 1.5, 2], id: \.self) { value in
                        Text(Self.speedText(value)).tag(value)
                    }
                }
            } label: {
                Label("Speed (\(Self.speedText(model.speed)))", systemImage: "gauge.with.needle")
                    .font(.subheadline.weight(.medium))
                    .frame(minHeight: 44)
            }
            .simultaneousGesture(TapGesture().onEnded { hideTask?.cancel() })
            .accessibilityLabel("Playback Speed")
            .accessibilityValue(Self.speedText(model.speed))
            Spacer()
            if let next = model.nextEpisode {
                Button { model.playNext() } label: {
                    Label("Next Episode", systemImage: "forward.end.fill")
                        .font(.subheadline.weight(.medium))
                        .frame(minHeight: 44)
                }
                .accessibilityHint("Plays \(next.episodeLabel ?? ""), \(next.title)")
            }
        }
        .padding(.top, 4)
    }

    static func speedText(_ value: Float) -> String {
        value == 1 ? "Normal" : String(format: value == value.rounded() ? "%.0f×" : "%g×", value)
    }

    private var scrubber: some View {
        let shown = scrubbing ?? model.time
        return VStack(spacing: 4) {
            Slider(value: Binding(get: { shown }, set: { scrubbing = $0 }),
                   in: 0...max(model.duration, 1)) { editing in
                if !editing, let target = scrubbing {
                    model.seek(to: target)
                    scrubbing = nil
                    scheduleHide()
                } else {
                    hideTask?.cancel()
                }
            }
            .tint(Theme.gold)
            .accessibilityLabel("Position")
            .accessibilityValue("\(shown.clockText) of \(model.duration.clockText)")
            HStack {
                Text(shown.clockText)
                Spacer()
                Text("-" + max(model.duration - shown, 0).clockText)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.8))
            .accessibilityHidden(true)
        }
    }
}

private struct SkipFlash: View {
    let forward: Bool

    var body: some View {
        Image(systemName: forward ? "goforward.10" : "gobackward.10")
            .font(.system(size: 34, weight: .semibold))
            .foregroundStyle(.white)
            .padding(22)
            .background(.ultraThinMaterial, in: Circle())
    }
}

/// Sound and subtitles, with what each track is.
private struct TrackMenu: View {
    @ObservedObject var model: PlayerModel

    var body: some View {
        Menu {
            Section("Sound") {
                ForEach(model.sounds) { track in
                    Button { model.choose(sound: track) } label: {
                        if track == model.sound { Label(track.name, systemImage: "checkmark") } else { Text(track.name) }
                        Text(track.detail + (track.isCommentary ? ", commentary" : ""))
                    }
                }
            }
            Section("Subtitles") {
                Button { model.choose(subtitles: nil) } label: {
                    if model.subtitles == nil { Label("Off", systemImage: "checkmark") } else { Text("Off") }
                }
                ForEach(model.subtitleTracks) { track in
                    Button { model.choose(subtitles: track) } label: {
                        if track == model.subtitles { Label(track.name, systemImage: "checkmark") } else { Text(track.name) }
                        if !track.detail.isEmpty { Text(track.detail) }
                    }
                }
            }
        } label: {
            Image(systemName: model.subtitles == nil ? "captions.bubble" : "captions.bubble.fill")
                .font(.title3)
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel("Sound and Subtitles")
    }
}

/// The live bitrate panel, as on Apple TV.
private struct BitratePanel: View {
    @ObservedObject var model: PlayerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            row("Film", model.stats.filmMegabits)
            if model.source == .stream { row("Network", model.stats.networkMegabits) }
            HStack {
                Text("Buffered")
                Spacer(minLength: 16)
                Text(String(format: "%.0f s", model.stats.bufferSeconds)).monospacedDigit()
            }
            if model.stats.stalls > 0 {
                HStack {
                    Text("Stalls")
                    Spacer(minLength: 16)
                    Text("\(model.stats.stalls)").monospacedDigit()
                }
            }
            Text(model.sourceDescription)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.white)
        .padding(12)
        .frame(width: 290, alignment: .leading)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func row(_ label: String, _ value: Double) -> some View {
        HStack {
            Text(label)
            Spacer(minLength: 16)
            Text(value > 0 ? String(format: "%.1f Mbps", value) : "–").monospacedDigit()
        }
    }
}

/// Draws Blu-ray picture subtitles and text subtitles over the picture.
private struct SubtitleLayer: View {
    let cues: [Cue]
    let video: CGRect
    let lifted: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(cues.enumerated()), id: \.offset) { _, cue in
                if let image = cue.image, cue.canvas.width > 0 {
                    let scale = video.width / cue.canvas.width
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: cue.frame.width * scale, height: cue.frame.height * scale)
                        .position(x: video.minX + cue.frame.midX * scale,
                                  y: video.minY + cue.frame.midY * video.height / cue.canvas.height - (lifted ? 40 : 0))
                } else if let text = cue.text {
                    Text(text)
                        .font(.system(size: max(17, video.height * 0.05), weight: .semibold))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .shadow(color: .black, radius: 2)
                        .shadow(color: .black, radius: 4)
                        .padding(.horizontal, 24)
                        .frame(width: video.width)
                        .position(x: video.midX, y: video.maxY - video.height * 0.1 - (lifted ? 40 : 0))
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: lifted)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(cues.compactMap(\.text).joined(separator: " "))
    }
}

/// AVPlayer's picture, with Picture in Picture.
private struct VideoSurface: UIViewRepresentable {
    let player: AVPlayer
    let fill: Bool
    let onPictureInPicture: (AVPictureInPictureController?) -> Void

    final class Surface: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> Surface {
        let view = Surface()
        view.backgroundColor = .black
        view.playerLayer.player = player
        let controller = AVPictureInPictureController(playerLayer: view.playerLayer)
        controller?.canStartPictureInPictureAutomaticallyFromInline = true
        DispatchQueue.main.async { onPictureInPicture(controller) }
        return view
    }

    func updateUIView(_ view: Surface, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
        view.playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
    }
}

private struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        view.activeTintColor = Theme.goldUI
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}

/// Turns the phone sideways for films.
enum Orientation {
    static var mask: UIInterfaceOrientationMask = .portrait

    @MainActor
    static func lock(landscape: Bool) {
        mask = landscape ? .landscape : .portrait
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
            scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
    }
}

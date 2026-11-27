import AVFoundation
import AVKit
import SwiftUI

/// Two versions of a film, one above the other, playing in step. The sound comes from the one marked with a speaker.
struct CompareView: View {
    @ObservedObject var model: CompareModel
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var scrubbing: Double?
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 2) {
                ForEach(model.lanes) { lane in
                    LanePane(lane: lane, position: lane.id == 0 ? "Top" : "Bottom", isSound: model.soundLane == lane.id,
                             offset: lane.id == 1 ? model.offset : nil, labelsVisible: controlsVisible, showAspect: showAspect) {
                        model.soundFrom(lane.id)
                    }
                }
            }
            if model.preparing || (model.buffering && !model.lanes.isEmpty) {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.large).tint(.white)
                    Text(model.preparing ? "Opening both versions…" : "Lining up both pictures…")
                        .font(.callout).foregroundStyle(.white.opacity(0.8))
                }
                .padding(20)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityElement(children: .combine)
            }
            if let problem = model.problem {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(Theme.gold)
                    Text("Couldn’t Compare").font(.title2.weight(.semibold))
                    Text(problem).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
                    Button("Close") { model.isPresented = false }.keyboardShortcut(.cancelAction)
                }
                .padding(28)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            if controlsVisible && model.problem == nil {
                controls.transition(.opacity)
            }
        }
        .environment(\.colorScheme, .dark)
        .onContinuousHover { phase in
            if case .active = phase { show() }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true; show() }
        .onKeyPress(.space) { model.togglePlay(); show(); return .handled }
        .onKeyPress(.leftArrow) { model.skip(-10); show(); return .handled }
        .onKeyPress(.rightArrow) { model.skip(10); show(); return .handled }
        .onKeyPress(.upArrow) { model.soundFrom(0); show(); return .handled }
        .onKeyPress(.downArrow) { model.soundFrom(1); show(); return .handled }
        .onKeyPress(",") { model.step(-1); show(); return .handled }
        .onKeyPress(".") { model.step(1); show(); return .handled }
        .onKeyPress(.escape) { model.isPresented = false; return .handled }
        .onChange(of: model.playing) { _, _ in scheduleHide() }
    }

    /// The widest picture of the two. A UHD disc keeps a scope film's black bars inside a 16:9 frame while a Blu-ray
    /// encode is often cropped to the picture, so the bars are trimmed to show both pictures at the same size.
    private var showAspect: Double {
        model.lanes.compactMap { lane in lane.video.flatMap { $0.height > 0 ? Double($0.width) / Double($0.height) : nil } }.max() ?? 16 / 9
    }

    // MARK: Controls

    private var controls: some View {
        VStack {
            HStack {
                Button { model.isPresented = false } label: {
                    Image(systemName: "xmark").font(.title3.weight(.semibold)).frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .background(.ultraThinMaterial, in: Circle())
                .help("Stop Comparing (Esc)")
                .accessibilityLabel("Stop Comparing")
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 52)
            Spacer()
            VStack(spacing: 10) {
                scrubber
                HStack(spacing: 18) {
                    Picker("Sound from", selection: Binding(get: { model.soundLane }, set: { model.soundFrom($0) })) {
                        Text("Top").tag(0)
                        Text("Bottom").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 210)
                    .help("Which version you hear (↑ top, ↓ bottom)")
                    Spacer()
                    controlButton("backward.frame.fill", "One Frame Back (,)") { model.step(-1) }
                    controlButton("gobackward.10", "Back 10 Seconds (←)") { model.skip(-10) }
                    Button { model.togglePlay() } label: {
                        Image(systemName: model.playing || model.buffering ? "pause.fill" : "play.fill")
                            .font(.system(size: 30, weight: .semibold))
                            .frame(width: 56, height: 48)
                    }
                    .buttonStyle(.plain)
                    .disabled(model.preparing)
                    .accessibilityLabel(model.playing ? "Pause" : "Play")
                    .help(model.playing ? "Pause (Space)" : "Play (Space)")
                    controlButton("goforward.10", "Forward 10 Seconds (→)") { model.skip(10) }
                    controlButton("forward.frame.fill", "One Frame Forward (.)") { model.step(1) }
                    Spacer()
                    alignMenu.frame(width: 210, alignment: .trailing)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .foregroundStyle(.white)
    }

    private var scrubber: some View {
        HStack(spacing: 12) {
            Text((scrubbing ?? model.time).clockText).monospacedDigit().font(.caption)
            Slider(value: Binding(get: { scrubbing ?? model.time }, set: { scrubbing = $0 }),
                   in: 0...max(model.duration, 1)) { editing in
                if !editing, let target = scrubbing {
                    model.seek(to: target)
                    scrubbing = nil
                }
            }
            .tint(Theme.gold)
            .accessibilityLabel("Position")
            .accessibilityValue(model.time.clockText)
            Text("-" + max(0, model.duration - (scrubbing ?? model.time)).clockText).monospacedDigit().font(.caption)
        }
    }

    private var alignMenu: some View {
        Menu {
            Button("Bottom One Frame Earlier") { model.nudge(frames: -1) }
            Button("Bottom One Frame Later") { model.nudge(frames: 1) }
            Button("Bottom One Second Earlier") { model.nudge(frames: -24) }
            Button("Bottom One Second Later") { model.nudge(frames: 24) }
            Divider()
            Button("Line Up From the Start") { model.resetOffset() }.disabled(model.offset == 0)
        } label: {
            Label(model.offset == 0 ? "Lined Up" : String(format: "Bottom %+.3f s", model.offset), systemImage: "arrow.up.and.down.text.horizontal")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("If one release starts a moment later than the other, shift the bottom picture until they match")
    }

    private func controlButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.title2).frame(width: 40, height: 40)
        }
        .buttonStyle(.plain)
        .disabled(model.preparing)
        .help(label)
        .accessibilityLabel(label)
    }

    private func show() {
        if !controlsVisible { withAnimation(.easeInOut(duration: 0.2)) { controlsVisible = true } }
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard model.playing, !AppState.voiceOverRunning else { return }
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, scrubbing == nil else { return }
            withAnimation(.easeInOut(duration: 0.3)) { controlsVisible = false }
        }
    }
}

/// One version's picture with its name, what the picture is, and its live bitrate. Clicking the speaker takes its sound.
private struct LanePane: View {
    @ObservedObject var lane: CompareLane
    let position: String
    let isSound: Bool
    let offset: Double?
    let labelsVisible: Bool
    let showAspect: Double
    let takeSound: () -> Void

    private var frameAspect: Double {
        guard let video = lane.video, video.height > 0 else { return showAspect }
        return Double(video.width) / Double(video.height)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black
            if let player = lane.player {
                CompareSurface(player: player, frameAspect: frameAspect, showAspect: showAspect)
                    .accessibilityLabel("\(position) picture, \(lane.name)")
            }
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(lane.name).font(.headline)
                    Text([lane.pictureLine, lane.filmMegabits > 0 ? String(format: "%.0f Mbit/s", lane.filmMegabits) : nil]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).monospacedDigit().foregroundStyle(.white.opacity(0.75))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .opacity(labelsVisible ? 1 : 0)
                .padding(.leading, position == "Top" ? 56 : 0)   // clear of the close button
                Spacer()
                Button(action: takeSound) {
                    Image(systemName: isSound ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .font(.title3)
                        .foregroundStyle(isSound ? Theme.gold : .white.opacity(0.7))
                        .frame(width: 44, height: 44)
                        .background(.black.opacity(0.55), in: Circle())
                }
                .buttonStyle(.plain)
                .opacity(labelsVisible || isSound ? 1 : 0)
                .help(isSound ? "You’re hearing this version" : "Hear this version")
                .accessibilityLabel(isSound ? "Sound from \(lane.name), on" : "Hear \(lane.name)")
            }
            .padding(.horizontal, 20)
            .padding(.top, position == "Top" ? 52 : 14)
            .foregroundStyle(.white)
        }
        .clipped()
    }
}

/// An AVPlayerLayer, which shows HDR and Dolby Vision as the system player does.
private struct CompareSurface: NSViewRepresentable {
    let player: AVPlayer
    let frameAspect: Double
    let showAspect: Double

    func makeNSView(context: Context) -> Surface {
        let view = Surface()
        view.playerLayer.player = player
        update(view)
        return view
    }

    func updateNSView(_ view: Surface, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
        update(view)
    }

    private func update(_ view: Surface) {
        // Only bars of more than a few percent count; equal frames are shown as they are.
        let crop = showAspect > frameAspect * 1.03
        if view.frameAspect != frameAspect || view.showAspect != (crop ? showAspect : frameAspect) {
            view.frameAspect = frameAspect
            view.showAspect = crop ? showAspect : frameAspect
            view.needsLayout = true
        }
    }

    final class Surface: NSView {
        let playerLayer = AVPlayerLayer()
        var frameAspect = 16.0 / 9
        var showAspect = 16.0 / 9

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.cgColor
            playerLayer.videoGravity = .resizeAspect
            layer?.masksToBounds = true
            layer?.addSublayer(playerLayer)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            // The visible picture (showAspect) fitted in the view; the whole frame around it, its bars outside the view.
            var width = bounds.width, height = width / showAspect
            if height > bounds.height { height = bounds.height; width = height * showAspect }
            let frameHeight = width / frameAspect
            playerLayer.frame = CGRect(x: bounds.midX - width / 2, y: bounds.midY - frameHeight / 2, width: width, height: frameHeight)
            CATransaction.commit()
        }
    }
}

/// Choosing which two versions to compare, and which one you hear.
struct CompareSetup: View {
    let versions: [Film]
    @EnvironmentObject private var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var top: String = ""
    @State private var bottom: String = ""
    @State private var sound = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Compare Versions").font(.title2.weight(.bold))
                Text("Both play at once, one above the other, frame for frame, so you can see the difference. You hear one of them.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Form {
                Picker("Top", selection: $top) {
                    ForEach(versions) { Text(name($0)).tag($0.id) }
                }
                Picker("Bottom", selection: $bottom) {
                    ForEach(versions) { Text(name($0)).tag($0.id) }
                }
                Picker("Sound from", selection: $sound) {
                    Text("Top").tag(0)
                    Text("Bottom").tag(1)
                }
                .pickerStyle(.segmented)
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            Text("Streaming two versions at once needs about the bitrate of both together. Downloaded versions play from this Mac.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Compare") {
                    guard let a = versions.first(where: { $0.id == top }), let b = versions.first(where: { $0.id == bottom }) else { return }
                    dismiss()
                    CompareModel.shared.open(top: a, bottom: b, soundFrom: sound, at: library.resumeSeconds(a))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(top == bottom || top.isEmpty || bottom.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480)
        .onAppear {
            // The sharpest on top, the next one below.
            let sorted = versions.sorted { ($0.info?.width ?? 0) > ($1.info?.width ?? 0) }
            top = sorted.first?.id ?? ""
            bottom = sorted.dropFirst().first?.id ?? ""
        }
    }

    private func name(_ film: Film) -> String {
        let label = film.info?.filmVersion?.label ?? film.title
        let size = (film.info?.width ?? 0) >= 3200 ? "4K" : (film.info?.width ?? 0) >= 1900 ? "HD" : nil
        return [label, size.flatMap { label.localizedCaseInsensitiveContains($0) ? nil : $0 }].compactMap { $0 }.joined(separator: " · ")
    }
}

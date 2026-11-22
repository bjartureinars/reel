import SwiftUI

/// Pairing and live streams.
struct AppleTVView: View {
    @ObservedObject var server: ServerManager
    @State private var showPairing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Now Streaming").font(.title2.weight(.semibold))
                    if server.sessions.isEmpty {
                        Text("Nothing is playing. Open Reel on your Apple TV to start watching.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(server.sessions) { session in
                            StreamRow(session: session, server: server)
                        }
                    }
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Connect an Apple TV", systemImage: "appletv").font(.headline)
                        Text("Open Reel on your Apple TV. It finds this Mac by itself and shows a six-digit code. Enter that code here.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Enter Code…") { showPairing = true }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Server", systemImage: "server.rack").font(.headline)
                        LabeledContent("Name", value: "Reel on \(server.serverName)")
                        LabeledContent("Address", value: server.lanAddress.map { "http://\($0):\(Reel.port)" } ?? "Not connected")
                        LabeledContent("Jellyfin", value: server.version ?? "–")
                        Text("For the best 4K HDR playback, connect this Mac and your Apple TV with Ethernet. A 4K Blu-ray remux can need 80 Mbit/s or more.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(28)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .navigationTitle("Apple TV")
        .sheet(isPresented: $showPairing) { PairingSheet(server: server) }
    }
}

private struct StreamRow: View {
    let session: SessionInfo
    @ObservedObject var server: ServerManager

    var body: some View {
        HStack(spacing: 14) {
            if let item = session.nowPlayingItem {
                AsyncImage(url: server.client.backdropURL(for: item, maxWidth: 320)) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: { Color.secondary.opacity(0.2) }
                .frame(width: 128, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(session.nowPlayingItem?.title ?? "").font(.headline)
                Text("\(session.deviceName ?? "Apple TV")\(session.playState?.isPaused == true ? " · Paused" : "")")
                    .foregroundStyle(.secondary)
                Label(session.qualityDescription, systemImage: isOriginal ? "checkmark.seal.fill" : "gearshape.2")
                    .font(.caption)
                    .foregroundStyle(isOriginal ? Color.green : Color.orange)
            }
            Spacer()
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var isOriginal: Bool {
        let method = session.playState?.playMethod
        return method == "DirectPlay" || method == "DirectStream" || session.transcodingInfo?.isVideoDirect == true
    }
}

/// Approves an Apple TV through Jellyfin Quick Connect.
struct PairingSheet: View {
    @ObservedObject var server: ServerManager
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var working = false
    @State private var error: String?
    @State private var success = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Connect Apple TV", systemImage: "appletv").font(.title2.weight(.semibold))
            if success {
                Text("Connected. Your Apple TV is loading your library now.")
                HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
            } else {
                Text("Enter the six-digit code shown in Reel on your Apple TV.")
                    .foregroundStyle(.secondary)
                TextField("000000", text: $code)
                    .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
                    .multilineTextAlignment(.center)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onChange(of: code) { _, new in
                        let digits = String(new.filter(\.isNumber).prefix(6))
                        if digits != new { code = digits }
                        error = nil
                    }
                    .onSubmit(connect)
                    .accessibilityLabel("Code from Apple TV")
                if let error { Text(error).foregroundStyle(.red).font(.callout) }
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                    Button(action: connect) {
                        if working { ProgressView().controlSize(.small) } else { Text("Connect") }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(code.count != 6 || working)
                }
            }
        }
        .padding(24)
        .frame(width: 400)
        .onAppear { focused = true }
    }

    private func connect() {
        guard code.count == 6, !working else { return }
        working = true
        Task {
            do {
                try await server.authorizeAppleTV(code: code)
                success = true
            } catch {
                self.error = (error as? JellyfinError)?.status == 400 || (error as? JellyfinError)?.status == 404
                    ? "That code didn't match. Codes expire after a few minutes; check your TV and try again."
                    : error.localizedDescription
            }
            working = false
        }
    }
}

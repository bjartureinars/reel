import Network
import SwiftUI

/// Finds Reel servers on the local network through Bonjour; no IP addresses to type.
@MainActor
final class ServerBrowser: ObservableObject {
    struct Found: Identifiable, Hashable {
        var id: String { name }
        let name: String
        let url: URL
    }

    @Published private(set) var servers: [Found] = []
    private var browser: NWBrowser?
    private var resolving: [String: NWConnection] = [:]

    func start() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjour(type: Reel.bonjourType, domain: nil), using: NWParameters())
        b.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.handle(results) }
        }
        b.start(queue: .main)
        browser = b
    }

    func stop() {
        browser?.cancel()
        browser = nil
        resolving.values.forEach { $0.cancel() }
        resolving.removeAll()
    }

    private func handle(_ results: Set<NWBrowser.Result>) {
        let names = Set(results.compactMap { r -> String? in
            if case .service(let name, _, _, _) = r.endpoint { return name }
            return nil
        })
        servers.removeAll { !names.contains($0.name) }
        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint,
                  !servers.contains(where: { $0.name == name }), resolving[name] == nil else { continue }
            resolve(result.endpoint, name: name)
        }
    }

    /// Connects briefly over IPv4 to learn the Mac's address and port.
    private func resolve(_ endpoint: NWEndpoint, name: String) {
        let params = NWParameters.tcp
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        let connection = NWConnection(to: endpoint, using: params)
        resolving[name] = connection
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    if case .hostPort(let host, let port) = connection.currentPath?.remoteEndpoint,
                       let url = Self.url(host: host, port: port) {
                        if !self.servers.contains(where: { $0.name == name }) {
                            self.servers.append(Found(name: name, url: url))
                            self.servers.sort { $0.name < $1.name }
                        }
                    }
                    connection.cancel()
                    self.resolving[name] = nil
                case .failed, .cancelled:
                    self.resolving[name] = nil
                default: break
                }
            }
        }
        connection.start(queue: .main)
    }

    private static func url(host: NWEndpoint.Host, port: NWEndpoint.Port) -> URL? {
        let hostString: String
        switch host {
        case .ipv4(let a): hostString = "\(a)".components(separatedBy: "%").first ?? "\(a)"
        case .ipv6(let a): hostString = "[\("\(a)".components(separatedBy: "%").first ?? "\(a)")]"
        case .name(let n, _): hostString = n
        @unknown default: return nil
        }
        return URL(string: "http://\(hostString):\(port.rawValue)")
    }

    /// One-shot lookup used when a saved address stops answering.
    static func findOnce(named name: String, timeout: TimeInterval) async -> Found? {
        let browser = ServerBrowser()
        browser.start()
        defer { browser.stop() }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let match = browser.servers.first(where: { $0.name == name }) { return match }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return nil
    }
}

/// First-run flow: find the Mac, then pair with a Quick Connect code typed on the Mac.
struct ConnectView: View {
    @EnvironmentObject private var session: AppSession
    @StateObject private var browser = ServerBrowser()
    @State private var selected: ServerBrowser.Found?
    @State private var showManual = false
    @State private var manualAddress = ""

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.10), .black], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            if let selected {
                PairingView(server: selected) { self.selected = nil }
            } else {
                discovery
            }
        }
        .onAppear { browser.start() }
        .onDisappear { browser.stop() }
        .onChange(of: browser.servers) { _, servers in
            // One Mac at home is the common case: go straight to pairing.
            if selected == nil, servers.count == 1, !showManual { selected = servers[0] }
        }
    }

    private var discovery: some View {
        VStack(spacing: 40) {
            Wordmark()
            if browser.servers.isEmpty {
                VStack(spacing: 24) {
                    ProgressView().controlSize(.large)
                    Text("Looking for Reel on your network…").font(.title3)
                    Text("Make sure Reel Server is open on your Mac and both are on the same network.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 900)
                }
            } else {
                VStack(spacing: 20) {
                    Text("Choose your Mac").font(.title3)
                    ForEach(browser.servers) { server in
                        Button {
                            selected = server
                        } label: {
                            Label(server.name, systemImage: "macmini").frame(width: 700)
                        }
                    }
                }
            }
            Button("Enter Address Manually") { showManual = true }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(80)
        .sheet(isPresented: $showManual) {
            VStack(spacing: 30) {
                Text("Mac Address").font(.title2.weight(.semibold))
                Text("Find it in Reel Server under Apple TV → Server, for example 192.168.1.79.")
                    .foregroundStyle(.secondary)
                TextField("192.168.1.79", text: $manualAddress)
                    .keyboardType(.numbersAndPunctuation)
                    .frame(width: 700)
                Button("Connect") {
                    let trimmed = manualAddress.trimmingCharacters(in: .whitespaces)
                    let withScheme = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
                    let withPort = withScheme.split(separator: ":").count > 2 ? withScheme : "\(withScheme):\(Reel.port)"
                    if let url = URL(string: withPort) {
                        showManual = false
                        selected = .init(name: trimmed, url: url)
                    }
                }
                .disabled(manualAddress.isEmpty)
            }
            .padding(60)
        }
    }
}

private struct Wordmark: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "film.stack")
                .font(.system(size: 80, weight: .light))
                .foregroundStyle(Theme.gold)
                .accessibilityHidden(true)
            Text("Reel").font(.system(size: 76, weight: .bold, design: .rounded))
        }
    }
}

private struct PairingView: View {
    let server: ServerBrowser.Found
    let onCancel: () -> Void
    @EnvironmentObject private var session: AppSession
    @State private var code: String?
    @State private var error: String?
    @State private var serverName: String?

    var body: some View {
        VStack(spacing: 44) {
            Text("Connect to \(serverName ?? server.name)").font(.title2.weight(.semibold))
            if let code {
                Text(code.count == 6 ? "\(code.prefix(3)) \(code.suffix(3))" : code)
                    .font(.system(size: 150, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Theme.gold)
                    .accessibilityLabel("Code \(code.map(String.init).joined(separator: " "))")
                Text("On your Mac, open Reel Server, click Connect Apple TV, and enter this code.")
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 1100)
            } else if let error {
                Text(error).multilineTextAlignment(.center).frame(maxWidth: 1100)
                Button("Try Again") { Task { await run() } }
            } else {
                ProgressView().controlSize(.large)
            }
            Button("Choose a Different Mac", action: onCancel)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(80)
        .task { await run() }
    }

    private func run() async {
        error = nil
        code = nil
        let client = JellyfinClient(baseURL: server.url, deviceName: AppSession.deviceName, deviceId: DeviceIdentity.id)
        do {
            let info = try await client.publicInfo()
            serverName = info.serverName
            // Codes expire after a few minutes, so start a fresh one each time it lapses.
            while !Task.isCancelled {
                let qc: QuickConnectState = try await client.post("/QuickConnect/Initiate")
                code = qc.code
                let expires = Date().addingTimeInterval(270)
                while Date() < expires, !Task.isCancelled {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    let state: QuickConnectState = try await client.get("/QuickConnect/Connect", [.init("secret", qc.secret)])
                    if state.authenticated == true {
                        let auth: AuthResult = try await client.post("/Users/AuthenticateWithQuickConnect",
                                                                     json: ["Secret": qc.secret])
                        session.signedIn(url: server.url, auth: auth, serverName: serverName ?? server.name, bonjourName: server.name)
                        return
                    }
                }
            }
        } catch is CancellationError {
        } catch {
            self.error = "Couldn’t reach Reel on \(server.name). Check that Reel Server is running on your Mac.\n\(error.localizedDescription)"
        }
    }
}

import Foundation
import Network

struct HTTPRequest {
    let method: String
    let path: String
    let query: [URLQueryItem]
    let headers: [String: String]   // lower-cased names

    func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
}

struct HTTPResponse {
    var status = 200
    var contentType = "application/json"
    var body = Data()

    static func json<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, body: (try? JSONEncoder().encode(value)) ?? Data())
    }

    static func error(_ status: Int, _ message: String) -> HTTPResponse {
        .json(["error": message], status: status)
    }
}

/// Just enough HTTP for the Apple TV control API and Google's sign-in redirect. Requests have no bodies.
final class MiniHTTP {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "reel.http", attributes: .concurrent)
    private let handler: (HTTPRequest) async -> HTTPResponse
    private static let headerLimit = 32 * 1024

    init(port: UInt16, loopbackOnly: Bool, handler: @escaping (HTTPRequest) async -> HTTPResponse) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let endpointPort: NWEndpoint.Port = port == 0 ? .any : NWEndpoint.Port(rawValue: port)!
        if loopbackOnly {
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: endpointPort)
            listener = try NWListener(using: parameters)
        } else {
            listener = try NWListener(using: parameters, on: endpointPort)
        }
        self.handler = handler
    }

    /// Returns the port it's listening on.
    @discardableResult
    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return connection.cancel() }
            connection.start(queue: self.queue)
            // A client that never finishes its request can't hold the socket forever.
            self.queue.asyncAfter(deadline: .now() + 60) { connection.cancel() }
            self.receive(connection, Data())
        }
        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            let serial = DispatchQueue(label: "reel.http.listener")
            listener.stateUpdateHandler = { [listener] state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error), .waiting(let error):
                    resumed = true
                    listener.cancel()
                    continuation.resume(throwing: error)
                case .cancelled:
                    resumed = true
                    continuation.resume(throwing: CancellationError())
                default: break
                }
            }
            listener.start(queue: serial)
        }
    }

    func stop() { listener.cancel() }

    private func receive(_ connection: NWConnection, _ buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let request = Self.parse(buffer[..<end.lowerBound])
                Task {
                    var response = HTTPResponse.error(400, "Bad request")
                    if let request { response = await self.handler(request) }
                    self.send(response, on: connection)
                }
            } else if complete || error != nil || buffer.count > Self.headerLimit {
                connection.cancel()
            } else {
                self.receive(connection, buffer)
            }
        }
    }

    private static func parse(_ data: Data) -> HTTPRequest? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count >= 2, let url = URLComponents(string: String(first[1])) else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return HTTPRequest(method: String(first[0]), path: url.path, query: url.queryItems ?? [], headers: headers)
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        let reason = HTTPURLResponse.localizedString(forStatusCode: response.status)
        let header = """
        HTTP/1.1 \(response.status) \(reason)\r
        Content-Type: \(response.contentType)\r
        Content-Length: \(response.body.count)\r
        Cache-Control: no-store\r
        Connection: close\r
        \r

        """
        connection.send(content: Data(header.utf8) + response.body, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

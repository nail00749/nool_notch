import Foundation
import Network
import Security

struct NooLLinkHTTPRequest: Sendable {
    let method: String
    let target: String
    let headers: [String: String]
    let body: Data
}

struct NooLLinkHTTPResponse: Sendable {
    let status: Int
    var body = Data()
}

/// A deliberately small HTTP/1.1 endpoint: one bounded request per TLS connection.
/// Authorization is checked after the header, before accepting a large body.
final class NooLLinkHTTPServer: @unchecked Sendable {
    typealias Authorize = @Sendable (NooLLinkHTTPRequest) async -> Bool
    typealias Handle = @Sendable (NooLLinkHTTPRequest) async -> NooLLinkHTTPResponse
    private let queue = DispatchQueue(label: "app.nool.link.network")
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private let listeningPort: NWEndpoint.Port

    init(port: NWEndpoint.Port = 52961) { listeningPort = port }

    func start(identity: NooLLinkIdentity, authorize: @escaping Authorize,
               handle: @escaping Handle, ready: @escaping @Sendable (UInt16?) -> Void,
               failure: @escaping @Sendable (String) -> Void = { _ in }) throws {
        let tls = NWProtocolTLS.Options()
        guard let localIdentity = sec_identity_create(identity.identity) else { throw NooLLinkError.identity }
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, localIdentity)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.prohibitedInterfaceTypes = [.cellular, .other]
        let listener = try NWListener(using: parameters, on: listeningPort)
        self.listener = listener
        listener.stateUpdateHandler = { [weak listener] state in
            switch state {
            case .ready: ready(listener?.port?.rawValue)
            case .failed(let error): failure(error.localizedDescription); ready(nil)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            guard self.connections.count < 4, Self.isLocal(connection.endpoint) else { connection.cancel(); return }
            let id = UUID()
            self.connections[id] = connection
            connection.start(queue: self.queue)
            let exchange = Exchange(connection: connection, authorize: authorize, handle: handle) { [weak self] in
                self?.connections.removeValue(forKey: id)
            }
            exchange.receive()
            self.queue.asyncAfter(deadline: .now() + 15) {
                if !exchange.authorized { exchange.finish() }
            }
            self.queue.asyncAfter(deadline: .now() + 180) { exchange.finish() }
        }
        listener.start(queue: queue)
    }

    func stop() {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
            for connection in connections.values { connection.cancel() }
            connections.removeAll()
        }
    }

    static func isLocal(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address):
            let bytes = Array(address.rawValue)
            return bytes[0] == 10 || (bytes[0] == 172 && (16...31).contains(bytes[1])) ||
                (bytes[0] == 192 && bytes[1] == 168) || (bytes[0] == 169 && bytes[1] == 254) || bytes[0] == 127
        case .ipv6(let address):
            let bytes = Array(address.rawValue)
            return bytes[0] & 0xfe == 0xfc || (bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80) || address == .loopback
        default: return false
        }
    }

    private final class Exchange: @unchecked Sendable {
        let connection: NWConnection
        let authorize: Authorize
        let handle: Handle
        let onFinish: @Sendable () -> Void
        var buffer = Data()
        var request: NooLLinkHTTPRequest?
        var contentLength = 0
        var finished = false
        var authorized = false

        init(connection: NWConnection, authorize: @escaping Authorize,
             handle: @escaping Handle, onFinish: @escaping @Sendable () -> Void) {
            self.connection = connection; self.authorize = authorize; self.handle = handle; self.onFinish = onFinish
        }

        func receive() {
            guard !finished else { return }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, complete, error in
                guard !finished else { return }
                if let data { buffer.append(data) }
                if error != nil || (complete && buffer.isEmpty) { finish(); return }
                if request == nil {
                    guard let range = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                        if buffer.count > 16 * 1024 || complete { respond(.init(status: 400)); return }
                        receive(); return
                    }
                    guard range.lowerBound <= 16 * 1024,
                          let header = String(data: buffer[..<range.lowerBound], encoding: .utf8),
                          let parsed = Self.parse(header) else { respond(.init(status: 400)); return }
                    buffer.removeSubrange(..<range.upperBound)
                    request = parsed.0
                    contentLength = parsed.1
                    Task {
                        let allowed = await authorize(parsed.0)
                        connection.queue?.async { [self] in
                            guard !finished else { return }
                            if allowed {
                                authorized = true
                                consume(complete: complete)
                            } else { respond(.init(status: 401)) }
                        }
                    }
                } else { consume(complete: complete) }
            }
        }

        func consume(complete: Bool) {
            guard buffer.count <= contentLength else { respond(.init(status: 400)); return }
            guard buffer.count == contentLength else {
                if complete { finish() } else { receive() }
                return
            }
            guard let request else { finish(); return }
            let completeRequest = NooLLinkHTTPRequest(method: request.method, target: request.target,
                                                       headers: request.headers, body: buffer)
            Task {
                let response = await handle(completeRequest)
                connection.queue?.async { [self] in respond(response) }
            }
        }

        static func parse(_ header: String) -> (NooLLinkHTTPRequest, Int)? {
            let lines = header.components(separatedBy: "\r\n")
            guard let first = lines.first else { return nil }
            let words = first.split(separator: " ")
            guard words.count == 3, words[2] == "HTTP/1.1", ["GET", "POST"].contains(String(words[0])),
                  words[1].count <= 256 else { return nil }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { return nil }
                let name = line[..<colon].lowercased()
                guard headers[name] == nil else { return nil }
                headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            guard headers["transfer-encoding"] == nil,
                  let length = Int(headers["content-length"] ?? "0"), length >= 0,
                  length <= NooLLinkEnvelope.maximumBodyBytes else { return nil }
            if words[1] == "/v1/pair", length > 4096 { return nil }
            return (.init(method: String(words[0]), target: String(words[1]), headers: headers, body: Data()), length)
        }

        func respond(_ response: NooLLinkHTTPResponse) {
            guard !finished else { return }
            let reason = [200: "OK", 204: "No Content", 400: "Bad Request", 401: "Unauthorized", 409: "Conflict", 413: "Payload Too Large", 503: "Unavailable"][response.status] ?? "Error"
            var data = Data("HTTP/1.1 \(response.status) \(reason)\r\nContent-Length: \(response.body.count)\r\nContent-Type: application/json\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n".utf8)
            data.append(response.body)
            connection.send(content: data, completion: .contentProcessed { [self] _ in finish() })
        }

        func finish() {
            guard !finished else { return }
            finished = true
            buffer = Data()
            connection.cancel()
            onFinish()
        }
    }
}

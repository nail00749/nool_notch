import Foundation
import Network
import Security

/// A Mac-side receiver advertising the paired PC's name to Finder.
/// Protocol facts are independently implemented from the public owly wire specification.
final class AirDropReceiver: @unchecked Sendable {
    typealias Consent = @Sendable (AirDropOffer) async -> Bool
    typealias Deliver = @Sendable ([URL]) async throws -> Void
    private let queue = DispatchQueue(label: "app.nool.link.airdrop")
    private var listener: NWListener?
    private var bonjour: AirDropBonjour?
    private var connections: [UUID: Session] = [:]
    private var recentConnections: [Date] = []

    func start(identity: NooLLinkIdentity, deviceName: String,
               consent: @escaping Consent, deliver: @escaping Deliver,
               ready: @escaping @Sendable (UInt16?) -> Void = { _ in },
               failure: @escaping @Sendable (String) -> Void = { _ in },
               activity: @escaping @Sendable (String) -> Void = { _ in },
               advertise: Bool = true) throws {
        guard AirDropProtocol.safeDisplayName(deviceName), let local = sec_identity_create(identity.identity) else { throw NooLLinkError.identity }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, local)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.includePeerToPeer = true
        parameters.prohibitedInterfaceTypes = [.cellular]
        let listener = try NWListener(using: parameters, on: .any)
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
        self.listener = listener
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            switch state {
            case .ready:
                guard let self, let port = listener?.port?.rawValue else { ready(nil); return }
                guard advertise else { ready(port); return }
                do {
                    let bonjour = AirDropBonjour()
                    self.bonjour = bonjour
                    try bonjour.start(id: id, port: port, queue: self.queue) { [weak self, weak listener] registered in
                        guard let self, self.listener === listener else { return }
                        if registered { ready(port) }
                        else {
                            self.bonjour?.stop(); self.bonjour = nil
                            listener?.cancel(); self.listener = nil
                            failure(NooLLinkError.unavailable.localizedDescription); ready(nil)
                        }
                    }
                } catch {
                    listener?.cancel(); self.listener = nil
                    self.bonjour?.stop(); self.bonjour = nil
                    failure(error.localizedDescription); ready(nil)
                }
            case .failed(let error):
                self?.bonjour?.stop(); self?.bonjour = nil
                listener?.cancel(); self?.listener = nil
                failure(error.localizedDescription); ready(nil)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, self.connections.count < 4, NooLLinkHTTPServer.isLocal(connection.endpoint) else { connection.cancel(); return }
            let now = Date()
            self.recentConnections.removeAll { now.timeIntervalSince($0) > 1 }
            guard self.recentConnections.count < 8 else { connection.cancel(); return }
            self.recentConnections.append(now)
            let id = UUID()
            let fromThisMac = Self.isThisMac(connection.endpoint)
            let session = Session(connection: connection, queue: self.queue, name: deviceName, fromThisMac: fromThisMac,
                                  consent: consent, deliver: deliver, activity: activity) { [weak self] in
                self?.connections.removeValue(forKey: id)
            }
            self.connections[id] = session
            activity("connection opened, this Mac: \(fromThisMac)")
            connection.start(queue: self.queue)
            session.receive()
            self.queue.asyncAfter(deadline: .now() + 420) { [weak session] in session?.finish() }
        }
        listener.start(queue: queue)
    }

    func stop() {
        queue.async { [self] in
            listener?.cancel(); listener = nil
            bonjour?.stop(); bonjour = nil
            for session in Array(connections.values) { session.finish() }
            connections.removeAll()
        }
    }

    /// True when the peer address belongs to one of this Mac's own interfaces.
    static func isThisMac(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        let remote: Data
        switch host {
        case .ipv4(let address): if address == .loopback { return true }; remote = address.rawValue
        case .ipv6(let address): if address == .loopback { return true }; remote = address.rawValue
        default: return false
        }
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return false }
        defer { freeifaddrs(first) }
        var cursor = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            guard let address = current.pointee.ifa_addr else { continue }
            let local: Data
            switch Int32(address.pointee.sa_family) {
            case AF_INET:
                var value = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
                local = withUnsafeBytes(of: &value) { Data($0) }
            case AF_INET6:
                var value = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in6.self).pointee.sin6_addr
                local = withUnsafeBytes(of: &value) { Data($0) }
            default: continue
            }
            if local == remote { return true }
        }
        return false
    }

    private final class Session: @unchecked Sendable {
        let connection: NWConnection
        let queue: DispatchQueue
        let name: String
        let fromThisMac: Bool
        let consent: Consent
        let deliver: Deliver
        let activity: @Sendable (String) -> Void
        let onFinish: @Sendable () -> Void
        var decoder = AirDropHTTPDecoder()
        var finished = false
        var busy = false
        var discovered = false
        var offer: AirDropOffer?
        var uploaded = false
        var didSendUploadContinue = false
        var requestGeneration = 0
        var task: Task<Void, Never>?

        init(connection: NWConnection, queue: DispatchQueue, name: String, fromThisMac: Bool, consent: @escaping Consent,
             deliver: @escaping Deliver, activity: @escaping @Sendable (String) -> Void, onFinish: @escaping @Sendable () -> Void) {
            self.connection = connection; self.queue = queue; self.name = name; self.fromThisMac = fromThisMac; self.consent = consent
            self.deliver = deliver; self.onFinish = onFinish
            self.activity = activity
        }

        func receive() {
            guard !finished, !busy else { return }
            let generation = requestGeneration
            queue.asyncAfter(deadline: .now() + 30) { [weak self] in
                guard let self, !self.finished, !self.busy, self.requestGeneration == generation else { return }
                self.finish()
            }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, complete, error in
                guard !finished else { return }
                if let data, !data.isEmpty {
                    do { try decoder.append(data); requestGeneration += 1; processBuffered() }
                    catch { activity("buffer rejected: \(error)"); respond(status: 400, close: true) }
                } else if error != nil || complete {
                    finish()
                } else { receive() }
            }
        }

        func processBuffered() {
            guard !finished, !busy else { return }
            do {
                let prepared = try decoder.prepareHeader()
                if prepared, let head = decoder.head {
                    if head.path == "/Upload" {
                        let contentType = head.headers["content-type"]?.lowercased().split(separator: ";").first.map(String.init) ?? "missing"
                        guard offer != nil, !uploaded else {
                            respond(status: 403, close: true); return
                        }
                        guard contentType == "application/x-cpio" || contentType == "application/x-dvzip" else {
                            activity("/Upload unsupported content type \(contentType)")
                            respond(status: 406, close: true); return
                        }
                        didSendUploadContinue = false
                    }
                }
                guard let request = try decoder.nextRequest(uploadOffer: offer) else {
                    if decoder.head?.path == "/Upload" {
                        // Honor the HTTP expectation when the body is not buffered yet.
                        if !didSendUploadContinue, decoder.head?.headers["expect"]?.lowercased() == "100-continue" {
                            didSendUploadContinue = true
                            connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .contentProcessed { _ in })
                        }
                    }
                    receive(); return
                }
                activity(request.path)
                let acceptedOffer = offer
                switch request.path {
                case "/Discover":
                    guard !discovered, offer == nil, !uploaded else { respond(status: 400, close: true); return }
                    discovered = true
                case "/Ask":
                    guard offer == nil, !uploaded else { respond(status: 400, close: true); return }
                case "/Upload":
                    guard offer != nil, !uploaded else { respond(status: 403, close: true); return }
                    uploaded = true
                default: break
                }
                busy = true
                requestGeneration += 1
                let epoch = requestGeneration
                // Includes Windows' delivery acknowledgement, not only the local upload.
                queue.asyncAfter(deadline: .now() + (request.path == "/Ask" ? 15 : 210)) { [weak self] in
                    guard let self, !self.finished, self.busy, self.requestGeneration == epoch else { return }
                    self.respond(status: 408, close: true)
                }
                task = Task { [self] in
                    let response = await handle(request, acceptedOffer: acceptedOffer)
                    queue.async { [self] in
                        guard !finished, requestGeneration == epoch else { return }
                        activity("\(request.path) status=\(response.status)")
                        if let accepted = response.acceptedOffer { offer = accepted }
                        respond(status: response.status, body: response.body, close: response.close)
                    }
                }
            } catch {
                activity("request rejected: \(error) \(decoder.rejectedRequestLine ?? "")")
                respond(status: 400, close: true)
            }
        }

        private struct Response: Sendable {
            let status: Int
            var body = Data()
            var close = false
            var acceptedOffer: AirDropOffer?
        }

        private func handle(_ request: AirDropHTTPRequest, acceptedOffer: AirDropOffer?) async -> Response {
            guard request.method == "POST" else { return .init(status: 200, close: true) }
            do {
                switch request.path {
                case "/Discover":
                    // Visibility never consumes identity records. Keeping this
                    // bounded payload opaque also accepts Finder's empty probe.
                    return .init(status: 200, body: try AirDropProtocol.response(name: name, discover: true))
                case "/Ask":
                    var incoming = try AirDropProtocol.offer(request.body)
                    incoming.fromThisMac = fromThisMac
                    guard await consent(incoming), !Task.isCancelled else { return .init(status: 403, close: true) }
                    return .init(status: 200, body: try AirDropProtocol.response(name: name, discover: false), acceptedOffer: incoming)
                case "/Upload":
                    guard let offer = acceptedOffer else { return .init(status: 403, close: true) }
                    guard offer.transferID == nil || request.headers["transferid"]?.caseInsensitiveCompare(offer.transferID!) == .orderedSame else {
                        return .init(status: 400, close: true)
                    }
                    let format = try AirDropArchive.UploadFormat(contentType: request.headers["content-type"])
                    let directory = try AirDropArchive.extract(request.body, offered: offer, format: format)
                    defer { try? FileManager.default.removeItem(at: directory) }
                    try Task.checkCancellation()
                    try await deliver(offer.files.map { directory.appendingPathComponent($0.name) })
                    try Task.checkCancellation()
                    return .init(status: 200, close: true)
                default: return .init(status: 400, close: true)
                }
            } catch {
                activity("\(request.path) failed: \(error)")
                return .init(status: 400, close: true)
            }
        }

        func respond(status: Int, body: Data = Data(), close: Bool) {
            guard !finished else { return }
            let reason = [200: "OK", 400: "Bad Request", 403: "Forbidden", 406: "Not Acceptable", 408: "Request Timeout"][status] ?? "Error"
            var response = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Length: \(body.count)\r\nContent-Type: application/octet-stream\r\nConnection: \(close ? "close" : "keep-alive")\r\n\r\n".utf8)
            response.append(body)
            connection.send(content: response, completion: .contentProcessed { [self] _ in
                if close { finish() }
                else { busy = false; task = nil; processBuffered() }
            })
        }

        func finish() {
            guard !finished else { return }
            finished = true; requestGeneration += 1; task?.cancel(); task = nil
            connection.cancel(); onFinish()
        }
    }
}

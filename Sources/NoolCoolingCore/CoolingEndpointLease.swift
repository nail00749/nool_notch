import Foundation

/// Per-XPC-connection ownership. Call on the same serial queue as the controller.
/// A client may reuse its own session UUID after reconnecting; the controller
/// lease must still be unique so delayed cleanup cannot revoke the new owner.
public final class CoolingEndpointLease {
    private let controllerToken = UUID().uuidString
    private var clientSessionID: String?
    private var disconnected = false

    public init() {}

    @discardableResult
    public func apply(_ request: CoolingControlRequest, using controller: CoolingController) throws -> CoolingSnapshot {
        try validateClient(request.sessionID)
        var command = request
        command.sessionID = controllerToken
        let result = try controller.apply(command)
        clientSessionID = request.sessionID
        return result
    }

    public func heartbeat(_ sessionID: String, using controller: CoolingController) throws {
        try validateClient(sessionID)
        guard clientSessionID == sessionID else { throw CoolingError.sessionBusy }
        try controller.heartbeat(sessionID: controllerToken)
    }

    public func release(_ sessionID: String, using controller: CoolingController) throws {
        try validateClient(sessionID)
        // A new, unbound endpoint can confirm an idle controller was released;
        // it cannot release another endpoint's active controller token.
        try controller.release(sessionID: controllerToken)
        clientSessionID = nil
    }

    public func disconnect(using controller: CoolingController) {
        guard !disconnected else { return }
        disconnected = true
        if clientSessionID != nil { try? controller.release(sessionID: controllerToken) }
        clientSessionID = nil
    }

    private func validateClient(_ sessionID: String) throws {
        guard !disconnected else { throw CoolingError.unavailable("Соединение с помощником охлаждения закрыто.") }
        guard UUID(uuidString: sessionID) != nil else { throw CoolingError.invalidRequest("Некорректный сеанс управления.") }
        if let clientSessionID, clientSessionID != sessionID { throw CoolingError.sessionBusy }
    }
}

import Foundation

@MainActor
protocol AISessionSource: AnyObject, Sendable {
    var id: String { get }
    var displayName: String { get }

    func snapshots() -> AsyncStream<AISessionSourceSnapshot>
    func stop()
    func open(sessionID: String) async -> Bool
    func respond(
        sessionID: String,
        requestID: String,
        response: AISessionResponse
    ) async -> Bool
}

extension AISessionSource {
    func stop() {}

    func respond(
        sessionID: String,
        requestID: String,
        response: AISessionResponse
    ) async -> Bool {
        false
    }
}

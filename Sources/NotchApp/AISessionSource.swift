import Foundation

@MainActor
protocol AISessionSource: AnyObject, Sendable {
    var id: String { get }
    var displayName: String { get }

    func snapshots() -> AsyncStream<AISessionSourceSnapshot>
    func open(sessionID: String) async -> Bool
}

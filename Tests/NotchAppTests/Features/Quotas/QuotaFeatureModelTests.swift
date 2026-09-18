import NotchCore
import XCTest
@testable import NotchApp

@MainActor
final class QuotaFeatureModelTests: XCTestCase {
    func testRefreshIsDeduplicatedAndStopRejectsLateResults() async {
        let provider = SuspendedQuotaProvider()
        let model = QuotaFeatureModel(providers: [provider], preferences: MemoryAppPreferences())
        model.refresh()
        model.refresh()
        await provider.waitUntilRequested()
        let initial = model.snapshots
        model.stop()
        await provider.finish()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(model.snapshots, initial)
        model.refresh()
        for _ in 0..<10 { await Task.yield() }
        let requests = await provider.requests
        XCTAssertEqual(requests, 1)
    }

    func testPendingRequestDoesNotRetainQuotaOwner() async {
        let provider = SuspendedQuotaProvider()
        var owner: QuotaFeatureModel? = QuotaFeatureModel(providers: [provider], preferences: MemoryAppPreferences())
        weak var released = owner
        owner?.refresh()
        await provider.waitUntilRequested()
        owner = nil
        XCTAssertNil(released)
        await provider.finish()
    }
}

private actor SuspendedQuotaProvider: QuotaProvider {
    nonisolated let id = "delayed"
    nonisolated let displayName = "Delayed"
    nonisolated let sourceURL: URL? = nil
    private(set) var requests = 0
    private var continuation: CheckedContinuation<QuotaSnapshot, Never>?

    func loadSnapshot() async -> QuotaSnapshot {
        requests += 1
        return await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilRequested() async {
        for _ in 0..<100 where continuation == nil { await Task.yield() }
    }

    func finish() {
        continuation?.resume(returning: .unavailable(providerID: id, providerName: displayName,
                                                   sourceURL: nil, message: "Late response"))
        continuation = nil
    }
}

import AppKit
import Foundation
import NotchCore
import XCTest
@testable import NotchApp

@MainActor
final class WindowCoordinatorLifecycleTests: XCTestCase {
    func testQuotaEdgeOwnsPanelsAndStopCannotReopenThem() {
        let model = makeModel(mode: .wave)
        let coordinator = QuotaEdgeWindowCoordinator(
            model: model, displaySettings: NotchDisplaySettings(defaults: temporaryDefaults())
        )
        defer { coordinator.stop(); model.stop() }

        XCTAssertEqual(coordinator.ownedPanels.count, 3)
        coordinator.start()
        coordinator.start()
        XCTAssertTrue(coordinator.isStarted)
        XCTAssertTrue(coordinator.ownedPanels[0].isVisible)

        coordinator.stop()
        coordinator.synchronize()
        XCTAssertFalse(coordinator.isStarted)
        XCTAssertTrue(coordinator.ownedPanels.allSatisfy { !$0.isVisible })

        coordinator.start()
        XCTAssertTrue(coordinator.ownedPanels[0].isVisible)
    }

    func testQuotaStackOwnsTriggerAndStopCannotReopenIt() {
        let model = makeModel(mode: .stack)
        let coordinator = QuotaStackWindowCoordinator(
            model: model, displaySettings: NotchDisplaySettings(defaults: temporaryDefaults())
        )
        defer { coordinator.stop(); model.stop() }

        XCTAssertEqual(coordinator.ownedPanels.count, 1)
        coordinator.start()
        XCTAssertTrue(coordinator.ownedPanels[0].isVisible)

        coordinator.stop()
        coordinator.stop()
        coordinator.synchronize()
        XCTAssertFalse(coordinator.isStarted)
        XCTAssertTrue(coordinator.ownedPanels.allSatisfy { !$0.isVisible })

        coordinator.start()
        XCTAssertTrue(coordinator.ownedPanels[0].isVisible)
    }

    private func makeModel(mode: CompactQuotaDisplayMode) -> NotchViewModel {
        NotchViewModel(
            providers: [LifecycleQuotaProvider()],
            calendarProvider: FakeCalendarProvider(),
            nowPlayingProvider: FakeNowPlayingProvider(),
            liveActivityCenter: LiveActivityCenter(additionalSources: []),
            jiraProvider: FakeJiraProvider(),
            aiSessionStore: AISessionStore(sources: []),
            preferences: MemoryAppPreferences(compactQuotaDisplayMode: mode)
        )
    }

    private func temporaryDefaults() -> UserDefaults {
        UserDefaults(suiteName: "WindowCoordinatorLifecycleTests.\(UUID().uuidString)")!
    }
}

private actor LifecycleQuotaProvider: QuotaProvider {
    nonisolated let id = "lifecycle-quota"
    nonisolated let displayName = "Lifecycle quota"
    nonisolated let sourceURL: URL? = nil

    func loadSnapshot() async -> QuotaSnapshot {
        QuotaSnapshot.unavailable(
            providerID: id,
            providerName: displayName,
            sourceURL: nil,
            message: "Тест"
        )
    }
}

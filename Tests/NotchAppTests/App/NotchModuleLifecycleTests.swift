import Foundation
import NotchCore
import XCTest
@testable import NotchApp

private struct QueueLifecycleSource: YandexMusicQueueReading {
    func read() async -> YandexMusicQueueState { .loaded([], partial: false) }
    func openQueue() async -> YandexMusicQueueState { .closed }
}

@MainActor
final class NotchModuleLifecycleTests: XCTestCase {
    func testYandexQueueIsClearedWhenMusicIsHiddenOrDisabled() async {
        let modules = AppModuleStore(defaults: nil)
        for module in AppModuleID.allCases { modules.setEnabled(module, enabled: module == .music) }
        let queue = YandexMusicQueueStore(source: QueueLifecycleSource())
        let model = NotchViewModel(providers: [], nowPlayingProvider: FakeNowPlayingProvider(),
                                   modules: modules, musicQueue: queue)
        defer { model.stop() }
        for hide in [0, 1, 2] {
            model.openPanel(.music)
            queue.setActive(true)
            for _ in 0..<100 {
                if case .loaded = queue.state { break }
                await Task.yield()
            }
            guard case .loaded = queue.state else { return XCTFail("Queue did not load") }
            switch hide {
            case 0: model.isExpanded = false
            case 1: model.openUtility(.overview)
            default: modules.setEnabled(.music, enabled: false)
            }
            XCTAssertEqual(queue.state, .idle)
        }
    }

    func testMusicLyricsCollapseCancelsLookupAndModuleOffClearsTrack() {
        let modules = AppModuleStore(defaults: nil)
        for module in AppModuleID.allCases { modules.setEnabled(module, enabled: module == .music) }
        let provider = FakeNowPlayingProvider()
        let lyrics = MusicLyricsStore(client: MusicLyricsClient(transport: { _ in
            try await Task.sleep(for: .seconds(30))
            return MusicLyricsHTTPResponse(data: Data(), statusCode: 404, retryAfter: nil)
        }))
        let model = NotchViewModel(providers: [], nowPlayingProvider: provider,
                                   modules: modules, musicLyrics: lyrics)
        defer { model.stop() }
        model.selectPanel(.music)
        model.isExpanded = true
        provider.onChange?(NowPlayingSnapshot(id: "test", title: "Test", artist: "Artist",
            album: nil, appName: "Fixture", artworkData: nil, duration: 120,
            elapsedTime: 10, playbackRate: 1, playbackState: .playing, updatedAt: .now))
        XCTAssertEqual(lyrics.track?.title, "Test")
        XCTAssertEqual(lyrics.state, .idle)
        lyrics.lookup()
        XCTAssertEqual(lyrics.state, .loading)
        model.isExpanded = false
        XCTAssertEqual(lyrics.state, .idle)
        XCTAssertEqual(lyrics.track?.title, "Test")
        model.openPanel(.music)
        lyrics.lookup()
        XCTAssertEqual(lyrics.state, .loading)
        model.openUtility(.overview)
        XCTAssertEqual(lyrics.state, .idle)
        modules.setEnabled(.music, enabled: false)
        XCTAssertNil(lyrics.track)
    }

    func testRecentCapturesPickerClosesBeforeCollapseAndModuleIsGated() {
        let suite = "RecentCapturesLifecycle-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let modules = AppModuleStore(defaults: nil)
        for module in AppModuleID.allCases { modules.setEnabled(module, enabled: false) }
        let model = NotchViewModel(providers: [], modules: modules,
                                   recentCaptures: RecentCapturesStore(defaults: defaults))
        defer { model.stop() }
        model.openUtility(.recentCaptures)
        XCTAssertNil(model.activeUtility)
        modules.setEnabled(.recentCaptures, enabled: true)
        model.openUtility(.recentCaptures)
        XCTAssertEqual(model.activeUtility, .recentCaptures)
        model.transientSurfaceDidPresent(.recentCapturesFolderPicker)
        let request = model.transientSurfaceDismissalRequest
        // With Jira off, an unrelated module change must not dismiss this picker.
        modules.setEnabled(.gestures, enabled: true)
        XCTAssertEqual(model.transientSurfaceDismissalRequest, request)
        model.requestCollapse()
        XCTAssertTrue(model.isExpanded)
        XCTAssertEqual(model.activeUtility, .recentCaptures)
        XCTAssertEqual(model.transientSurfaceDismissalRequest, request + 1)
        model.transientSurfaceDidDisappear(.recentCapturesFolderPicker)
        XCTAssertNil(model.activeUtility)
        XCTAssertFalse(model.isExpanded)
        model.openUtility(.recentCaptures)
        modules.setEnabled(.recentCaptures, enabled: false)
        XCTAssertNil(model.activeUtility)
    }

    func testScratchpadIsGatedAndExplicitCollapseWaitsForExport() {
        let modules = AppModuleStore(defaults: nil)
        for module in AppModuleID.allCases { modules.setEnabled(module, enabled: false) }
        let model = NotchViewModel(providers: [], modules: modules)
        defer { model.stop() }
        model.openUtility(.scratchpad)
        XCTAssertNil(model.activeUtility)
        XCTAssertFalse(model.isExpanded)
        modules.setEnabled(.scratchpad, enabled: true)
        model.openUtility(.scratchpad)
        XCTAssertEqual(model.activeUtility, .scratchpad)
        XCTAssertTrue(model.isTransientSurfaceVisible)
        model.transientSurfaceDidPresent(.scratchpadExport)
        let request = model.transientSurfaceDismissalRequest
        model.requestCollapse()
        XCTAssertTrue(model.isExpanded)
        XCTAssertEqual(model.activeUtility, .scratchpad)
        XCTAssertEqual(model.transientSurfaceDismissalRequest, request + 1)
        model.transientSurfaceDidDisappear(.scratchpadExport)
        XCTAssertFalse(model.isExpanded)
        XCTAssertNil(model.activeUtility)
        model.openUtility(.scratchpad)
        modules.setEnabled(.scratchpad, enabled: false)
        XCTAssertNil(model.activeUtility)
        XCTAssertFalse(model.scratchpad.canEdit)
    }

    func testAllDisabledStopsProvidersAndRestoresSavedPanelOrder() async {
        let modules = AppModuleStore(defaults: nil)
        for module in AppModuleID.allCases { modules.setEnabled(module, enabled: false) }
        let calendar = FakeCalendarProvider()
        calendar.canLoadWithoutPrompt = true
        let music = FakeNowPlayingProvider()
        let jira = FakeJiraProvider()
        let agent = MemoryAISessionSource()
        let activity = RecordingModuleActivitySource()
        let center = LiveActivityCenter(timerSource: NoolTimerSource(), additionalSources: [activity])
        let preferences = MemoryAppPreferences(panelOrder: [.jira, .music, .ai, .calendar, .live])
        let model = NotchViewModel(providers: [], calendarProvider: calendar,
                                   nowPlayingProvider: music, liveActivityCenter: center,
                                   jiraProvider: jira, aiSessionStore: AISessionStore(sources: [agent]),
                                   preferences: preferences, modules: modules)
        defer { model.stop() }

        model.isExpanded = true
        model.refreshCalendar()
        model.refreshJira()
        model.refreshNowPlaying()
        XCTAssertTrue(model.visiblePanels.isEmpty)
        XCTAssertFalse(music.didStart)
        XCTAssertFalse(jira.didStart)
        XCTAssertEqual(calendar.loadUpcomingEventsCallCount, 0)
        XCTAssertEqual(activity.startCount, 0)
        XCTAssertEqual(agent.subscriptionCount, 0)

        modules.applyPreset(.all)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(model.visiblePanels, preferences.panelOrder)
        XCTAssertTrue(music.didStart)
        XCTAssertTrue(jira.didStart)
        XCTAssertGreaterThan(calendar.loadUpcomingEventsCallCount, 0)
        XCTAssertEqual(activity.startCount, 1)
        XCTAssertEqual(agent.subscriptionCount, 1)

        for module in AppModuleID.allCases { modules.setEnabled(module, enabled: false) }
        XCTAssertTrue(model.visiblePanels.isEmpty)
        XCTAssertTrue(music.didStop)
        XCTAssertTrue(jira.didStop)
        XCTAssertEqual(activity.stopCount, 1)
        XCTAssertEqual(preferences.panelOrder, [.jira, .music, .ai, .calendar, .live])

        modules.setEnabled(.calendar, enabled: true)
        XCTAssertEqual(model.visiblePanels, [.calendar])
        XCTAssertEqual(preferences.panelOrder, [.jira, .music, .ai, .calendar, .live])
    }

    func testColdDisabledQuotaDoesNotLoadAndReenableRejectsEarlierResult() async {
        let modules = AppModuleStore(defaults: nil)
        for module in AppModuleID.allCases { modules.setEnabled(module, enabled: false) }
        let provider = DelayedModuleQuotaProvider()
        let model = NotchViewModel(providers: [provider], modules: modules)
        defer { model.stop() }

        model.isCompactHovered = true
        model.isExpanded = true
        model.refresh()
        for _ in 0..<20 { await Task.yield() }
        let coldRequests = await provider.requestCount
        XCTAssertEqual(coldRequests, 0)
        XCTAssertTrue(model.visiblePanels.isEmpty)
        XCTAssertFalse(model.shouldEnableQuotaCornerStack)

        modules.setEnabled(.quotas, enabled: true)
        await provider.waitForRequests(1)
        XCTAssertEqual(model.visiblePanels, [.ai])
        modules.setEnabled(.quotas, enabled: false)
        await provider.finishRequest(0, message: "late")
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNotEqual(model.snapshot(for: provider.id)?.message, "late")

        modules.setEnabled(.quotas, enabled: true)
        XCTAssertNotEqual(model.snapshot(for: provider.id)?.message, "late")
        await provider.waitForRequests(2)
        await provider.finishRequest(1, message: "current")
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(model.snapshot(for: provider.id)?.message, "current")
    }
}

@MainActor
private final class RecordingModuleActivitySource: LiveActivitySource {
    let id = "module-activity"
    let displayName = "Module activity"
    var onChange: (([LiveActivity]) -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start() { startCount += 1 }
    func stop() { stopCount += 1 }
}

private actor DelayedModuleQuotaProvider: QuotaProvider {
    nonisolated let id = "module-delayed"
    nonisolated let displayName = "Module Delayed"
    nonisolated let sourceURL: URL? = nil
    private(set) var requestCount = 0
    private var continuations: [CheckedContinuation<QuotaSnapshot, Never>] = []

    func loadSnapshot() async -> QuotaSnapshot {
        requestCount += 1
        return await withCheckedContinuation { continuations.append($0) }
    }

    func waitForRequests(_ count: Int) async {
        for _ in 0..<100 where requestCount < count { await Task.yield() }
    }

    func finishRequest(_ index: Int, message: String) {
        guard continuations.indices.contains(index) else { return }
        continuations[index].resume(returning: .unavailable(
            providerID: id, providerName: displayName, sourceURL: nil, message: message
        ))
    }
}

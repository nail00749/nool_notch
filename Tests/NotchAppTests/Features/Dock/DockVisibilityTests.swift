import AppKit
import XCTest
@testable import NotchApp

final class DockVisibilityTests: XCTestCase {
    @MainActor
    func testIntelligentStartsHiddenWhenOverlappedAndHasFullscreenCollectionFlags() async throws {
        let fixture = try makeFixture(mode: .intelligent, overlapped: true)
        defer { fixture.stop() }
        fixture.coordinator.start()
        XCTAssertFalse(fixture.coordinator.ownedPanel.isVisible)
        XCTAssertTrue(fixture.coordinator.ownedTrigger.isVisible)
        XCTAssertFalse(fixture.inputs.overlapSamples.isEmpty)
        for panel in [fixture.coordinator.ownedPanel, fixture.coordinator.ownedTrigger] {
            XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
            XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllApplications))
            XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
            XCTAssertFalse(panel.canBecomeKey)
            XCTAssertFalse(panel.canBecomeMain)
            XCTAssertFalse(panel.hidesOnDeactivate)
        }
        await fixture.coordinator.waitForRestoration()
    }

    @MainActor
    func testIntelligentOverlapRetainsHoveredPanelUntilPointerLeavesAndDelayEnds() async throws {
        let fixture = try makeFixture(mode: .intelligent)
        defer { fixture.stop() }
        fixture.coordinator.start()
        XCTAssertTrue(fixture.coordinator.ownedPanel.isVisible)
        fixture.coordinator.setHovered(true)
        fixture.inputs.overlapped = true
        fixture.coordinator.reposition()
        XCTAssertTrue(fixture.coordinator.ownedPanel.isVisible)
        fixture.coordinator.setHovered(false)
        XCTAssertTrue(fixture.coordinator.ownedPanel.isVisible)
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertFalse(fixture.coordinator.ownedPanel.isVisible)
        XCTAssertTrue(fixture.coordinator.ownedTrigger.isVisible)
    }

    @MainActor
    func testMouseDragRetainsVisiblePanelButUnrelatedMouseDownDoesNotRevealHiddenPanel() async throws {
        let fixture = try makeFixture(mode: .intelligent)
        defer { fixture.stop() }
        fixture.coordinator.start()
        fixture.inputs.mouseButtons = 1
        fixture.inputs.overlapped = true
        fixture.coordinator.reposition()
        XCTAssertTrue(fixture.coordinator.ownedPanel.isVisible)
        fixture.inputs.mouseButtons = 0
        fixture.coordinator.setHovered(false)
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertFalse(fixture.coordinator.ownedPanel.isVisible)
        fixture.inputs.mouseButtons = 1
        fixture.coordinator.reposition()
        XCTAssertFalse(fixture.coordinator.ownedPanel.isVisible)
    }

    @MainActor
    func testMousePressedAtHideDeadlineDoesNotLeaveAnUnusableCompletedHideTask() async throws {
        let fixture = try makeFixture(mode: .autoHide)
        defer { fixture.stop() }
        fixture.coordinator.start()
        fixture.coordinator.reveal()
        fixture.inputs.mouseButtons = 1
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertTrue(fixture.coordinator.ownedPanel.isVisible)
        fixture.inputs.mouseButtons = 0
        fixture.coordinator.setHovered(false)
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertFalse(fixture.coordinator.ownedPanel.isVisible)
    }

    @MainActor
    func testEndingInteractionSchedulesAutohideWithoutAnotherPointerExit() async throws {
        let fixture = try makeFixture(mode: .autoHide)
        defer { fixture.stop() }
        fixture.coordinator.start()
        fixture.coordinator.reveal()
        fixture.coordinator.setInteracting(true)
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertTrue(fixture.coordinator.ownedPanel.isVisible)
        fixture.coordinator.setInteracting(false)
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertFalse(fixture.coordinator.ownedPanel.isVisible)
    }

    @MainActor
    func testNestedMenusRetainDockUntilBothMenusFinishTracking() async throws {
        let fixture = try makeFixture(mode: .autoHide)
        defer { fixture.stop() }
        fixture.coordinator.start()
        fixture.coordinator.reveal()
        fixture.coordinator.setHovered(true)
        let parent = NSMenu()
        let child = NSMenu()
        fixture.notifications.post(name: NSMenu.didBeginTrackingNotification, object: parent)
        fixture.notifications.post(name: NSMenu.didBeginTrackingNotification, object: child)
        fixture.coordinator.setHovered(false)
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertTrue(fixture.coordinator.ownedPanel.isVisible)
        fixture.notifications.post(name: NSMenu.didEndTrackingNotification, object: parent)
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertTrue(fixture.coordinator.ownedPanel.isVisible)
        fixture.notifications.post(name: NSMenu.didEndTrackingNotification, object: child)
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertFalse(fixture.coordinator.ownedPanel.isVisible)
    }

    @MainActor
    func testRepeatedSynchronizationDoesNotPostponeAnAlreadyScheduledHide() async throws {
        let fixture = try makeFixture(mode: .autoHide)
        defer { fixture.stop() }
        fixture.coordinator.start()
        fixture.coordinator.reveal()
        for _ in 0..<8 {
            try await Task.sleep(for: .milliseconds(10))
            fixture.coordinator.reposition()
        }
        XCTAssertFalse(fixture.coordinator.ownedPanel.isVisible)
        XCTAssertTrue(fixture.coordinator.ownedTrigger.isVisible)
    }

    @MainActor
    func testSpaceChangeClearsOldPointerMenuAndInteractionWithoutOverlapFlash() async throws {
        let fixture = try makeFixture(mode: .intelligent)
        defer { fixture.stop() }
        fixture.coordinator.start()
        fixture.coordinator.setHovered(true)
        fixture.coordinator.setInteracting(true)
        let menu = NSMenu()
        fixture.notifications.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        fixture.inputs.overlapped = true
        let generation = fixture.feature.surfaceGeneration
        fixture.workspace.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        XCTAssertGreaterThan(fixture.feature.surfaceGeneration, generation)
        XCTAssertFalse(fixture.coordinator.ownedPanel.isVisible)
        XCTAssertTrue(fixture.coordinator.ownedTrigger.isVisible)
        // Late callbacks from the retired surface cannot make the hidden panel sticky again.
        fixture.coordinator.setHovered(true)
        fixture.coordinator.setInteracting(true)
        fixture.notifications.post(name: NSMenu.didEndTrackingNotification, object: menu)
        XCTAssertFalse(fixture.coordinator.ownedPanel.isVisible)
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertFalse(fixture.coordinator.ownedPanel.isVisible)
    }

    @MainActor
    func testSpaceAndScreenChangesCannotWakeSleepingDock() async throws {
        let fixture = try makeFixture(mode: .always)
        defer { fixture.stop() }
        fixture.coordinator.start()
        XCTAssertTrue(fixture.coordinator.ownedPanel.isVisible)
        fixture.workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        XCTAssertFalse(fixture.coordinator.ownedPanel.isVisible)
        fixture.workspace.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        fixture.notifications.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        XCTAssertFalse(fixture.coordinator.ownedPanel.isVisible)
        XCTAssertFalse(fixture.coordinator.ownedTrigger.isVisible)
        fixture.workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        XCTAssertTrue(fixture.coordinator.ownedPanel.isVisible)
    }

    @MainActor
    func testScreenParametersInvalidatePanelGeometryAndCloseTransientSurfaces() async throws {
        let fixture = try makeFixture(mode: .always)
        defer { fixture.stop() }
        fixture.coordinator.start()
        let frame = fixture.coordinator.ownedPanel.frame
        let generation = fixture.feature.surfaceGeneration
        fixture.coordinator.ownedPanel.setFrame(frame.offsetBy(dx: 17, dy: 20), display: false)
        fixture.inputs.screens.append(CGRect(x: 1_440, y: 0, width: 1_920, height: 1_080))
        fixture.notifications.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(fixture.coordinator.ownedPanel.frame, frame)
        XCTAssertGreaterThan(fixture.feature.surfaceGeneration, generation)
    }

    /// Software dimming and gamma updates repeat the notification without changing any screen.
    @MainActor
    func testRepeatedScreenNotificationsWithoutGeometryChangeAreIgnored() async throws {
        let fixture = try makeFixture(mode: .always)
        defer { fixture.stop() }
        fixture.coordinator.start()
        let generation = fixture.feature.surfaceGeneration
        let samples = fixture.inputs.overlapSamples.count
        for _ in 0..<50 {
            fixture.notifications.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        }
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(fixture.feature.surfaceGeneration, generation)
        XCTAssertEqual(fixture.inputs.overlapSamples.count, samples)
        fixture.inputs.screens[0].size.height -= 25
        for _ in 0..<50 {
            fixture.notifications.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        }
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(fixture.feature.surfaceGeneration, generation + 1, "A burst is coalesced into one reset")
    }

    @MainActor
    func testSwitchingToIntelligentSamplesOverlapBeforeShowing() throws {
        let fixture = try makeFixture(mode: .always, overlapped: true)
        defer { fixture.stop() }
        fixture.coordinator.start()
        XCTAssertTrue(fixture.coordinator.ownedPanel.isVisible)
        fixture.preferences.visibility = .intelligent
        XCTAssertFalse(fixture.coordinator.ownedPanel.isVisible)
        XCTAssertTrue(fixture.coordinator.ownedTrigger.isVisible)
    }

    @MainActor
    func testEdgeStripIsClickThroughAndRevealsOnlyOnPointerContact() async throws {
        let fixture = try makeFixture(mode: .autoHide)
        defer { fixture.stop() }
        fixture.coordinator.start()
        let strip = fixture.coordinator.ownedTrigger
        XCTAssertTrue(strip.isVisible)
        XCTAssertTrue(strip.ignoresMouseEvents, "Other applications must keep clicks at the bottom edge")
        fixture.coordinator.pointerMoved(to: CGPoint(x: strip.frame.midX, y: strip.frame.maxY + 40))
        XCTAssertFalse(fixture.coordinator.ownedPanel.isVisible)
        fixture.coordinator.pointerMoved(to: CGPoint(x: strip.frame.midX, y: strip.frame.minY))
        XCTAssertTrue(fixture.coordinator.ownedPanel.isVisible)
        XCTAssertFalse(strip.isVisible)
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertFalse(fixture.coordinator.ownedPanel.isVisible)
    }

    @MainActor
    func testClickOutsideClosesFanAndSurfacesButNotOwnWindows() throws {
        let fixture = try makeFixture(mode: .always)
        defer { fixture.stop() }
        fixture.coordinator.start()
        let feature = fixture.feature
        feature.fan.present(element: DockElement(id: "stack:/tmp", kind: .stack, title: "tmp", directoryPath: "/tmp"),
                            files: [DockStackFile(url: URL(fileURLWithPath: "/tmp/a"), title: "a", isDirectory: false, modifiedAt: nil)],
                            provider: feature.stacks, anchor: CGRect(x: 300, y: 10, width: 64, height: 64), dockTop: 84,
                            screen: NSScreen.screens[0].visibleFrame, interactionChanged: { fixture.coordinator.setInteracting($0) })
        XCTAssertTrue(fixture.coordinator.ownsWindow(fixture.coordinator.ownedPanel))
        XCTAssertTrue(fixture.coordinator.ownsWindow(feature.fan.window))
        XCTAssertFalse(fixture.coordinator.ownsWindow(NSWindow()))
        let generation = feature.surfaceGeneration
        fixture.coordinator.clickedOutside()
        XCTAssertNil(feature.fan.presentedID)
        XCTAssertEqual(feature.surfaceGeneration, generation + 1)
        fixture.coordinator.clickedOutside()
        XCTAssertEqual(feature.surfaceGeneration, generation + 1, "Nothing open: outside clicks are ignored")
    }

    @MainActor
    func testSideDockAnchorsToItsEdgeAndRevealsFromThatEdge() async throws {
        let fixture = try makeFixture(mode: .autoHide)
        defer { fixture.stop() }
        fixture.preferences.position = .left
        fixture.coordinator.start()
        let strip = fixture.coordinator.ownedTrigger
        let bounds = try XCTUnwrap(NSScreen.screens.first).visibleFrame
        XCTAssertEqual(strip.frame.width, 5)
        XCTAssertEqual(strip.frame.minX, bounds.minX, accuracy: 0.5)
        fixture.coordinator.pointerMoved(to: CGPoint(x: strip.frame.minX, y: strip.frame.midY))
        let panel = fixture.coordinator.ownedPanel
        XCTAssertTrue(panel.isVisible)
        XCTAssertGreaterThan(panel.frame.height, panel.frame.width, "A side Dock is vertical")
        let dockFrame = try XCTUnwrap(fixture.feature.dockFrame)
        // AppKit rounds window frames to the display's pixel grid.
        let expected = DockLayout.windowFrame(strip: dockFrame, position: .left, scale: 1)
        XCTAssertEqual(panel.frame.minX, expected.minX, accuracy: 1)
        XCTAssertEqual(panel.frame.minY, expected.minY, accuracy: 1)
        XCTAssertEqual(panel.frame.width, expected.width, accuracy: 1,
                       "The panel adds bounce headroom on the side facing the screen")
        XCTAssertEqual(panel.frame.height, expected.height, accuracy: 1)
        XCTAssertEqual(panel.frame.minX, dockFrame.minX)
        fixture.preferences.position = .right
        XCTAssertEqual(panel.frame.maxX, bounds.maxX - 8, accuracy: 0.5)
        XCTAssertEqual(fixture.feature.dockFrame?.maxX ?? 0, bounds.maxX - 8, accuracy: 0.5)
        XCTAssertEqual(strip.frame.maxX, bounds.maxX, accuracy: 0.5)
    }

    @MainActor
    func testAutoHiddenDockRevealsOnlyAfterPointerRestsOnEdge() async throws {
        let fixture = try makeFixture(mode: .autoHide, revealDelay: .milliseconds(60))
        defer { fixture.stop() }
        fixture.coordinator.start()
        let strip = fixture.coordinator.ownedTrigger.frame
        let edge = CGPoint(x: strip.midX, y: strip.minY)
        let panel = fixture.coordinator.ownedPanel

        // Passing through the edge does not show the Dock.
        fixture.inputs.pointer = edge
        fixture.coordinator.pointerMoved(to: edge)
        XCTAssertFalse(panel.isVisible)
        fixture.inputs.pointer = CGPoint(x: strip.midX, y: strip.maxY + 200)
        fixture.coordinator.pointerMoved(to: fixture.inputs.pointer)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertFalse(panel.isVisible)

        // Resting on it does.
        fixture.inputs.pointer = edge
        fixture.coordinator.pointerMoved(to: edge)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(panel.isVisible)
    }

    @MainActor
    func testFullscreenApplicationHidesAlwaysVisibleDockUntilEdgeIsReached() async throws {
        let fixture = try makeFixture(mode: .always)
        defer { fixture.stop() }
        fixture.coordinator.start()
        XCTAssertTrue(fixture.coordinator.ownedPanel.isVisible)
        fixture.inputs.fullscreen = true
        fixture.workspace.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        XCTAssertFalse(fixture.coordinator.ownedPanel.isVisible)
        XCTAssertTrue(fixture.coordinator.ownedTrigger.isVisible)
        let screen = try XCTUnwrap(fixture.coordinator.ownedTrigger.screen ?? NSScreen.screens.first)
        XCTAssertEqual(fixture.coordinator.ownedTrigger.frame.minY, screen.frame.minY, accuracy: 1)
        fixture.coordinator.reveal()
        XCTAssertTrue(fixture.coordinator.ownedPanel.isVisible)
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertFalse(fixture.coordinator.ownedPanel.isVisible)
        // Leaving full screen restores the user's mode, including after the settle recheck.
        fixture.inputs.fullscreen = false
        fixture.workspace.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(fixture.coordinator.ownedPanel.isVisible)
    }

    @MainActor
    func testApplicationActivationResamplesFullscreenAfterTransitionSettles() async throws {
        let fixture = try makeFixture(mode: .always)
        defer { fixture.stop() }
        fixture.coordinator.start()
        XCTAssertTrue(fixture.coordinator.ownedPanel.isVisible)
        fixture.workspace.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        fixture.inputs.fullscreen = true // The full-screen window appears only after the animation.
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertFalse(fixture.coordinator.ownedPanel.isVisible)
    }

    @MainActor
    func testFullscreenGameOrVideoKeepsEdgeInertUntilPlaybackStops() async throws {
        let fixture = try makeFixture(mode: .always)
        defer { fixture.stop() }
        fixture.coordinator.start()
        fixture.inputs.fullscreen = true
        fixture.inputs.immersive = true
        fixture.workspace.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        XCTAssertEqual(fixture.inputs.immersiveChecks.last, 4_242)
        XCTAssertFalse(fixture.coordinator.ownedPanel.isVisible)
        XCTAssertFalse(fixture.coordinator.ownedTrigger.isVisible, "The edge must not summon the Dock")
        let edge = CGPoint(x: fixture.coordinator.ownedPanel.frame.midX, y: NSScreen.screens[0].frame.minY)
        fixture.coordinator.pointerMoved(to: edge)
        XCTAssertFalse(fixture.coordinator.ownedPanel.isVisible)
        // Pausing the video releases its display assertion; the next poll re-arms the edge.
        fixture.inputs.immersive = false
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertTrue(fixture.coordinator.ownedTrigger.isVisible)
        XCTAssertFalse(fixture.coordinator.ownedPanel.isVisible)
        // Playback resumes while the Dock is open: it hides without waiting for the pointer.
        fixture.coordinator.reveal()
        XCTAssertTrue(fixture.coordinator.ownedPanel.isVisible)
        fixture.inputs.immersive = true
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertFalse(fixture.coordinator.ownedPanel.isVisible)
        XCTAssertFalse(fixture.coordinator.ownedTrigger.isVisible)
    }

    @MainActor
    func testPointerRestingOnEdgeRevealsByPollingAndKeepsDockOpen() async throws {
        let fixture = try makeFixture(mode: .autoHide)
        defer { fixture.stop() }
        fixture.coordinator.start()
        let strip = fixture.coordinator.ownedTrigger.frame
        XCTAssertTrue(fixture.coordinator.ownedTrigger.isVisible)
        // No mouse-moved event at all: the poll alone notices the pointer on the bottom row.
        fixture.inputs.pointer = CGPoint(x: strip.midX, y: strip.minY)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(fixture.coordinator.ownedPanel.isVisible)
        // Resting on the edge below the panel is not "leaving" the Dock.
        try await Task.sleep(for: .milliseconds(90))
        XCTAssertTrue(fixture.coordinator.ownedPanel.isVisible)
        fixture.inputs.pointer = CGPoint(x: strip.midX, y: strip.maxY + 400)
        try await Task.sleep(for: .milliseconds(90))
        XCTAssertFalse(fixture.coordinator.ownedPanel.isVisible)
    }

    @MainActor
    func testExcludedApplicationAndOptionsReachImmersiveCheck() throws {
        let fixture = try makeFixture(mode: .always)
        defer { fixture.stop() }
        fixture.preferences.hideInFullscreenVideo = false
        fixture.preferences.addFullscreenExclusion("com.example.player")
        fixture.coordinator.start()
        fixture.inputs.fullscreen = true
        fixture.workspace.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        XCTAssertEqual(fixture.inputs.immersiveOptions,
                       .init(games: true, video: false, excludedBundleIdentifiers: ["com.example.player"]))
    }

    @MainActor
    func testRegularWindowsNeverQueryImmersiveContent() throws {
        let fixture = try makeFixture(mode: .autoHide)
        defer { fixture.stop() }
        fixture.inputs.immersive = true
        fixture.coordinator.start()
        XCTAssertTrue(fixture.inputs.immersiveChecks.isEmpty)
        XCTAssertTrue(fixture.coordinator.ownedTrigger.isVisible)
    }

    func testGameCategoryAndVideoAssertionClassification() {
        XCTAssertTrue(DockImmersiveContent.isGame(category: "public.app-category.games", bundlePath: "/Applications/A.app"))
        XCTAssertTrue(DockImmersiveContent.isGame(category: "public.app-category.action-games", bundlePath: "/Applications/A.app"))
        XCTAssertTrue(DockImmersiveContent.isGame(category: nil,
            bundlePath: "/Users/u/Library/Application Support/Steam/steamapps/common/Game/Game.app"))
        XCTAssertFalse(DockImmersiveContent.isGame(category: "public.app-category.video", bundlePath: "/Applications/IINA.app"))
        XCTAssertFalse(DockImmersiveContent.isGame(category: nil, bundlePath: "/Applications/Safari.app"))

        let playback: [String: Any] = ["AssertType": "PreventUserIdleDisplaySleep",
                                       "AssertName": "com.apple.WebCore: HTMLMediaElement playback"]
        let electronIdle: [String: Any] = ["AssertType": "NoIdleSleepAssertion", "AssertName": "Electron"]
        let music: [String: Any] = ["AssertType": "PreventUserIdleSystemSleep"]
        XCTAssertTrue(DockImmersiveContent.holdsVideoAssertion([(pid: 10, assertions: [playback])], owner: 10))
        XCTAssertFalse(DockImmersiveContent.holdsVideoAssertion([(pid: 11, assertions: [playback])], owner: 10),
                       "Another application's video must not affect this one")
        XCTAssertFalse(DockImmersiveContent.holdsVideoAssertion([(pid: 10, assertions: [electronIdle, music])], owner: 10))
        var onBehalf = playback
        onBehalf["AssertionOnBehalfOfPID"] = NSNumber(value: 10)
        XCTAssertTrue(DockImmersiveContent.holdsVideoAssertion([(pid: 795, assertions: [onBehalf])], owner: 10))
        XCTAssertTrue(DockImmersiveContent.holdsVideoAssertion([(pid: 12, assertions: [playback])], owner: 10,
                                                              isHelper: { $0 == 12 }))
    }

    func testFullscreenDetectionAcceptsNotchedFullscreenAndRejectsMaximizedWindowAmongOthers() {
        // Measured on a 1800×1169 notched display: full-screen content starts below the 39 pt strip.
        let display = CGRect(x: 0, y: 0, width: 1800, height: 1169)
        let fullscreen = DockFullscreenDetection.Window(pid: 7, frame: CGRect(x: 0, y: 39, width: 1800, height: 1130))
        let titlebar = DockFullscreenDetection.Window(pid: 7, frame: CGRect(x: 0, y: 39, width: 1800, height: 32))
        XCTAssertTrue(DockFullscreenDetection.isFullscreen(windows: [fullscreen, titlebar], display: display, topInset: 39))
        // Same geometry, but another application's window is on this Space: an ordinary maximized window.
        let other = DockFullscreenDetection.Window(pid: 9, frame: CGRect(x: 100, y: 100, width: 600, height: 400))
        XCTAssertFalse(DockFullscreenDetection.isFullscreen(windows: [fullscreen, other], display: display, topInset: 39))
        // Non-notched display: content covers the entire frame.
        let edgeToEdge = DockFullscreenDetection.Window(pid: 7, frame: display)
        XCTAssertTrue(DockFullscreenDetection.isFullscreen(windows: [edgeToEdge], display: display, topInset: 0))
        // A window that does not reach the bottom edge, or starts lower than the strip, is not full screen.
        let short = DockFullscreenDetection.Window(pid: 7, frame: CGRect(x: 0, y: 39, width: 1800, height: 1000))
        let lowered = DockFullscreenDetection.Window(pid: 7, frame: CGRect(x: 0, y: 80, width: 1800, height: 1089))
        XCTAssertFalse(DockFullscreenDetection.isFullscreen(windows: [short], display: display, topInset: 39))
        XCTAssertFalse(DockFullscreenDetection.isFullscreen(windows: [lowered], display: display, topInset: 39))
        XCTAssertFalse(DockFullscreenDetection.isFullscreen(windows: [], display: display, topInset: 39))
    }

    @MainActor
    private func makeFixture(mode: DockVisibilityMode, overlapped: Bool = false,
                             revealDelay: Duration = .zero) throws -> VisibilityFixture {
        _ = NSApplication.shared
        guard NSScreen.screens.first != nil else { throw XCTSkip("Requires an AppKit display") }
        let suite = "DockVisibilityTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let preferences = DockPreferences(defaults: defaults)
        preferences.visibility = mode
        preferences.isEnabled = true
        let feature = DockFeatureModel(prefs: preferences,
            systemDock: SystemDockController(operations: VisibilitySystemOperations()))
        let model = NotchViewModel(providers: [], calendarProvider: FakeCalendarProvider(),
            nowPlayingProvider: FakeNowPlayingProvider(), liveActivityCenter: LiveActivityCenter(additionalSources: []),
            jiraProvider: FakeJiraProvider(), preferences: MemoryAppPreferences(hiddenPanelIDs: [.calendar]),
            modules: AppModuleStore(defaults: nil), displays: makeTestDisplayFeatureModel())
        let inputs = VisibilityInputs()
        inputs.overlapped = overlapped
        let notifications = NotificationCenter()
        let workspace = NotificationCenter()
        let environment = DockCoordinatorEnvironment(mouseButtons: { inputs.mouseButtons },
            overlap: { inputs.overlapSamples.append($0); return inputs.overlapped },
            fullscreenOwner: { _ in inputs.fullscreen ? 4_242 : nil },
            immersive: { pid, options in inputs.immersiveChecks.append(pid); inputs.immersiveOptions = options; return inputs.immersive },
            pointerLocation: { inputs.pointer }, edgePollInterval: .milliseconds(10),
            immersivePollInterval: .milliseconds(10), fullscreenSettleDelay: .milliseconds(10),
            hideDelay: .milliseconds(25), revealDelay: revealDelay, notificationCenter: notifications,
            workspaceNotificationCenter: workspace, installEventMonitors: false,
            screenSignature: { inputs.screens }, screenChangeDelay: .milliseconds(5), animatesVisibility: false)
        let coordinator = DockWindowCoordinator(feature: feature, model: model, environment: environment)
        // Tests drive exact events themselves, independent of the user's current pointer position.
        coordinator.ownedPanel.contentView = NSView()
        coordinator.ownedTrigger.contentView = NSView()
        return .init(coordinator: coordinator, feature: feature, preferences: preferences,
                     inputs: inputs, notifications: notifications, workspace: workspace, defaults: defaults, suite: suite)
    }
}

@MainActor
private final class VisibilityInputs {
    var mouseButtons = 0
    var screens: [CGRect] = [CGRect(x: 0, y: 0, width: 1_440, height: 900)]
    var overlapped = false
    var fullscreen = false
    var immersive = false
    var immersiveChecks: [Int32] = []
    var immersiveOptions: DockImmersiveContent.Options?
    /// Far outside every screen unless a test places the pointer.
    var pointer = CGPoint(x: -100_000, y: -100_000)
    var overlapSamples: [CGRect] = []
}

@MainActor
private struct VisibilityFixture {
    let coordinator: DockWindowCoordinator
    let feature: DockFeatureModel
    let preferences: DockPreferences
    let inputs: VisibilityInputs
    let notifications: NotificationCenter
    let workspace: NotificationCenter
    let defaults: UserDefaults
    let suite: String
    func stop() { coordinator.stop(); defaults.removePersistentDomain(forName: suite) }
}

private actor VisibilitySystemOperations: SystemDockOperating {
    func perform(_ operation: SystemDockOperation) async -> SystemDockOperationResult {
        .init(active: operation == .enable)
    }
}

import AppKit
import CoreGraphics
import XCTest
@testable import NotchApp

final class DockWindowPreviewTests: XCTestCase {
    func testMatchingRequiresUniqueTitleAndGeometry() {
        let frame = CGRect(x: -1_000, y: 50, width: 800, height: 600)
        XCTAssertEqual(DockWindowMatching.uniqueIndex(title: "Editor", frame: frame,
                                                      candidates: [("Editor", frame), ("Other", frame)]), 0)
        XCTAssertNil(DockWindowMatching.uniqueIndex(title: "Editor", frame: frame,
                                                    candidates: [("Editor", frame), ("Editor", frame)]))
        XCTAssertNil(DockWindowMatching.uniqueIndex(title: "Editor", frame: frame,
                                                    candidates: [("Other", frame)]))
        XCTAssertFalse(DockWindowMatching.matches(title: "Editor", frame: frame, candidateTitle: "Editor",
                                                  candidateFrame: frame.offsetBy(dx: 4, dy: 0)))
        XCTAssertFalse(DockWindowMatching.framesMatch(.zero, .zero))
        XCTAssertFalse(DockWindowMatching.framesMatch(CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1), frame))
    }

    func testObservedWarpFixtureIncludesOneWindowAndExcludesEightHiddenStrips() {
        // Read-only Warp observation: one AXStandardWindow, four hidden 5120×30 surfaces,
        // four hidden 1800×39 surfaces, and one layer-3 popup. No terminal text is recorded.
        let mainFrame = CGRect(x: -1_614, y: -1_410, width: 2_560, height: 1_410)
        var descriptors = [descriptor(id: 1, title: "Terminal", frame: mainFrame)]
        descriptors += (2...5).map { descriptor(id: UInt32($0), title: "",
            frame: CGRect(x: -1_614, y: -1_440, width: 5_120, height: 30), onScreen: false) }
        descriptors += (6...9).map { descriptor(id: UInt32($0), title: "",
            frame: CGRect(x: 0, y: 0, width: 1_800, height: 39), onScreen: false) }
        descriptors.append(descriptor(id: 10, title: "", frame: CGRect(x: -1_398, y: -67, width: 144, height: 83),
                                      onScreen: false, layer: 3))
        let ax = accessibility(title: "Terminal", frame: mainFrame)
        let records = DockWindowRecordBuilder.records(application: PreviewEnvironment.application,
            descriptors: descriptors, accessibility: [ax], captureWindowIDs: Set(1...10))
        XCTAssertEqual(records.map(\.id), [1])
        XCTAssertEqual(records.first?.captureWindowID, 1)
        XCTAssertEqual(records.first?.accessibilityToken, ax.token)
        XCTAssertTrue(records.first?.availableActions.contains(.activate) == true)
    }

    func testMinimizedAndOtherSpaceStandardWindowsSurviveEligibilityFilter() {
        let frame = CGRect(x: 100, y: 100, width: 800, height: 600)
        let minimized = accessibility(title: "Minimized", frame: frame, minimized: true)
        let otherSpace = accessibility(title: "Other Space", frame: frame.offsetBy(dx: 20, dy: 0))
        let missingFromCG = accessibility(title: "AX minimized", frame: frame.offsetBy(dx: 40, dy: 0), minimized: true)
        let records = DockWindowRecordBuilder.records(application: PreviewEnvironment.application,
            descriptors: [descriptor(id: 1, title: "Minimized", frame: frame, onScreen: false),
                          descriptor(id: 2, title: "Other Space", frame: otherSpace.frame, onScreen: false)],
            accessibility: [minimized, otherSpace, missingFromCG], captureWindowIDs: [1, 2])
        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(records.first(where: { $0.title == "Minimized" })?.isMinimized, true)
        XCTAssertEqual(records.first(where: { $0.title == "Other Space" })?.captureWindowID, 2)
        XCTAssertEqual(records.first(where: { $0.title == "AX minimized" })?.isMinimized, true)
    }

    func testNoAXKeepsNamedOtherSpaceButRejectsHiddenNamelessAndTransparentWindows() {
        let frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let records = DockWindowRecordBuilder.records(application: PreviewEnvironment.application,
            descriptors: [descriptor(id: 1, title: "", frame: frame, onScreen: false),
                          descriptor(id: 2, title: "Other Space", frame: frame, onScreen: false),
                          descriptor(id: 3, title: "Invisible", frame: frame, alpha: 0),
                          descriptor(id: 4, title: "Popup", frame: frame, layer: 3)],
            accessibility: [], captureWindowIDs: [1, 2, 3, 4])
        XCTAssertEqual(records.map(\.id), [2])
    }

    func testTitleRaceDeduplicatesRepresentationWithoutGuessingAXActions() {
        let frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let records = DockWindowRecordBuilder.records(application: PreviewEnvironment.application,
            descriptors: [descriptor(id: 1, title: "New title", frame: frame)],
            accessibility: [accessibility(title: "Old title", frame: frame)], captureWindowIDs: [1])
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].title, "New title")
        XCTAssertEqual(records[0].captureWindowID, 1)
        XCTAssertNil(records[0].accessibilityToken)
        XCTAssertTrue(records[0].availableActions.isEmpty)
    }

    func testAmbiguousMatchingDoesNotDuplicateAXFallbacksOrGrantActions() {
        let frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let records = DockWindowRecordBuilder.records(application: PreviewEnvironment.application,
            descriptors: [descriptor(id: 1, title: "Same", frame: frame), descriptor(id: 2, title: "Same", frame: frame)],
            accessibility: [accessibility(title: "Same", frame: frame), accessibility(title: "Same", frame: frame)],
            captureWindowIDs: [1, 2])
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(Set(records.map(\.id)), [1, 2])
        XCTAssertTrue(records.allSatisfy { $0.accessibilityToken == nil && $0.availableActions.isEmpty })
    }

    func testRedactedCaptureTitlePreservesNamedExactAXWindowWithoutGuessedCaptureID() {
        let frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let ax = accessibility(title: "Named document", frame: frame)
        let records = DockWindowRecordBuilder.records(application: PreviewEnvironment.application,
            descriptors: [descriptor(id: 1, title: "", frame: frame)],
            accessibility: [ax], captureWindowIDs: [])
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].title, "Named document")
        XCTAssertEqual(records[0].accessibilityToken, ax.token)
        XCTAssertNil(records[0].captureWindowID)
        XCTAssertTrue(records[0].availableActions.contains(.activate))
    }

    @MainActor
    func testHoverWithoutPermissionDoesNotPromptOrEnumerate() async {
        let environment = PreviewEnvironment()
        let backend = PreviewBackend()
        let service = DockWindowPreviewService(backend: backend, environment: environment)
        await service.show(applicationPath: environment.identity.applicationPath)
        let calls = await backend.enumerationCount
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(environment.captureRequests, 0)
        XCTAssertEqual(environment.accessibilityRequests, 0)
        XCTAssertFalse(service.isLoading)
        XCTAssertTrue(service.windows.isEmpty)
        service.requestCaptureAccess()
        service.requestAccessibilityAccess()
        XCTAssertEqual(environment.captureRequests, 1)
        XCTAssertEqual(environment.accessibilityRequests, 1)
    }

    @MainActor
    func testAXOnlyListsPlaceholderAndNeverCaptures() async {
        let environment = PreviewEnvironment(accessibility: true)
        let backend = PreviewBackend(records: [Self.record()])
        let service = DockWindowPreviewService(backend: backend, environment: environment)
        await service.show(applicationPath: environment.identity.applicationPath)
        let captures = await backend.capturedIDs
        XCTAssertEqual(service.windows.map(\.title), ["Document"])
        XCTAssertNil(service.windows.first?.image)
        XCTAssertTrue(captures.isEmpty)
    }

    @MainActor
    func testMinimizedWindowHasPlaceholderWhileOtherWindowCaptures() async {
        let environment = PreviewEnvironment(capture: true, accessibility: true)
        let backend = PreviewBackend(records: [Self.record(id: 1, minimized: true), Self.record(id: 2)])
        let service = DockWindowPreviewService(backend: backend, environment: environment)
        await service.show(applicationPath: environment.identity.applicationPath)
        let captures = await backend.capturedIDs
        XCTAssertEqual(captures, [2])
        XCTAssertNil(service.windows.first?.image)
        XCTAssertNotNil(service.windows.last?.image)
    }

    @MainActor
    func testOneUnavailableThumbnailDoesNotHideOtherWindows() async {
        let environment = PreviewEnvironment(capture: true)
        let backend = PreviewBackend(records: [Self.record(id: 1), Self.record(id: 2)], failingCapture: 1)
        let service = DockWindowPreviewService(backend: backend, environment: environment)
        await service.show(applicationPath: environment.identity.applicationPath)
        XCTAssertEqual(service.windows.count, 2)
        XCTAssertNil(service.windows[0].image)
        XCTAssertNotNil(service.windows[1].image)
        XCTAssertNil(service.errorMessage)
    }

    @MainActor
    func testTotalCaptureFailureExplainsMissingPreviewWithoutHidingWindow() async {
        let environment = PreviewEnvironment(capture: true)
        let backend = PreviewBackend(records: [Self.record()], failingCapture: 1)
        let service = DockWindowPreviewService(backend: backend, environment: environment)
        await service.show(applicationPath: environment.identity.applicationPath)
        XCTAssertEqual(service.windows.count, 1)
        XCTAssertNil(service.windows[0].image)
        XCTAssertNotNil(service.errorMessage)
        XCTAssertFalse(service.isLoading)
    }

    @MainActor
    func testOpenPreviewHasBoundedNumberOfImagesAndCancelDropsThem() async {
        let environment = PreviewEnvironment(capture: true)
        let backend = PreviewBackend(records: (1...40).map { Self.record(id: UInt32($0)) })
        let service = DockWindowPreviewService(backend: backend, environment: environment)
        await service.show(applicationPath: environment.identity.applicationPath)
        let captures = await backend.capturedIDs
        XCTAssertEqual(service.windows.count, 24)
        XCTAssertEqual(captures.count, 24)
        service.cancel()
        XCTAssertTrue(service.windows.isEmpty)
        XCTAssertFalse(service.isLoading)
    }

    @MainActor
    func testCancelledEnumerationCannotRepopulateHiddenPreview() async {
        let environment = PreviewEnvironment(accessibility: true)
        let backend = PreviewBackend(records: [Self.record()], suspendEnumeration: true)
        let service = DockWindowPreviewService(backend: backend, environment: environment)
        let showing = Task { await service.show(applicationPath: environment.identity.applicationPath) }
        await backend.waitForEnumeration()
        service.cancel()
        await backend.resumeEnumeration()
        await showing.value
        XCTAssertTrue(service.windows.isEmpty)
        XCTAssertFalse(service.isLoading)
    }

    @MainActor
    func testOldPresentationCannotCancelNewApplicationOrDeliverItsLateEnumeration() async {
        let environment = PreviewEnvironment(capture: true, accessibility: true)
        let second = DockWindowApplicationIdentity(pid: 5_678, applicationPath: "/Applications/Second.app",
                                                   launchDate: Date(timeIntervalSince1970: 200))
        environment.otherApplications[second.applicationPath] = second
        let backend = PreviewBackend(records: [Self.record(title: "First")], suspendEnumeration: true)
        let service = DockWindowPreviewService(backend: backend, environment: environment)
        let firstPresentation = UUID()
        let secondPresentation = UUID()
        let firstShow = Task {
            await service.show(applicationPath: environment.identity.applicationPath, presentationID: firstPresentation)
        }
        await backend.waitForEnumeration()
        await backend.setRecords([Self.record(id: 2, title: "Second", application: second)])
        await service.show(applicationPath: second.applicationPath, presentationID: secondPresentation)
        service.cancel(presentationID: firstPresentation)
        await backend.resumeEnumeration()
        await firstShow.value
        XCTAssertEqual(service.windows.map(\.title), ["Second"])
        XCTAssertEqual(service.windows.first?.pid, second.pid)
        XCTAssertNotNil(service.windows.first?.image)
        XCTAssertFalse(service.isLoading)
        XCTAssertNil(service.errorMessage)
        service.cancel(presentationID: secondPresentation)
        XCTAssertTrue(service.windows.isEmpty)
    }

    @MainActor
    func testOldPresentationCannotCancelReopenedSameApplication() async {
        let environment = PreviewEnvironment(capture: true)
        let backend = PreviewBackend(records: [Self.record()])
        let service = DockWindowPreviewService(backend: backend, environment: environment)
        let oldPresentation = UUID()
        let newPresentation = UUID()
        await service.show(applicationPath: environment.identity.applicationPath, presentationID: oldPresentation)
        await service.show(applicationPath: environment.identity.applicationPath, presentationID: newPresentation)
        service.cancel(presentationID: oldPresentation)
        XCTAssertEqual(service.windows.count, 1)
        XCTAssertNotNil(service.windows.first?.image)
        XCTAssertNil(service.errorMessage)
        service.cancel(presentationID: newPresentation)
        XCTAssertTrue(service.windows.isEmpty)
    }

    @MainActor
    func testActionRefreshPreservesPresentationOwnershipAndGlobalCancelStillClears() async {
        let environment = PreviewEnvironment(accessibility: true)
        let backend = PreviewBackend(records: [Self.record()])
        let service = DockWindowPreviewService(backend: backend, environment: environment)
        let presentation = UUID()
        await service.show(applicationPath: environment.identity.applicationPath, presentationID: presentation)
        await service.perform(.zoom, on: service.windows[0])
        XCTAssertEqual(service.windows.count, 1)
        service.cancel(presentationID: presentation)
        XCTAssertTrue(service.windows.isEmpty)
        await service.show(applicationPath: environment.identity.applicationPath, presentationID: UUID())
        service.cancel()
        XCTAssertTrue(service.windows.isEmpty)
    }

    @MainActor
    func testAlreadyCancelledOldTaskCannotClaimNewPresentation() async {
        let environment = PreviewEnvironment(capture: true)
        let backend = PreviewBackend(records: [Self.record()])
        let service = DockWindowPreviewService(backend: backend, environment: environment)
        await service.show(applicationPath: environment.identity.applicationPath, presentationID: UUID())
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await service.show(applicationPath: environment.identity.applicationPath, presentationID: UUID())
        }
        await cancelled.value
        let count = await backend.enumerationCount
        XCTAssertEqual(count, 1)
        XCTAssertEqual(service.windows.count, 1)
        XCTAssertNotNil(service.windows.first?.image)
    }

    @MainActor
    func testOldActionCompletionCannotCloseSuccessorPresentation() async {
        let environment = PreviewEnvironment(accessibility: true)
        let backend = PreviewBackend(records: [Self.record()])
        let service = DockWindowPreviewService(backend: backend, environment: environment)
        let first = UUID()
        let second = UUID()
        await service.show(applicationPath: environment.identity.applicationPath, presentationID: first)
        let oldWindow = service.windows[0]
        await backend.suspendActions()
        let action = Task { await service.perform(.activate, on: oldWindow, presentationID: first) }
        await backend.waitForAction()
        await service.show(applicationPath: environment.identity.applicationPath, presentationID: second)
        await backend.resumeAction()
        await action.value
        XCTAssertTrue(service.isPresented(by: second))
        XCTAssertFalse(service.isPresented(by: first))
        XCTAssertEqual(service.windows.count, 1)
        XCTAssertNil(service.errorMessage)
    }

    @MainActor
    func testStaleSurfaceCannotDispatchWindowActionOrPublishErrorToSuccessor() async {
        let environment = PreviewEnvironment(accessibility: true)
        let backend = PreviewBackend(records: [Self.record()])
        let service = DockWindowPreviewService(backend: backend, environment: environment)
        let first = UUID()
        let second = UUID()
        await service.show(applicationPath: environment.identity.applicationPath, presentationID: first)
        let oldWindow = service.windows[0]
        await service.show(applicationPath: environment.identity.applicationPath, presentationID: second)
        await service.perform(.activate, on: oldWindow, presentationID: first)
        let actions = await backend.actions
        XCTAssertTrue(actions.isEmpty)
        XCTAssertTrue(service.isPresented(by: second))
        XCTAssertEqual(service.windows.count, 1)
        XCTAssertNil(service.errorMessage)
    }

    @MainActor
    func testReusedProcessIdentityRejectsEnumerationAndActions() async {
        let environment = PreviewEnvironment(accessibility: true)
        let backend = PreviewBackend(records: [Self.record()], suspendEnumeration: true)
        let service = DockWindowPreviewService(backend: backend, environment: environment)
        let showing = Task { await service.show(applicationPath: environment.identity.applicationPath) }
        await backend.waitForEnumeration()
        environment.current = false
        await backend.resumeEnumeration()
        await showing.value
        XCTAssertTrue(service.windows.isEmpty)
        XCTAssertFalse(service.isLoading)
        XCTAssertNotNil(service.errorMessage)
    }

    @MainActor
    func testStaleRecordWithReusedIDCannotActOnNewWindow() async {
        let environment = PreviewEnvironment(accessibility: true)
        let current = Self.record(title: "Current")
        let backend = PreviewBackend(records: [current])
        let service = DockWindowPreviewService(backend: backend, environment: environment)
        await service.show(applicationPath: environment.identity.applicationPath)
        let stale = DockWindowPreview(record: Self.record(title: "Old"), image: nil)
        await service.perform(.close, on: stale)
        let actions = await backend.actions
        XCTAssertTrue(actions.isEmpty)
        XCTAssertNotNil(service.errorMessage)
    }

    @MainActor
    func testRevokedAXPermissionPreventsExactWindowAction() async {
        let environment = PreviewEnvironment(accessibility: true)
        let backend = PreviewBackend(records: [Self.record()])
        let service = DockWindowPreviewService(backend: backend, environment: environment)
        await service.show(applicationPath: environment.identity.applicationPath)
        let preview = service.windows[0]
        environment.accessibility = false
        await service.perform(.close, on: preview)
        let actions = await backend.actions
        XCTAssertTrue(actions.isEmpty)
        XCTAssertFalse(service.hasAccessibilityAccess)
    }

    @MainActor
    func testUnsupportedWindowActionIsNotSentToBackend() async {
        let environment = PreviewEnvironment(accessibility: true)
        let backend = PreviewBackend(records: [Self.record(actions: [.activate])])
        let service = DockWindowPreviewService(backend: backend, environment: environment)
        await service.show(applicationPath: environment.identity.applicationPath)
        await service.perform(.zoom, on: service.windows[0])
        let actions = await backend.actions
        XCTAssertTrue(actions.isEmpty)
    }

    @MainActor
    func testSelectingExactWindowClosesPreviewOnlyAfterSuccessfulAction() async {
        let environment = PreviewEnvironment(accessibility: true)
        let backend = PreviewBackend(records: [Self.record()])
        let service = DockWindowPreviewService(backend: backend, environment: environment)
        await service.show(applicationPath: environment.identity.applicationPath)
        await service.perform(.activate, on: service.windows[0])
        let actions = await backend.actions
        XCTAssertEqual(actions, [.activate])
        XCTAssertTrue(service.windows.isEmpty)
    }

    @MainActor
    func testCaptureRevocationRemovesAlreadyDisplayedImages() async {
        let environment = PreviewEnvironment(capture: true)
        let backend = PreviewBackend(records: [Self.record()])
        let service = DockWindowPreviewService(backend: backend, environment: environment)
        await service.show(applicationPath: environment.identity.applicationPath)
        XCTAssertNotNil(service.windows.first?.image)
        environment.capture = false
        service.refreshPermissions()
        XCTAssertNil(service.windows.first?.image)
        XCTAssertFalse(service.hasCaptureAccess)
    }

    private static func record(id: UInt32 = 1, title: String = "Document", minimized: Bool = false,
                               actions: Set<DockWindowAction> = Set(DockWindowAction.allCases),
                               application: DockWindowApplicationIdentity = PreviewEnvironment.application) -> DockWindowRecord {
        .init(id: id, application: application, title: title,
              frame: CGRect(x: 0, y: 0, width: 800, height: 600), isMinimized: minimized,
              captureWindowID: id, accessibilityToken: UUID(), availableActions: actions)
    }

    private func descriptor(id: UInt32, title: String, frame: CGRect, onScreen: Bool = true,
                            layer: Int = 0, alpha: Double = 1) -> DockWindowServerDescriptor {
        .init(id: id, pid: PreviewEnvironment.application.pid, title: title, frame: frame,
              isOnScreen: onScreen, layer: layer, alpha: alpha)
    }

    private func accessibility(title: String, frame: CGRect, minimized: Bool = false) -> DockAccessibilityWindow {
        .init(token: UUID(), title: title, frame: frame, isMinimized: minimized, actions: [.activate, .close])
    }
}

@MainActor
private final class PreviewEnvironment: DockWindowPreviewEnvironment {
    nonisolated static let application = DockWindowApplicationIdentity(pid: 1_234,
        applicationPath: "/Applications/Fake.app", launchDate: Date(timeIntervalSince1970: 100))
    let identity = PreviewEnvironment.application
    var capture: Bool
    var accessibility: Bool
    var current = true
    var otherApplications: [String: DockWindowApplicationIdentity] = [:]
    var captureRequests = 0
    var accessibilityRequests = 0
    init(capture: Bool = false, accessibility: Bool = false) {
        self.capture = capture
        self.accessibility = accessibility
    }
    var hasCaptureAccess: Bool { capture }
    var hasAccessibilityAccess: Bool { accessibility }
    func application(at path: String) -> DockWindowApplicationIdentity? {
        guard current else { return nil }
        return path == identity.applicationPath ? identity : otherApplications[path]
    }
    func isCurrent(_ application: DockWindowApplicationIdentity) -> Bool {
        current && (application == identity || otherApplications.values.contains(application))
    }
    func requestCaptureAccess() { captureRequests += 1 }
    func requestAccessibilityAccess() { accessibilityRequests += 1 }
    func screens() -> [WindowLayoutScreen] { [] }
}

private actor PreviewBackend: DockWindowPreviewBackend {
    var records: [DockWindowRecord]
    var enumerationCount = 0
    var capturedIDs: [UInt32] = []
    var actions: [DockWindowAction] = []
    var failingCapture: UInt32?
    var suspendEnumeration: Bool
    var continuation: CheckedContinuation<Void, Never>?
    var waiters: [CheckedContinuation<Void, Never>] = []
    var actionsSuspended = false
    var actionContinuation: CheckedContinuation<Void, Never>?
    var actionWaiters: [CheckedContinuation<Void, Never>] = []
    init(records: [DockWindowRecord] = [], failingCapture: UInt32? = nil, suspendEnumeration: Bool = false) {
        self.records = records
        self.failingCapture = failingCapture
        self.suspendEnumeration = suspendEnumeration
    }
    func windows(for application: DockWindowApplicationIdentity, captureAllowed: Bool,
                 accessibilityAllowed: Bool) async throws -> [DockWindowRecord] {
        enumerationCount += 1
        let snapshot = records
        if suspendEnumeration {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                waiters.forEach { $0.resume() }
                waiters = []
            }
        }
        return snapshot
    }
    func setRecords(_ records: [DockWindowRecord]) { self.records = records; suspendEnumeration = false }
    func waitForEnumeration() async {
        if continuation != nil { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func resumeEnumeration() { continuation?.resume(); continuation = nil }
    func thumbnail(for window: DockWindowRecord) async throws -> CGImage? {
        capturedIDs.append(window.id)
        if failingCapture == window.id { throw DockWindowPreviewError.failed }
        return CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
    }
    func perform(_ action: DockWindowAction, on window: DockWindowRecord,
                 screens: [WindowLayoutScreen]) async throws {
        actions.append(action)
        if actionsSuspended {
            await withCheckedContinuation { continuation in
                actionContinuation = continuation
                actionWaiters.forEach { $0.resume() }
                actionWaiters = []
            }
        }
    }
    func suspendActions() { actionsSuspended = true }
    func waitForAction() async {
        if actionContinuation != nil { return }
        await withCheckedContinuation { actionWaiters.append($0) }
    }
    func resumeAction() { actionContinuation?.resume(); actionContinuation = nil; actionsSuspended = false }
}

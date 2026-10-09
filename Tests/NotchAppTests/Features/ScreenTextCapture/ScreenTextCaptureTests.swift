import CoreGraphics
import XCTest
@testable import NotchApp

@MainActor
final class ScreenTextCaptureTests: XCTestCase {
    func testNegativeScreenOriginConvertsToDisplayTopLeftAndRetinaPixels() {
        let screen = CGRect(x: -1_920, y: -200, width: 1_920, height: 1_080)
        let selection = CGRect(x: -1_820, y: -100, width: 100, height: 50)
        let request = ScreenTextCaptureGeometry.request(displayID: 7, screenFrame: screen,
                                                        selectedScreenRect: selection, backingScale: 2)
        XCTAssertEqual(request?.sourceRect, CGRect(x: 100, y: 930, width: 100, height: 50))
        XCTAssertEqual(request?.pixelWidth, 200)
        XCTAssertEqual(request?.pixelHeight, 100)
    }

    func testSelectionClampsToOneDisplayAndCapsPixelSize() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let dragged = ScreenTextCaptureGeometry.selection(from: CGPoint(x: 150, y: -20),
                                                           to: CGPoint(x: -10, y: 60), in: bounds)
        XCTAssertEqual(dragged, CGRect(x: 0, y: 0, width: 100, height: 60))

        let screen = CGRect(x: 0, y: 0, width: 7_680, height: 4_320)
        let request = ScreenTextCaptureGeometry.request(displayID: 1, screenFrame: screen,
                                                        selectedScreenRect: screen, backingScale: 2)
        XCTAssertEqual(request?.pixelWidth, 4_096)
        XCTAssertEqual(request?.pixelHeight, 2_304)
        XCTAssertNil(ScreenTextCaptureGeometry.request(
            displayID: 1, screenFrame: bounds,
            selectedScreenRect: CGRect(x: 0, y: 0, width: 7, height: 30), backingScale: 2
        ))
    }

    func testSessionDiscardsLateCaptureAfterCancelAndAllowsNewCapture() async {
        let service = SuspendedScreenCaptureService()
        let session = ScreenTextCaptureSession(service: service)
        let request = ScreenTextCaptureGeometry.request(
            displayID: 1, screenFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            selectedScreenRect: CGRect(x: 10, y: 10, width: 20, height: 20), backingScale: 2
        )!
        var received: [Data] = []
        session.capture(request) { result in
            if case .success(let data) = result { received.append(data) }
        }
        await waitForCalls(1, service: service)
        session.cancel()
        XCTAssertFalse(session.isActive)
        await service.finishNext(data: Data("old".utf8))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(received.isEmpty)

        session.capture(request) { result in
            if case .success(let data) = result { received.append(data) }
        }
        await waitForCalls(2, service: service)
        await service.finishNext(data: Data("new".utf8))
        for _ in 0..<100 where received.isEmpty { await Task.yield() }
        XCTAssertEqual(received, [Data("new".utf8)])
    }

    func testDeniedPermissionRequestedOnlyOnceFromExplicitStart() {
        let permissions = DeniedScreenCapturePermission()
        let coordinator = ScreenTextCaptureCoordinator(captureService: SuspendedScreenCaptureService(),
                                                       permissions: permissions)
        var failures: [String] = []
        coordinator.start(onCapture: { _ in XCTFail("Unexpected capture") },
                          onFailure: { failures.append($0) }, onCancel: {})
        coordinator.start(onCapture: { _ in XCTFail("Unexpected capture") },
                          onFailure: { failures.append($0) }, onCancel: {})
        XCTAssertEqual(permissions.requestCount, 1)
        XCTAssertEqual(failures.count, 2)
        XCTAssertFalse(coordinator.isActive)
    }

    private func waitForCalls(_ expected: Int, service: SuspendedScreenCaptureService) async {
        for _ in 0..<100 {
            if await service.callCount() == expected { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Capture service was not called")
    }
}

private actor SuspendedScreenCaptureService: ScreenTextCapturing {
    private var calls = 0
    private var continuations: [CheckedContinuation<Data, Error>] = []

    func callCount() -> Int { calls }

    func capture(_ request: ScreenTextCaptureRequest) async throws -> Data {
        calls += 1
        return try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func finishNext(data: Data) {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume(returning: data)
    }
}

@MainActor
private final class DeniedScreenCapturePermission: ScreenTextCapturePermissionChecking {
    var requestCount = 0
    func isAllowed() -> Bool { false }
    func request() -> Bool { requestCount += 1; return false }
}

import Foundation
import XCTest
@testable import NotchApp

final class IdlePerformancePolicyTests: XCTestCase {
    func testWebViewOnlyAttachesDuringAuthentication() {
        XCTAssertFalse(OllamaWebViewAttachmentPolicy.shouldAttach(isAuthenticating: false))
        XCTAssertTrue(OllamaWebViewAttachmentPolicy.shouldAttach(isAuthenticating: true))
    }

    func testCompactNotchHasNoCPUDrivenAnimationTimeline() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repositoryRoot
            .appendingPathComponent("Sources/NotchApp/CompactNotch.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(source.contains("TimelineView(.animation"))
        XCTAssertFalse(source.contains("PhaseAnimator("))
        XCTAssertFalse(source.contains("pulseValue(at:"))
    }
}

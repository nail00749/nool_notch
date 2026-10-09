import Foundation
import XCTest
@testable import NotchApp

final class CodeReviewIntegrationCancellationTests: XCTestCase {
    func testCancellationStopsOwnedProcessPromptly() async throws {
        let cancellation = CodeReviewIntegrationCancellation()
        let started = ProcessInfo.processInfo.systemUptime
        let task = Task.detached {
            CodeReviewIntegrationCommandRunner.run(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["10"],
                cancellation: cancellation
            )
        }

        try await Task.sleep(for: .milliseconds(150))
        cancellation.cancel()

        let result = await task.value
        XCTAssertNil(result)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 3)
    }

    func testCancelledInspectionCannotLaunchAnotherCommand() {
        let cancellation = CodeReviewIntegrationCancellation()
        cancellation.cancel()
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("nool-inspection-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }

        let result = CodeReviewIntegrationCommandRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/touch"),
            arguments: [marker.path],
            cancellation: cancellation
        )

        XCTAssertNil(result)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }
}

import Foundation
import NotchCore
import XCTest
@testable import NotchApp

final class QuotaWidgetTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func provider(connection: ProviderConnectionState = .live, remaining: Double = 38,
                          reset: Date? = nil) -> QuotaWidgetProvider {
        QuotaWidgetProvider(snapshot: QuotaSnapshot(
            providerID: "chatgpt-subscription", providerName: "ChatGPT",
            windows: [QuotaWindow(id: "weekly", label: "7d", limit: 100, remaining: remaining,
                                  resetAt: reset, unit: .percentage)],
            connection: connection, updatedAt: now,
            sourceURL: URL(string: "https://private.example/account"), message: "PRIVATE_ACCOUNT_MESSAGE"
        ))
    }

    func testRemainingAndMissingPeriodNeverSubstituteOrInventFullQuota() {
        let item = provider()
        XCTAssertEqual(item.percentage(for: .week), 38)
        XCTAssertNil(item.percentage(for: .fiveHours))
        XCTAssertNil(provider(connection: .requiresAuthentication).percentage(for: .week))
        XCTAssertNil(provider(connection: .unavailable).percentage(for: .week))
        XCTAssertEqual(provider(remaining: 0).percentage(for: .week), 0)
        XCTAssertEqual(provider(remaining: 120).percentage(for: .week), 100)
        XCTAssertNil(QuotaWidgetWindow(label: "7d", remainingRatio: .nan, resetAt: nil).remainingRatio)
    }

    func testStalenessAfterAgeResetAndProviderFailureDoesNotResetQuota() {
        let reset = now.addingTimeInterval(300)
        let item = provider(reset: reset)
        XCTAssertFalse(item.isStale(window: item.window(for: .week), at: now))
        XCTAssertTrue(item.isStale(window: item.window(for: .week), at: reset))
        XCTAssertEqual(item.percentage(for: .week), 38)
        XCTAssertTrue(provider().isStale(window: nil, at: now.addingTimeInterval(900)))
        XCTAssertTrue(provider(connection: .stale).isStale(window: nil, at: now))
        XCTAssertTrue(provider().isStale(window: nil, at: now.addingTimeInterval(-120)))
    }

    func testPrimaryWindowIsPreferredOverNamedBucket() {
        let item = QuotaWidgetProvider(snapshot: QuotaSnapshot(
            providerID: "test", providerName: "Test",
            windows: [
                QuotaWindow(id: "bucket", label: "Other · 7d", limit: 100, remaining: 99, resetAt: nil, unit: .percentage),
                QuotaWindow(id: "primary", label: "7d", limit: 100, remaining: 20, resetAt: nil, unit: .percentage)
            ], connection: .live, updatedAt: now, sourceURL: nil, message: nil))
        XCTAssertEqual(item.percentage(for: .week), 20)
    }

    func testSnapshotRoundTripExcludesAccountDataAndRejectsCorruption() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("widget.json")
        XCTAssertEqual(QuotaWidgetStore.read(from: file), .empty)
        let snapshot = QuotaWidgetData(generatedAt: now, providers: [provider()])
        try QuotaWidgetStore.write(snapshot, to: file)
        XCTAssertEqual(QuotaWidgetStore.read(from: file), snapshot)
        let json = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(json.contains("PRIVATE_ACCOUNT_MESSAGE"))
        XCTAssertFalse(json.contains("private.example"))
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        try json.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2").write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(QuotaWidgetStore.read(from: file), .empty)
        try Data(repeating: 32, count: QuotaWidgetStore.maximumBytes + 1).write(to: file)
        XCTAssertEqual(QuotaWidgetStore.read(from: file), .empty)
        try Data("{broken".utf8).write(to: file)
        XCTAssertEqual(QuotaWidgetStore.read(from: file), .empty)
    }

    func testOnlyExactReadOnlyWidgetRouteIsAccepted() {
        XCTAssertTrue(QuotaWidgetLink.opensLimits(URL(string: "nool-notch://limits")!))
        for link in ["https://limits", "nool-notch://limits/delete", "nool-notch://limits?action=send",
                     "nool-notch://user@limits", "nool-notch://other"] {
            XCTAssertFalse(QuotaWidgetLink.opensLimits(URL(string: link)!))
        }
    }

    @MainActor
    func testPublisherSerialOrderingAndShutdownDrain() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("widget.json")
        let publisher = QuotaWidgetPublisher(fileURL: file, reload: {})
        for remaining in 0..<30 { publisher.publish([provider(remaining: Double(remaining))]) }
        publisher.stop()
        publisher.publish([provider(remaining: 100)])
        await publisher.waitForPersistence()
        XCTAssertEqual(QuotaWidgetStore.read(from: file).providers.first?.percentage(for: .week), 29)
    }
}

import XCTest
@testable import NotchApp

final class AIChatStoreTests: XCTestCase {
    @MainActor
    func testDisabledConnectionsAreNeverProbedOrUsed() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.store.refreshAvailability()
        await settle()
        XCTAssertEqual(fixture.apple.probes, 1)
        XCTAssertEqual(fixture.codex.probes, 0)
        fixture.store.selectProvider(.codex)
        fixture.store.draft = "Hello"
        XCTAssertFalse(fixture.store.canSend)
        fixture.store.send()
        XCTAssertEqual(fixture.codex.requests.count, 0)
    }

    @MainActor
    func testStreamingStopAndNewChatIgnoreLateResponses() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.store.refreshAvailability()
        await settle()
        fixture.store.draft = "Question"
        fixture.store.send()
        let first = try XCTUnwrap(fixture.apple.continuation)
        first.yield("Partial")
        await settle()
        XCTAssertEqual(fixture.store.messages.last?.text, "Partial")
        fixture.store.stop()
        XCTAssertEqual(fixture.store.messages.last?.state, .interrupted)
        first.yield(" must not appear")
        await settle()
        XCTAssertEqual(fixture.store.messages.last?.text, "Partial")
        fixture.store.newChat()
        fixture.store.draft = "New question"
        fixture.store.send()
        first.finish()
        fixture.apple.continuation?.yield("New answer")
        fixture.apple.continuation?.finish()
        await settle()
        XCTAssertEqual(fixture.store.messages.map(\.text), ["New question", "New answer"])
        XCTAssertEqual(fixture.store.messages.last?.state, .complete)
    }

    @MainActor
    func testProviderSwitchClearsContextAndDisablingStopsGeneration() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.store.codexEnabled = true
        fixture.store.refreshAvailability()
        await settle()
        fixture.store.draft = "Private Apple context"
        fixture.store.send()
        fixture.apple.continuation?.yield("Apple reply")
        fixture.apple.continuation?.finish()
        await settle()
        fixture.store.selectProvider(.codex)
        await settle()
        XCTAssertTrue(fixture.store.messages.isEmpty)
        fixture.store.draft = "Codex question"
        fixture.store.send()
        XCTAssertEqual(fixture.codex.requests.first?.map(\.text), ["Codex question"])
        fixture.store.codexEnabled = false
        XCTAssertFalse(fixture.store.isStreaming)
        XCTAssertFalse(fixture.store.canSend)
        XCTAssertGreaterThan(fixture.codex.cancellations, 0)
    }

    @MainActor
    func testModelRefreshDoesNotSilentlyChangeExistingConversation() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.store.refreshAvailability()
        await settle()
        fixture.store.draft = "Hello"
        fixture.store.send()
        fixture.apple.continuation?.yield("Reply")
        fixture.apple.continuation?.finish()
        await settle()
        fixture.apple.modelID = "replacement"
        fixture.store.refreshAvailability()
        await settle()
        XCTAssertEqual(fixture.store.selectedModelID, "apple-system")
        fixture.store.draft = "Follow-up"
        XCTAssertFalse(fixture.store.canSend)
        fixture.store.selectModel("replacement")
        XCTAssertTrue(fixture.store.messages.isEmpty)
    }

    @MainActor
    func testEmptyResponseFailsAndInputLimitsPreventRequests() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.store.refreshAvailability()
        await settle()
        fixture.store.draft = String(repeating: "x", count: 8_001)
        fixture.store.send()
        XCTAssertTrue(fixture.apple.requests.isEmpty)
        fixture.store.draft = "Hello"
        fixture.store.send()
        fixture.apple.continuation?.finish()
        await settle()
        XCTAssertEqual(fixture.store.messages.last?.state, .failed)
        XCTAssertNotNil(fixture.store.errorMessage)
    }

    @MainActor
    func testDeadlineCancelsProviderAndKeepsPartialResponse() async throws {
        let fixture = try Fixture(timeout: .milliseconds(20))
        defer { fixture.cleanup() }
        fixture.store.refreshAvailability()
        await settle()
        fixture.store.draft = "Hello"
        fixture.store.send()
        fixture.apple.continuation?.yield("Partial")
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertFalse(fixture.store.isStreaming)
        XCTAssertEqual(fixture.store.messages.last?.text, "Partial")
        XCTAssertEqual(fixture.store.messages.last?.state, .interrupted)
        XCTAssertEqual(fixture.store.errorMessage, AIChatError.timeout.localizedDescription)
    }

    func testContextTruncatesWholeTurnsAndRejectsOversizeLatestPrompt() throws {
        let messages = [AIChatMessage(role: .user, text: "1234"), AIChatMessage(role: .assistant, text: "5678"),
                        AIChatMessage(role: .user, text: "abc")]
        XCTAssertEqual(try AIChatContext.bounded(messages, maximumCharacters: 10).map(\.text), ["abc"])
        XCTAssertEqual(try AIChatContext.bounded(messages, maximumCharacters: 11).count, 3)
        XCTAssertThrowsError(try AIChatContext.bounded(messages, maximumCharacters: 2))
    }

    func testAppleSnapshotsBecomeDeltasWithoutDuplicatingText() {
        XCTAssertEqual(LauncherAppleChatProvider.delta(previous: "Привет", snapshot: "Привет!"), "!")
        XCTAssertEqual(LauncherAppleChatProvider.delta(previous: "Hello", snapshot: "Hello"), "")
        XCTAssertNil(LauncherAppleChatProvider.delta(previous: "Hello", snapshot: "Changed"))
    }

    @MainActor
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    @MainActor
    private struct Fixture {
        let suite = "ai-chat-test-\(UUID().uuidString)"
        let defaults: UserDefaults
        let apple = FakeProvider(id: .apple, modelID: "apple-system")
        let codex = FakeProvider(id: .codex, modelID: "codex-test")
        let store: AIChatStore
        init(timeout: Duration = .seconds(30)) throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            store = AIChatStore(providers: [apple, codex], defaults: defaults, timeout: timeout)
        }
        func cleanup() { store.shutdown(); defaults.removePersistentDomain(forName: suite) }
    }

    @MainActor
    private final class FakeProvider: LauncherAIChatProviding {
        let id: AIChatProviderID
        var modelID: String
        var probes = 0
        var cancellations = 0
        var requests: [[AIChatMessage]] = []
        var continuation: AsyncThrowingStream<String, Error>.Continuation?
        init(id: AIChatProviderID, modelID: String) { self.id = id; self.modelID = modelID }
        func availability() async -> AIChatProviderStatus {
            probes += 1
            return AIChatProviderStatus(isAvailable: true, message: "Ready", models: [
                AIChatModelOption(id: modelID, title: modelID, provider: id)
            ])
        }
        func stream(messages: [AIChatMessage], model: String) -> AsyncThrowingStream<String, Error> {
            requests.append(messages)
            return AsyncThrowingStream { continuation = $0 }
        }
        func cancel() { cancellations += 1 }
    }
}

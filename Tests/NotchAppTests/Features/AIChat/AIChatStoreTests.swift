import XCTest
@testable import NotchApp

final class AIChatStoreTests: XCTestCase {
    @MainActor
    func testQuickQuestionUsesOnlySelectedProviderAndOnlyTypedText() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.store.draft = "Unsent private draft"
        fixture.store.addAttachments([AIChatAttachment(name: "private.txt", kind: .text, text: "Private document")])
        let result = await fixture.store.sendQuickQuestion("  A new question  ")
        XCTAssertEqual(result, .sent)
        XCTAssertEqual(fixture.apple.probes, 1)
        XCTAssertEqual(fixture.codex.probes, 0)
        XCTAssertEqual(fixture.apple.requests.last?.map(\.text), ["A new question"])
        XCTAssertEqual(fixture.apple.requests.last?.first?.attachments, [])
    }

    @MainActor
    func testQuickQuestionPreservesExistingConversationAndDraftInHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "quick-ai-history-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let provider = FakeProvider(id: .apple, modelID: "apple-system")
        let store = AIChatStore(providers: [provider], defaults: defaults,
                                historyURL: directory.appendingPathComponent("history.json"))
        await store.waitForPersistence()
        store.refreshAvailability()
        await settle()
        store.draft = "Previous question"
        store.send()
        provider.continuation?.yield("Previous answer")
        provider.continuation?.finish()
        await settle()
        let previousID = try XCTUnwrap(store.activeConversationID)
        store.draft = "Keep my draft"
        store.addAttachments([AIChatAttachment(name: "draft.txt", kind: .text, text: "Keep attachment")])

        let result = await store.sendQuickQuestion("Independent question")
        XCTAssertEqual(result, .sent)
        XCTAssertNotEqual(store.activeConversationID, previousID)
        let previous = try XCTUnwrap(store.history.first { $0.id == previousID })
        XCTAssertEqual(previous.messages.map(\.text), ["Previous question", "Previous answer"])
        XCTAssertEqual(previous.draft, "Keep my draft")
        XCTAssertEqual(previous.draftAttachments.first?.text, "Keep attachment")
        XCTAssertEqual(provider.requests.last?.map(\.text), ["Independent question"])
        store.shutdown()
        await store.waitForPersistence()
    }

    @MainActor
    func testQuickQuestionCannotInterruptStreamOrUseDisabledConnection() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let first = await fixture.store.sendQuickQuestion("First")
        XCTAssertEqual(first, .sent)
        let busy = await fixture.store.sendQuickQuestion("Second")
        guard case .unavailable = busy else { return XCTFail("An active reply must be preserved") }
        XCTAssertTrue(fixture.store.isStreaming)
        XCTAssertEqual(fixture.apple.requests.count, 1)
        fixture.store.stop()
        fixture.store.selectProvider(.codex)
        fixture.store.draft = "Keep this draft"
        let disabled = await fixture.store.sendQuickQuestion("Must not send")
        guard case .unavailable = disabled else { return XCTFail("Disabled connection must be rejected") }
        XCTAssertEqual(fixture.store.draft, "Keep this draft")
        XCTAssertEqual(fixture.codex.probes, 0)
        XCTAssertTrue(fixture.codex.requests.isEmpty)
    }

    @MainActor
    func testCancelledQuickQuestionDoesNotSendAfterDelayedDiscovery() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.apple.pausesAvailability = true
        fixture.store.draft = "Keep draft"
        let task = Task { await fixture.store.sendQuickQuestion("Do not send") }
        await settle()
        let continuation = try XCTUnwrap(fixture.apple.availabilityGate)
        task.cancel()
        continuation.resume()
        let result = await task.value
        XCTAssertEqual(result, .cancelled)
        XCTAssertTrue(fixture.apple.requests.isEmpty)
        XCTAssertEqual(fixture.store.draft, "Keep draft")
    }

    @MainActor
    func testQuickQuestionRejectsBlankAndOversizedInputBeforeDiscovery() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        for input in [" \n ", String(repeating: "x", count: 8_001)] {
            let result = await fixture.store.sendQuickQuestion(input)
            guard case .unavailable = result else { return XCTFail("Invalid input must be rejected") }
        }
        XCTAssertEqual(fixture.apple.probes, 0)
        XCTAssertTrue(fixture.apple.requests.isEmpty)
    }

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
        var pausesAvailability = false
        var availabilityGate: CheckedContinuation<Void, Never>?
        var cancellations = 0
        var requests: [[AIChatMessage]] = []
        var continuation: AsyncThrowingStream<String, Error>.Continuation?
        init(id: AIChatProviderID, modelID: String) { self.id = id; self.modelID = modelID }
        func availability() async -> AIChatProviderStatus {
            probes += 1
            if pausesAvailability { await withCheckedContinuation { availabilityGate = $0 } }
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

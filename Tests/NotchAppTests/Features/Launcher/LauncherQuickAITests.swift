import XCTest
@testable import NotchApp

@MainActor
final class LauncherQuickAITests: XCTestCase {
    func testQuestionStaysInAllAndAnswerStreamsIntoSharedChat() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.model.query = "Explain this"
        fixture.model.askAI()
        await settle()
        XCTAssertEqual(fixture.model.category, .all)
        XCTAssertTrue(fixture.model.showsQuickAI)
        XCTAssertFalse(fixture.model.isPreparingQuickAI)
        XCTAssertNotNil(fixture.model.quickAIConversationID)
        XCTAssertEqual(fixture.model.quickAIConversationID, fixture.store.activeConversationID)
        fixture.provider.streamGate?.yield("Answer")
        fixture.provider.streamGate?.finish()
        await settle()
        XCTAssertEqual(fixture.store.messages.last?.text, "Answer")
        XCTAssertEqual(fixture.provider.requests.first?.map(\.text), ["Explain this"])
        fixture.model.category = .ai
        XCTAssertFalse(fixture.model.showsQuickAI)
        XCTAssertEqual(fixture.store.messages.last?.text, "Answer")
    }

    func testQueryEditCancelsPendingSendWithoutSendingOldQuestion() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.provider.pausesAvailability = true
        fixture.model.query = "Old question"
        fixture.model.askAI()
        await settle()
        let gate = try XCTUnwrap(fixture.provider.availabilityGate)
        fixture.model.query = "New search"
        gate.resume()
        await settle()
        XCTAssertFalse(fixture.model.showsQuickAI)
        XCTAssertFalse(fixture.model.isPreparingQuickAI)
        XCTAssertTrue(fixture.provider.requests.isEmpty)
    }

    func testDismissCancelsPendingSendAndRepeatedShortcutCannotInterruptReply() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.model.query = "First"
        fixture.model.askAI()
        fixture.model.askAI()
        await settle()
        fixture.model.askAI()
        XCTAssertEqual(fixture.provider.requests.count, 1)
        XCTAssertNotNil(fixture.model.quickAIConversationID)
        XCTAssertTrue(fixture.store.isStreaming)
        fixture.model.stopQuickAI()
        XCTAssertFalse(fixture.store.isStreaming)

        fixture.provider.pausesAvailability = true
        fixture.model.query = "Never send after dismissal"
        fixture.model.askAI()
        await settle()
        let gate = try XCTUnwrap(fixture.provider.availabilityGate)
        fixture.model.dismiss()
        gate.resume()
        await settle()
        XCTAssertEqual(fixture.provider.requests.count, 1)
        XCTAssertFalse(fixture.model.showsQuickAI)
    }

    func testOnlyNonemptyAllQueriesCanBeSent() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        for query in ["", " \n ", String(repeating: "x", count: 8_001)] {
            fixture.model.query = query
            XCTAssertFalse(fixture.model.canAskAI)
        }
        fixture.model.query = "Question"
        XCTAssertTrue(fixture.model.canAskAI)
        for category in [LauncherCategory.applications, .files, .clipboard, .ai] {
            fixture.model.category = category
            fixture.model.askAI()
            XCTAssertFalse(fixture.model.showsQuickAI)
        }
        XCTAssertTrue(fixture.provider.requests.isEmpty)
    }

    private func settle() async {
        for _ in 0..<100 { await Task.yield() }
    }

    @MainActor
    private struct Fixture {
        let suite = "launcher-quick-ai-\(UUID().uuidString)"
        let defaults: UserDefaults
        let provider = Provider()
        let store: AIChatStore
        let model: LauncherModel
        init() throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            store = AIChatStore(providers: [provider], defaults: defaults)
            model = LauncherModel(settings: LauncherSettings(defaults: defaults), aiChat: store)
        }
        func cleanup() {
            model.dismiss()
            store.shutdown()
            defaults.removePersistentDomain(forName: suite)
        }
    }

    @MainActor
    private final class Provider: LauncherAIChatProviding {
        let id = AIChatProviderID.apple
        var pausesAvailability = false
        var availabilityGate: CheckedContinuation<Void, Never>?
        var streamGate: AsyncThrowingStream<String, Error>.Continuation?
        var requests: [[AIChatMessage]] = []
        func availability() async -> AIChatProviderStatus {
            if pausesAvailability { await withCheckedContinuation { availabilityGate = $0 } }
            return AIChatProviderStatus(isAvailable: true, message: "Ready", models: [
                AIChatModelOption(id: "apple-system", title: "Apple", provider: .apple)
            ])
        }
        func stream(messages: [AIChatMessage], model: String) -> AsyncThrowingStream<String, Error> {
            requests.append(messages)
            return AsyncThrowingStream { streamGate = $0 }
        }
        func cancel() { streamGate?.finish() }
    }
}

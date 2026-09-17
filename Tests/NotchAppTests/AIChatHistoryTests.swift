import Foundation
import XCTest
@testable import NotchApp

final class AIChatHistoryTests: XCTestCase {
    @MainActor
    func testPersistsDraftAndRestoresTheConversationSelection() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        await fixture.store.waitForPersistence()
        fixture.store.refreshAvailability()
        await settle()

        fixture.store.draft = "Сохранить этот черновик"
        await fixture.store.flushHistory()
        let saved = try XCTUnwrap(fixture.store.history.first)
        XCTAssertEqual(saved.provider, .apple)
        XCTAssertEqual(saved.modelID, "apple-system")
        XCTAssertEqual(saved.draft, "Сохранить этот черновик")
        let filePermissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: fixture.historyURL.path)[.posixPermissions] as? NSNumber
        )
        let directoryPermissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: fixture.directory.path)[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(filePermissions.intValue & 0o777, 0o600)
        XCTAssertEqual(directoryPermissions.intValue & 0o777, 0o700)

        let restored = try fixture.makeStore()
        defer { restored.shutdown() }
        await restored.waitForPersistence()
        XCTAssertEqual(restored.history, [saved])

        restored.openConversation(saved.id)
        XCTAssertEqual(restored.activeConversationID, saved.id)
        XCTAssertEqual(restored.selectedProvider, .apple)
        XCTAssertEqual(restored.selectedModelID, "apple-system")
        XCTAssertEqual(restored.draft, "Сохранить этот черновик")
    }

    @MainActor
    func testStreamingMessagesAreRestoredAsInterrupted() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let conversation = fixture.conversation(
            messages: [
                AIChatMessage(role: .user, text: "Вопрос"),
                AIChatMessage(role: .assistant, text: "Неполный", state: .streaming)
            ]
        )
        XCTAssertEqual(AIChatHistoryDisk.write([conversation], url: fixture.historyURL), .success)

        let restored = try fixture.makeStore()
        defer { restored.shutdown() }
        await restored.waitForPersistence()
        let loaded = try XCTUnwrap(restored.history.first)
        XCTAssertEqual(loaded.messages.last?.state, .interrupted)
        restored.openConversation(loaded.id)
        XCTAssertEqual(restored.messages.last?.state, .interrupted)
    }

    @MainActor
    func testCorruptHistoryIsKeptAndNeverOverwritten() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        let invalid = Data("not-json".utf8)
        try invalid.write(to: fixture.historyURL)

        let store = try fixture.makeStore()
        defer { store.shutdown() }
        // Mutate before the asynchronous initial read completes: this must not
        // race into an overwrite of data that later proves unreadable.
        store.draft = "Новый черновик"
        await store.flushHistory()
        XCTAssertNotNil(store.historyError)
        XCTAssertEqual(try Data(contentsOf: fixture.historyURL), invalid)
    }

    @MainActor
    func testHistoryEvictsOnlyOldUnpinnedConversationsWithNotice() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let conversations = (0..<AIChatHistoryDisk.maximumConversationCount).map { index in
            fixture.conversation(
                id: UUID(),
                title: "Старый \(index)",
                updatedAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
        XCTAssertEqual(AIChatHistoryDisk.write(conversations, url: fixture.historyURL), .success)

        let store = try fixture.makeStore()
        defer { store.shutdown() }
        await store.waitForPersistence()
        store.draft = "Новый чат"
        await store.flushHistory()

        XCTAssertEqual(store.history.count, AIChatHistoryDisk.maximumConversationCount)
        XCTAssertTrue(store.history.contains(where: { $0.draft == "Новый чат" }))
        XCTAssertFalse(store.history.contains(where: { $0.title == "Старый 0" }))
        XCTAssertNotNil(store.historyError)
    }

    @MainActor
    func testPinnedHistoryIsNotSilentlyDiscardedWhenFull() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let conversations = (0..<AIChatHistoryDisk.maximumConversationCount).map { index in
            fixture.conversation(
                id: UUID(),
                title: "Закреплённый \(index)",
                updatedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                isPinned: true
            )
        }
        XCTAssertEqual(AIChatHistoryDisk.write(conversations, url: fixture.historyURL), .success)

        let store = try fixture.makeStore()
        defer { store.shutdown() }
        await store.waitForPersistence()
        store.draft = "Не терять новый чат"
        await store.flushHistory()

        XCTAssertEqual(store.history.count, AIChatHistoryDisk.maximumConversationCount + 1)
        XCTAssertEqual(store.history.filter(\.isPinned).count, AIChatHistoryDisk.maximumConversationCount)
        XCTAssertTrue(store.history.contains(where: { $0.draft == "Не терять новый чат" }))
        XCTAssertNotNil(store.historyError)
    }

    func testSearchIncludesTitlesAndTranscript() {
        let conversation = AIChatHistoryConversation(
            id: UUID(),
            title: "План релиза",
            provider: .apple,
            modelID: "apple-system",
            messages: [AIChatMessage(role: .assistant, text: "Проверить подпись приложения")],
            draft: "",
            createdAt: .now,
            updatedAt: .now,
            isPinned: false
        )
        XCTAssertTrue(conversation.matches("релиз"))
        XCTAssertTrue(conversation.matches("подпись"))
        XCTAssertFalse(conversation.matches("календарь"))
    }

    @MainActor
    func testClearingAStandaloneDraftRemovesItsPersistedSnapshot() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        await fixture.store.waitForPersistence()
        fixture.store.draft = "Временный черновик"
        await fixture.store.flushHistory()
        XCTAssertEqual(fixture.store.history.map(\.draft), ["Временный черновик"])

        fixture.store.draft = ""
        await fixture.store.flushHistory()
        XCTAssertTrue(fixture.store.history.isEmpty)

        let restored = try fixture.makeStore()
        defer { restored.shutdown() }
        await restored.waitForPersistence()
        XCTAssertTrue(restored.history.isEmpty)
    }

    @MainActor
    func testOpeningActiveStreamingConversationRestoresLatestInterruptedReply() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        await fixture.store.waitForPersistence()
        fixture.store.refreshAvailability()
        await settle()
        fixture.store.draft = "Вопрос"
        fixture.store.send()
        await settle()
        let id = try XCTUnwrap(fixture.store.activeConversationID)
        let continuation = try XCTUnwrap(fixture.apple.continuation)
        continuation.yield("Неполный ответ")
        await settle()

        fixture.store.openConversation(id)
        XCTAssertEqual(fixture.store.messages.last?.text, "Неполный ответ")
        XCTAssertEqual(fixture.store.messages.last?.state, .interrupted)
    }

    @MainActor
    func testOpeningAndSwitchingProvidersKeepsContextsSeparate() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var codexConversation = fixture.conversation(
            title: "Codex",
            messages: [AIChatMessage(role: .user, text: "Только для Codex")]
        )
        codexConversation.provider = .codex
        codexConversation.modelID = "codex-test"
        XCTAssertEqual(AIChatHistoryDisk.write([codexConversation], url: fixture.historyURL), .success)

        let store = try fixture.makeStore()
        defer { store.shutdown() }
        await store.waitForPersistence()
        store.openConversation(codexConversation.id)
        XCTAssertEqual(store.selectedProvider, .codex)
        XCTAssertEqual(store.messages.map(\.text), ["Только для Codex"])

        store.selectProvider(.apple)
        XCTAssertEqual(store.selectedProvider, .apple)
        XCTAssertTrue(store.messages.isEmpty)
        XCTAssertTrue(store.draft.isEmpty)
    }

    @MainActor
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    @MainActor
    private final class Fixture {
        let suite = "ai-chat-history-test-\(UUID().uuidString)"
        let directory: URL
        let historyURL: URL
        let defaults: UserDefaults
        let apple = FakeProvider(id: .apple, modelID: "apple-system")
        let codex = FakeProvider(id: .codex, modelID: "codex-test")
        let store: AIChatStore

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("ai-chat-history-test-\(UUID().uuidString)", isDirectory: true)
            historyURL = directory.appendingPathComponent("history.json")
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            store = AIChatStore(providers: [apple, codex], defaults: defaults, historyURL: historyURL)
        }

        func makeStore() throws -> AIChatStore {
            AIChatStore(
                providers: [FakeProvider(id: .apple, modelID: "apple-system"), FakeProvider(id: .codex, modelID: "codex-test")],
                defaults: defaults,
                historyURL: historyURL
            )
        }

        func conversation(
            id: UUID = UUID(),
            title: String = "Чат",
            messages: [AIChatMessage] = [],
            updatedAt: Date = .now,
            isPinned: Bool = false
        ) -> AIChatHistoryConversation {
            AIChatHistoryConversation(
                id: id,
                title: title,
                provider: .apple,
                modelID: "apple-system",
                messages: messages,
                draft: "",
                createdAt: updatedAt,
                updatedAt: updatedAt,
                isPinned: isPinned
            )
        }

        func cleanup() {
            store.shutdown()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @MainActor
    private final class FakeProvider: LauncherAIChatProviding {
        let id: AIChatProviderID
        let modelID: String
        var continuation: AsyncThrowingStream<String, Error>.Continuation?

        init(id: AIChatProviderID, modelID: String) {
            self.id = id
            self.modelID = modelID
        }

        func availability() async -> AIChatProviderStatus {
            AIChatProviderStatus(
                isAvailable: true,
                message: "Ready",
                models: [AIChatModelOption(id: modelID, title: modelID, provider: id)]
            )
        }

        func stream(messages: [AIChatMessage], model: String) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { continuation = $0 }
        }

        func cancel() { continuation?.finish(throwing: CancellationError()) }
    }
}

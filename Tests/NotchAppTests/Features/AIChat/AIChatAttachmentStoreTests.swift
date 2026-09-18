import XCTest
@testable import NotchApp

@MainActor
final class AIChatAttachmentStoreTests: XCTestCase {
    func testUnsupportedImageBlocksSendUntilVisionModelSelectedAndKeepsDraft() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        fixture.store.refreshAvailability()
        await ready(fixture.store)
        fixture.store.draft = "Explain"
        fixture.store.addAttachments([image])
        XCTAssertNotNil(fixture.store.attachmentIssue)
        XCTAssertFalse(fixture.store.canSend)
        fixture.store.send()
        XCTAssertTrue(fixture.provider.received.isEmpty)
        fixture.store.selectModel("vision")
        XCTAssertEqual(fixture.store.draft, "Explain")
        XCTAssertEqual(fixture.store.draftAttachments, [image])
        XCTAssertTrue(fixture.store.canSend)
        fixture.store.send()
        XCTAssertEqual(fixture.provider.received.last?.attachments, [image])
        XCTAssertTrue(fixture.store.draftAttachments.isEmpty)
        fixture.store.shutdown()
    }

    func testAttachmentOnlyDraftRoundTripsAndDeletionRemovesPayload() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        await fixture.store.waitForPersistence()
        fixture.store.addAttachments([document, image])
        await fixture.store.flushHistory()
        let id = try XCTUnwrap(fixture.store.activeConversationID)
        let restored = AIChatStore(providers: [fixture.provider], defaults: fixture.defaults, historyURL: fixture.url)
        await restored.waitForPersistence()
        restored.openConversation(id)
        XCTAssertEqual(restored.draftAttachments, [document, image])
        restored.deleteConversation(id)
        await restored.flushHistory()
        let data = try Data(contentsOf: fixture.url)
        XCTAssertEqual(try JSONDecoder().decode([AIChatHistoryConversation].self, from: data), [])
        restored.shutdown()
        await restored.waitForPersistence()
        // Do not flush the earlier independent store after deleting through the restored store.
    }

    func testClearingLastAttachmentRemovesAnOtherwiseEmptyDraft() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        await fixture.store.waitForPersistence()
        fixture.store.addAttachments([document])
        fixture.store.removeAttachment(document.id)
        await fixture.store.flushHistory()
        XCTAssertNil(fixture.store.activeConversationID)
        XCTAssertTrue(fixture.store.history.isEmpty)
    }

    func testFailedImportBatchExplicitlyLeavesDraftUnchanged() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        let valid = fixture.directory.appendingPathComponent("valid.txt")
        let invalid = fixture.directory.appendingPathComponent("invalid.exe")
        try Data("Document".utf8).write(to: valid)
        try Data([0]).write(to: invalid)
        fixture.store.importAttachments([valid, invalid])
        for _ in 0..<100 where fixture.store.isImportingAttachments { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(fixture.store.isImportingAttachments)
        XCTAssertTrue(fixture.store.draftAttachments.isEmpty)
        XCTAssertTrue(fixture.store.errorMessage?.contains("не добавлены") == true)
        await fixture.store.waitForPersistence()
    }

    func testLegacyMessagesAndHistoryDecodeWithoutAttachments() throws {
        let message = AIChatMessage(role: .user, text: "old")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: Any])
        object.removeValue(forKey: "attachments")
        let restored = try JSONDecoder().decode(AIChatMessage.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(restored.attachments.isEmpty)
        let conversation = AIChatHistoryConversation(id: UUID(), title: "old", provider: .apple, modelID: "text", messages: [message], draft: "", createdAt: .now, updatedAt: .now, isPinned: false)
        var history = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(conversation)) as? [String: Any])
        history.removeValue(forKey: "draftAttachments")
        XCTAssertTrue(try JSONDecoder().decode(AIChatHistoryConversation.self, from: JSONSerialization.data(withJSONObject: history)).draftAttachments.isEmpty)
    }

    func testContextCountsExtractedDocumentsAndBoundsImagesByWholeTurns() throws {
        let oversized = AIChatMessage(role: .user, text: "", attachments: [document])
        XCTAssertThrowsError(try AIChatContext.bounded([oversized], maximumCharacters: 5))
        let older = AIChatMessage(role: .user, text: "old", attachments: [image, image, image, image])
        let latest = AIChatMessage(role: .user, text: "new", attachments: [image])
        XCTAssertEqual(try AIChatContext.bounded([older, AIChatMessage(role: .assistant, text: "reply"), latest], maximumCharacters: 24_000), [latest])
        XCTAssertTrue(AIChatContext.transcript([oversized]).contains(document.text))
    }

    private let image = AIChatAttachment(name: "screen.png", kind: .image, imageData: Data([1, 2, 3]), mimeType: "image/png")
    private let document = AIChatAttachment(name: "note.txt", kind: .text, text: "Only explicitly attached content")
    private func ready(_ store: AIChatStore) async {
        for _ in 0..<50 where store.selectedStatus == nil { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @MainActor private struct Fixture {
        let suite = "attachment-store-\(UUID().uuidString)"
        let defaults: UserDefaults
        let directory: URL
        let url: URL
        let store: AIChatStore
        let provider: Provider
        init() throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
            url = directory.appendingPathComponent("history.json")
            provider = Provider()
            store = AIChatStore(providers: [provider], defaults: defaults, historyURL: url)
        }
        func clean() { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
    }

    private final class Provider: LauncherAIChatProviding {
        let id: AIChatProviderID = .apple
        var received: [AIChatMessage] = []
        func availability() async -> AIChatProviderStatus {
            AIChatProviderStatus(isAvailable: true, message: "test", models: [
                AIChatModelOption(id: "text", title: "Text", provider: .apple),
                AIChatModelOption(id: "vision", title: "Vision", provider: .apple, supportsImages: true)
            ])
        }
        func stream(messages: [AIChatMessage], model: String) -> AsyncThrowingStream<String, Error> {
            received = messages
            return AsyncThrowingStream { $0.yield("Answer"); $0.finish() }
        }
        func cancel() {}
    }
}

import AppKit
import Carbon
import XCTest
@testable import NotchApp

final class LauncherResultActionTests: XCTestCase {
    func testActionsMatchCapabilitiesAndUnavailableClipboardCannotBeUsed() {
        let image = result(.file(URL(fileURLWithPath: "/tmp/image.png")))
        let imageActions = LauncherResultAction.available(for: image)
        XCTAssertTrue(imageActions.contains(.recognizeText))
        XCTAssertTrue(imageActions.contains(.attachToAI))
        XCTAssertTrue(imageActions.contains(.renameFile))
        let unknown = result(.file(URL(fileURLWithPath: "/tmp/archive.zip")))
        XCTAssertFalse(LauncherResultAction.available(for: unknown).contains(.recognizeText))
        XCTAssertFalse(LauncherResultAction.available(for: unknown).contains(.attachToAI))

        let id = UUID()
        let clipboard = result(.clipboard(id))
        XCTAssertTrue(LauncherResultAction.available(for: clipboard).isEmpty)
        let imageItem = LauncherClipboardItem(id: id, text: nil, imageData: Data([0]), createdAt: Date())
        XCTAssertEqual(LauncherResultAction.available(for: clipboard, clipboardItem: imageItem), [.copy, .paste])
        let textItem = LauncherClipboardItem(id: id, text: "Selected text", imageData: nil, createdAt: Date())
        XCTAssertTrue(LauncherResultAction.available(for: clipboard, clipboardItem: textItem).contains(.translate))
        XCTAssertTrue(LauncherResultAction.available(for: result(.nool(id: "issue", kind: .jira))).contains(.jiraWorklog))
        XCTAssertFalse(LauncherResultAction.available(for: result(.nool(id: "event", kind: .event))).contains(.jiraWorklog))
    }

    func testOnlyCommandKOpensActions() {
        XCTAssertTrue(LauncherKeyboardShortcuts.isActions(keyCode: UInt16(kVK_ANSI_K), modifiers: [.command, .capsLock]))
        for flags: NSEvent.ModifierFlags in [[], .control, .option, [.command, .shift], [.command, .option]] {
            XCTAssertFalse(LauncherKeyboardShortcuts.isActions(keyCode: UInt16(kVK_ANSI_K), modifiers: flags))
        }
        XCTAssertFalse(LauncherKeyboardShortcuts.isActions(keyCode: UInt16(kVK_ANSI_A), modifiers: .command))
    }

    @MainActor
    func testChangingQueryOrCategoryInvalidatesActionTargetImmediately() async throws {
        let suite = "launcher-actions-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let chat = AIChatStore(providers: [], defaults: defaults)
        let model = LauncherModel(settings: LauncherSettings(defaults: defaults), aiChat: chat, snippets: LauncherSnippetStore(url: nil))
        model.query = "2+2"
        for _ in 0..<100 where model.selectedResult == nil { try await Task.sleep(for: .milliseconds(10)) }
        model.toggleActions()
        XCTAssertEqual(model.actionResult?.payload, .calculation("4"))
        model.moveAction(100)
        XCTAssertEqual(model.selectedActionIndex, 3)
        model.moveAction(-100)
        XCTAssertEqual(model.selectedActionIndex, 0)
        XCTAssertFalse(model.canAskAI)
        model.query = "3+3"
        XCTAssertNil(model.actionResult)
        for _ in 0..<100 where model.selectedResult == nil { try await Task.sleep(for: .milliseconds(10)) }
        model.toggleActions()
        XCTAssertEqual(model.actionResult?.payload, .calculation("6"))
        model.category = .ai
        XCTAssertNil(model.actionResult)
        model.toggleActions()
        XCTAssertNil(model.actionResult)
        model.dismiss()
        chat.shutdown()
    }

    @MainActor
    func testSavedTemplatesRemainSearchableWhenClipboardHistoryIsDisabled() async throws {
        let suite = "launcher-snippet-search-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let snippets = LauncherSnippetStore(url: nil)
        XCTAssertTrue(snippets.save(text: "Reusable reply\nDetails with needle"))
        let id = try XCTUnwrap(snippets.items.first?.id)
        let chat = AIChatStore(providers: [], defaults: defaults)
        let settings = LauncherSettings(defaults: defaults)
        XCTAssertFalse(settings.clipboardEnabled)
        let model = LauncherModel(settings: settings, aiChat: chat, snippets: snippets)
        model.category = .clipboard
        model.query = "needle"
        for _ in 0..<100 where model.selectedResult == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.selectedResult?.payload, .snippet(id))
        model.toggleActions()
        XCTAssertNotNil(model.actionResult)
        snippets.remove(id: id)
        for _ in 0..<100 where model.actionResult != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(model.actionResult)
        XCTAssertTrue(model.results.isEmpty)
        model.dismiss()
        chat.shutdown()
    }

    @MainActor
    func testPreparingTextPreservesPriorDraftAndNeverSends() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "launcher-ai-draft-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let chat = AIChatStore(providers: [], defaults: defaults, historyURL: directory.appendingPathComponent("history.json"))
        await chat.waitForPersistence()
        let model = LauncherModel(settings: LauncherSettings(defaults: defaults), aiChat: chat, snippets: LauncherSnippetStore(url: nil))
        chat.draft = "Keep old draft"
        chat.addAttachments([AIChatAttachment(name: "old.txt", kind: .text, text: "Old context")])
        let oldID = try XCTUnwrap(chat.activeConversationID)
        XCTAssertTrue(model.prepareAIText("Recognized text", prompt: "Explain"))
        XCTAssertEqual(model.category, .ai)
        XCTAssertEqual(chat.draft, "Explain")
        XCTAssertEqual(chat.draftAttachments.map(\.text), ["Recognized text"])
        XCTAssertTrue(chat.messages.isEmpty)
        XCTAssertFalse(chat.isStreaming)
        XCTAssertEqual(chat.history.first { $0.id == oldID }?.draft, "Keep old draft")
        XCTAssertEqual(chat.history.first { $0.id == oldID }?.draftAttachments.first?.text, "Old context")
        XCTAssertFalse(model.prepareAIText(String(repeating: "x", count: 12_001)))
        XCTAssertFalse(model.prepareAIText(" \n "))
        XCTAssertEqual(chat.draftAttachments.map(\.text), ["Recognized text"])
        model.dismiss()
        chat.shutdown()
        await chat.waitForPersistence()
    }

    private func result(_ payload: LauncherPayload) -> LauncherResult {
        LauncherResult(id: "test", title: "Test", subtitle: "", payload: payload)
    }
}

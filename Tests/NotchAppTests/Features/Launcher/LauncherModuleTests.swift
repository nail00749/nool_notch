import AppKit
import XCTest
@testable import NotchApp

@MainActor
final class LauncherModuleTests: XCTestCase {
    func testDisabledModulesDisappearFromCategoriesResultsAndActionsThenReturn() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let modules = AppModuleStore(defaults: nil)
        let model = LauncherModel(settings: fixture.settings, modules: modules)

        XCTAssertTrue(model.availableCategories.contains(.ai))
        XCTAssertTrue(model.availableCategories.contains(.clipboard))
        XCTAssertTrue(model.resultActions(for: .init(id: "file", title: "Image", subtitle: "",
                                                    payload: .file(URL(fileURLWithPath: "/tmp/example.png")))).contains(.recognizeText))

        model.category = .ai
        modules.setEnabled(.aiChat, enabled: false)
        XCTAssertEqual(model.category, .all)
        XCTAssertFalse(model.availableCategories.contains(.ai))
        model.category = .ai
        XCTAssertEqual(model.category, .all, "A direct keyboard selection cannot reopen a disabled category")
        XCTAssertFalse(model.prepareAIText("draft"))
        XCTAssertFalse(model.canAskAI)
        XCTAssertFalse(model.resultActions(for: .init(id: "file", title: "Image", subtitle: "",
                                                    payload: .file(URL(fileURLWithPath: "/tmp/example.png")))).contains(.attachToAI))

        modules.setEnabled(.clipboard, enabled: false)
        XCTAssertFalse(model.availableCategories.contains(.clipboard))
        XCTAssertFalse(model.isResultAvailable(.init(id: "snippet", title: "Saved", subtitle: "",
                                                      payload: .snippet(UUID()))))

        modules.setEnabled(.networkTools, enabled: false)
        model.query = "speedtest"
        await waitForSearch(model)
        XCTAssertFalse(model.results.contains { $0.payload == .speedTest })

        let file = LauncherResult(id: "file", title: "Image", subtitle: "",
                                  payload: .file(URL(fileURLWithPath: "/tmp/example.png")))
        modules.setEnabled(.fileShelf, enabled: false)
        modules.setEnabled(.textRecognition, enabled: false)
        XCTAssertFalse(model.resultActions(for: file).contains(.processFile))
        XCTAssertFalse(model.resultActions(for: file).contains(.renameFile))
        XCTAssertFalse(model.resultActions(for: file).contains(.recognizeText))
        XCTAssertFalse(model.isResultAvailable(.init(id: "capture", title: "Capture", subtitle: "",
                                                      payload: .screenTextCapture)))

        modules.setEnabled(.aiChat, enabled: true)
        modules.setEnabled(.clipboard, enabled: true)
        modules.setEnabled(.networkTools, enabled: true)
        modules.setEnabled(.fileShelf, enabled: true)
        modules.setEnabled(.textRecognition, enabled: true)
        XCTAssertTrue(model.availableCategories.contains(.ai))
        XCTAssertTrue(model.availableCategories.contains(.clipboard))
        XCTAssertTrue(model.resultActions(for: file).contains(.processFile))
        XCTAssertTrue(model.resultActions(for: file).contains(.recognizeText))
        model.query = "speedtest"
        for _ in 0..<100 where !model.results.contains(where: { $0.payload == .speedTest }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(model.results.contains { $0.payload == .speedTest })
    }

    func testDisablingClipboardModuleStopsPollingWithoutErasingHistoryOrPreference() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let modules = AppModuleStore(defaults: nil)
        fixture.settings.clipboardEnabled = true
        let clipboard = LauncherClipboardStore(persistenceURL: fixture.historyURL, pasteboard: fixture.pasteboard)
        let model = LauncherModel(settings: fixture.settings, clipboard: clipboard, modules: modules)
        defer { clipboard.stop() }
        model.settingsChanged()
        await clipboard.waitForPersistence()

        fixture.pasteboard.clearContents()
        fixture.pasteboard.setString("сохранённый текст", forType: .string)
        clipboard.captureIfChanged()
        await clipboard.waitForPersistence()
        XCTAssertEqual(clipboard.items.map(\.text), ["сохранённый текст"])

        modules.setEnabled(.clipboard, enabled: false)
        model.settingsChanged()
        fixture.pasteboard.clearContents()
        fixture.pasteboard.setString("новый текст", forType: .string)
        clipboard.captureIfChanged()
        await clipboard.waitForPersistence()
        XCTAssertEqual(clipboard.items.map(\.text), ["сохранённый текст"])
        XCTAssertTrue(fixture.settings.clipboardEnabled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.historyURL.path))

        modules.setEnabled(.clipboard, enabled: true)
        await clipboard.waitForPersistence()
        XCTAssertEqual(clipboard.items.map(\.text), ["сохранённый текст"])
    }

    func testColdDisabledAIChatDefersHistoryReadUntilModuleIsEnabled() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let historyURL = fixture.directory.appendingPathComponent("ai-history.json")
        let saved = AIChatHistoryConversation(
            id: UUID(), title: "Сохранённый чат", provider: .apple, modelID: "apple-system",
            messages: [AIChatMessage(role: .user, text: "Вопрос")], draft: "",
            createdAt: .now, updatedAt: .now, isPinned: false
        )
        XCTAssertEqual(AIChatHistoryDisk.write([saved], url: historyURL), .success)
        let modules = AppModuleStore(defaults: nil)
        modules.setEnabled(.aiChat, enabled: false)
        let chat = AIChatStore(providers: [], defaults: fixture.defaults,
                               historyURL: historyURL, loadHistoryImmediately: false)
        defer { chat.shutdown() }
        let model = LauncherModel(settings: fixture.settings, aiChat: chat, modules: modules)

        await chat.flushHistory()
        XCTAssertTrue(chat.history.isEmpty, "A disabled AI module must not read saved conversations on startup")
        XCTAssertNil(chat.historyError)
        XCTAssertFalse(model.availableCategories.contains(.ai))

        modules.setEnabled(.aiChat, enabled: true)
        await chat.waitForPersistence()
        XCTAssertEqual(chat.history.map(\.id), [saved.id])
        XCTAssertTrue(model.availableCategories.contains(.ai))
    }

    func testSuspendedColdAIChatFlushMergesDraftWithSavedHistory() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let historyURL = fixture.directory.appendingPathComponent("ai-history.json")
        let saved = AIChatHistoryConversation(
            id: UUID(), title: "Старый чат", provider: .apple, modelID: "apple-system",
            messages: [AIChatMessage(role: .user, text: "Ранее")], draft: "",
            createdAt: .now, updatedAt: .now, isPinned: false
        )
        XCTAssertEqual(AIChatHistoryDisk.write([saved], url: historyURL), .success)
        let chat = AIChatStore(providers: [], defaults: fixture.defaults,
                               historyURL: historyURL, loadHistoryImmediately: false)
        defer { chat.shutdown() }

        chat.draft = "Новый черновик"
        chat.suspend()
        await chat.flushHistory()

        let persisted = try JSONDecoder().decode([AIChatHistoryConversation].self,
                                                  from: Data(contentsOf: historyURL))
        XCTAssertTrue(persisted.contains { $0.id == saved.id })
        XCTAssertTrue(persisted.contains { $0.draft == "Новый черновик" })
    }

    func testSuspendedColdAIChatShutdownWaitPersistsDraftAndSavedHistory() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let historyURL = fixture.directory.appendingPathComponent("ai-history.json")
        let saved = AIChatHistoryConversation(
            id: UUID(), title: "Старый чат", provider: .apple, modelID: "apple-system",
            messages: [AIChatMessage(role: .user, text: "Ранее")], draft: "",
            createdAt: .now, updatedAt: .now, isPinned: false
        )
        XCTAssertEqual(AIChatHistoryDisk.write([saved], url: historyURL), .success)
        let chat = AIChatStore(providers: [], defaults: fixture.defaults,
                               historyURL: historyURL, loadHistoryImmediately: false)

        chat.draft = "Черновик перед выходом"
        chat.suspend()
        chat.shutdown()
        await chat.waitForPersistence()

        let persisted = try JSONDecoder().decode([AIChatHistoryConversation].self,
                                                  from: Data(contentsOf: historyURL))
        XCTAssertTrue(persisted.contains { $0.id == saved.id })
        XCTAssertTrue(persisted.contains { $0.draft == "Черновик перед выходом" })
    }

    private func waitForSearch(_ model: LauncherModel) async {
        for _ in 0..<100 where model.isSearching {
            try? await Task.sleep(for: .milliseconds(10))
        }
        // Ranking has its own task and may complete after source loading.
        try? await Task.sleep(for: .milliseconds(30))
    }

    private func makeFixture() throws -> Fixture {
        let name = "launcher-modules-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(name))
        return Fixture(name: name, defaults: defaults, settings: LauncherSettings(defaults: defaults),
                       pasteboard: pasteboard, directory: directory)
    }

    private struct Fixture {
        let name: String
        let defaults: UserDefaults
        let settings: LauncherSettings
        let pasteboard: NSPasteboard
        let directory: URL
        var historyURL: URL { directory.appendingPathComponent("clipboard.json") }

        func cleanup() {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}

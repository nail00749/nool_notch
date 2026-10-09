import Foundation
import XCTest
@testable import NotchApp

@MainActor
final class TextRecognitionStoreTests: XCTestCase {
    func testCancelledRecognitionCannotPublishStaleText() async throws {
        let store = TextRecognitionStore(
            urls: [], onSendToAI: { _, _ in false }, onClose: {},
            recognizer: { _, _ in
                try? await Task.sleep(for: .milliseconds(80))
                return "stale result"
            }
        )

        store.start()
        store.cancel()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(store.phase, .idle)
        XCTAssertTrue(store.text.isEmpty)
    }

    func testSearchNavigatesMatchesInEditableResult() async throws {
        let store = readyStore()
        store.start()
        try await waitUntilReady(store)
        store.text = "Hello hello Привет"
        store.searchQuery = "HELLO"

        XCTAssertEqual(store.matches.count, 2)
        XCTAssertEqual(store.selectedMatchRange?.location, 0)
        let revisionBeforeEdit = store.selectionRevision
        store.text = "Hello hello Привет hello"
        XCTAssertEqual(store.matches.count, 3)
        XCTAssertEqual(store.selectionRevision, revisionBeforeEdit,
                       "Editing recognized text must not move the caret to a search match")
        store.nextMatch()
        XCTAssertEqual(store.selectedMatchRange?.location, 6)
        store.nextMatch()
        XCTAssertEqual(store.selectedMatchRange?.location, 19)
        store.nextMatch()
        XCTAssertEqual(store.selectedMatchRange?.location, 0)
    }

    func testFailedAIDraftHandoffKeepsCorrectedTextAndPreview() async throws {
        var received: [String] = []
        var closeCount = 0
        let store = TextRecognitionStore(
            urls: [],
            onSendToAI: { text, _ in received.append(text); return false },
            onClose: { closeCount += 1 },
            recognizer: { _, _ in "uncorrected" }
        )
        store.start()
        try await waitUntilReady(store)
        store.text = " corrected text "

        store.prepareAIDraft()

        XCTAssertEqual(received, ["corrected text"])
        XCTAssertEqual(closeCount, 0)
        XCTAssertEqual(store.text, " corrected text ")
        XCTAssertNotNil(store.actionMessage)
    }

    func testOversizedAIDraftIsRejectedWithoutCallingHandoff() async throws {
        var called = false
        let store = TextRecognitionStore(
            urls: [], onSendToAI: { _, _ in called = true; return true }, onClose: {},
            recognizer: { _, _ in "ready" }
        )
        store.start()
        try await waitUntilReady(store)
        store.text = String(repeating: "x", count: TextRecognitionStore.maximumAIDraftCharacters + 1)

        store.prepareAIDraft()

        XCTAssertFalse(called)
        XCTAssertTrue(store.actionMessage?.contains("12 000") == true)
    }

    private func readyStore() -> TextRecognitionStore {
        TextRecognitionStore(urls: [], onSendToAI: { _, _ in false }, onClose: {},
                             recognizer: { _, _ in "ready" })
    }

    func testTranslationPreparesEditedTextOnlyOnExplicitActionAndBoundsWholePrompt() async throws {
        var drafts: [String] = []
        var prompts: [String] = []
        var closes = 0
        let store = TextRecognitionStore(urls: [], sourceTitle: "Область экрана",
                                         onSendToAI: { text, prompt in drafts.append(text); prompts.append(prompt); return true },
                                         onClose: { closes += 1 }, recognizer: { _, _ in "original" })
        store.start()
        try await waitUntilReady(store)
        XCTAssertTrue(drafts.isEmpty)
        XCTAssertEqual(store.sourceTitle, "Область экрана")
        store.text = "  Edited capture  "
        store.prepareTranslationDraft()
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts[0], "Edited capture")
        XCTAssertTrue(prompts[0].hasPrefix("Переведи прикреплённый текст"))
        XCTAssertEqual(closes, 1)

        store.text = String(repeating: "x", count: TextRecognitionStore.maximumAIDraftCharacters)
        store.prepareTranslationDraft()
        XCTAssertEqual(drafts.count, 1, "The instruction prefix also counts against the AI limit")
        XCTAssertEqual(closes, 1)
        XCTAssertNotNil(store.actionMessage)
    }

    private func waitUntilReady(_ store: TextRecognitionStore) async throws {
        for _ in 0..<50 {
            if store.phase == .ready { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Recognition did not complete")
    }
}

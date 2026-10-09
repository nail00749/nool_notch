import XCTest
import AppKit
import Carbon
@testable import NotchApp

final class LauncherPreviewTests: XCTestCase {
    func testPreviewShortcutsKeepTypingModifiersDistinct() {
        XCTAssertTrue(LauncherKeyboardShortcuts.isPreview(keyCode: UInt16(kVK_ANSI_Y), modifiers: [.command, .capsLock]))
        XCTAssertFalse(LauncherKeyboardShortcuts.isPreview(keyCode: UInt16(kVK_ANSI_Y), modifiers: [.command, .option]))
        XCTAssertTrue(LauncherKeyboardShortcuts.isPlainSpace(keyCode: UInt16(kVK_Space), modifiers: .capsLock))
        XCTAssertFalse(LauncherKeyboardShortcuts.isPlainSpace(keyCode: UInt16(kVK_Space), modifiers: .command))
        XCTAssertFalse(LauncherKeyboardShortcuts.isPlainSpace(keyCode: UInt16(kVK_Space), modifiers: .shift))
    }

    func testSpaceRequiresExplicitKeyboardNavigationToSelectedFile() {
        let file = LauncherResult(id: "file", title: "Note", subtitle: "", payload: .file(URL(fileURLWithPath: "/tmp/note.txt")))
        let other = LauncherResult(id: "app", title: "App", subtitle: "", payload: .application(URL(fileURLWithPath: "/tmp/App.app")))
        XCTAssertFalse(LauncherPreviewKeyboardPolicy.canUseSpace(selected: file, navigatedID: nil, category: .all, hasDetail: false))
        XCTAssertFalse(LauncherPreviewKeyboardPolicy.canUseSpace(selected: file, navigatedID: "old", category: .all, hasDetail: false))
        XCTAssertTrue(LauncherPreviewKeyboardPolicy.canUseSpace(selected: file, navigatedID: "file", category: .files, hasDetail: false))
        XCTAssertFalse(LauncherPreviewKeyboardPolicy.canUseSpace(selected: other, navigatedID: "app", category: .all, hasDetail: false))
        XCTAssertFalse(LauncherPreviewKeyboardPolicy.canUseSpace(selected: file, navigatedID: "file", category: .ai, hasDetail: false))
        XCTAssertFalse(LauncherPreviewKeyboardPolicy.canUseSpace(selected: file, navigatedID: "file", category: .all, hasDetail: true))
    }

    @MainActor
    func testLatePreflightCannotReopenReplacedOrClosedPreview() async throws {
        let gate = LauncherPreviewPreflightGate()
        let parent = NSPanel(contentRect: NSRect(x: 50, y: 50, width: 400, height: 300),
                             styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        parent.orderFront(nil)
        defer { parent.close() }
        XCTAssertTrue(parent.isVisible)

        var starts = 0
        var stops = 0
        var errors: [String] = []
        let preview = LauncherPreviewController(preflight: { url in await gate.check(url.lastPathComponent) },
                                                makeAccess: { url in
            LauncherPreviewFileAccess(url: url, start: { _ in starts += 1; return true },
                                      stop: { _ in stops += 1 })
        })
        preview.onError = { errors.append($0) }
        let oldURL = FileManager.default.temporaryDirectory.appendingPathComponent("old-preview.txt")
        let newURL = FileManager.default.temporaryDirectory.appendingPathComponent("new-preview.txt")

        preview.present(url: oldURL, resultID: "old", parent: parent)
        let oldTask = try XCTUnwrap(preview.preflightTask)
        await gate.waitForCheck("old-preview.txt")
        preview.present(url: newURL, resultID: "new", parent: parent)
        let newTask = try XCTUnwrap(preview.preflightTask)
        await gate.waitForCheck("new-preview.txt")
        await gate.release("old-preview.txt", as: .ready)
        await oldTask.value
        XCTAssertEqual(preview.resultID, "new")
        XCTAssertNil(preview.panel, "A replaced file must never create a late Quick Look window")
        XCTAssertEqual(starts, 2)
        XCTAssertEqual(stops, 1)

        preview.cancel(restoreFocus: false)
        await gate.release("new-preview.txt", as: .ready)
        await newTask.value
        XCTAssertNil(preview.resultID)
        XCTAssertNil(preview.panel, "Closing Launcher must reject an in-flight file check")
        XCTAssertEqual(stops, 2)
        XCTAssertTrue(errors.isEmpty)
    }

    func testPreflightAcceptsOnlyReadableRegularLocalFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nool-preview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("note.txt")
        try "Preview fixture".write(to: file, atomically: true, encoding: .utf8)
        let regular = await LauncherPreviewPreflight.check(file)
        let folder = await LauncherPreviewPreflight.check(directory)
        let missing = await LauncherPreviewPreflight.check(directory.appendingPathComponent("missing.txt"))
        let remote = await LauncherPreviewPreflight.check(URL(string: "https://example.invalid/file")!)
        XCTAssertEqual(regular, .ready)
        XCTAssertEqual(folder, .notAFile)
        XCTAssertEqual(missing, .unavailable)
        XCTAssertEqual(remote, .notAFile)
    }

    @MainActor
    func testSecurityScopeReleasesExactlyOnce() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("preview-scope")
        var starts = 0
        var stops = 0
        let access = LauncherPreviewFileAccess(url: url, start: { _ in starts += 1; return true },
                                               stop: { _ in stops += 1 })
        XCTAssertEqual(starts, 1)
        access.release()
        access.release()
        XCTAssertEqual(stops, 1)

        let plain = LauncherPreviewFileAccess(url: url, start: { _ in false }, stop: { _ in stops += 1 })
        plain.release()
        XCTAssertEqual(stops, 1, "Ordinary URLs must not call stopAccessing without a scope")
    }
}

private actor LauncherPreviewPreflightGate {
    private var checks: [String: CheckedContinuation<LauncherPreviewPreflight, Never>] = [:]
    private var waiters: [String: CheckedContinuation<Void, Never>] = [:]

    func check(_ name: String) async -> LauncherPreviewPreflight {
        await withCheckedContinuation { continuation in
            checks[name] = continuation
            waiters.removeValue(forKey: name)?.resume()
        }
    }

    func waitForCheck(_ name: String) async {
        if checks[name] != nil { return }
        await withCheckedContinuation { continuation in waiters[name] = continuation }
    }

    func release(_ name: String, as verdict: LauncherPreviewPreflight) {
        checks.removeValue(forKey: name)?.resume(returning: verdict)
    }
}

import AppKit
import WebKit
import XCTest
@testable import NotchApp

final class WallpaperEngineWebViewTests: XCTestCase {
    @MainActor
    func testMissingPackageIsRejected() {
        _ = NSApplication.shared
        XCTAssertNil(WallpaperEngineWebView(projectURL: URL(fileURLWithPath: "/tmp/nool-missing-we-package")))
    }

    /// Opt in on a logged-in Mac with the generated animated fixture. This exercises
    /// WebKit/WebGL, custom-scheme loading, real rendered pixels and pause-before-load.
    @MainActor
    func testNativeAnimatedPackagePausesAndResumesWithoutReloading() throws {
        guard ProcessInfo.processInfo.environment["NOOL_WE_NATIVE"] == "1" else {
            throw XCTSkip("Set NOOL_WE_NATIVE=1 with a native display and the generated scene.pkg fixture")
        }
        let fixture = fixtureURL
        let retainedImport = ProcessInfo.processInfo.environment["NOOL_WE_IMPORT_DIRECTORY"]
        let libraryURL = retainedImport.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { if retainedImport == nil { try? FileManager.default.removeItem(at: libraryURL) } }
        let library = LiveWallpaperLibrary(directory: libraryURL)
        // This tiny local fixture is imported synchronously only in this native run-loop test.
        // Production imports run off the main actor; an async test would monopolize its
        // main-actor executor while the synchronous AppKit pump waits for WebKit callbacks.
        let imported = try library.importWallpaperEngine(from: fixture)
        let importedURL = try XCTUnwrap(imported.url)
        let view = try XCTUnwrap(WallpaperEngineWebView(projectURL: importedURL))
        let panel = NSPanel(contentRect: NSRect(x: 80, y: 100, width: 640, height: 360),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.contentView = view
        panel.orderFrontRegardless()
        defer { view.stop(); panel.orderOut(nil); panel.contentView = nil; panel.close() }
        var failure: String?
        var readyNotifications = 0
        view.onFailure = { failure = $0 }
        view.onReady = { readyNotifications += 1 }
        func apply(_ playing: Bool) {
            view.apply(playing: playing, framesPerSecond: 60, volume: 0, playbackRate: 1,
                       scaleMode: .fill, screenFrame: panel.screen?.frame ?? panel.frame)
        }
        apply(false)
        pump(until: { view.cachedSnapshot != nil || failure != nil }, timeout: 50)
        XCTAssertNil(failure)
        XCTAssertTrue(view.isReady)
        XCTAssertEqual(readyNotifications, 1)
        let initial = try XCTUnwrap(view.cachedSnapshot)
        let png = NSBitmapImageRep(cgImage: initial).representation(using: .png, properties: [:])
        try png?.write(to: URL(fileURLWithPath: "/tmp/nool-we-scene.png"))
        XCTAssertGreaterThan(initial.width, 0)
        XCTAssertGreaterThan(initial.height, 0)
        let bytes = try XCTUnwrap(pixelBytes(initial))
        let colors = Set(stride(from: 0, to: bytes.count, by: 16).compactMap { offset -> UInt32? in
            guard offset + 3 < bytes.count else { return nil }
            return bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
        })
        XCTAssertGreaterThan(colors.count, 20, "The loaded scene must contain the fixture's visible texture")
        let pausedState = try diagnostic(view)
        XCTAssertEqual(pausedState["playing"] as? Bool, false)
        let initialStats = try XCTUnwrap(pausedState["stats"] as? [String: Any])
        XCTAssertEqual(initialStats["running"] as? Bool, false)
        let webView = try XCTUnwrap(view.subviews.compactMap { $0 as? WKWebView }.first)
        var rejected: [Int]?
        webView.callAsyncJavaScript("""
            return await Promise.all([
              'noolwe://runtime/project/../../../../etc/passwd',
              'file:///etc/passwd', 'https://example.invalid/no-network-allowed'
            ].map(async url => { try { return (await fetch(url)).status; } catch { return -1; } }));
            """, arguments: [:], in: nil, in: .page) { result in
                if case .success(let value) = result { rejected = value as? [Int] }
            }
        pump(until: { rejected != nil }, timeout: 4)
        XCTAssertEqual(rejected, [-1, -1, -1])

        apply(true)
        pump(until: { view.reportedFrameCount > 0 || failure != nil }, timeout: 8)
        XCTAssertNil(failure)
        XCTAssertEqual(try diagnostic(view)["playing"] as? Bool, true)
        let revision = view.snapshotRevision
        apply(false)
        pump(until: { view.snapshotRevision > revision }, timeout: 4)
        let animated = try XCTUnwrap(view.cachedSnapshot)
        XCTAssertNotEqual(pixelBytes(initial), pixelBytes(animated), "The shader/particles must change actual pixels")
        let stoppedStats = try XCTUnwrap(try diagnostic(view)["stats"] as? [String: Any])
        XCTAssertEqual(stoppedStats["running"] as? Bool, false)
        let uniformCache = try XCTUnwrap(try diagnostic(view)["uniformCache"] as? [String: Any])
        XCTAssertGreaterThan((uniformCache["skipped"] as? NSNumber)?.intValue ?? 0, 0,
                             "The real renderer must avoid redundant shader-parameter uploads")
        print("NOOL_WE_UNIFORM_CACHE \(uniformCache)")

        pump(for: 0.4)
        let pausedRevision = view.snapshotRevision
        apply(false)
        pump(for: 0.1)
        XCTAssertEqual(view.snapshotRevision, pausedRevision, "Unchanged paused settings must not recapture")
        view.requestSnapshot()
        pump(until: { view.snapshotRevision > pausedRevision }, timeout: 4)
        let still = try XCTUnwrap(view.cachedSnapshot)
        XCTAssertEqual(pixelBytes(animated), pixelBytes(still), "A paused scene must remain visually stable")
        apply(true)
        pump(for: 0.5)
        let resumedRevision = view.snapshotRevision
        apply(false)
        pump(until: { view.snapshotRevision > resumedRevision }, timeout: 4)
        XCTAssertNotEqual(pixelBytes(still), pixelBytes(try XCTUnwrap(view.cachedSnapshot)))
        XCTAssertEqual(readyNotifications, 1, "Resume must preserve the mounted scene")
    }

    @MainActor
    func testMalformedPackageFailsOnceAndReleasesPlayback() throws {
        guard ProcessInfo.processInfo.environment["NOOL_WE_NATIVE"] == "1" else {
            throw XCTSkip("Native WebKit acceptance is opt in")
        }
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("not a package".utf8).write(to: directory.appendingPathComponent("scene.pkg"))
        try Data("{\"type\":\"scene\",\"file\":\"scene.json\"}".utf8)
            .write(to: directory.appendingPathComponent("project.json"))
        let view = try XCTUnwrap(WallpaperEngineWebView(projectURL: directory))
        var failures = 0
        view.onFailure = { _ in failures += 1 }
        pump(until: { failures > 0 }, timeout: 10)
        XCTAssertEqual(failures, 1)
        XCTAssertFalse(view.isReady)
        XCTAssertNil(view.cachedSnapshot)
        view.apply(playing: true, framesPerSecond: 60, volume: 0, playbackRate: 1,
                   scaleMode: .fill, screenFrame: CGRect(x: 0, y: 0, width: 640, height: 360))
        pump(for: 0.2)
        XCTAssertEqual(failures, 1)
        view.stop()
    }

    private var fixtureURL: URL {
        if let path = ProcessInfo.processInfo.environment["NOOL_WE_FIXTURE"] {
            return URL(fileURLWithPath: path)
        }
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return root.appendingPathComponent("third_party/wallpaper-engine/fixture")
    }

    @MainActor
    private func diagnostic(_ view: WallpaperEngineWebView) throws -> [String: Any] {
        var response: String?
        var done = false
        view.readDiagnosticState { response = $0; done = true }
        pump(until: { done }, timeout: 3)
        let data = try XCTUnwrap(response?.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func pixelBytes(_ image: CGImage) -> Data? {
        guard let data = image.dataProvider?.data else { return nil }
        return data as Data
    }

    @MainActor
    private func pump(for seconds: TimeInterval) { pump(until: { false }, timeout: seconds) }

    @MainActor
    private func pump(until condition: () -> Bool, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            if let event = NSApp.nextEvent(matching: .any, until: min(deadline, Date().addingTimeInterval(0.01)),
                                          inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
            NSApp.updateWindows()
            RunLoop.current.run(until: Date().addingTimeInterval(0.002))
        }
    }
}

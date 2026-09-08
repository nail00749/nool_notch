import Foundation
import WebKit
import XCTest
@testable import NotchApp

@MainActor
final class OllamaUsageTests: XCTestCase {
    func testWebKitSessionLoadsNewDocumentOnEveryRefreshAndPreservesDataOnFailure() async {
        let fixture = OllamaSchemeFixture()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(fixture, forURLScheme: "nool-usage")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let session = OllamaWebSession(
            webView: webView,
            settingsURL: URL(string: "nool-usage://ollama.com/settings")!
        )

        let first = await session.loadSnapshot()
        fixture.body = "Session 75% resets in 1 hour Weekly 40% resets in 2 days"
        let second = await session.loadSnapshot()
        fixture.fails = true
        let failed = await session.loadSnapshot()

        XCTAssertEqual(first.windows.first?.remaining, 90)
        XCTAssertEqual(second.windows.first?.remaining, 25)
        XCTAssertEqual(second.connection, .live)
        XCTAssertEqual(fixture.requestCount, 3)
        XCTAssertEqual(failed.connection, .stale)
        XCTAssertEqual(failed.windows, second.windows)
        XCTAssertEqual(failed.updatedAt, second.updatedAt)
    }

    func testRefreshFetchesChangedUsageBeforeReportingLive() async {
        let page = FixtureOllamaPage()
        let reader = OllamaUsageReader()
        let first = await reader.loadSnapshot(from: page)
        page.serverBody = "Session 70% resets in 1 hour Weekly 40% resets in 2 days"

        let second = await reader.loadSnapshot(from: page)

        XCTAssertEqual(first.windows.first?.remaining, 90)
        XCTAssertEqual(second.windows.first?.remaining, 30)
        XCTAssertEqual(second.connection, .live)
        XCTAssertEqual(page.reloadCount, 2)
    }

    func testFailedReloadKeepsLastSuccessAndItsResetDeadlineAsStale() async {
        let page = FixtureOllamaPage()
        let reader = OllamaUsageReader()
        let first = await reader.loadSnapshot(from: page)
        page.reloadError = URLError(.timedOut)

        let second = await reader.loadSnapshot(from: page)

        XCTAssertEqual(second.connection, .stale)
        XCTAssertEqual(second.windows, first.windows)
        XCTAssertEqual(second.updatedAt, first.updatedAt)
    }

    func testConcurrentRefreshesShareOneNavigation() async {
        let page = FixtureOllamaPage()
        let reader = OllamaUsageReader()
        page.suspendReload = true
        let first = Task { await reader.loadSnapshot(from: page) }
        let second = Task { await reader.loadSnapshot(from: page) }
        for _ in 0..<100 where page.reloadContinuation == nil { await Task.yield() }
        page.reloadContinuation?.resume()
        page.reloadContinuation = nil

        let snapshots = await [first.value, second.value]

        XCTAssertEqual(page.reloadCount, 1)
        XCTAssertEqual(snapshots[0], snapshots[1])
        XCTAssertEqual(snapshots[0].windows.first?.remaining, 90)
    }
}

@MainActor
private final class OllamaSchemeFixture: NSObject, WKURLSchemeHandler {
    var body = "Session 10% resets in 1 hour Weekly 20% resets in 2 days"
    var requestCount = 0
    var fails = false

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        requestCount += 1
        if fails {
            urlSchemeTask.didFailWithError(URLError(.cannotConnectToHost))
            return
        }
        let data = Data("<html><body>\(body)</body></html>".utf8)
        let response = URLResponse(
            url: urlSchemeTask.request.url!, mimeType: "text/html",
            expectedContentLength: data.count, textEncodingName: "utf-8"
        )
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}

@MainActor
private final class FixtureOllamaPage: OllamaUsagePage {
    var serverBody = "Session 10% resets in 1 hour Weekly 20% resets in 2 days"
    private var renderedBody = "Session 80% resets in 1 hour Weekly 60% resets in 2 days"
    var reloadError: Error?
    var reloadCount = 0
    var suspendReload = false
    var reloadContinuation: CheckedContinuation<Void, Never>?

    func reloadUsage() async throws {
        reloadCount += 1
        if let reloadError { throw reloadError }
        if suspendReload {
            await withCheckedContinuation { reloadContinuation = $0 }
        }
        renderedBody = serverBody
    }

    func bodyText() async throws -> String { renderedBody }
}

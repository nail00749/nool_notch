import AppKit
import Foundation
import NotchCore
import WebKit

enum OllamaWebViewAttachmentPolicy {
    static func shouldAttach(isAuthenticating: Bool) -> Bool {
        isAuthenticating
    }
}

struct OllamaQuotaProvider: QuotaProvider, QuotaProviderAuthenticating, Sendable {
    let id = "ollama-cloud"
    let displayName = "Ollama Cloud"
    let sourceURL = URL(string: "https://ollama.com/settings")

    func loadSnapshot() async -> QuotaSnapshot {
        await OllamaWebSession.shared.loadSnapshot()
    }

    @MainActor
    func prepare(onUpdate: @escaping @MainActor () -> Void) {
        OllamaWebSession.shared.prepare(onUpdate: onUpdate)
    }

    @MainActor
    func beginAuthentication(onUpdate: @escaping @MainActor () -> Void) {
        OllamaWebSession.shared.beginAuthentication(onUpdate: onUpdate)
    }
}

@MainActor
protocol OllamaUsagePage: AnyObject {
    func reloadUsage() async throws
    func bodyText() async throws -> String
}

@MainActor
final class OllamaUsageReader {
    private var lastSuccessfulSnapshot: QuotaSnapshot?
    private var refreshTask: Task<QuotaSnapshot, Never>?

    func loadSnapshot(from page: any OllamaUsagePage) async -> QuotaSnapshot {
        if let refreshTask { return await refreshTask.value }
        let task = Task { @MainActor in
            do {
                try await page.reloadUsage()
                let body = try await page.bodyText()
                return try self.recordLoadedBody(body)
            } catch {
                return self.failureSnapshot(for: error)
            }
        }
        refreshTask = task
        let snapshot = await task.value
        refreshTask = nil
        return snapshot
    }

    func recordLoadedBody(_ body: String) throws -> QuotaSnapshot {
        let snapshot = try OllamaUsageParser.snapshot(from: body)
        lastSuccessfulSnapshot = snapshot
        return snapshot
    }

    private func failureSnapshot(for error: Error) -> QuotaSnapshot {
        if let usageError = error as? OllamaUsageError,
           case .authenticationRequired = usageError {
            // A different account may be signing in. Do not retain its predecessor's usage.
            lastSuccessfulSnapshot = nil
            return usageError.snapshot(sourceURL: URL(string: "https://ollama.com/settings")!)
        }
        if let previous = lastSuccessfulSnapshot {
            return QuotaSnapshot(
                providerID: previous.providerID,
                providerName: previous.providerName,
                windows: previous.windows,
                connection: .stale,
                updatedAt: previous.updatedAt,
                sourceURL: previous.sourceURL,
                message: "Не удалось обновить Ollama. Показаны последние загруженные лимиты."
            )
        }
        if let error = error as? OllamaUsageError {
            return error.snapshot(sourceURL: URL(string: "https://ollama.com/settings")!)
        }
        return .unavailable(
            providerID: "ollama-cloud",
            providerName: "Ollama Cloud",
            sourceURL: URL(string: "https://ollama.com/settings"),
            message: "Не удалось обновить usage со страницы Ollama."
        )
    }
}

@MainActor
final class OllamaWebSession: NSObject, WKNavigationDelegate, NSWindowDelegate, OllamaUsagePage {
    static let shared = OllamaWebSession()

    private let settingsURL: URL
    private var webView: WKWebView?
    private var authWindow: NSWindow?
    private var onUpdate: (@MainActor () -> Void)?
    private var isAuthenticating = false
    private let usageReader = OllamaUsageReader()
    private var navigationContinuation: CheckedContinuation<Void, Error>?
    private var awaitedNavigation: WKNavigation?
    private var navigationTimeoutTask: Task<Void, Never>?
    private var navigationGeneration = 0

    init(
        webView: WKWebView? = nil,
        settingsURL: URL = URL(string: "https://ollama.com/settings")!
    ) {
        self.webView = webView
        self.settingsURL = settingsURL
        super.init()
        webView?.navigationDelegate = self
    }

    func loadSnapshot() async -> QuotaSnapshot {
        guard webView != nil, isAuthenticating == false else {
            return .requiresAuthentication(
                providerID: "ollama-cloud",
                providerName: "Ollama Cloud",
                sourceURL: settingsURL,
                message: "Войдите в Ollama, чтобы загрузить usage."
            )
        }

        return await usageReader.loadSnapshot(from: self)
    }

    func reloadUsage() async throws {
        guard let webView, isAuthenticating == false else {
            throw OllamaUsageError.authenticationRequired
        }
        try await withCheckedThrowingContinuation { continuation in
            navigationContinuation = continuation
            awaitedNavigation = webView.load(settingsRequest)
            guard let navigation = awaitedNavigation else {
                finishNavigation(throwing: URLError(.cannotLoadFromNetwork))
                return
            }
            navigationTimeoutTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                guard let self, self.awaitedNavigation === navigation else { return }
                self.finishNavigation(throwing: URLError(.timedOut))
                self.webView?.stopLoading()
            }
        }
    }

    func bodyText() async throws -> String {
        guard let webView,
              webView.url?.host == "ollama.com",
              ["/settings", "/settings/"].contains(webView.url?.path ?? "") else {
            throw OllamaUsageError.authenticationRequired
        }
        let generation = navigationGeneration
        let body = try await webView.evaluateJavaScript("document.body.innerText") as? String ?? ""
        guard generation == navigationGeneration else { throw URLError(.cancelled) }
        return body
    }

    private var settingsRequest: URLRequest {
        URLRequest(url: settingsURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
    }

    private func finishNavigation(throwing error: Error? = nil) {
        let continuation = navigationContinuation
        navigationContinuation = nil
        awaitedNavigation = nil
        navigationTimeoutTask?.cancel()
        navigationTimeoutTask = nil
        if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
    }

    func prepare(onUpdate: @escaping @MainActor () -> Void) {
        self.onUpdate = onUpdate
        ensureWebView()
        isAuthenticating = false
        applyAttachmentPolicy()

        if webView?.url == nil {
            webView?.load(settingsRequest)
        } else {
            onUpdate()
        }
    }

    func beginAuthentication(onUpdate: @escaping @MainActor () -> Void) {
        self.onUpdate = onUpdate
        ensureWebView()
        let wasAuthenticating = isAuthenticating
        isAuthenticating = true
        finishNavigation(throwing: OllamaUsageError.authenticationRequired)
        applyAttachmentPolicy()
        NSApp.activate(ignoringOtherApps: true)
        authWindow?.level = .floating
        authWindow?.orderFrontRegardless()
        authWindow?.makeKey()

        if wasAuthenticating == false {
            webView?.load(settingsRequest)
        }
    }

    private func ensureWebView() {
        if webView == nil {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .default()
            let webView = WKWebView(
                frame: NSRect(x: 0, y: 0, width: 920, height: 680),
                configuration: configuration
            )
            webView.navigationDelegate = self
            webView.allowsBackForwardNavigationGestures = true
            self.webView = webView
        }

        guard authWindow == nil else { return }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Подключение Ollama"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        authWindow = window
    }

    private func applyAttachmentPolicy() {
        if OllamaWebViewAttachmentPolicy.shouldAttach(isAuthenticating: isAuthenticating) {
            attachWebViewForAuthentication()
        } else {
            detachWebView()
        }
    }

    private func attachWebViewForAuthentication() {
        guard let webView, let authWindow else { return }
        if authWindow.contentView !== webView {
            authWindow.contentView = webView
        }
    }

    private func detachWebView() {
        guard let webView, let authWindow else { return }
        if authWindow.contentView === webView {
            authWindow.contentView = nil
        }
        authWindow.orderOut(nil)
        webView.stopLoading()
    }

    private func recordFinishedNavigation() {
        let generation = navigationGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let body = try? await bodyText(),
                  generation == navigationGeneration,
                  (try? usageReader.recordLoadedBody(body)) != nil else { return }
            if isAuthenticating {
                isAuthenticating = false
                applyAttachmentPolicy()
            }
            onUpdate?()
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        isAuthenticating = false
        applyAttachmentPolicy()
        return false
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let awaitedNavigation, navigation === awaitedNavigation {
            finishNavigation()
            return
        }
        // Only unsolicited navigation (initial load or sign-in) notifies the owner.
        // A requested refresh already has a waiting caller; notifying again would reload forever.
        recordFinishedNavigation()
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        navigationGeneration += 1
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if let awaitedNavigation, navigation === awaitedNavigation {
            finishNavigation(throwing: error)
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if let awaitedNavigation, navigation === awaitedNavigation {
            finishNavigation(throwing: error)
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finishNavigation(throwing: URLError(.networkConnectionLost))
    }
}

private enum OllamaUsageError: Error {
    case authenticationRequired
    case usageNotFound

    func snapshot(sourceURL: URL) -> QuotaSnapshot {
        switch self {
        case .authenticationRequired:
            .requiresAuthentication(
                providerID: "ollama-cloud",
                providerName: "Ollama Cloud",
                sourceURL: sourceURL,
                message: "Войдите в Ollama, чтобы загрузить usage."
            )
        case .usageNotFound:
            .unavailable(
                providerID: "ollama-cloud",
                providerName: "Ollama Cloud",
                sourceURL: sourceURL,
                message: "Usage не найден на странице Ollama."
            )
        }
    }
}

private enum OllamaUsageParser {
    private struct Match {
        let label: String
        let usedPercent: Double
        let end: Int
    }

    static func snapshot(from body: String) throws -> QuotaSnapshot {
        let text = body.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let lowercased = text.lowercased()

        if lowercased.contains("sign in") || lowercased.contains("continue with email") {
            throw OllamaUsageError.authenticationRequired
        }

        let matches = percentageMatches(in: text)
        guard matches.isEmpty == false else {
            throw OllamaUsageError.usageNotFound
        }

        let windows: [QuotaWindow] = matches.enumerated().compactMap { index, match in
            let nextStart = index + 1 < matches.count
                ? matches[index + 1].end
                : (text as NSString).length
            let suffix = substring(text, from: match.end, to: nextStart)
            let resetAt = parseResetDate(in: suffix)
            let label = match.label == "session" ? "5h" : "7d"
            let usedPercent = min(max(match.usedPercent, 0), 100)
            return QuotaWindow(
                id: match.label,
                label: label,
                limit: 100,
                remaining: 100 - usedPercent,
                resetAt: resetAt,
                unit: .percentage
            )
        }

        guard windows.isEmpty == false else {
            throw OllamaUsageError.usageNotFound
        }

        return QuotaSnapshot(
            providerID: "ollama-cloud",
            providerName: "Ollama Cloud",
            windows: windows,
            connection: .live,
            updatedAt: Date(),
            sourceURL: URL(string: "https://ollama.com/settings"),
            message: "Встроенная Ollama web-сессия"
        )
    }

    private static func percentageMatches(in text: String) -> [Match] {
        let pattern = #"(?i)(session|weekly|week)[\s\S]{0,180}?(\d+(?:[.,]\d+)?)\s*%"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)

        let matches: [Match] = regex.matches(in: text, range: nsRange).compactMap { match -> Match? in
            guard let labelRange = Range(match.range(at: 1), in: text),
                  let percentageRange = Range(match.range(at: 2), in: text),
                  let usedPercent = Double(text[percentageRange].replacingOccurrences(of: ",", with: ".")) else {
                return nil
            }
            return Match(
                label: String(text[labelRange]).lowercased().hasPrefix("session") ? "session" : "weekly",
                usedPercent: usedPercent,
                end: match.range.location + match.range.length
            )
        }
        var unique: [Match] = []
        for match in matches {
            if unique.contains(where: { $0.label == match.label }) == false {
                unique.append(match)
            }
        }
        return unique
    }

    private static func parseResetDate(in text: String) -> Date? {
        let relativePattern = #"(?i)(\d+)\s*(days?|d|hours?|hrs?|h|minutes?|mins?|m)\b"#
        guard let regex = try? NSRegularExpression(pattern: relativePattern) else { return nil }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var seconds: TimeInterval = 0

        for match in regex.matches(in: text, range: nsRange) {
            guard let valueRange = Range(match.range(at: 1), in: text),
                  let unitRange = Range(match.range(at: 2), in: text),
                  let value = Double(text[valueRange]) else { continue }
            let unit = text[unitRange].lowercased()
            if unit.hasPrefix("d") {
                seconds += value * 86_400
            } else if unit.hasPrefix("h") {
                seconds += value * 3_600
            } else {
                seconds += value * 60
            }
        }

        return seconds > 0 ? Date().addingTimeInterval(seconds) : nil
    }

    private static func substring(_ text: String, from start: Int, to end: Int) -> String {
        let nsText = text as NSString
        let safeStart = min(max(start, 0), nsText.length)
        let safeEnd = min(max(end, safeStart), nsText.length)
        return nsText.substring(with: NSRange(location: safeStart, length: safeEnd - safeStart))
    }
}

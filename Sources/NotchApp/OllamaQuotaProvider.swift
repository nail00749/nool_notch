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
private final class OllamaWebSession: NSObject, WKNavigationDelegate, NSWindowDelegate {
    static let shared = OllamaWebSession()

    private let settingsURL = URL(string: "https://ollama.com/settings")!
    private var webView: WKWebView?
    private var authWindow: NSWindow?
    private var onUpdate: (@MainActor () -> Void)?
    private var isAuthenticating = false

    func loadSnapshot() async -> QuotaSnapshot {
        guard let webView else {
            return .requiresAuthentication(
                providerID: "ollama-cloud",
                providerName: "Ollama Cloud",
                sourceURL: settingsURL,
                message: "Войдите в Ollama, чтобы загрузить usage."
            )
        }

        do {
            let body = try await webView.evaluateJavaScript("document.body.innerText") as? String ?? ""
            return try OllamaUsageParser.snapshot(from: body)
        } catch let error as OllamaUsageError {
            return error.snapshot(sourceURL: settingsURL)
        } catch {
            return .unavailable(
                providerID: "ollama-cloud",
                providerName: "Ollama Cloud",
                sourceURL: settingsURL,
                message: "Не удалось прочитать usage со страницы Ollama."
            )
        }
    }

    func prepare(onUpdate: @escaping @MainActor () -> Void) {
        self.onUpdate = onUpdate
        ensureWebView()
        isAuthenticating = false
        applyAttachmentPolicy()

        if webView?.url == nil {
            webView?.load(URLRequest(url: settingsURL))
        } else {
            refreshAndNotify()
        }
    }

    func beginAuthentication(onUpdate: @escaping @MainActor () -> Void) {
        self.onUpdate = onUpdate
        ensureWebView()
        isAuthenticating = true
        applyAttachmentPolicy()
        NSApp.activate(ignoringOtherApps: true)
        authWindow?.level = .floating
        authWindow?.orderFrontRegardless()
        authWindow?.makeKey()

        if webView?.url == nil {
            webView?.load(URLRequest(url: settingsURL))
        } else {
            refreshAndNotify()
        }
    }

    private func ensureWebView() {
        guard webView == nil else { return }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 920, height: 680),
            configuration: configuration
        )
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        self.webView = webView

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

    private func refreshAndNotify() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let snapshot = await loadSnapshot()
            if snapshot.connection == .live {
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
        let host = webView.url?.host
        guard host == "ollama.com" || host == "signin.ollama.com" else { return }
        refreshAndNotify()
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

import AppKit
import Darwin
import Foundation
import NotchCore

/// Hybrid Google Antigravity / Gemini quota provider.
/// 1. Fast path: local Antigravity IDE `language_server_macos` (`GetUserStatus` on `127.0.0.1`) when running.
/// 2. Standalone path: official `agy` CLI (`/Applications/Gemini.app/Contents/Helpers/agy` or `PATH`)
///    via PTY `/usage` TUI parser, with built-in `agy acp --login` sign-in window for individual accounts.
struct GoogleQuotaProvider: QuotaProvider, QuotaProviderAuthenticating, Sendable {
    let id = "google-antigravity"
    let displayName = "Google Antigravity"
    let sourceURL = URL(string: "https://antigravity.google/")

    func loadSnapshot() async -> QuotaSnapshot {
        let now = Date()
        if let cached = await GoogleQuotaGate.shared.cachedSnapshot(at: now) {
            return cached
        }

        do {
            let snapshot = try await fetchHybridSnapshot(now: now)
            await GoogleQuotaGate.shared.recordSuccess(snapshot, at: now)
            return snapshot
        } catch let error as GoogleQuotaError {
            if let stale = await GoogleQuotaGate.shared.staleSnapshot(for: error) {
                return stale
            }
            return error.snapshot(sourceURL: sourceURL)
        } catch {
            return .unavailable(
                providerID: id,
                providerName: displayName,
                sourceURL: sourceURL,
                message: "Не удалось загрузить лимиты Google Antigravity."
            )
        }
    }

    @MainActor
    func beginAuthentication(onUpdate: @escaping @MainActor () -> Void) {
        AgyAuthenticationSession.shared.begin(onUpdate: onUpdate)
    }

    private func fetchHybridSnapshot(now: Date) async throws -> QuotaSnapshot {
        if let localSnapshot = try? await AntigravityLocalQuotaClient.loadSnapshot(
            providerID: id,
            providerName: displayName,
            sourceURL: sourceURL,
            now: now
        ) {
            return localSnapshot
        }

        do {
            return try await AgyQuotaClient.loadSnapshot(
                providerID: id,
                providerName: displayName,
                sourceURL: sourceURL,
                now: now
            )
        } catch GoogleQuotaError.authenticationRequired {
            if let authError = await GoogleQuotaGate.shared.currentAuthError() {
                throw GoogleQuotaError.authenticationFailed(authError)
            }
            throw GoogleQuotaError.authenticationRequired
        }
    }
}

actor GoogleQuotaGate {
    static let shared = GoogleQuotaGate()
    static let minimumInterval: TimeInterval = 180

    private var lastSnapshot: QuotaSnapshot?
    private var lastFetchAt: Date?
    private var lastAuthError: String?

    func cachedSnapshot(at date: Date) -> QuotaSnapshot? {
        if let lastFetchAt, let lastSnapshot,
           date.timeIntervalSince(lastFetchAt) < Self.minimumInterval {
            return lastSnapshot
        }
        return nil
    }

    func recordSuccess(_ snapshot: QuotaSnapshot, at date: Date) {
        lastSnapshot = snapshot
        lastFetchAt = date
        lastAuthError = nil
    }

    func invalidateCache() {
        lastFetchAt = nil
    }

    func recordAuthError(_ message: String) {
        lastAuthError = message
    }

    func clearAuthError() {
        lastAuthError = nil
    }

    func currentAuthError() -> String? {
        lastAuthError
    }

    func staleSnapshot(for error: GoogleQuotaError) -> QuotaSnapshot? {
        switch error {
        case .authenticationRequired, .authenticationFailed, .cliUnavailable:
            lastSnapshot = nil
            return nil
        case .serviceUnavailable, .invalidResponse, .noLimits:
            guard let lastSnapshot else { return nil }
            return QuotaSnapshot(
                providerID: lastSnapshot.providerID,
                providerName: lastSnapshot.providerName,
                windows: lastSnapshot.windows,
                connection: .stale,
                updatedAt: lastSnapshot.updatedAt,
                sourceURL: lastSnapshot.sourceURL,
                message: "Показаны последние лимиты: \(error.shortReason)."
            )
        }
    }
}

enum GoogleQuotaError: Error, Equatable {
    case authenticationRequired
    case authenticationFailed(String)
    case cliUnavailable
    case invalidResponse
    case noLimits
    case serviceUnavailable

    var shortReason: String {
        switch self {
        case .authenticationRequired:
            "требуется вход"
        case .authenticationFailed(let reason):
            reason
        case .cliUnavailable:
            "agy не найден"
        case .invalidResponse:
            "неизвестный формат ответа"
        case .noLimits:
            "лимиты не найдены"
        case .serviceUnavailable:
            "таймаут или сбой сервиса"
        }
    }

    func snapshot(sourceURL: URL?) -> QuotaSnapshot {
        switch self {
        case .authenticationRequired:
            return .requiresAuthentication(
                providerID: "google-antigravity",
                providerName: "Google Antigravity",
                sourceURL: sourceURL,
                message: "Нажмите «Войти», чтобы авторизовать Google Antigravity (agy)."
            )
        case .authenticationFailed(let reason):
            return .requiresAuthentication(
                providerID: "google-antigravity",
                providerName: "Google Antigravity",
                sourceURL: sourceURL,
                message: "Ошибка входа Google: \(reason)"
            )
        case .cliUnavailable:
            return .unavailable(
                providerID: "google-antigravity",
                providerName: "Google Antigravity",
                sourceURL: sourceURL,
                message: "Не найден agy CLI (установите Gemini.app или Antigravity)."
            )
        case .invalidResponse:
            return .unavailable(
                providerID: "google-antigravity",
                providerName: "Google Antigravity",
                sourceURL: sourceURL,
                message: "Не удалось распознать вывод /usage из agy."
            )
        case .noLimits:
            return .unavailable(
                providerID: "google-antigravity",
                providerName: "Google Antigravity",
                sourceURL: sourceURL,
                message: "В панели /usage не найдены активные квоты моделей."
            )
        case .serviceUnavailable:
            return .unavailable(
                providerID: "google-antigravity",
                providerName: "Google Antigravity",
                sourceURL: sourceURL,
                message: "Не удалось получить ответ от Antigravity CLI."
            )
        }
    }
}

// MARK: - Executable Discovery

enum AgyPaths {
    static func executable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = [
            "/Applications/Gemini.app/Contents/Helpers/agy",
            "\(home)/Applications/Gemini.app/Contents/Helpers/agy",
            "/Applications/Antigravity.app/Contents/Resources/app/bin/agy",
            "\(home)/.gemini/antigravity/bin/agy",
            "\(home)/.local/bin/agy",
            "/opt/homebrew/bin/agy",
            "/usr/local/bin/agy"
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/agy" }
        }
        return candidates
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            .map(URL.init(fileURLWithPath:))
    }
}

// MARK: - Agy Login Window (`agy acp --login`)

@MainActor
private final class AgyAuthenticationSession: NSObject, NSWindowDelegate {
    static let shared = AgyAuthenticationSession()

    private var loginProcess: Process?
    private var stdinPipe: Pipe?
    private var outputCollector: AuthURLCollector?
    private var submitTimeoutTask: Task<Void, Never>?
    private var window: AgyLoginPanel?
    private var authURL: URL?
    private var statusLabel: NSTextField?
    private var codeField: NSTextField?
    private var submitButton: NSButton?
    private var onUpdate: (@MainActor () -> Void)?
    private var isSubmitting = false

    func begin(onUpdate: @escaping @MainActor () -> Void) {
        self.onUpdate = onUpdate
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        guard let executableURL = AgyPaths.executable() else {
            Task {
                await GoogleQuotaGate.shared.recordAuthError("не найден бинарник agy")
                onUpdate()
            }
            return
        }

        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        process.executableURL = executableURL
        process.arguments = ["acp", "--login"]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stdout

        let urlCollector = AuthURLCollector()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            if let extracted = urlCollector.appendAndExtractURL(data) {
                Task { @MainActor in
                    AgyAuthenticationSession.shared.didReceiveAuthURL(extracted)
                }
            }
        }
        self.outputCollector = urlCollector

        do {
            try process.run()
            self.loginProcess = process
            self.stdinPipe = stdin
            self.isSubmitting = false
            Task { await GoogleQuotaGate.shared.clearAuthError() }
            presentLoginWindow()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            Task {
                await GoogleQuotaGate.shared.recordAuthError(error.localizedDescription)
                onUpdate()
            }
        }
    }

    private func didReceiveAuthURL(_ url: URL) {
        guard authURL == nil else { return }
        authURL = url
        statusLabel?.stringValue = "Браузер открыт. После входа в Google скопируйте код со страницы и вставьте его ниже:"
        NSWorkspace.shared.open(url)
    }

    private func presentLoginWindow() {
        let panel = AgyLoginPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 210),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Вход в Google Antigravity"
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.delegate = self
        panel.center()

        let content = NSView(frame: panel.contentRect(forFrameRect: panel.frame))

        let titleLabel = NSTextField(labelWithString: "Авторизация индивидуального аккаунта Google")
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.frame = NSRect(x: 20, y: 166, width: 420, height: 22)
        content.addSubview(titleLabel)

        let status = NSTextField(wrappingLabelWithString: "Запускаю agy acp --login и открываю страницу входа Google…")
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.frame = NSRect(x: 20, y: 118, width: 420, height: 42)
        content.addSubview(status)
        self.statusLabel = status

        let field = NSTextField(frame: NSRect(x: 20, y: 76, width: 420, height: 28))
        field.placeholderString = "Вставьте код авторизации или URL со страницы antigravity.google…"
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.target = self
        field.action = #selector(submitCode)
        content.addSubview(field)
        self.codeField = field

        let pasteButton = NSButton(title: "Вставить из буфера", target: self, action: #selector(pasteFromClipboard))
        pasteButton.bezelStyle = .rounded
        pasteButton.frame = NSRect(x: 16, y: 20, width: 155, height: 32)
        content.addSubview(pasteButton)

        let reopenButton = NSButton(title: "Открыть ссылку", target: self, action: #selector(reopenBrowser))
        reopenButton.bezelStyle = .rounded
        reopenButton.frame = NSRect(x: 173, y: 20, width: 125, height: 32)
        content.addSubview(reopenButton)

        let submit = NSButton(title: "Войти", target: self, action: #selector(submitCode))
        submit.bezelStyle = .rounded
        submit.keyEquivalent = "\r"
        submit.frame = NSRect(x: 350, y: 20, width: 94, height: 32)
        content.addSubview(submit)
        self.submitButton = submit

        panel.contentView = content
        self.window = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    @objc private func pasteFromClipboard() {
        if let str = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !str.isEmpty {
            codeField?.stringValue = str
        }
    }

    @objc private func reopenBrowser() {
        if let authURL {
            NSWorkspace.shared.open(authURL)
        }
    }

    @objc private func submitCode() {
        guard !isSubmitting else { return }
        let code = (codeField?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else {
            statusLabel?.textColor = .systemOrange
            statusLabel?.stringValue = "Сначала скопируйте код авторизации из браузера и вставьте его в поле."
            return
        }
        guard let process = loginProcess, let stdin = stdinPipe else {
            cleanupWindowAndProcess()
            return
        }

        isSubmitting = true
        submitButton?.isEnabled = false
        codeField?.isEnabled = false
        statusLabel?.textColor = .secondaryLabelColor
        statusLabel?.stringValue = "Проверяю код авторизации в Antigravity…"

        let payload = Data((code + "\n").utf8)
        let updateCallback = self.onUpdate
        let collector = self.outputCollector

        process.terminationHandler = { terminatedProcess in
            let status = terminatedProcess.terminationStatus
            let detail = collector?.lastErrorLine()
            Task {
                if status == 0 {
                    await GoogleQuotaGate.shared.clearAuthError()
                    await GoogleQuotaGate.shared.invalidateCache()
                    await MainActor.run {
                        AgyAuthenticationSession.shared.finishSuccess(onUpdate: updateCallback)
                    }
                } else {
                    let message = detail ?? "код отклонён или сессия истекла (код \(status))"
                    await GoogleQuotaGate.shared.recordAuthError(message)
                    await MainActor.run {
                        AgyAuthenticationSession.shared.finishFailure(message: message, onUpdate: updateCallback)
                    }
                }
            }
        }

        try? stdin.fileHandleForWriting.write(contentsOf: payload)
        try? stdin.fileHandleForWriting.close()

        submitTimeoutTask?.cancel()
        submitTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 45_000_000_000)
            guard !Task.isCancelled, let self, self.isSubmitting else { return }
            if let running = self.loginProcess, running.isRunning {
                running.terminate()
            }
        }
    }

    private func finishSuccess(onUpdate: (@MainActor () -> Void)?) {
        submitTimeoutTask?.cancel()
        submitTimeoutTask = nil
        cleanupWindowAndProcess()
        onUpdate?()
    }

    private func finishFailure(message: String, onUpdate: (@MainActor () -> Void)?) {
        submitTimeoutTask?.cancel()
        submitTimeoutTask = nil
        isSubmitting = false
        cleanupWindowAndProcess()
        onUpdate?()
    }

    func windowWillClose(_ notification: Notification) {
        let callback = onUpdate
        window = nil
        cleanupProcessOnly()
        callback?()
    }

    private func cleanupWindowAndProcess() {
        let currentWindow = window
        window = nil
        currentWindow?.delegate = nil
        currentWindow?.close()
        cleanupProcessOnly()
    }

    private func cleanupProcessOnly() {
        submitTimeoutTask?.cancel()
        submitTimeoutTask = nil
        outputCollector = nil
        authURL = nil
        statusLabel = nil
        codeField = nil
        submitButton = nil
        isSubmitting = false
        loginProcess?.terminationHandler = nil
        if let stdout = loginProcess?.standardOutput as? Pipe {
            stdout.fileHandleForReading.readabilityHandler = nil
        }
        try? stdinPipe?.fileHandleForWriting.close()
        if let process = loginProcess, process.isRunning {
            process.terminate()
        }
        loginProcess = nil
        stdinPipe = nil
    }
}

private final class AgyLoginPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
           let editor = firstResponder as? NSTextView, editor.isFieldEditor {
            switch event.keyCode {
            case 0: editor.selectAll(nil)
            case 8: editor.copy(nil)
            case 9: editor.paste(nil)
            case 7: editor.cut(nil)
            default: return super.performKeyEquivalent(with: event)
            }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

private final class AuthURLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    private var emitted = false

    func appendAndExtractURL(_ data: Data) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        guard let chunk = String(data: data, encoding: .utf8) else { return nil }
        if buffer.count < 32_768 {
            buffer += chunk
        }
        guard !emitted,
              let range = buffer.range(
                  of: #"https://accounts\.google\.com/\S+"#,
                  options: .regularExpression
              ) else {
            return nil
        }
        let candidate = String(buffer[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidate.contains("state="), let url = URL(string: candidate) else {
            return nil
        }
        emitted = true
        return url
    }

    func lastErrorLine() -> String? {
        lock.lock()
        defer { lock.unlock() }
        let lines = buffer.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return lines.last { line in
            let lower = line.lowercased()
            return lower.contains("couldn't log in") || lower.contains("error") || lower.contains("failed") || lower.contains("cancelled")
        }
    }
}

// MARK: - Agy PTY `/usage` Client

enum AgyQuotaClient {
    static func loadSnapshot(
        providerID: String,
        providerName: String,
        sourceURL: URL?,
        now: Date
    ) async throws -> QuotaSnapshot {
        guard let executableURL = AgyPaths.executable() else {
            throw GoogleQuotaError.cliUnavailable
        }

        let screenText = try await Task.detached(priority: .utility) {
            try runUsageViaPTY(executableURL: executableURL)
        }.value

        let windows = try AgyUsageParser.parseWindows(from: screenText, now: now)
        guard !windows.isEmpty else {
            throw GoogleQuotaError.noLimits
        }

        return QuotaSnapshot(
            providerID: providerID,
            providerName: providerName,
            windows: windows,
            connection: .live,
            updatedAt: now,
            sourceURL: sourceURL,
            message: "Antigravity CLI (/usage)"
        )
    }

    private static func runUsageViaPTY(executableURL: URL) throws -> String {
        if isUnauthenticatedViaModelsSubcommand(executableURL: executableURL) {
            throw GoogleQuotaError.authenticationRequired
        }

        var masterFD: Int32 = -1
        var slaveFD: Int32 = -1
        var winSize = winsize(ws_row: 100, ws_col: 140, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&masterFD, &slaveFD, nil, nil, &winSize) == 0 else {
            throw GoogleQuotaError.serviceUnavailable
        }

        let flags = fcntl(masterFD, F_GETFL)
        _ = fcntl(masterFD, F_SETFL, flags | O_NONBLOCK)

        let inHandle = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: true)
        let outHandle = FileHandle(fileDescriptor: dup(slaveFD), closeOnDealloc: true)
        let errHandle = FileHandle(fileDescriptor: dup(slaveFD), closeOnDealloc: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = [
            "-q",
            "/dev/null",
            executableURL.path,
            "--settings",
            #"{"altScreenMode":"never","showTips":false,"notifications":false}"#
        ]
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["NO_COLOR"] = "1"
        process.environment = env
        process.standardInput = inHandle
        process.standardOutput = outHandle
        process.standardError = errHandle

        defer {
            let scriptPID = process.isRunning ? process.processIdentifier : 0
            close(masterFD)
            if scriptPID > 0 {
                terminateChildProcesses(parentPID: scriptPID)
            }
            if process.isRunning {
                process.terminate()
                for _ in 0..<10 where process.isRunning {
                    usleep(50_000)
                }
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
        }

        do {
            try process.run()
        } catch {
            try? inHandle.close()
            try? outHandle.close()
            try? errHandle.close()
            throw GoogleQuotaError.serviceUnavailable
        }
        try? inHandle.close()
        try? outHandle.close()
        try? errHandle.close()

        let terminal = AgyVirtualTerminal(rows: 120, cols: 140)
        let start = Date()
        let overallDeadline = start.addingTimeInterval(14)
        var rawAccumulated = Data()
        var repliedDA = false
        var repliedOSC = false
        var confirmedWorkspaceTrust = false
        var sentCommand = false
        var sentSecondEnter = false
        var commandSentAt: Date?
        var quotaLoadedAt: Date?
        var readBuf = [UInt8](repeating: 0, count: 8192)

        while Date() < overallDeadline {
            var pfd = pollfd(fd: masterFD, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, 80)
            if ready > 0 && (pfd.revents & Int16(POLLIN)) != 0 {
                while true {
                    let count = Darwin.read(masterFD, &readBuf, readBuf.count)
                    if count > 0 {
                        let slice = readBuf[0..<count]
                        rawAccumulated.append(contentsOf: slice)
                        if rawAccumulated.count > 16_384 {
                            rawAccumulated.removeFirst(rawAccumulated.count - 8_192)
                        }
                        if !repliedDA && (
                            rawAccumulated.range(of: Data([0x1B, 0x5B, 0x3E, 0x63])) != nil
                            || rawAccumulated.range(of: Data([0x1B, 0x5B, 0x63])) != nil
                        ) {
                            writeBytes(Array("\u{1B}[?62;22c\u{1B}[>0;276;0c".utf8), to: masterFD)
                            repliedDA = true
                        }
                        if !repliedOSC && rawAccumulated.range(of: Data("\u{1B}]11;?".utf8)) != nil {
                            writeBytes(Array("\u{1B}]11;rgb:0000/0000/0000\u{1B}\\".utf8), to: masterFD)
                            repliedOSC = true
                        }
                        if slice.count >= 4, Data(slice).range(of: Data("\u{1B}[6n".utf8)) != nil {
                            writeBytes(Array("\u{1B}[1;1R".utf8), to: masterFD)
                        }
                        terminal.feed(slice)
                    } else {
                        break
                    }
                }
            }

            let snapshotText = terminal.renderedText()
            let lower = snapshotText.lowercased()

            if lower.contains("not signed in")
                || lower.contains("select login method")
                || lower.contains("authentication required")
                || lower.contains("please visit the url to log in")
                || lower.contains("open this link in a browser to log in")
                || lower.contains("please sign in") {
                throw GoogleQuotaError.authenticationRequired
            }

            if !confirmedWorkspaceTrust && lower.contains("do you trust the contents") {
                usleep(100_000)
                writeBytes(Array("\r".utf8), to: masterFD)
                confirmedWorkspaceTrust = true
                continue
            }

            if let loadedAt = quotaLoadedAt {
                if Date().timeIntervalSince(loadedAt) >= 0.25 {
                    writeBytes(Array("\u{1B}".utf8), to: masterFD)
                    return snapshotText
                }
            } else if snapshotText.contains("Limit Remaining")
                        && (snapshotText.contains("Refreshes")
                            || snapshotText.contains("Resets")
                            || snapshotText.contains("Quota available")) {
                quotaLoadedAt = Date()
            } else if !sentCommand && snapshotText.contains("? for shortcuts") {
                usleep(250_000)
                writeBytes(Array("/usage".utf8), to: masterFD)
                usleep(200_000)
                writeBytes(Array("\r".utf8), to: masterFD)
                sentCommand = true
                commandSentAt = Date()
            } else if !sentSecondEnter,
                      let sentAt = commandSentAt,
                      Date().timeIntervalSince(sentAt) >= 1.2,
                      !snapshotText.contains("Models & Quota") {
                writeBytes(Array("\r".utf8), to: masterFD)
                sentSecondEnter = true
            }

            if !process.isRunning && quotaLoadedAt == nil {
                break
            }
        }

        let finalText = terminal.renderedText()
        if finalText.contains("Limit Remaining") {
            return finalText
        }
        let lower = finalText.lowercased()
        if lower.contains("not signed in")
            || lower.contains("select login method")
            || lower.contains("authentication required")
            || lower.contains("log in")
            || lower.contains("sign in") {
            throw GoogleQuotaError.authenticationRequired
        }
        throw GoogleQuotaError.serviceUnavailable
    }

    private static func isUnauthenticatedViaModelsSubcommand(executableURL: URL) -> Bool {
        let process = Process()
        let out = Pipe()
        process.executableURL = executableURL
        process.arguments = ["models"]
        process.standardOutput = out
        process.standardError = out
        do {
            try process.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = (String(data: data, encoding: .utf8) ?? "").lowercased()
            return text.contains("please sign in") || text.contains("not signed in")
        } catch {
            return false
        }
    }

    private static func terminateChildProcesses(parentPID: pid_t) {
        let killer = Process()
        killer.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        killer.arguments = ["-P", String(parentPID)]
        killer.standardOutput = FileHandle.nullDevice
        killer.standardError = FileHandle.nullDevice
        try? killer.run()
        killer.waitUntilExit()
    }

    private static func writeBytes(_ bytes: [UInt8], to fd: Int32) {
        bytes.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            _ = Darwin.write(fd, base, ptr.count)
        }
    }
}

// MARK: - Minimal VT100 Screen Emulator + `/usage` Parser

final class AgyVirtualTerminal {
    private let rows: Int
    private let cols: Int
    private var grid: [[Character]]
    private var row = 0
    private var col = 0
    private var scrollback: [String] = []
    private var state: ParseState = .ground
    private var csiParams = ""

    private enum ParseState {
        case ground
        case escape
        case csi
        case osc
        case oscEscape
    }

    init(rows: Int = 120, cols: Int = 140) {
        self.rows = rows
        self.cols = cols
        self.grid = Array(repeating: Array(repeating: " ", count: cols), count: rows)
    }

    func feed<S: Sequence>(_ bytes: S) where S.Element == UInt8 {
        let data = Data(bytes)
        let text = String(decoding: data, as: UTF8.self)
        for ch in text {
            consume(ch)
        }
    }

    private func consume(_ ch: Character) {
        switch state {
        case .ground:
            if ch == "\u{1B}" {
                state = .escape
            } else if ch == "\r" {
                col = 0
            } else if ch == "\n" {
                lineFeed()
            } else if ch == "\r\n" {
                col = 0
                lineFeed()
            } else if ch == "\u{08}" {
                col = max(0, col - 1)
            } else if ch == "\t" {
                col = min(cols - 1, ((col / 8) + 1) * 8)
            } else if ch >= " " {
                if col >= cols {
                    col = 0
                    lineFeed()
                }
                grid[row][col] = ch
                col += 1
            }

        case .escape:
            if ch == "[" {
                state = .csi
                csiParams = ""
            } else if ch == "]" {
                state = .osc
            } else {
                state = .ground
            }

        case .csi:
            if ch.isASCII, let scalar = ch.unicodeScalars.first,
               (0x40...0x7E).contains(scalar.value) {
                applyCSI(final: ch, params: csiParams)
                state = .ground
            } else {
                csiParams.append(ch)
            }

        case .osc:
            if ch == "\u{07}" {
                state = .ground
            } else if ch == "\u{1B}" {
                state = .oscEscape
            }

        case .oscEscape:
            state = .ground
        }
    }

    private func lineFeed() {
        if row + 1 < rows {
            row += 1
        } else {
            let top = String(grid[0]).replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
            if !top.isEmpty {
                scrollback.append(top)
                if scrollback.count > 200 {
                    scrollback.removeFirst(scrollback.count - 200)
                }
            }
            grid.removeFirst()
            grid.append(Array(repeating: " ", count: cols))
        }
    }

    private func applyCSI(final: Character, params: String) {
        let cleaned = params.trimmingCharacters(in: CharacterSet(charactersIn: "?<>="))
        let nums = cleaned.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        let n1 = max(nums.first ?? 0, 1)

        switch final {
        case "A":
            row = max(0, row - n1)
        case "B":
            row = min(rows - 1, row + n1)
        case "C":
            col = min(cols - 1, col + n1)
        case "D":
            col = max(0, col - n1)
        case "E":
            row = min(rows - 1, row + n1)
            col = 0
        case "F":
            row = max(0, row - n1)
            col = 0
        case "G":
            col = min(max(n1 - 1, 0), cols - 1)
        case "H", "f":
            let targetRow = (nums.count >= 1 && nums[0] > 0) ? nums[0] - 1 : 0
            let targetCol = (nums.count >= 2 && nums[1] > 0) ? nums[1] - 1 : 0
            row = min(max(targetRow, 0), rows - 1)
            col = min(max(targetCol, 0), cols - 1)
        case "J":
            let mode = nums.first ?? 0
            if mode == 2 || mode == 3 {
                grid = Array(repeating: Array(repeating: " ", count: cols), count: rows)
                row = 0
                col = 0
            } else if mode == 0 {
                for c in col..<cols { grid[row][c] = " " }
                if row + 1 < rows {
                    for r in (row + 1)..<rows {
                        grid[r] = Array(repeating: " ", count: cols)
                    }
                }
            }
        case "K":
            let mode = nums.first ?? 0
            if mode == 0 {
                for c in col..<cols { grid[row][c] = " " }
            } else if mode == 1 {
                for c in 0...min(col, cols - 1) { grid[row][c] = " " }
            } else if mode == 2 {
                grid[row] = Array(repeating: " ", count: cols)
            }
        default:
            break
        }
    }

    func renderedText() -> String {
        let activeLines = grid.map { line in
            String(line).replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
        }
        let all = scrollback + activeLines
        return all.joined(separator: "\n")
    }
}

enum AgyUsageParser {
    private enum ModelGroup {
        case gemini
        case partner
    }

    static func parseWindows(from rawText: String, now: Date = Date()) throws -> [QuotaWindow] {
        let lines = rawText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        var currentGroup: ModelGroup = .gemini
        var pendingWindowKind: String?
        var results: [QuotaWindow] = []
        var seenIDs = Set<String>()

        for index in lines.indices {
            let line = lines[index]
            guard !line.isEmpty else { continue }
            let upper = line.uppercased()

            if upper.contains("GEMINI MODELS") {
                currentGroup = .gemini
                pendingWindowKind = nil
                continue
            }
            if upper.contains("CLAUDE") && upper.contains("MODELS")
                || upper.contains("PARTNER MODELS")
                || (upper.hasSuffix("MODELS") && !upper.contains("GEMINI") && !upper.contains("WITHIN THIS GROUP")) {
                currentGroup = .partner
                pendingWindowKind = nil
                continue
            }

            if let kind = detectWindowKind(in: line) {
                pendingWindowKind = kind
                if let percent = extractPercentage(from: line) {
                    let reset = (index + 1 < lines.count) ? parseRelativeReset(from: lines[index + 1], now: now) : nil
                    appendWindow(group: currentGroup, kind: kind, percent: percent, resetAt: reset, into: &results, seen: &seenIDs)
                    pendingWindowKind = nil
                }
                continue
            }

            if let kind = pendingWindowKind, let percent = extractPercentage(from: line) {
                var reset: Date?
                if let sameLineReset = parseRelativeReset(from: line, now: now) {
                    reset = sameLineReset
                } else if index + 1 < lines.count {
                    reset = parseRelativeReset(from: lines[index + 1], now: now)
                }
                appendWindow(group: currentGroup, kind: kind, percent: percent, resetAt: reset, into: &results, seen: &seenIDs)
                pendingWindowKind = nil
            }
        }

        // Show Gemini's primary 5h and 7d windows cleanly (matching Codex/Claude mini-rings).
        let geminiWindows = results.filter { $0.id == "google-5h" || $0.id == "google-7d" }
        let selected = geminiWindows.isEmpty ? results : geminiWindows
        let priority = ["google-5h": 0, "google-7d": 1, "google-partner-5h": 2, "google-partner-7d": 3]
        return selected.sorted { (priority[$0.id] ?? 99) < (priority[$1.id] ?? 99) }
    }

    private static func appendWindow(
        group: ModelGroup,
        kind: String,
        percent: Double,
        resetAt: Date?,
        into results: inout [QuotaWindow],
        seen: inout Set<String>
    ) {
        let id: String
        let label: String
        switch group {
        case .gemini:
            id = "google-\(kind)"
            label = kind
        case .partner:
            id = "google-partner-\(kind)"
            label = "Partner · \(kind)"
        }
        guard seen.insert(id).inserted else { return }
        let clamped = min(max(percent, 0), 100)
        let rounded = (clamped * 10).rounded() / 10
        results.append(
            QuotaWindow(
                id: id,
                label: label,
                limit: 100,
                remaining: rounded,
                resetAt: resetAt,
                unit: .percentage
            )
        )
    }

    private static func detectWindowKind(in line: String) -> String? {
        let lower = line.lowercased()
        guard lower.contains("limit") else { return nil }
        if lower.contains("five hour") || lower.contains("5 hour") || lower.contains("5-hour") || lower.contains("5h") {
            return "5h"
        }
        if lower.contains("weekly") || lower.contains("seven day") || lower.contains("7 day") || lower.contains("7-day") || lower.contains("7d") {
            return "7d"
        }
        return nil
    }

    static func extractPercentage(from line: String) -> Double? {
        guard let range = line.range(
            of: #"([0-9]{1,3}(?:\.[0-9]+)?)%"#,
            options: .regularExpression
        ) else {
            return nil
        }
        let numberPart = line[range].dropLast()
        return Double(numberPart)
    }

    static func parseRelativeReset(from line: String, now: Date) -> Date? {
        let lower = line.lowercased()
        guard lower.contains("reset") || lower.contains("refresh") else { return nil }

        var totalSeconds: TimeInterval = 0
        var matched = false

        let patterns: [(String, TimeInterval)] = [
            (#"(\d+)\s*d(?:ays?)?"#, 86_400),
            (#"(\d+)\s*h(?:ours?|rs?)?"#, 3_600),
            (#"(\d+)\s*m(?:in(?:ute)?s?)?"#, 60)
        ]

        for (pattern, unitSeconds) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let nsRange = NSRange(lower.startIndex..<lower.endIndex, in: lower)
            if let match = regex.firstMatch(in: lower, range: nsRange),
               let valRange = Range(match.range(at: 1), in: lower),
               let value = Double(lower[valRange]) {
                totalSeconds += value * unitSeconds
                matched = true
            }
        }

        return matched && totalSeconds > 0 ? now.addingTimeInterval(totalSeconds) : nil
    }
}

// MARK: - Local Antigravity Language Server (`GetUserStatus`)

enum AntigravityLocalQuotaClient {
    struct ServerTarget: Equatable, Sendable {
        let pid: Int
        let csrfToken: String
        let ports: [Int]
    }

    static func loadSnapshot(
        providerID: String,
        providerName: String,
        sourceURL: URL?,
        now: Date
    ) async throws -> QuotaSnapshot {
        let target = try await Task.detached(priority: .utility) {
            try discoverServerTarget()
        }.value

        let body = try JSONSerialization.data(withJSONObject: [
            "metadata": [
                "ideName": "antigravity",
                "extensionName": "antigravity",
                "locale": "en"
            ]
        ])

        for port in target.ports {
            for scheme in ["https", "http"] {
                guard let url = URL(
                    string: "\(scheme)://127.0.0.1:\(port)/exa.language_server_pb.LanguageServerService/GetUserStatus"
                ) else { continue }

                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.timeoutInterval = 4
                request.httpBody = body
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue(target.csrfToken, forHTTPHeaderField: "X-Codeium-Csrf-Token")
                request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")

                guard let (data, response) = try? await loopbackSession.data(for: request),
                      let http = response as? HTTPURLResponse,
                      http.statusCode == 200 else {
                    continue
                }

                let windows = try GoogleQuotaMapper.windows(fromLocalUserStatusData: data)
                guard !windows.isEmpty else { throw GoogleQuotaError.noLimits }

                return QuotaSnapshot(
                    providerID: providerID,
                    providerName: providerName,
                    windows: windows,
                    connection: .live,
                    updatedAt: now,
                    sourceURL: sourceURL,
                    message: "Локальный Antigravity language server"
                )
            }
        }

        throw GoogleQuotaError.serviceUnavailable
    }

    private static let loopbackSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        config.timeoutIntervalForResource = 6
        return URLSession(
            configuration: config,
            delegate: LoopbackSelfSignedDelegate(),
            delegateQueue: nil
        )
    }()

    static func discoverServerTarget() throws -> ServerTarget {
        let psOutput = runCommand("/bin/ps", arguments: ["-axo", "pid=,command="])
        guard let parsed = parseServerProcess(from: psOutput) else {
            throw GoogleQuotaError.serviceUnavailable
        }

        var ports = parsed.ports
        let lsofOutput = runCommand(
            "/usr/sbin/lsof",
            arguments: ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", String(parsed.pid)]
        )
        for port in parseListeningPorts(from: lsofOutput) where !ports.contains(port) {
            ports.append(port)
        }

        guard !ports.isEmpty else {
            throw GoogleQuotaError.serviceUnavailable
        }

        return ServerTarget(pid: parsed.pid, csrfToken: parsed.csrfToken, ports: ports)
    }

    static func parseServerProcess(from psOutput: String) -> (pid: Int, csrfToken: String, ports: [Int])? {
        for rawLine in psOutput.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.contains("language_server_macos") || line.contains("language_server") else {
                continue
            }
            guard let csrfToken = extractFlagValue("--csrf_token", from: line)
                ?? extractFlagValue("--csrf-token", from: line),
                  !csrfToken.isEmpty else {
                continue
            }
            let scanner = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard let pidToken = scanner.first, let pid = Int(pidToken) else {
                continue
            }
            var ports: [Int] = []
            for flag in ["--extension_server_port", "--server_port", "--port"] {
                if let rawPort = extractFlagValue(flag, from: line),
                   let port = Int(rawPort),
                   port > 0,
                   !ports.contains(port) {
                    ports.append(port)
                }
            }
            return (pid: pid, csrfToken: csrfToken, ports: ports)
        }
        return nil
    }

    static func parseListeningPorts(from lsofOutput: String) -> [Int] {
        var ports: [Int] = []
        for line in lsofOutput.split(whereSeparator: \.isNewline) {
            guard line.contains("LISTEN") else { continue }
            for token in line.split(whereSeparator: \.isWhitespace) {
                guard let colonIndex = token.lastIndex(of: ":") else { continue }
                let afterColon = token[token.index(after: colonIndex)...]
                if let port = Int(afterColon), port > 0, !ports.contains(port) {
                    ports.append(port)
                }
            }
        }
        return ports
    }

    private static func extractFlagValue(_ flag: String, from line: String) -> String? {
        let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
        for (index, token) in tokens.enumerated() {
            if token.hasPrefix("\(flag)=") {
                return String(token.dropFirst(flag.count + 1))
            }
            if token == flag, index + 1 < tokens.count {
                return tokens[index + 1]
            }
        }
        return nil
    }

    private static func runCommand(_ path: String, arguments: [String]) -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0, data.count <= 1_000_000 else { return "" }
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
}

private final class LoopbackSelfSignedDelegate: NSObject, URLSessionDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let host = challenge.protectionSpace.host
        guard (host == "127.0.0.1" || host == "localhost"),
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

// MARK: - Local Server Mapping

enum GoogleQuotaMapper {
    private struct LocalUserStatusResponse: Decodable {
        struct UserStatus: Decodable {
            struct CascadeModelConfigData: Decodable {
                let clientModelConfigs: [ModelConfig]?
            }
            let cascadeModelConfigData: CascadeModelConfigData?
        }
        let userStatus: UserStatus?
    }

    private struct ModelConfig: Decodable {
        let label: String?
        let modelOrAlias: ModelOrAlias?
        let quotaInfo: QuotaInfo?
    }

    private struct ModelOrAlias: Decodable {
        let model: String?
    }

    private struct QuotaInfo: Decodable {
        let remainingFraction: Double?
        let resetTime: String?
    }

    struct RawModelQuota: Sendable {
        let identifier: String
        let label: String
        let remainingFraction: Double
        let resetAt: Date?
    }

    static func windows(fromLocalUserStatusData data: Data) throws -> [QuotaWindow] {
        let decoded = try JSONDecoder().decode(LocalUserStatusResponse.self, from: data)
        let configs = decoded.userStatus?.cascadeModelConfigData?.clientModelConfigs ?? []
        let raw = configs.compactMap { config -> RawModelQuota? in
            guard let fraction = config.quotaInfo?.remainingFraction else { return nil }
            let identifier = config.modelOrAlias?.model ?? config.label ?? ""
            let label = config.label ?? identifier
            guard !label.isEmpty else { return nil }
            return RawModelQuota(
                identifier: identifier,
                label: label,
                remainingFraction: fraction,
                resetAt: parseISO8601(config.quotaInfo?.resetTime)
            )
        }
        return aggregateWindows(from: raw)
    }

    static func aggregateWindows(from items: [RawModelQuota]) -> [QuotaWindow] {
        guard !items.isEmpty else { return [] }

        var pro: [RawModelQuota] = []
        var flash: [RawModelQuota] = []
        var partner: [RawModelQuota] = []

        for item in items {
            let key = (item.identifier + " " + item.label).lowercased()
            if key.contains("gemini") && key.contains("flash") {
                flash.append(item)
            } else if key.contains("gemini") && key.contains("pro") {
                pro.append(item)
            } else if key.contains("claude") || key.contains("gpt") {
                partner.append(item)
            }
        }

        var windows: [QuotaWindow] = []
        if let proWindow = makeBucketWindow(id: "google-gemini-pro", label: "Pro", items: pro) {
            windows.append(proWindow)
        }
        if let flashWindow = makeBucketWindow(id: "google-gemini-flash", label: "Flash", items: flash) {
            windows.append(flashWindow)
        }
        if let partnerWindow = makeBucketWindow(id: "google-antigravity-partner", label: "Partner", items: partner) {
            windows.append(partnerWindow)
        }

        if !windows.isEmpty {
            return windows
        }

        return items.prefix(3).enumerated().map { index, item in
            let clamped = min(max(item.remainingFraction, 0), 1)
            return QuotaWindow(
                id: "google-model-\(index)",
                label: item.label,
                limit: 100,
                remaining: (clamped * 100).rounded(),
                resetAt: item.resetAt,
                unit: .percentage
            )
        }
    }

    private static func makeBucketWindow(
        id: String,
        label: String,
        items: [RawModelQuota]
    ) -> QuotaWindow? {
        guard !items.isEmpty else { return nil }
        let minFraction = items.map(\.remainingFraction).min() ?? 0
        let clamped = min(max(minFraction, 0), 1)
        let earliestReset = items.compactMap(\.resetAt).min()
        return QuotaWindow(
            id: id,
            label: label,
            limit: 100,
            remaining: (clamped * 100).rounded(),
            resetAt: earliestReset,
            unit: .percentage
        )
    }

    static func parseISO8601(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) {
            return date
        }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: string)
    }
}

import Foundation
import Darwin

@MainActor
final class LauncherClaudeChatProvider: LauncherAIChatProviding {
    let id: AIChatProviderID = .claude

    private static let stableModelAliases = ["sonnet", "opus", "haiku"]
    private let executableURL: URL?
    private let timeout: TimeInterval
    private let temporaryDirectory: URL
    private var activeSession: LauncherClaudeChatSession?
    private var streamGeneration = 0
    private var preflightTask: Task<Void, Never>?
    private var preflightGeneration: Int?
    private var preflightContinuation: AsyncThrowingStream<String, Error>.Continuation?

    init(
        executableURL: URL? = LauncherClaudeChatProvider.discoverExecutable(),
        timeout: TimeInterval = 120,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        self.executableURL = executableURL
        self.timeout = timeout
        self.temporaryDirectory = temporaryDirectory
    }

    func availability() async -> AIChatProviderStatus {
        guard let executableURL else {
            return unavailableStatus("Claude Code не найден. Установите CLI и войдите с подпиской.")
        }

        let auth = await subscriptionStatus(for: executableURL)
        guard auth.isSubscriptionAuthenticated else {
            return unavailableStatus("Войдите в Claude Code с подпиской, чтобы использовать чат.")
        }

        let aliases = auth.supportedAliases.isEmpty ? ["sonnet", "opus"] : auth.supportedAliases
        let models = aliases.map { alias in
            AIChatModelOption(id: alias, title: Self.title(for: alias), provider: .claude, supportsImages: true)
        }
        return AIChatProviderStatus(isAvailable: true, message: "Claude Code подключён.", models: models)
    }

    func stream(messages: [AIChatMessage], model: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            guard let executableURL else {
                continuation.finish(throwing: AIChatError.unavailable("Claude Code не найден."))
                return
            }
            guard Self.stableModelAliases.contains(model) else {
                continuation.finish(throwing: AIChatError.unavailable("Выберите поддерживаемую модель Claude."))
                return
            }
            let boundedMessages: [AIChatMessage]
            do {
                boundedMessages = try AIChatContext.bounded(messages, maximumCharacters: 24_000)
            } catch {
                continuation.finish(throwing: error)
                return
            }

            streamGeneration += 1
            let generation = streamGeneration
            cancelPreflight(throwing: AIChatError.interrupted)
            activeSession?.cancel()
            activeSession = nil
            preflightGeneration = generation
            preflightContinuation = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.cancel(generation: generation)
                }
            }
            preflightTask = Task { @MainActor [weak self] in
                guard let self else { return }
                let auth = await self.subscriptionStatus(for: executableURL)
                guard Task.isCancelled == false else { return }
                guard self.streamGeneration == generation else {
                    continuation.finish(throwing: AIChatError.interrupted)
                    return
                }
                self.clearPreflight(generation: generation)
                guard auth.isSubscriptionAuthenticated else {
                    continuation.finish(throwing: AIChatError.unavailable("Войдите в Claude Code с подпиской, чтобы использовать чат."))
                    return
                }
                let input: Data
                do {
                    input = try Self.input(for: boundedMessages)
                } catch {
                    continuation.finish(throwing: error)
                    return
                }
                let session = LauncherClaudeChatSession(
                    executableURL: executableURL,
                    model: model,
                    input: input,
                    timeout: self.timeout,
                    temporaryDirectory: self.temporaryDirectory,
                    continuation: continuation,
                    didFinish: { [weak self] in
                        guard self?.streamGeneration == generation else { return }
                        self?.activeSession = nil
                    }
                )
                self.activeSession = session
                session.start()
            }
        }
    }

    func cancel() {
        cancel(generation: nil)
    }

    private func cancel(generation: Int?) {
        guard generation == nil || generation == streamGeneration else { return }
        let cancelledGeneration = streamGeneration
        streamGeneration += 1
        if preflightGeneration == cancelledGeneration {
            cancelPreflight(throwing: AIChatError.interrupted)
        }
        activeSession?.cancel()
        activeSession = nil
    }

    private func subscriptionStatus(for executableURL: URL) async -> LauncherClaudeAuthStatus {
        let probe = Task.detached(priority: .utility) {
            LauncherClaudeAuthProbe.status(executableURL: executableURL)
        }
        return await withTaskCancellationHandler {
            await probe.value
        } onCancel: {
            probe.cancel()
        }
    }

    private func clearPreflight(generation: Int) {
        guard preflightGeneration == generation else { return }
        preflightTask = nil
        preflightGeneration = nil
        preflightContinuation = nil
    }

    private func cancelPreflight(throwing error: Error) {
        preflightTask?.cancel()
        preflightTask = nil
        preflightGeneration = nil
        preflightContinuation?.finish(throwing: error)
        preflightContinuation = nil
    }

    private func unavailableStatus(_ message: String) -> AIChatProviderStatus {
        AIChatProviderStatus(isAvailable: false, message: message, models: [])
    }

    private static func title(for alias: String) -> String {
        alias.prefix(1).uppercased() + alias.dropFirst()
    }

    private static func input(for messages: [AIChatMessage]) throws -> Data {
        var content: [[String: Any]] = [["type": "text", "text": AIChatContext.instructions]]
        for message in messages {
            let role = message.role == .user ? "User" : "Assistant"
            content.append(["type": "text", "text": "\(role):\n\(message.modelText)"])
            for attachment in message.attachments where attachment.kind == .image {
                guard let imageData = attachment.imageData,
                      imageData.isEmpty == false,
                      let mimeType = supportedImageMimeType(attachment.mimeType) else {
                    throw AIChatError.unavailable("Это изображение нельзя отправить в Claude.")
                }
                content.append([
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": mimeType,
                        "data": imageData.base64EncodedString()
                    ]
                ])
            }
        }
        let envelope: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": content]
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope) + Data([0x0A])
        guard data.count <= LauncherClaudeChatSession.maximumInputBytes else {
            throw AIChatError.contextTooLarge
        }
        return data
    }

    private static func supportedImageMimeType(_ mimeType: String?) -> String? {
        switch mimeType?.lowercased() {
        case "image/jpeg", "image/png", "image/gif", "image/webp": mimeType?.lowercased()
        default: nil
        }
    }

    nonisolated private static func discoverExecutable() -> URL? {
        let fileManager = FileManager.default
        let candidates = [
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude")
        ]
        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }
}

private struct LauncherClaudeAuthStatus: Sendable {
    let isSubscriptionAuthenticated: Bool
    let supportedAliases: [String]
}

private enum LauncherClaudeAuthProbe {
    private static let maximumOutputBytes = 64 * 1024
    private static let timeout: TimeInterval = 5

    static func status(executableURL: URL) -> LauncherClaudeAuthStatus {
        let process = Process()
        let output = Pipe()
        process.executableURL = executableURL
        process.arguments = ["auth", "status", "--json"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return LauncherClaudeAuthStatus(isSubscriptionAuthenticated: false, supportedAliases: [])
        }

        let outputHandle = output.fileHandleForReading
        let outputBuffer = LauncherClaudeBoundedDataBuffer(limit: maximumOutputBytes)
        outputHandle.readabilityHandler = { handle in
            outputBuffer.append(handle.availableData)
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            if Task.isCancelled {
                stop(process)
                outputHandle.readabilityHandler = nil
                return LauncherClaudeAuthStatus(isSubscriptionAuthenticated: false, supportedAliases: [])
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            stop(process)
        }
        guard process.isRunning == false else {
            outputHandle.readabilityHandler = nil
            return LauncherClaudeAuthStatus(isSubscriptionAuthenticated: false, supportedAliases: [])
        }
        outputHandle.readabilityHandler = nil
        let data = outputBuffer.data
        guard outputBuffer.exceeded == false,
              process.terminationStatus == 0,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["loggedIn"] as? Bool == true,
              let authMethod = (object["authMethod"] as? String)?.lowercased(),
              (object["apiProvider"] as? String)?.lowercased() == "firstparty",
              ["oauth", "claude.ai", "claudeai"].contains(authMethod) else {
            return LauncherClaudeAuthStatus(isSubscriptionAuthenticated: false, supportedAliases: [])
        }

        let advertised = (object["models"] as? [String]) ?? (object["availableModels"] as? [String]) ?? []
        let aliases = advertised.compactMap { model -> String? in
            let normalized = model.lowercased()
            return ["sonnet", "opus", "haiku"].contains(normalized) ? normalized : nil
        }
        return LauncherClaudeAuthStatus(isSubscriptionAuthenticated: true, supportedAliases: Array(Set(aliases)).sorted())
    }

    private static func stop(_ process: Process) {
        process.terminate()
        let graceDeadline = Date().addingTimeInterval(1)
        while process.isRunning, Date() < graceDeadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }
}

@MainActor
private final class LauncherClaudeChatSession {
    private static let maximumLineBytes = 1 * 1024 * 1024
    static let maximumInputBytes = 7 * 1024 * 1024
    private static let terminationGrace: TimeInterval = 1

    private let executableURL: URL
    private let model: String
    private let inputData: Data
    private let timeout: TimeInterval
    private let temporaryDirectory: URL
    private let continuation: AsyncThrowingStream<String, Error>.Continuation
    private let onFinish: @MainActor () -> Void
    private var process: Process?
    private var outputBuffer = Data()
    private var didReceiveText = false
    private var didFinish = false
    private var timeoutTask: Task<Void, Never>?
    private var outputEOFTask: Task<Void, Never>?
    private var workingDirectoryURL: URL?
    private var outputHandle: FileHandle?
    private var terminationStatus: Int32?
    private var didReachOutputEOF = false

    init(
        executableURL: URL,
        model: String,
        input: Data,
        timeout: TimeInterval,
        temporaryDirectory: URL,
        continuation: AsyncThrowingStream<String, Error>.Continuation,
        didFinish: @escaping @MainActor () -> Void
    ) {
        self.executableURL = executableURL
        self.model = model
        self.inputData = input
        self.timeout = timeout
        self.temporaryDirectory = temporaryDirectory
        self.continuation = continuation
        self.onFinish = didFinish
    }

    func start() {
        do {
            let directory = temporaryDirectory.appendingPathComponent("nool-claude-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
            workingDirectoryURL = directory

            let process = Process()
            let input = Pipe()
            let output = Pipe()
            process.executableURL = executableURL
            process.currentDirectoryURL = directory
            process.arguments = [
                "--safe-mode",
                "--tools", "",
                "--strict-mcp-config",
                "--mcp-config", "{\"mcpServers\":{}}",
                "--no-chrome",
                "--disable-slash-commands",
                "--no-session-persistence",
                "--print",
                "--verbose",
                "--output-format", "stream-json",
                "--input-format", "stream-json",
                "--include-partial-messages",
                "--model", model
            ]
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            let outputHandle = output.fileHandleForReading
            self.outputHandle = outputHandle
            outputHandle.readabilityHandler = { [self] handle in
                let data = handle.availableData
                Task { @MainActor in
                    if data.isEmpty {
                        self.didReachOutputEOF = true
                        self.finishAfterOutputEOF()
                    } else {
                        self.receiveOutput(data)
                    }
                }
            }
            process.terminationHandler = { [self] terminatedProcess in
                Task { @MainActor in
                    self.didTerminate(status: terminatedProcess.terminationStatus)
                }
            }
            try process.run()
            self.process = process
            let inputHandle = input.fileHandleForWriting
            DispatchQueue.global(qos: .utility).async { [weak self] in
                do {
                    try inputHandle.write(contentsOf: self?.inputData ?? Data())
                    try inputHandle.close()
                } catch {
                    Task { @MainActor [weak self] in
                        self?.finish(throwing: AIChatError.invalidResponse, terminateProcess: true)
                    }
                }
            }
            timeoutTask = Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: .seconds(self.timeout))
                guard Task.isCancelled == false else { return }
                self.finish(throwing: AIChatError.timeout, terminateProcess: true)
            }
        } catch {
            finish(throwing: AIChatError.unavailable("Не удалось запустить Claude Code."), terminateProcess: false)
            removeWorkingDirectory()
        }
    }

    func cancel() {
        finish(throwing: AIChatError.interrupted, terminateProcess: true)
    }

    private func receiveOutput(_ data: Data) {
        guard didFinish == false else { return }
        guard data.isEmpty == false else { return }
        outputBuffer.append(data)
        guard outputBuffer.count <= Self.maximumLineBytes else {
            finish(throwing: AIChatError.invalidResponse, terminateProcess: true)
            return
        }

        while let newlineIndex = outputBuffer.firstIndex(of: 0x0A) {
            let line = outputBuffer.prefix(upTo: newlineIndex)
            outputBuffer.removeSubrange(...newlineIndex)
            guard line.isEmpty == false else { continue }
            handleLine(Data(line))
            if didFinish { return }
        }
    }

    private func handleLine(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            finish(throwing: AIChatError.invalidResponse, terminateProcess: true)
            return
        }
        if LauncherClaudeStreamEvent.containsToolUse(object) {
            finish(throwing: AIChatError.invalidResponse, terminateProcess: true)
            return
        }
        guard let delta = LauncherClaudeStreamEvent.textDelta(in: object) else { return }
        didReceiveText = true
        continuation.yield(delta)
    }

    private func didTerminate(status: Int32) {
        guard didFinish == false else {
            releaseTerminatedProcess()
            return
        }
        terminationStatus = status
        if didReachOutputEOF == false {
            outputEOFTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard Task.isCancelled == false else { return }
                guard let self, self.didReachOutputEOF == false else { return }
                self.finish(throwing: AIChatError.invalidResponse, terminateProcess: false)
                self.releaseTerminatedProcess()
            }
        }
        finishAfterOutputEOF()
    }

    private func finishAfterOutputEOF() {
        guard didFinish == false,
              didReachOutputEOF,
              let status = terminationStatus else {
            return
        }
        outputEOFTask?.cancel()
        outputEOFTask = nil
        if outputBuffer.isEmpty == false {
            handleLine(outputBuffer)
            outputBuffer.removeAll(keepingCapacity: false)
        }
        guard didFinish == false else { return }
        guard status == 0, didReceiveText else {
            finish(throwing: AIChatError.invalidResponse, terminateProcess: false)
            releaseTerminatedProcess()
            return
        }
        finish(throwing: nil, terminateProcess: false)
        releaseTerminatedProcess()
    }

    private func finish(throwing error: Error?, terminateProcess: Bool) {
        guard didFinish == false else { return }
        didFinish = true
        timeoutTask?.cancel()
        timeoutTask = nil
        outputEOFTask?.cancel()
        outputEOFTask = nil
        outputHandle?.readabilityHandler = nil
        if terminateProcess, let process, process.isRunning {
            process.terminate()
            let pid = process.processIdentifier
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.terminationGrace) {
                guard process.isRunning else { return }
                kill(pid, SIGKILL)
            }
        }
        continuation.finish(throwing: error)
        onFinish()
    }

    private func releaseTerminatedProcess() {
        outputHandle?.readabilityHandler = nil
        outputHandle = nil
        process?.terminationHandler = nil
        process = nil
        removeWorkingDirectory()
    }

    private func removeWorkingDirectory() {
        if let directory = workingDirectoryURL {
            try? FileManager.default.removeItem(at: directory)
        }
        workingDirectoryURL = nil
    }
}

private enum LauncherClaudeStreamEvent {
    static func containsToolUse(_ object: [String: Any]) -> Bool {
        if let type = object["type"] as? String,
           ["tool_use", "tool_result", "tool", "mcp_message", "hook_event", "error"].contains(type) {
            return true
        }
        if object["is_error"] as? Bool == true { return true }
        if let subtype = (object["subtype"] as? String)?.lowercased(), subtype.contains("error") {
            return true
        }
        for value in object.values {
            if let dictionary = value as? [String: Any], containsToolUse(dictionary) { return true }
            if let array = value as? [[String: Any]], array.contains(where: containsToolUse) { return true }
        }
        return false
    }

    static func textDelta(in object: [String: Any]) -> String? {
        guard object["type"] as? String == "stream_event",
              let event = object["event"] as? [String: Any],
              event["type"] as? String == "content_block_delta",
              let delta = event["delta"] as? [String: Any],
              delta["type"] as? String == "text_delta",
              let text = delta["text"] as? String,
              text.isEmpty == false else {
            return nil
        }
        return text
    }
}

private final class LauncherClaudeBoundedDataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var storage = Data()
    private var didExceed = false

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ data: Data) {
        guard data.isEmpty == false else { return }
        lock.lock()
        defer { lock.unlock() }
        guard storage.count + data.count <= limit else {
            didExceed = true
            return
        }
        storage.append(data)
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var exceeded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didExceed
    }
}

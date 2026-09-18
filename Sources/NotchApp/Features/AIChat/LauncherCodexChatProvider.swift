import Combine
import Darwin
import Foundation

@MainActor
final class LauncherCodexChatProvider: LauncherAIChatProviding {
    let id: AIChatProviderID = .codex

    private let executable: URL?
    private let transportFactory: (URL, [String]) -> AIChatCodexTransport
    private var transport: AIChatCodexTransport?
    private var activeThreadID: String?
    private var activeTurnID: String?
    private var streamTask: Task<Void, Never>?
    private var didTimeout = false
    private var activeGenerationID: UUID?
    private var modelsWithImageInput = Set<String>()

    init(
        executable: URL? = AIChatCodexPaths.executable(),
        transportFactory: @escaping (URL, [String]) -> AIChatCodexTransport = { AIChatCodexProcess(executable: $0, overrides: $1) }
    ) {
        self.executable = executable
        self.transportFactory = transportFactory
    }

    func availability() async -> AIChatProviderStatus {
        guard let executable else {
            modelsWithImageInput = []
            return AIChatProviderStatus(isAvailable: false, message: "Codex CLI не найден.", models: [])
        }
        do {
            let transport = try await connect(executable)
            defer { transport.stop() }
            let account = try await transport.request("account/read", params: ["refreshToken": false])
            guard (account["account"] as? [String: Any])?["type"] as? String == "chatgpt" else {
                modelsWithImageInput = []
                return AIChatProviderStatus(isAvailable: false, message: "Войдите в Codex через ChatGPT.", models: [])
            }
            let models = try await listModels(transport)
            guard models.isEmpty == false else {
                modelsWithImageInput = []
                return AIChatProviderStatus(isAvailable: false, message: "Codex не вернул доступные модели.", models: [])
            }
            modelsWithImageInput = Set(models.lazy.filter(\.supportsImages).map(\.id))
            return AIChatProviderStatus(isAvailable: true, message: "Готово", models: models)
        } catch let error as AIChatError {
            modelsWithImageInput = []
            return AIChatProviderStatus(isAvailable: false, message: error.localizedDescription, models: [])
        } catch {
            modelsWithImageInput = []
            return AIChatProviderStatus(isAvailable: false, message: "Codex недоступен.", models: [])
        }
    }

    func stream(messages: [AIChatMessage], model: String) -> AsyncThrowingStream<String, Error> {
        cancel()
        let generationID = UUID()
        activeGenerationID = generationID
        return AsyncThrowingStream { continuation in
            streamTask = Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.activeGenerationID == generationID, !Task.isCancelled else {
                    continuation.finish(throwing: AIChatError.interrupted); return
                }
                do {
                    try await self.run(messages: messages, model: model, generationID: generationID, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                self.finishActiveTransport(generationID: generationID)
            }
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.cancel(generationID: generationID) }
            }
        }
    }

    func cancel() {
        cancel(generationID: activeGenerationID)
    }

    private func cancel(generationID: UUID?) {
        guard generationID == activeGenerationID else { return }
        streamTask?.cancel()
        streamTask = nil
        if let transport, let activeThreadID, let activeTurnID {
            transport.interrupt(threadID: activeThreadID, turnID: activeTurnID)
        }
        finishActiveTransport(generationID: generationID)
    }

    private func run(
        messages: [AIChatMessage], model: String,
        generationID: UUID,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        guard let executable else { throw AIChatError.unavailable("Codex CLI не найден.") }
        if messages.contains(where: { $0.attachments.contains(where: { $0.kind == .image }) }),
           modelsWithImageInput.contains(model) == false {
            throw AIChatError.unavailable("Выбранная модель Codex не поддерживает изображения.")
        }
        let bounded = try AIChatContext.bounded(messages, maximumCharacters: 24_000)
        let input = try Self.input(for: bounded)
        let transport = try await connect(executable)
        guard activeGenerationID == generationID, !Task.isCancelled else {
            transport.stop(); throw AIChatError.interrupted
        }
        self.transport = transport

        let account = try await transport.request("account/read", params: ["refreshToken": false])
        guard (account["account"] as? [String: Any])?["type"] as? String == "chatgpt" else {
            throw AIChatError.unavailable("Войдите в Codex через ChatGPT.")
        }

        let temporaryDirectory = try AIChatCodexPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let thread = try await transport.request("thread/start", params: Self.threadParameters(model: model, cwd: temporaryDirectory.path))
        try Task.checkCancellation()
        guard activeGenerationID == generationID else { throw AIChatError.interrupted }
        guard let threadID = ((thread["thread"] as? [String: Any])?["id"] as? String), threadID.isEmpty == false else {
            throw AIChatError.invalidResponse
        }
        activeThreadID = threadID

        let turn = try await transport.request("turn/start", params: [
            "threadId": threadID,
            "input": input,
            "environments": [],
            "runtimeWorkspaceRoots": [],
            "effort": "low",
            "approvalPolicy": "never"
        ])
        try Task.checkCancellation()
        guard activeGenerationID == generationID else { throw AIChatError.interrupted }
        guard let turnID = ((turn["turn"] as? [String: Any])?["id"] as? String), turnID.isEmpty == false else {
            throw AIChatError.invalidResponse
        }
        activeTurnID = turnID

        didTimeout = false
        let timeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 75_000_000_000)
            } catch {
                return
            }
            guard self?.activeGenerationID == generationID else { return }
            self?.didTimeout = true
            self?.transport?.stop()
        }
        defer { timeoutTask.cancel() }

        for await event in transport.events {
            try Task.checkCancellation()
            if event.method == "item/agentMessage/delta",
               event.threadID == threadID, event.turnID == turnID,
               let delta = event.delta, delta.isEmpty == false {
                continuation.yield(delta)
            } else if event.method == "turn/completed", event.threadID == threadID, event.turnID == turnID {
                guard event.completionStatus == "completed" else { throw AIChatError.interrupted }
                return
            } else if event.isToolRelated {
                cancel(generationID: generationID)
                throw AIChatError.invalidResponse
            }
        }
        if didTimeout { throw AIChatError.timeout }
        try Task.checkCancellation()
        throw AIChatError.invalidResponse
    }

    private func initialize(_ transport: AIChatCodexTransport) async throws {
        _ = try await transport.request("initialize", params: [
            "clientInfo": ["name": "nool-launcher", "title": "Nool Launcher", "version": "1"],
            "capabilities": ["experimentalApi": true]
        ])
        transport.notify("initialized", params: [:])
    }

    private func connect(_ executable: URL) async throws -> AIChatCodexTransport {
        var connection = transportFactory(executable, [])
        do {
            try connection.start()
            try await initialize(connection)
            let response = try await connection.request("config/read", params: [:])
            guard let config = response["config"] as? [String: Any],
                  let servers = config["mcp_servers"] as? [String: Any], servers.count <= 128 else {
                throw AIChatError.invalidResponse
            }
            if !servers.isEmpty {
                // CLI table overrides merge. Disable each inherited server explicitly in a
                // second process, then verify its effective config before starting a thread.
                let names = servers.keys.sorted()
                guard names.allSatisfy({ $0.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil }) else {
                    throw AIChatError.unavailable("Не удалось изолировать MCP-конфигурацию Codex.")
                }
                connection.stop()
                connection = transportFactory(executable, names.map { "mcp_servers.\($0).enabled=false" })
                try connection.start()
                try await initialize(connection)
            }
            try Task.checkCancellation()
            try await verifyNoTools(connection)
            return connection
        } catch {
            connection.stop()
            throw error
        }
    }

    private func verifyNoTools(_ transport: AIChatCodexTransport) async throws {
        let response = try await transport.request("config/read", params: [:])
        guard let config = response["config"] as? [String: Any],
              let servers = config["mcp_servers"] as? [String: Any],
              servers.values.allSatisfy({ ($0 as? [String: Any])?["enabled"] as? Bool == false }),
              let features = config["features"] as? [String: Any],
              AIChatCodexProcess.disabledFeatures.allSatisfy({ features[$0] as? Bool == false }),
              (config["notify"] as? [Any])?.isEmpty == true,
              config["web_search"] as? String == "disabled",
              config["profile"] == nil || config["profile"] is NSNull else {
            throw AIChatError.unavailable("Codex tools нельзя безопасно отключить в текущей конфигурации.")
        }
    }

    private func listModels(_ transport: AIChatCodexTransport) async throws -> [AIChatModelOption] {
        var cursor: String?
        var models: [AIChatModelOption] = []
        for _ in 0..<20 {
            var params: [String: Any] = ["limit": 100]
            if let cursor { params["cursor"] = cursor }
            let response = try await transport.request("model/list", params: params)
            guard let data = response["data"] as? [[String: Any]] else { throw AIChatError.invalidResponse }
            models += data.compactMap { model in
                guard let id = model["id"] as? String, id.isEmpty == false else { return nil }
                let title = (model["displayName"] as? String) ?? id
                // Older app servers do not advertise modalities. Treat that as text-only
                // rather than assuming an image can be sent to an unknown model.
                let modalities = model["inputModalities"] as? [String]
                return AIChatModelOption(
                    id: id,
                    title: title,
                    provider: .codex,
                    supportsImages: modalities?.contains("image") == true
                )
            }
            cursor = response["nextCursor"] as? String
            if cursor == nil { return models }
        }
        throw AIChatError.invalidResponse
    }

    private func finishActiveTransport(generationID: UUID?) {
        guard generationID == activeGenerationID else { return }
        transport?.stop()
        transport = nil
        activeThreadID = nil
        activeTurnID = nil
        activeGenerationID = nil
    }

    private static func threadParameters(model: String, cwd: String) -> [String: Any] {
        [
            "ephemeral": true,
            "model": model,
            "modelProvider": "openai",
            "cwd": cwd,
            "environments": [],
            "runtimeWorkspaceRoots": [],
            "sandbox": "read-only",
            "approvalPolicy": "never",
            "allowProviderModelFallback": false,
            "dynamicTools": [],
            "baseInstructions": AIChatContext.instructions,
            "developerInstructions": AIChatContext.instructions
        ]
    }

    private static func input(for messages: [AIChatMessage]) throws -> [[String: Any]] {
        var input: [[String: Any]] = [["type": "text", "text": AIChatContext.instructions]]
        for message in messages {
            let role = message.role == .user ? "User" : "Assistant"
            input.append(["type": "text", "text": "\(role):\n\(message.modelText)"])
            for attachment in message.attachments where attachment.kind == .image {
                guard let data = attachment.imageData,
                      data.isEmpty == false,
                      let mimeType = supportedImageMimeType(attachment.mimeType) else {
                    throw AIChatError.unavailable("Это изображение нельзя отправить в Codex.")
                }
                input.append([
                    "type": "image",
                    "url": "data:\(mimeType);base64,\(data.base64EncodedString())",
                    "detail": "auto"
                ])
            }
        }
        return input
    }

    private static func supportedImageMimeType(_ mimeType: String?) -> String? {
        switch mimeType?.lowercased() {
        case "image/jpeg", "image/png", "image/gif", "image/webp": mimeType?.lowercased()
        default: nil
        }
    }
}

@MainActor
protocol AIChatCodexTransport: AnyObject {
    var events: AsyncStream<AIChatCodexEvent> { get }
    func start() throws
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any]
    func notify(_ method: String, params: [String: Any])
    func interrupt(threadID: String, turnID: String)
    func stop()
}

struct AIChatCodexEvent: Sendable {
    let method: String
    let threadID: String?
    let turnID: String?
    let delta: String?
    let isToolRelated: Bool
    let completionStatus: String?
}

@MainActor
final class AIChatCodexProcess: AIChatCodexTransport {
    private static let maximumBufferedBytes = 1_048_576
    private let executable: URL
    private let overrides: [String]
    private let writer = DispatchQueue(label: "nool.ai.codex.stdin")
    private let eventStream: AsyncStream<AIChatCodexEvent>
    private let eventContinuation: AsyncStream<AIChatCodexEvent>.Continuation
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var buffer = Data()
    private var nextRequestID = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var requestTimeouts: [Int: Task<Void, Never>] = [:]
    private var privateCWD: URL?
    private var readerTask: Task<Void, Never>?

    init(executable: URL, overrides: [String] = []) {
        self.executable = executable
        self.overrides = overrides
        var continuation: AsyncStream<AIChatCodexEvent>.Continuation!
        eventStream = AsyncStream { continuation = $0 }
        eventContinuation = continuation
    }

    var events: AsyncStream<AIChatCodexEvent> { eventStream }

    func start() throws {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = Array(Self.launchArguments.dropLast(2))
            + overrides.flatMap { ["-c", $0] } + ["app-server", "--stdio"]
        privateCWD = try AIChatCodexPaths.makeTemporaryDirectory()
        process.currentDirectoryURL = privateCWD
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let directory = privateCWD
        process.terminationHandler = { _ in
            if let directory { try? FileManager.default.removeItem(at: directory) }
        }
        do { try process.run() } catch {
            if let directory { try? FileManager.default.removeItem(at: directory) }
            throw error
        }
        self.process = process
        self.input = input
        self.output = output
        let handle = output.fileHandleForReading
        readerTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                let data = handle.availableData
                await self?.consume(data)
                if data.isEmpty { break }
            }
            try? handle.close()
        }
    }

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        try Task.checkCancellation()
        guard input != nil else { throw AIChatError.unavailable("Codex CLI не запущен.") }
        let id = nextRequestID
        nextRequestID += 1
        return try await withTaskCancellationHandler {
          try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            requestTimeouts[id] = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(nanoseconds: 15_000_000_000)
                } catch {
                    return
                }
                self?.timeoutRequest(id)
            }
            send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
          }
        } onCancel: {
            Task { @MainActor [weak self] in self?.stop() }
        }
    }

    func notify(_ method: String, params: [String: Any]) {
        send(["jsonrpc": "2.0", "method": method, "params": params])
    }

    func interrupt(threadID: String, turnID: String) {
        notify("turn/interrupt", params: ["threadId": threadID, "turnId": turnID])
    }

    func stop() {
        readerTask?.cancel()
        readerTask = nil
        if let handle = input?.fileHandleForWriting { writer.async { try? handle.close() } }
        if process?.isRunning == true { process?.terminate() }
        if let process {
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        failAll(AIChatError.interrupted)
        eventContinuation.finish()
        process = nil
        input = nil
        output = nil
        privateCWD = nil
    }

    private func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { failAll(AIChatError.invalidResponse); return }
        guard data.count <= 7 * 1024 * 1024 else { failAll(AIChatError.contextTooLarge); return }
        guard let handle = input?.fileHandleForWriting else { failAll(AIChatError.interrupted); return }
        let line = data + Data([0x0A])
        writer.async { [weak self] in
            do { try handle.write(contentsOf: line) }
            catch { Task { @MainActor in self?.stop() } }
        }
    }

    private func consume(_ data: Data) {
        guard data.isEmpty == false else {
            if !buffer.isEmpty { consumeLine(buffer); buffer.removeAll() }
            failAll(AIChatError.invalidResponse)
            eventContinuation.finish()
            return
        }
        guard buffer.count + data.count <= Self.maximumBufferedBytes else { stop(); return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            consumeLine(line)
        }
    }

    private func consumeLine(_ line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        if let id = (object["id"] as? NSNumber)?.intValue, object["method"] == nil {
            requestTimeouts.removeValue(forKey: id)?.cancel()
            guard let result = object["result"] as? [String: Any] else { pending.removeValue(forKey: id)?.resume(throwing: AIChatError.invalidResponse); return }
            pending.removeValue(forKey: id)?.resume(returning: result)
            return
        }
        guard let method = object["method"] as? String else { return }
        if let id = object["id"] { // No server request is valid in text-only mode.
            send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Denied"]])
            stop()
            return
        }
        let params = object["params"] as? [String: Any]
        let completedTurn = params?["turn"] as? [String: Any]
        let itemType = (params?["item"] as? [String: Any])?["type"] as? String
        let unexpectedItem = itemType.map { !["userMessage", "agentMessage", "reasoning", "contextCompaction"].contains($0) } ?? false
        let event = AIChatCodexEvent(
            method: method,
            threadID: params?["threadId"] as? String,
            turnID: (params?["turnId"] as? String) ?? (completedTurn?["id"] as? String),
            delta: params?["delta"] as? String,
            isToolRelated: unexpectedItem || method.contains("tool") || method.contains("command") || method.contains("mcp") || method.contains("fileChange"),
            completionStatus: completedTurn?["status"] as? String
        )
        eventContinuation.yield(event)
    }

    private func failAll(_ error: Error) {
        requestTimeouts.values.forEach { $0.cancel() }
        requestTimeouts.removeAll()
        let continuations = pending.values
        pending.removeAll()
        continuations.forEach { $0.resume(throwing: error) }
    }

    private func timeoutRequest(_ id: Int) {
        requestTimeouts.removeValue(forKey: id)
        pending.removeValue(forKey: id)?.resume(throwing: AIChatError.timeout)
    }

    static let disabledFeatures = [
        "apps", "browser_use", "browser_use_external", "browser_use_full_cdp_access", "in_app_browser",
        "computer_use", "hooks", "plugins", "plugin_sharing", "remote_plugin", "shell_tool", "shell_snapshot",
        "unified_exec", "unified_exec_tty", "sleep_tool", "skill_search", "skill_mcp_dependency_install",
        "tool_call_mcp_elicitation", "tool_suggest", "multi_agent", "multi_agent_v2", "goals", "memories",
        "image_generation", "view_image", "workspace_dependencies", "code_mode", "code_mode_host",
        "code_mode_interrupt", "code_mode_only", "code_mode_prewarm", "enable_mcp_apps",
        "mcp_2026_07_28", "codex_apps_mcp_2026_07_28", "request_permissions_tool", "chronicle"
    ]

    static var launchArguments: [String] {
        disabledFeatures.flatMap { ["--disable", $0] } + [
            "-c", "notify=[]", "-c", "web_search=\"disabled\"", "-c", "skills.include_instructions=false",
            "-c", "project_doc_max_bytes=0", "-c", "tools.update_plan.enabled=false",
            "-c", "tools.experimental_request_user_input.enabled=false", "-c", "history.persistence=\"none\"",
            "-c", "analytics.enabled=false", "app-server", "--stdio"
        ]
    }
}

private enum AIChatCodexPaths {
    static func executable() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        var candidates = ["/Applications/Codex.app/Contents/Resources/codex", "/Applications/ChatGPT.app/Contents/Resources/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex", "\(NSHomeDirectory())/.local/bin/codex"]
        if let path = environment["PATH"] { candidates += path.split(separator: ":").map { "\($0)/codex" } }
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map(URL.init(fileURLWithPath:))
    }

    static func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NoolCodexChat-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        return directory
    }
}

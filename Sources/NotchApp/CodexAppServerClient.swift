import Foundation

enum CodexJSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([CodexJSONValue])
    case object([String: CodexJSONValue])

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var objectValue: [String: CodexJSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var arrayValue: [CodexJSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    var foundationValue: Any {
        switch self {
        case .null: NSNull()
        case .bool(let value): value
        case .number(let value): value
        case .string(let value): value
        case .array(let values): values.map(\.foundationValue)
        case .object(let values): values.mapValues(\.foundationValue)
        }
    }

    static func decode(_ value: Any?) -> CodexJSONValue {
        switch value {
        case nil, is NSNull: .null
        case let value as Bool: .bool(value)
        case let value as NSNumber: .number(value.doubleValue)
        case let value as String: .string(value)
        case let value as [Any]: .array(value.map(Self.decode))
        case let value as [String: Any]:
            .object(value.mapValues(Self.decode))
        default: .null
        }
    }
}

enum CodexRequestID: Hashable, Sendable {
    case number(Int64)
    case string(String)

    var foundationValue: Any {
        switch self {
        case .number(let value): value
        case .string(let value): value
        }
    }

    var stableString: String {
        switch self {
        case .number(let value): "number:\(value)"
        case .string(let value): "string:\(value)"
        }
    }
}

struct CodexAppServerMessage: Equatable, Sendable {
    let id: CodexRequestID?
    let method: String?
    let params: [String: CodexJSONValue]
    let result: CodexJSONValue?
    let errorMessage: String?
}

enum CodexAppServerClientError: Error, Equatable, Sendable {
    case executableUnavailable
    case launchFailed
    case notConnected
    case writeFailed
}

final class CodexAppServerClient: @unchecked Sendable {
    typealias MessageHandler = @Sendable (CodexAppServerMessage) -> Void
    typealias ExitHandler = @Sendable (Int32) -> Void

    var onMessage: MessageHandler?
    var onExit: ExitHandler?

    private let executableURL: URL
    private let callbackQueue: DispatchQueue
    private let ioQueue = DispatchQueue(label: "app.nool.notch.codex-app-server")
    private let lock = NSLock()
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var readBuffer = Data()
    private var intentionallyStopped = true

    init(executableURL: URL, callbackQueue: DispatchQueue = .main) {
        self.executableURL = executableURL
        self.callbackQueue = callbackQueue
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return process?.isRunning == true
    }

    func start(clientVersion: String) throws {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw CodexAppServerClientError.executableUnavailable
        }

        lock.lock()
        if process?.isRunning == true {
            lock.unlock()
            return
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["app-server", "--listen", "stdio://"]
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard data.isEmpty == false else {
                handle.readabilityHandler = nil
                return
            }
            self?.enqueueReceive(data)
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty {
                handle.readabilityHandler = nil
            }
        }
        process.terminationHandler = { [weak self] process in
            self?.enqueueExit(process.terminationStatus)
        }

        do {
            try process.run()
        } catch {
            lock.unlock()
            throw CodexAppServerClientError.launchFailed
        }

        self.process = process
        stdinHandle = input.fileHandleForWriting
        readBuffer.removeAll(keepingCapacity: true)
        intentionallyStopped = false
        lock.unlock()

        try send([
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "clientInfo": ["name": "Nool Notch", "version": clientVersion],
                "capabilities": [
                    "experimentalApi": true,
                    "requestAttestation": false,
                    "extensions": [:] as [String: Any]
                ]
            ]
        ])
    }

    func stop() {
        lock.lock()
        intentionallyStopped = true
        let runningProcess = process
        let input = stdinHandle
        process = nil
        stdinHandle = nil
        lock.unlock()

        try? input?.close()
        if let runningProcess, runningProcess.isRunning {
            runningProcess.terminate()
        }
    }

    static func drainMessages(buffer: inout Data) -> [CodexAppServerMessage] {
        var messages: [CodexAppServerMessage] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            guard line.isEmpty == false,
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                continue
            }
            let params = (object["params"] as? [String: Any])?.mapValues(CodexJSONValue.decode) ?? [:]
            messages.append(CodexAppServerMessage(
                id: requestID(from: object["id"]),
                method: object["method"] as? String,
                params: params,
                result: object.keys.contains("result") ? CodexJSONValue.decode(object["result"]) : nil,
                errorMessage: (object["error"] as? [String: Any])?["message"] as? String
            ))
        }
        return messages
    }

    func sendResponse(id: CodexRequestID, result: [String: CodexJSONValue]) throws {
        try send([
            "jsonrpc": "2.0",
            "id": id.foundationValue,
            "result": result.mapValues(\.foundationValue)
        ])
    }

    private static func requestID(from value: Any?) -> CodexRequestID? {
        if let value = value as? String { return .string(value) }
        if let value = value as? NSNumber { return .number(value.int64Value) }
        return nil
    }

    private func send(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)

        lock.lock()
        guard let stdinHandle else {
            lock.unlock()
            throw CodexAppServerClientError.notConnected
        }
        lock.unlock()

        do {
            try stdinHandle.write(contentsOf: data)
        } catch {
            throw CodexAppServerClientError.writeFailed
        }
    }

    private func receive(_ data: Data) {
        readBuffer.append(data)
        let messages = Self.drainMessages(buffer: &readBuffer)
        for message in messages {
            if message.method == nil, message.id == .number(1), message.errorMessage == nil {
                try? send([
                    "jsonrpc": "2.0",
                    "method": "initialized"
                ])
            }
            let handler = onMessage
            callbackQueue.async { handler?(message) }
        }
    }

    private func enqueueReceive(_ data: Data) {
        ioQueue.async { [weak self] in self?.receive(data) }
    }

    private func enqueueExit(_ status: Int32) {
        ioQueue.async { [weak self] in self?.processDidExit(status) }
    }

    private func processDidExit(_ status: Int32) {
        lock.lock()
        let shouldNotify = intentionallyStopped == false
        process = nil
        stdinHandle = nil
        lock.unlock()
        guard shouldNotify else { return }
        let handler = onExit
        callbackQueue.async { handler?(status) }
    }
}

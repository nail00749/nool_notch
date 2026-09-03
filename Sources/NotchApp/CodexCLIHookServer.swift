import Darwin
import Foundation
import Network

struct CodexCLIHookEvent: Sendable {
    let sourceID: String
    let eventName: String
    let sessionID: String
    let workspacePath: String?
    let toolName: String?
    let detail: String?

    var isPermissionRequest: Bool {
        eventName.caseInsensitiveCompare("PermissionRequest") == .orderedSame
    }

    init?(data: Data) {
        guard data.count <= 1_048_576,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sourceID = object["_source"] as? String,
              ["codex-cli", "claude-code"].contains(sourceID),
              let eventName = object["hook_event_name"] as? String,
              eventName.isEmpty == false,
              let sessionID = object["session_id"] as? String,
              sessionID.isEmpty == false else {
            return nil
        }

        self.sourceID = sourceID
        self.eventName = eventName
        self.sessionID = sessionID
        workspacePath = Self.nonEmptyString(object["cwd"])
        toolName = Self.nonEmptyString(object["tool_name"])

        // Commands and permission reasons may contain credentials or prompt data.
        // Keep only the tool category needed to explain the approval request.
        detail = toolName.map { "Инструмент: \($0)" }
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

@MainActor
final class CodexCLIHookResponder {
    private var hasResponded = false
    private let handler: (Bool) -> Void

    init(handler: @escaping (Bool) -> Void) {
        self.handler = handler
    }

    func resolve(allowed: Bool) {
        guard hasResponded == false else { return }
        hasResponded = true
        handler(allowed)
    }
}

@MainActor
final class CodexCLIHookServer {
    nonisolated static var socketPath: String {
        "/tmp/nool-notch-\(getuid()).sock"
    }

    var onEvent: ((CodexCLIHookEvent, CodexCLIHookResponder?) -> Void)?

    private var listener: NWListener?

    func start() throws {
        guard listener == nil else { return }
        unlink(Self.socketPath)

        let previousMask = umask(0o077)
        let parameters = NWParameters()
        parameters.defaultProtocolStack.transportProtocol = NWProtocolTCP.Options()
        parameters.requiredLocalEndpoint = .unix(path: Self.socketPath)

        do {
            let listener = try NWListener(using: parameters)
            self.listener = listener
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.accept(connection)
                }
            }
            listener.stateUpdateHandler = { state in
                if case .ready = state {
                    umask(previousMask)
                    chmod(Self.socketPath, 0o700)
                } else if case .failed = state {
                    umask(previousMask)
                }
            }
            listener.start(queue: .main)
        } catch {
            umask(previousMask)
            throw error
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        unlink(Self.socketPath)
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        receiveAll(from: connection, accumulated: Data())
    }

    private func receiveAll(from connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
            [weak self] content, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                var data = accumulated
                if let content { data.append(content) }
                if data.count > 1_048_576 {
                    self.sendEmptyResponse(to: connection)
                } else if isComplete || error != nil {
                    self.process(data, from: connection)
                } else {
                    self.receiveAll(from: connection, accumulated: data)
                }
            }
        }
    }

    private func process(_ data: Data, from connection: NWConnection) {
        guard let event = CodexCLIHookEvent(data: data) else {
            sendEmptyResponse(to: connection)
            return
        }

        if event.isPermissionRequest {
            let responder = CodexCLIHookResponder { [weak self, weak connection] allowed in
                guard let self, let connection else { return }
                self.sendPermissionResponse(allowed: allowed, to: connection)
            }
            onEvent?(event, responder)
        } else {
            onEvent?(event, nil)
            sendEmptyResponse(to: connection)
        }
    }

    private func sendEmptyResponse(to connection: NWConnection) {
        send(Data("{}".utf8), to: connection)
    }

    private func sendPermissionResponse(allowed: Bool, to connection: NWConnection) {
        let behavior = allowed ? "allow" : "deny"
        let response = """
        {"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"\(behavior)"}}}
        """
        send(Data(response.utf8), to: connection)
    }

    private func send(_ data: Data, to connection: NWConnection) {
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

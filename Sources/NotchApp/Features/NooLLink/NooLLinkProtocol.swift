import Foundation

struct NooLLinkFile: Codable, Sendable {
    let name: String
    let dataBase64: String
}

struct NooLLinkTransferAcknowledgement: Codable, Sendable {
    let id: String
    let success: Bool
    var message: String? = nil

    var isValid: Bool {
        UUID(uuidString: id) != nil && (message?.utf8.count ?? 0) <= 256
    }
}

enum NooLLinkTransferError: LocalizedError {
    case unavailable, disabled, busy, timedOut, rejected, cancelled

    var errorDescription: String? {
        switch self {
        case .unavailable: "Компьютер Windows сейчас недоступен."
        case .disabled: "Включите передачу файлов в настройках NooL Link."
        case .busy: "Дождитесь завершения текущей передачи файлов."
        case .timedOut: "Windows не подтвердил сохранение файлов вовремя."
        case .rejected: "Не удалось сохранить файлы на Windows."
        case .cancelled: "Передача файлов отменена."
        }
    }
}

/// One explicit transfer remains available until the receiver confirms durable
/// saving. Clipboard updates never replace it, and a lost response can be retried.
@MainActor
final class NooLLinkTransferQueue {
    private(set) var pending: NooLLinkEnvelope?
    private var waiter: CheckedContinuation<Void, any Error>?
    private var timeoutTask: Task<Void, Never>?

    func deliver(_ envelope: NooLLinkEnvelope, timeout: Duration = .seconds(180)) async throws {
        guard envelope.kind == "files" else { throw NooLLinkError.invalidPayload }
        _ = try envelope.validated()
        guard pending == nil else { throw NooLLinkTransferError.busy }
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending = envelope
                waiter = continuation
                timeoutTask = Task { [weak self] in
                    do { try await Task.sleep(for: timeout) }
                    catch { return }
                    self?.finish(id: envelope.id, error: NooLLinkTransferError.timedOut)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(id: envelope.id, error: CancellationError())
            }
        }
    }

    @discardableResult
    func acknowledge(_ acknowledgement: NooLLinkTransferAcknowledgement) -> Bool {
        guard acknowledgement.isValid, pending?.id == acknowledgement.id else { return false }
        finish(id: acknowledgement.id, error: acknowledgement.success ? nil : NooLLinkTransferError.rejected)
        return true
    }

    func cancel(_ error: any Error = NooLLinkTransferError.cancelled) {
        guard let id = pending?.id else { return }
        finish(id: id, error: error)
    }

    private func finish(id: String, error: (any Error)?) {
        guard pending?.id == id else { return }
        pending = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        let continuation = waiter
        waiter = nil
        if let error { continuation?.resume(throwing: error) }
        else { continuation?.resume() }
    }
}

struct NooLLinkEnvelope: Codable, Sendable {
    let id: String
    let originDeviceID: String
    let createdAt: String
    let kind: String
    var text: String? = nil
    var imageBase64: String? = nil
    var files: [NooLLinkFile]? = nil

    static let maximumBodyBytes = 46 * 1024 * 1024
    static let maximumFilesBytes = 32 * 1024 * 1024

    func validated(now: Date = Date()) throws -> NooLLinkEnvelope {
        guard UUID(uuidString: id) != nil, UUID(uuidString: originDeviceID) != nil,
              let date = Self.date(createdAt), abs(now.timeIntervalSince(date)) <= 300 else {
            throw NooLLinkError.invalidPayload
        }
        switch kind {
        case "text":
            guard let text, !text.isEmpty, text.utf8.count <= 1024 * 1024,
                  imageBase64 == nil, files == nil else { throw NooLLinkError.invalidPayload }
        case "image":
            guard let imageBase64, imageBase64.count <= 14 * 1024 * 1024,
                  let bytes = Data(base64Encoded: imageBase64), bytes.count <= 10 * 1024 * 1024,
                  bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
                  text == nil, files == nil else { throw NooLLinkError.invalidPayload }
        case "files":
            guard let files, !files.isEmpty, files.count <= 64,
                  text == nil, imageBase64 == nil else { throw NooLLinkError.invalidPayload }
            var total = 0
            var names = Set<String>()
            for file in files {
                guard Self.safeFilename(file.name), names.insert(file.name.lowercased()).inserted,
                      file.dataBase64.count <= 45 * 1024 * 1024,
                      let data = Data(base64Encoded: file.dataBase64) else { throw NooLLinkError.invalidPayload }
                total += data.count
                guard total <= Self.maximumFilesBytes else { throw NooLLinkError.invalidPayload }
            }
        default: throw NooLLinkError.invalidPayload
        }
        return self
    }

    static func safeFilename(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 240, name != ".", name != "..",
              !name.contains(where: { $0 == "/" || $0 == "\\" || $0 == ":" || $0.asciiValue.map { $0 < 32 } == true }),
              !name.hasSuffix("."), !name.hasSuffix(" ") else { return false }
        let stem = name.split(separator: ".", omittingEmptySubsequences: false).first.map(String.init)?.uppercased() ?? ""
        let reserved = ["CON", "PRN", "AUX", "NUL"] + (1...9).flatMap { ["COM\($0)", "LPT\($0)"] }
        return !reserved.contains(stem)
    }

    static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

enum NooLLinkError: LocalizedError {
    case invalidPayload, keychain, identity, unavailable, invalidFiles

    var errorDescription: String? {
        switch self {
        case .invalidPayload: "Неподдерживаемое или устаревшее содержимое буфера."
        case .keychain: "Не удалось получить защищённые данные NooL Link из Связки ключей."
        case .identity: "Не удалось создать защищённое соединение NooL Link."
        case .unavailable: "Не найден адрес локальной сети. Подключите Mac по Wi-Fi или Ethernet."
        case .invalidFiles: "Поддерживаются до 64 обычных файлов общим размером до 32 МБ. Папки и ссылки пока не передаются."
        }
    }
}

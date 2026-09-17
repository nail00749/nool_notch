import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

@MainActor
final class LauncherAppleChatProvider: LauncherAIChatProviding {
    let id: AIChatProviderID = .apple
    private var task: Task<Void, Never>?
    private var generation = 0

    func availability() async -> AIChatProviderStatus {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return AIChatProviderStatus(isAvailable: true, message: "Модель на этом Mac · без отправки в облако",
                                            models: [AIChatModelOption(id: "apple-system", title: "Apple Intelligence", provider: .apple)])
            case .unavailable(.deviceNotEligible):
                return unavailable("Этот Mac не поддерживает системную модель Apple Intelligence.")
            case .unavailable(.appleIntelligenceNotEnabled):
                return unavailable("Включите Apple Intelligence в системных настройках Mac.")
            case .unavailable(.modelNotReady):
                return unavailable("Модель Apple ещё загружается или временно недоступна. Повторите проверку позже.")
            case .unavailable:
                return unavailable("Apple Intelligence сейчас недоступен на этом Mac.")
            }
        }
        #endif
        return unavailable("Для Apple Intelligence в чате требуется macOS 26 или новее.")
    }

    func stream(messages: [AIChatMessage], model: String) -> AsyncThrowingStream<String, Error> {
        cancel()
        let current = generation
        return AsyncThrowingStream { continuation in
            task = Task { [weak self] in
                guard let self else { continuation.finish(); return }
                let status = await self.availability()
                guard status.isAvailable else {
                    continuation.finish(throwing: AIChatError.unavailable(status.message)); return
                }
                do {
                    guard !messages.contains(where: { $0.attachments.contains(where: { $0.kind == .image }) }) else {
                        throw AIChatError.unavailable("Apple Intelligence в этом чате поддерживает только текстовые документы. Выберите модель с поддержкой изображений.")
                    }
                    #if canImport(FoundationModels)
                    if #available(macOS 26.0, *) {
                        // Leave room for instructions and reply in the smaller on-device context.
                        let context = try AIChatContext.bounded(messages, maximumCharacters: 6_000)
                        let session = LanguageModelSession(model: SystemLanguageModel.default, tools: [],
                                                           instructions: AIChatContext.instructions)
                        var previous = ""
                        for try await snapshot in session.streamResponse(to: AIChatContext.transcript(context),
                                                                         options: GenerationOptions(maximumResponseTokens: 1_024)) {
                            try Task.checkCancellation()
                            guard self.generation == current else { throw CancellationError() }
                            guard let delta = Self.delta(previous: previous, snapshot: snapshot.content) else {
                                throw AIChatError.invalidResponse
                            }
                            previous = snapshot.content
                            if !delta.isEmpty { continuation.yield(delta) }
                        }
                    }
                    #endif
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: Self.safeError(error))
                }
            }
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == current else { return }
                    self.task?.cancel()
                }
            }
        }
    }

    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
    }

    nonisolated static func delta(previous: String, snapshot: String) -> String? {
        guard snapshot.hasPrefix(previous) else { return nil }
        return String(snapshot.dropFirst(previous.count))
    }

    private func unavailable(_ reason: String) -> AIChatProviderStatus {
        AIChatProviderStatus(isAvailable: false, message: reason, models: [])
    }

    private static func safeError(_ error: Error) -> AIChatError {
        if let known = error as? AIChatError { return known }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize: return .contextTooLarge
            case .unsupportedLanguageOrLocale:
                return .unavailable("Системная модель Apple пока не поддерживает язык этого сообщения. Выберите другую модель.")
            case .guardrailViolation, .refusal:
                return .unavailable("Системная модель Apple отказалась отвечать на этот запрос. Можно изменить формулировку.")
            default: break
            }
        }
        #endif
        return .unavailable("Не удалось получить ответ Apple Intelligence. Проверьте доступность модели или начните новый чат.")
    }
}

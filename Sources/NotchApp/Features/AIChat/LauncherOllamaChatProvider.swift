import CFNetwork
import Foundation

/// Local-only Ollama chat adapter. Images are sent only to a verified vision model.
@MainActor
final class LauncherOllamaChatProvider: LauncherAIChatProviding {
    let id: AIChatProviderID = .ollama

    private static let endpoint = URL(string: "http://127.0.0.1:11434")!
    private static let maximumContextCharacters = 24_000
    private static let maximumRequestBytes = 7 * 1024 * 1024
    private static let maximumResponseBytes = 2 * 1024 * 1024
    private static let maximumLineBytes = 128 * 1024
    private static let maximumModelNameCharacters = 256
    private static let maximumModelsToInspect = 24
    private static let metadataCacheLifetime: TimeInterval = 30

    private let session: URLSession
    private var activeTask: Task<Void, Never>?
    private var activeGeneration: UInt64?
    private var nextGeneration: UInt64 = 0
    private var metadataCache: [String: CachedOllamaModelMetadata] = [:]

    /// `configuration` exists for URLProtocol-based tests. The destination remains fixed.
    init(configuration: URLSessionConfiguration = LauncherOllamaChatProvider.localConfiguration()) {
        configuration.timeoutIntervalForRequest = min(configuration.timeoutIntervalForRequest, 10)
        configuration.timeoutIntervalForResource = min(configuration.timeoutIntervalForResource, 120)
        // Never inherit a system HTTP(S) proxy for an endpoint that must stay on loopback.
        configuration.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: 0,
            kCFNetworkProxiesHTTPSEnable as String: 0
        ]
        session = URLSession(
            configuration: configuration,
            delegate: AIChatOllamaRedirectGuard(),
            delegateQueue: nil
        )
    }

    deinit {
        activeTask?.cancel()
        session.invalidateAndCancel()
    }

    func availability() async -> AIChatProviderStatus {
        do {
            let models = try await availableModels()
            guard models.isEmpty == false else {
                return unavailable("В локальном Ollama нет подходящих моделей.")
            }
            return AIChatProviderStatus(
                isAvailable: true,
                message: "Локальный Ollama доступен.",
                models: models
            )
        } catch let error as AIChatError {
            return unavailable(error.localizedDescription)
        } catch {
            return unavailable("Не удалось подключиться к локальному Ollama.")
        }
    }

    func stream(messages: [AIChatMessage], model: String) -> AsyncThrowingStream<String, Error> {
        cancel()
        nextGeneration &+= 1
        let generation = nextGeneration
        activeGeneration = generation

        return AsyncThrowingStream { continuation in
            let task = Task { @MainActor [weak self] in
                guard let self else {
                    continuation.finish(throwing: AIChatError.interrupted)
                    return
                }
                do {
                    try await self.run(
                        messages: messages,
                        model: model,
                        generation: generation,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: AIChatError.interrupted)
                } catch let error as URLError where error.code == .cancelled {
                    continuation.finish(throwing: AIChatError.interrupted)
                } catch let error as URLError where error.code == .timedOut {
                    continuation.finish(throwing: AIChatError.timeout)
                } catch {
                    continuation.finish(throwing: error)
                }
                self.clearActiveTask(generation: generation)
            }
            activeTask = task
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.cancel(generation: generation) }
            }
        }
    }

    func cancel() {
        cancel(generation: activeGeneration)
    }

    private func cancel(generation: UInt64?) {
        guard let generation, generation == activeGeneration else { return }
        activeTask?.cancel()
        activeTask = nil
        activeGeneration = nil
    }

    private func clearActiveTask(generation: UInt64) {
        guard activeGeneration == generation else { return }
        activeTask = nil
        activeGeneration = nil
    }

    private func run(
        messages: [AIChatMessage],
        model: String,
        generation: UInt64,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        guard model.count <= Self.maximumModelNameCharacters, Self.isSafeModelName(model) else {
            throw AIChatError.unavailable("Выберите модель из списка локального Ollama.")
        }
        let bounded = try AIChatContext.bounded(messages, maximumCharacters: Self.maximumContextCharacters)
        try Task.checkCancellation()
        guard activeGeneration == generation else { throw AIChatError.interrupted }

        let models = try await localModels()
        guard let candidate = models.first(where: { $0.name == model }) else {
            throw AIChatError.unavailable("Выберите модель из списка локального Ollama.")
        }
        let metadata = try await confirmLocalModel(candidate)
        let imageAttachments = bounded.flatMap(\.attachments).filter { $0.kind == .image }
        guard imageAttachments.allSatisfy({ ($0.imageData?.isEmpty == false) }) else {
            throw AIChatError.contextTooLarge
        }
        guard imageAttachments.isEmpty || metadata.supportsImages else {
            throw AIChatError.unavailable("Выбранная модель Ollama не поддерживает изображения.")
        }
        try Task.checkCancellation()
        guard activeGeneration == generation else { throw AIChatError.interrupted }

        let payload = ChatRequest(
            model: model,
            messages: [ChatMessage(role: "system", content: AIChatContext.instructions)]
                + bounded.map { Self.chatMessage(for: $0) },
            stream: true
        )
        let body = try JSONEncoder().encode(payload)
        guard body.count <= Self.maximumRequestBytes else { throw AIChatError.contextTooLarge }

        var request = try Self.makeRequest(path: "/api/chat", method: "POST", body: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (bytes, response) = try await session.bytes(for: request)
        try Self.validate(response: response)

        var receivedBytes = 0
        var line = Data()
        var completed = false
        for try await byte in bytes {
            try Task.checkCancellation()
            guard activeGeneration == generation else { throw AIChatError.interrupted }
            receivedBytes += 1
            guard receivedBytes <= Self.maximumResponseBytes else { throw AIChatError.invalidResponse }
            if byte != 0x0A {
                guard line.count < Self.maximumLineBytes else { throw AIChatError.invalidResponse }
                line.append(byte)
                continue
            }
            if line.last == 0x0D { line.removeLast() }
            guard line.isEmpty == false else { continue }
            let event = try Self.decodeEvent(line)
            line.removeAll(keepingCapacity: true)
            if let content = event.message?.content, content.isEmpty == false {
                continuation.yield(content)
            }
            if event.done {
                completed = true
                break
            }
        }
        if completed == false, line.isEmpty == false {
            if line.last == 0x0D { line.removeLast() }
            let event = try Self.decodeEvent(line)
            if let content = event.message?.content, content.isEmpty == false {
                continuation.yield(content)
            }
            completed = event.done
        }
        guard completed else { throw AIChatError.invalidResponse }
    }

    private func localModels() async throws -> [OllamaModel] {
        let request = try Self.makeRequest(path: "/api/tags")
        let data = try await readBoundedBody(request, limit: Self.maximumResponseBytes)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawModels = object["models"] as? [[String: Any]] else {
            throw AIChatError.invalidResponse
        }

        var seen = Set<String>()
        return rawModels.compactMap { raw in
            guard let name = raw["name"] as? String,
                  Self.isSafeModelName(name),
                  name.count <= Self.maximumModelNameCharacters,
                  let size = raw["size"] as? NSNumber,
                  size.int64Value > 0,
                  let digest = raw["digest"] as? String,
                  digest.isEmpty == false,
                  ((raw["model"] as? String).map(Self.isSafeModelName) ?? true),
                  Self.containsRemoteMarker(raw) == false,
                  seen.insert(name).inserted else {
                return nil
            }
            return OllamaModel(name: name, size: size.int64Value, digest: digest)
        }
    }

    private func availableModels() async throws -> [AIChatModelOption] {
        let candidates = Array(try await localModels().prefix(Self.maximumModelsToInspect))
        var options: [AIChatModelOption] = []
        for chunkStart in stride(from: 0, to: candidates.count, by: 4) {
            let chunk = candidates[chunkStart..<min(chunkStart + 4, candidates.count)]
            let results = await withTaskGroup(of: (String, AvailabilityMetadata).self, returning: [(String, AvailabilityMetadata)].self) { group in
                for candidate in chunk {
                    group.addTask { [weak self] in
                        guard let self else { return (candidate.name, .unknown) }
                        return (candidate.name, await self.availabilityMetadata(for: candidate))
                    }
                }
                var values: [(String, AvailabilityMetadata)] = []
                for await value in group { values.append(value) }
                return values
            }
            let metadata = Dictionary(uniqueKeysWithValues: results)
            for candidate in chunk {
                switch metadata[candidate.name] ?? .unknown {
                case .local(let supportsImages):
                    options.append(AIChatModelOption(
                        id: candidate.name,
                        title: candidate.name,
                        provider: .ollama,
                        supportsImages: supportsImages
                    ))
                case .unknown:
                    // Older daemons can lack /api/show capabilities. Keep the local tag,
                    // but never advertise image support until a generation-time confirmation.
                    options.append(AIChatModelOption(id: candidate.name, title: candidate.name, provider: .ollama))
                case .remote:
                    break
                }
            }
        }
        return options
    }

    private func availabilityMetadata(for model: OllamaModel) async -> AvailabilityMetadata {
        if let cached = metadataCache[model.name], Date().timeIntervalSince(cached.date) < Self.metadataCacheLifetime {
            return .local(supportsImages: cached.metadata.supportsImages)
        }
        do {
            guard let metadata = try await fetchModelMetadata(model) else { return .remote }
            metadataCache[model.name] = CachedOllamaModelMetadata(metadata: metadata, date: Date())
            return .local(supportsImages: metadata.supportsImages)
        } catch {
            return .unknown
        }
    }

    private func confirmLocalModel(_ model: OllamaModel) async throws -> OllamaModelMetadata {
        guard let metadata = try await fetchModelMetadata(model) else {
            throw AIChatError.unavailable("Выбранная модель не подтверждена как локальная.")
        }
        return metadata
    }

    private func fetchModelMetadata(_ model: OllamaModel) async throws -> OllamaModelMetadata? {
        let body = try JSONSerialization.data(withJSONObject: ["name": model.name])
        guard body.count <= Self.maximumRequestBytes else { throw AIChatError.invalidResponse }
        var request = try Self.makeRequest(path: "/api/show", method: "POST", body: body)
        request.timeoutInterval = 3
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let data = try await readBoundedBody(request, limit: Self.maximumResponseBytes)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIChatError.invalidResponse
        }
        guard Self.containsRemoteMarker(object) == false else { return nil }
        let capabilities = (object["capabilities"] as? [String]) ?? []
        return OllamaModelMetadata(supportsImages: capabilities.contains { $0.caseInsensitiveCompare("vision") == .orderedSame })
    }

    private func readBoundedBody(_ request: URLRequest, limit: Int) async throws -> Data {
        let (bytes, response) = try await session.bytes(for: request)
        try Self.validate(response: response)
        var body = Data()
        body.reserveCapacity(min(limit, 8 * 1024))
        for try await byte in bytes {
            guard body.count < limit else { throw AIChatError.invalidResponse }
            body.append(byte)
        }
        return body
    }

    private func unavailable(_ message: String) -> AIChatProviderStatus {
        AIChatProviderStatus(isAvailable: false, message: message, models: [])
    }

    private static func localConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        return configuration
    }

    private static func makeRequest(path: String, method: String = "GET", body: Data? = nil) throws -> URLRequest {
        guard path.hasPrefix("/"), let url = URL(string: endpoint.absoluteString + path), isLoopback(url) else {
            throw AIChatError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private static func validate(response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse,
              isLoopback(response.url),
              (200...299).contains(response.statusCode) else {
            throw AIChatError.invalidResponse
        }
    }

    private static func isLoopback(_ url: URL?) -> Bool {
        url?.scheme?.lowercased() == "http"
            && url?.host == "127.0.0.1"
            && url?.port == 11434
    }

    private static func isSafeModelName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == name, name.isEmpty == false,
              name.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }) else {
            return false
        }
        return name.lowercased().contains("-cloud") == false
    }

    private static func containsRemoteMarker(_ value: Any) -> Bool {
        if let dictionary = value as? [String: Any] {
            for (key, nested) in dictionary {
                let normalized = key.lowercased().replacingOccurrences(of: "-", with: "_")
                if ["remote_host", "remote_model", "remote", "cloud"].contains(normalized) {
                    if let text = nested as? String {
                        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { return true }
                    } else if let value = nested as? NSNumber {
                        if value.boolValue { return true }
                    } else if (nested is NSNull) == false {
                        return true
                    }
                }
                if containsRemoteMarker(nested) { return true }
            }
        } else if let values = value as? [Any] {
            return values.contains(where: containsRemoteMarker)
        }
        return false
    }

    private static func decodeEvent(_ data: Data) throws -> OllamaChatEvent {
        let decoder = JSONDecoder()
        let event = try decoder.decode(OllamaChatEvent.self, from: data)
        if event.message?.toolCalls?.isEmpty == false || event.message?.images?.isEmpty == false {
            throw AIChatError.invalidResponse
        }
        return event
    }

    private static func chatMessage(for message: AIChatMessage) -> ChatMessage {
        let images = message.attachments.compactMap { attachment -> String? in
            guard attachment.kind == .image, let imageData = attachment.imageData else { return nil }
            return imageData.base64EncodedString()
        }
        return ChatMessage(role: message.role.rawValue, content: message.modelText, images: images)
    }
}

private final class AIChatOllamaRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private struct OllamaModel: Sendable {
    let name: String
    let size: Int64
    let digest: String
}

private struct OllamaModelMetadata: Sendable {
    let supportsImages: Bool
}

private struct CachedOllamaModelMetadata {
    let metadata: OllamaModelMetadata
    let date: Date
}

private enum AvailabilityMetadata: Sendable {
    case local(supportsImages: Bool)
    case remote
    case unknown
}

private struct ChatRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let stream: Bool
}

private struct ChatMessage: Encodable {
    let role: String
    let content: String
    let images: [String]?

    init(role: String, content: String, images: [String] = []) {
        self.role = role
        self.content = content
        self.images = images.isEmpty ? nil : images
    }
}

private struct OllamaChatEvent: Decodable {
    struct Message: Decodable {
        let content: String?
        let toolCalls: [JSONValue]?
        let images: [String]?

        enum CodingKeys: String, CodingKey {
            case content
            case toolCalls = "tool_calls"
            case images
        }
    }

    let message: Message?
    let done: Bool
}

private enum JSONValue: Decodable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else { self = .array(try container.decode([JSONValue].self)) }
    }
}

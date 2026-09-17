import Foundation
import XCTest
@testable import NotchApp

@MainActor
final class AIChatOllamaProviderTests: XCTestCase {
    override func tearDown() {
        OllamaURLProtocol.handler = nil
        super.tearDown()
    }

    func testAvailabilityFiltersCloudAndRemoteAliases() async {
        install { request in
            switch request.url?.path {
            case "/api/tags":
                return .json("""
                {"models":[
                  {"name":"llama3.2:3b","size":123,"digest":"abc"},
                  {"name":"qwen-cloud","size":456,"digest":"cloud"},
                  {"name":"remote:latest","size":456,"digest":"remote","remote_host":"api.ollama.com"}
                ]}
                """)
            case "/api/show":
                return .json(#"{"capabilities":["completion"]}"#)
            default:
                return .status(404)
            }
        }
        let provider = LauncherOllamaChatProvider(configuration: testConfiguration())

        let status = await provider.availability()

        XCTAssertTrue(status.isAvailable)
        XCTAssertEqual(status.models.map(\.id), ["llama3.2:3b"])
    }

    func testStreamingSendsTextOnlyChatToFixedLoopbackAPI() async throws {
        let recorder = OllamaRequestRecorder()
        install { request in
            recorder.append(request)
            switch request.url?.path {
            case "/api/tags":
                return .json("{\"models\":[{\"name\":\"llama3.2:3b\",\"size\":123,\"digest\":\"abc\"}]}")
            case "/api/show":
                return .json("{\"details\":{\"family\":\"llama\"}}")
            case "/api/chat":
                return .chunks([
                    "{\"message\":{\"role\":\"assistant\",\"content\":\"Привет\"},\"done\":false}\n",
                    "{\"message\":{\"role\":\"assistant\",\"content\":\"!\"},\"done\":true}\n"
                ])
            default:
                return .status(404)
            }
        }
        let provider = LauncherOllamaChatProvider(configuration: testConfiguration())

        let chunks = try await collect(provider.stream(
            messages: [AIChatMessage(role: .user, text: "Как дела?")],
            model: "llama3.2:3b"
        ))

        XCTAssertEqual(chunks, ["Привет", "!"])
        let requests = recorder.requests
        XCTAssertEqual(requests.map { $0.url?.host }, ["127.0.0.1", "127.0.0.1", "127.0.0.1"])
        XCTAssertEqual(requests.map { $0.url?.port }, [11434, 11434, 11434])
        XCTAssertEqual(requests.map { $0.url?.path }, ["/api/tags", "/api/show", "/api/chat"])
        let body = try XCTUnwrap(requests.last?.body)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNil(object["tools"])
        XCTAssertEqual(object["model"] as? String, "llama3.2:3b")
        let messages = try XCTUnwrap(object["messages"] as? [[String: String]])
        XCTAssertEqual(messages.first?["role"], "system")
        XCTAssertEqual(messages.first?["content"], AIChatContext.instructions)
        XCTAssertEqual(messages.last?["content"], "Как дела?")
    }

    func testAvailabilityUsesShowVisionCapabilityForImageSupport() async {
        install { request in
            switch request.url?.path {
            case "/api/tags":
                return .json("{\"models\":[{\"name\":\"vision:latest\",\"size\":123,\"digest\":\"a\"},{\"name\":\"text:latest\",\"size\":456,\"digest\":\"b\"}]}")
            case "/api/show":
                let name = OllamaRequestRecorder.modelName(from: request)
                return name == "vision:latest"
                    ? .json("{\"capabilities\":[\"completion\",\"vision\"]}")
                    : .json("{\"capabilities\":[\"completion\"]}")
            default:
                return .status(404)
            }
        }
        let provider = LauncherOllamaChatProvider(configuration: testConfiguration())

        let status = await provider.availability()

        XCTAssertTrue(status.isAvailable)
        XCTAssertEqual(status.models.map(\.id), ["vision:latest", "text:latest"])
        XCTAssertEqual(status.models.map(\.supportsImages), [true, false])
    }

    func testVisionModelSendsAttachmentBytesOnlyInOllamaImagesField() async throws {
        let recorder = OllamaRequestRecorder()
        install { request in
            recorder.append(request)
            switch request.url?.path {
            case "/api/tags":
                return .json("{\"models\":[{\"name\":\"vision:latest\",\"size\":123,\"digest\":\"abc\"}]}")
            case "/api/show":
                return .json("{\"capabilities\":[\"vision\"]}")
            case "/api/chat":
                return .chunks(["{\"message\":{\"content\":\"Вижу\"},\"done\":true}\n"])
            default:
                return .status(404)
            }
        }
        let image = AIChatAttachment(
            name: "diagram.png", kind: .image, imageData: Data([0, 1, 2]), mimeType: "image/png"
        )
        let provider = LauncherOllamaChatProvider(configuration: testConfiguration())

        let chunks = try await collect(provider.stream(
            messages: [AIChatMessage(role: .user, text: "Что на картинке?", attachments: [image])],
            model: "vision:latest"
        ))

        XCTAssertEqual(chunks, ["Вижу"])
        let body = try XCTUnwrap(recorder.requests.last?.body)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.last?["images"] as? [String], ["AAEC"])
        XCTAssertTrue((messages.last?["content"] as? String)?.contains("Attached image: diagram.png") == true)
    }

    func testImageAttachmentRejectsTextOnlyModelBeforeChatRequest() async {
        let recorder = OllamaRequestRecorder()
        install { request in
            recorder.append(request)
            switch request.url?.path {
            case "/api/tags":
                return .json("{\"models\":[{\"name\":\"text:latest\",\"size\":123,\"digest\":\"abc\"}]}")
            case "/api/show":
                return .json("{\"capabilities\":[\"completion\"]}")
            default:
                return .status(500)
            }
        }
        let image = AIChatAttachment(name: "private.png", kind: .image, imageData: Data([1]), mimeType: "image/png")
        let provider = LauncherOllamaChatProvider(configuration: testConfiguration())

        do {
            _ = try await collect(provider.stream(
                messages: [AIChatMessage(role: .user, text: "look", attachments: [image])], model: "text:latest"
            ))
            XCTFail("Expected vision capability rejection")
        } catch let error as AIChatError {
            guard case .unavailable = error else { return XCTFail("Unexpected error: \(error)") }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(recorder.requests.map { $0.url?.path }, ["/api/tags", "/api/show"])
    }

    func testShowRemoteMarkerRejectsModelBeforePromptIsSent() async {
        let recorder = OllamaRequestRecorder()
        install { request in
            recorder.append(request)
            switch request.url?.path {
            case "/api/tags":
                return .json("{\"models\":[{\"name\":\"model:latest\",\"size\":123,\"digest\":\"abc\"}]}")
            case "/api/show":
                return .json("{\"details\":{\"remote_model\":\"cloud-model\"}}")
            default:
                return .status(500)
            }
        }
        let provider = LauncherOllamaChatProvider(configuration: testConfiguration())

        do {
            _ = try await collect(provider.stream(
                messages: [AIChatMessage(role: .user, text: "private prompt")],
                model: "model:latest"
            ))
            XCTFail("Expected local-model rejection")
        } catch let error as AIChatError {
            guard case .unavailable = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(recorder.requests.map { $0.url?.path }, ["/api/tags", "/api/show"])
    }

    func testToolCallsAndIncompleteNDJSONAreRejected() async {
        let recorder = OllamaRequestRecorder()
        install { request in
            recorder.append(request)
            switch request.url?.path {
            case "/api/tags":
                return .json("{\"models\":[{\"name\":\"model:latest\",\"size\":123,\"digest\":\"abc\"}]}")
            case "/api/show":
                return .json("{\"details\":{\"family\":\"llama\"}}")
            case "/api/chat":
                return .chunks(["{\"message\":{\"content\":\"x\",\"tool_calls\":[{}]},\"done\":false}\n"])
            default:
                return .status(404)
            }
        }
        let provider = LauncherOllamaChatProvider(configuration: testConfiguration())

        do {
            _ = try await collect(provider.stream(
                messages: [AIChatMessage(role: .user, text: "test")], model: "model:latest"
            ))
            XCTFail("Expected invalid response")
        } catch let error as AIChatError {
            XCTAssertEqual(error, .invalidResponse)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRedirectResponseIsNotAccepted() async {
        install { _ in
            .redirect("http://example.com/api/tags")
        }
        let provider = LauncherOllamaChatProvider(configuration: testConfiguration())

        let status = await provider.availability()

        XCTAssertFalse(status.isAvailable)
    }

    private func install(_ handler: @escaping @Sendable (URLRequest) -> OllamaStubResponse) {
        OllamaURLProtocol.handler = handler
    }

    private func testConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OllamaURLProtocol.self]
        return configuration
    }

    private func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> [String] {
        var chunks: [String] = []
        for try await chunk in stream { chunks.append(chunk) }
        return chunks
    }
}

private final class OllamaURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> OllamaStubResponse)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let stub = handler(request)
        let response = HTTPURLResponse(url: url, statusCode: stub.statusCode, httpVersion: "HTTP/1.1", headerFields: stub.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in stub.chunks { client?.urlProtocol(self, didLoad: chunk) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private struct OllamaStubResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let chunks: [Data]

    static func json(_ value: String) -> Self {
        chunks([value])
    }

    static func chunks(_ values: [String]) -> Self {
        Self(statusCode: 200, headers: ["Content-Type": "application/json"], chunks: values.map { Data($0.utf8) })
    }

    static func status(_ statusCode: Int) -> Self {
        Self(statusCode: statusCode, headers: [:], chunks: [])
    }

    static func redirect(_ location: String) -> Self {
        Self(statusCode: 302, headers: ["Location": location], chunks: [])
    }
}

private struct OllamaRecordedRequest: Sendable {
    let url: URL?
    let body: Data?
}

private final class OllamaRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequests: [OllamaRecordedRequest] = []

    func append(_ request: URLRequest) {
        let recorded = OllamaRecordedRequest(url: request.url, body: Self.body(from: request))
        lock.lock()
        storedRequests.append(recorded)
        lock.unlock()
    }

    var requests: [OllamaRecordedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storedRequests
    }

    static func body(from request: URLRequest) -> Data? {
        request.httpBody ?? readBody(request.httpBodyStream)
    }

    static func modelName(from request: URLRequest) -> String? {
        guard let body = body(from: request),
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: String] else {
            return nil
        }
        return object["name"]
    }

    private static func readBody(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4 * 1024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            body.append(buffer, count: count)
        }
        return stream.streamError == nil ? body : nil
    }
}

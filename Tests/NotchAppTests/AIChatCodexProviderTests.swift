import Foundation
import XCTest
@testable import NotchApp

@MainActor
final class AIChatCodexProviderTests: XCTestCase {
    func testAvailabilityRequiresChatGPTAndUsesEveryModelPage() async {
        let transport = StubCodexTransport(accountType: "chatgpt", pages: [
            ([model("gpt-first", "First")], "next"),
            ([model("gpt-second", "Second")], nil)
        ])
        let provider = LauncherCodexChatProvider(
            executable: URL(fileURLWithPath: "/stub/codex"),
            transportFactory: { _, _ in transport }
        )

        let status = await provider.availability()

        XCTAssertTrue(status.isAvailable)
        XCTAssertEqual(status.models.map(\.id), ["gpt-first", "gpt-second"])
        XCTAssertEqual(transport.methods, ["initialize", "config/read", "config/read", "account/read", "model/list", "model/list"])
    }

    func testAvailabilityUsesExplicitImageModalitiesOnly() async {
        let transport = StubCodexTransport(accountType: "chatgpt", pages: [
            ([
                model("vision", "Vision", modalities: ["text", "image"]),
                model("unknown", "Unknown")
            ], nil)
        ])
        let provider = LauncherCodexChatProvider(
            executable: URL(fileURLWithPath: "/stub/codex"),
            transportFactory: { _, _ in transport }
        )

        let status = await provider.availability()

        XCTAssertEqual(status.models.map(\.supportsImages), [true, false])
    }

    func testAvailabilityRejectsNonChatGPTAuthentication() async {
        let transport = StubCodexTransport(accountType: "apiKey", pages: [])
        let provider = LauncherCodexChatProvider(
            executable: URL(fileURLWithPath: "/stub/codex"),
            transportFactory: { _, _ in transport }
        )

        let status = await provider.availability()

        XCTAssertFalse(status.isAvailable)
        XCTAssertTrue(status.models.isEmpty)
        XCTAssertEqual(transport.methods, ["initialize", "config/read", "config/read", "account/read"])
    }

    func testProcessArgumentsDisableAllSupportedToolSurfaces() {
        let arguments = AIChatCodexProcess.launchArguments
        for feature in ["browser_use", "hooks", "plugins", "shell_tool", "skill_search", "tool_call_mcp_elicitation"] {
            XCTAssertTrue(arguments.contains(feature))
        }
        XCTAssertTrue(arguments.contains("notify=[]"))
        XCTAssertTrue(arguments.contains("web_search=\"disabled\""))
        XCTAssertTrue(arguments.contains("skills.include_instructions=false"))
    }

    func testInheritedMCPIsDisabledInNewProcessBeforeAnyThread() async {
        let discovery = StubCodexTransport(accountType: "chatgpt", pages: [])
        discovery.servers = ["local_agent": ["enabled": true]]
        let isolated = StubCodexTransport(accountType: "chatgpt", pages: [([model("test", "Test")], nil)])
        isolated.servers = ["local_agent": ["enabled": false]]
        var overrides: [[String]] = []
        let provider = LauncherCodexChatProvider(executable: URL(fileURLWithPath: "/stub/codex")) { _, options in
            overrides.append(options)
            return options.isEmpty ? discovery : isolated
        }
        let status = await provider.availability()
        XCTAssertTrue(status.isAvailable)
        XCTAssertEqual(overrides, [[], ["mcp_servers.local_agent.enabled=false"]])
        XCTAssertFalse(discovery.methods.contains("thread/start"))
        XCTAssertFalse(isolated.methods.contains("thread/start"))
        XCTAssertTrue(discovery.stopped)
    }

    func testUnsafeEffectiveConfigFailsBeforeAccountOrGeneration() async {
        let transport = StubCodexTransport(accountType: "chatgpt", pages: [])
        transport.unsafeFeature = true
        let provider = LauncherCodexChatProvider(executable: URL(fileURLWithPath: "/stub/codex")) { _, _ in transport }
        let status = await provider.availability()
        XCTAssertFalse(status.isAvailable)
        XCTAssertFalse(transport.methods.contains("account/read"))
        XCTAssertFalse(transport.methods.contains("thread/start"))
    }

    func testCompletedTurnStreamsDeltasAndHasNoEnvironment() async throws {
        let transport = StubCodexTransport(accountType: "chatgpt", pages: [])
        let provider = LauncherCodexChatProvider(executable: URL(fileURLWithPath: "/stub/codex")) { _, _ in transport }
        var reply = ""
        for try await delta in provider.stream(messages: [AIChatMessage(role: .user, text: "Hello")], model: "test") {
            reply += delta
        }
        XCTAssertEqual(reply, "Hello")
        for method in ["thread/start", "turn/start"] {
            XCTAssertEqual((transport.parameters[method]?["environments"] as? [String])?.count, 0)
            XCTAssertEqual((transport.parameters[method]?["runtimeWorkspaceRoots"] as? [String])?.count, 0)
        }
        XCTAssertEqual(transport.parameters["thread/start"]?["ephemeral"] as? Bool, true)
    }

    func testImageTurnUsesOnlyDataURLInputAndPreservesAssociation() async throws {
        let discovery = StubCodexTransport(accountType: "chatgpt", pages: [
            ([model("vision", "Vision", modalities: ["text", "image"])], nil)
        ])
        let transport = StubCodexTransport(accountType: "chatgpt", pages: [])
        var connections = 0
        let provider = LauncherCodexChatProvider(executable: URL(fileURLWithPath: "/stub/codex")) { _, _ in
            connections += 1
            return connections == 1 ? discovery : transport
        }
        _ = await provider.availability()
        let image = AIChatAttachment(
            name: "diagram.png",
            kind: .image,
            imageData: Data([0x01, 0x02, 0x03]),
            mimeType: "image/png"
        )

        _ = try await collect(provider.stream(messages: [
            AIChatMessage(role: .user, text: "Объясни схему", attachments: [image])
        ], model: "vision"))

        let input = try XCTUnwrap(transport.parameters["turn/start"]?["input"] as? [[String: Any]])
        XCTAssertEqual(input[0]["type"] as? String, "text")
        XCTAssertTrue((input[1]["text"] as? String)?.contains("Attached image: diagram.png") == true)
        XCTAssertEqual(input[2]["type"] as? String, "image")
        XCTAssertEqual(input[2]["url"] as? String, "data:image/png;base64,AQID")
        XCTAssertNil(input[2]["path"])
    }

    func testImageTurnRejectsUnknownModelBeforeStartingThread() async {
        let transport = StubCodexTransport(accountType: "chatgpt", pages: [])
        let provider = LauncherCodexChatProvider(executable: URL(fileURLWithPath: "/stub/codex")) { _, _ in transport }
        let image = AIChatAttachment(name: "diagram.png", kind: .image, imageData: Data([0x01]), mimeType: "image/png")

        do {
            _ = try await collect(provider.stream(messages: [
                AIChatMessage(role: .user, text: "Explain", attachments: [image])
            ], model: "unknown"))
            XCTFail("Expected unsupported model")
        } catch let error as AIChatError {
            XCTAssertEqual(error, .unavailable("Выбранная модель Codex не поддерживает изображения."))
        } catch {
            XCTFail("Unexpected error \(error)")
        }
        XCTAssertFalse(transport.methods.contains("thread/start"))
    }

    func testFailedTurnPreservesPartialTextAndReportsFailure() async {
        let transport = StubCodexTransport(accountType: "chatgpt", pages: [])
        transport.completionStatus = "failed"
        let provider = LauncherCodexChatProvider(executable: URL(fileURLWithPath: "/stub/codex")) { _, _ in transport }
        var reply = ""
        do {
            for try await delta in provider.stream(messages: [AIChatMessage(role: .user, text: "Hello")], model: "test") { reply += delta }
            XCTFail("Failed turn must throw")
        } catch { XCTAssertEqual(error as? AIChatError, .interrupted) }
        XCTAssertEqual(reply, "Hello")
    }

    private func model(_ id: String, _ title: String, modalities: [String]? = nil) -> [String: Any] {
        var model: [String: Any] = ["id": id, "displayName": title]
        if let modalities { model["inputModalities"] = modalities }
        return model
    }

    private func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> [String] {
        var chunks: [String] = []
        for try await chunk in stream { chunks.append(chunk) }
        return chunks
    }
}

@MainActor
private final class StubCodexTransport: AIChatCodexTransport {
    private let accountType: String
    private let pages: [([[String: Any]], String?)]
    private var pageIndex = 0
    private let stream: AsyncStream<AIChatCodexEvent>
    private var continuation: AsyncStream<AIChatCodexEvent>.Continuation!
    var methods: [String] = []
    var parameters: [String: [String: Any]] = [:]
    var servers: [String: Any] = [:]
    var unsafeFeature = false
    var stopped = false
    var completionStatus = "completed"

    init(accountType: String, pages: [([[String: Any]], String?)]) {
        self.accountType = accountType
        self.pages = pages
        let pair = AsyncStream<AIChatCodexEvent>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    var events: AsyncStream<AIChatCodexEvent> { stream }
    func start() throws {}
    func notify(_ method: String, params: [String: Any]) {}
    func interrupt(threadID: String, turnID: String) {}
    func stop() { stopped = true; continuation.finish() }

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        methods.append(method)
        parameters[method] = params
        switch method {
        case "initialize": return [:]
        case "config/read":
            var features = Dictionary(uniqueKeysWithValues: AIChatCodexProcess.disabledFeatures.map { ($0, false) })
            if unsafeFeature { features["shell_tool"] = true }
            return ["config": ["mcp_servers": servers, "features": features, "notify": [], "web_search": "disabled"]]
        case "account/read": return ["account": ["type": accountType]]
        case "model/list":
            let page = pages[pageIndex]
            pageIndex += 1
            return ["data": page.0, "nextCursor": page.1 as Any]
        case "thread/start": return ["thread": ["id": "thread"]]
        case "turn/start":
            continuation.yield(AIChatCodexEvent(method: "item/agentMessage/delta", threadID: "thread", turnID: "turn", delta: "Hello", isToolRelated: false, completionStatus: nil))
            continuation.yield(AIChatCodexEvent(method: "turn/completed", threadID: "thread", turnID: "turn", delta: nil, isToolRelated: false, completionStatus: completionStatus))
            continuation.finish()
            return ["turn": ["id": "turn"]]
        default: throw AIChatError.invalidResponse
        }
    }
}

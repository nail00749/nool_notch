import Foundation
import XCTest
@testable import NotchApp

@MainActor
final class AIChatClaudeProviderTests: XCTestCase {
    func testAvailabilityRequiresOAuthSubscription() async throws {
        let fixture = try makeFixture(script: """
        #!/bin/sh
        printf '%s\\n' '{"loggedIn":false,"authMethod":"none"}'
        """)
        defer { fixture.cleanup() }
        let provider = LauncherClaudeChatProvider(executableURL: fixture.executableURL)

        let status = await provider.availability()

        XCTAssertFalse(status.isAvailable)
        XCTAssertTrue(status.models.isEmpty)
    }

    func testAvailabilityUsesOnlyStableAliasesAdvertisedByStatus() async throws {
        let fixture = try makeFixture(script: """
        #!/bin/sh
        printf '%s\\n' '{"loggedIn":true,"authMethod":"oauth","apiProvider":"firstParty","availableModels":["haiku","opus","claude-sonnet-4-20250514"]}'
        """)
        defer { fixture.cleanup() }
        let provider = LauncherClaudeChatProvider(executableURL: fixture.executableURL)

        let status = await provider.availability()

        XCTAssertTrue(status.isAvailable)
        XCTAssertEqual(status.models.map(\.id), ["haiku", "opus"])
    }

    func testAvailabilityRejectsNonFirstPartyOAuth() async throws {
        let fixture = try makeFixture(script: """
        #!/bin/sh
        printf '%s\\n' '{"loggedIn":true,"authMethod":"oauth","apiProvider":"thirdParty"}'
        """)
        defer { fixture.cleanup() }
        let provider = LauncherClaudeChatProvider(executableURL: fixture.executableURL)

        let status = await provider.availability()

        XCTAssertFalse(status.isAvailable)
    }

    func testStreamUsesSandboxArgumentsAndStdinPrompt() async throws {
        let fixture = try makeFixture(script: """
        #!/bin/sh
        if [ "$1" = "auth" ]; then
          printf '%s\\n' '{"loggedIn":true,"authMethod":"oauth","apiProvider":"firstParty"}'
          exit 0
        fi
        printf '%s\\n' "$@" > \(shellQuote(fixturePathPlaceholder("arguments.txt")))
        cat > \(shellQuote(fixturePathPlaceholder("input.txt")))
        pwd > \(shellQuote(fixturePathPlaceholder("cwd.txt")))
        printf '%s\\n' '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Привет"}}}'
        """)
        defer { fixture.cleanup() }
        try fixture.replacePlaceholders()
        let provider = LauncherClaudeChatProvider(executableURL: fixture.executableURL)

        let chunks = try await collect(
            provider.stream(messages: [AIChatMessage(role: .user, text: "личный вопрос")], model: "sonnet")
        )

        XCTAssertEqual(chunks, ["Привет"])
        let arguments = try String(contentsOf: fixture.url("arguments.txt"), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .dropLast()
            .map(String.init)
        XCTAssertEqual(arguments, [
            "--safe-mode", "--tools", "", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}",
            "--no-chrome", "--disable-slash-commands", "--no-session-persistence", "--print", "--verbose",
            "--output-format", "stream-json", "--input-format", "stream-json", "--include-partial-messages", "--model", "sonnet"
        ])
        let input = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.url("input.txt"))) as? [String: Any]
        XCTAssertEqual(input?["type"] as? String, "user")
        let message = input?["message"] as? [String: Any]
        let content = message?["content"] as? [[String: Any]]
        XCTAssertTrue(content?.contains(where: { ($0["text"] as? String)?.contains("личный вопрос") == true }) == true)
        XCTAssertFalse(arguments.joined(separator: " ").contains("личный вопрос"))
        let cwd = try String(contentsOf: fixture.url("cwd.txt"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(URL(fileURLWithPath: cwd).lastPathComponent.hasPrefix("nool-claude-"))
    }

    func testImageTurnUsesStreamJSONBase64ContentAndKeepsTextBeforeImage() async throws {
        let fixture = try makeFixture(script: """
        #!/bin/sh
        if [ "$1" = "auth" ]; then
          printf '%s\\n' '{"loggedIn":true,"authMethod":"oauth","apiProvider":"firstParty"}'
          exit 0
        fi
        cat > \(shellQuote(fixturePathPlaceholder("input.json")))
        printf '%s\\n' '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Готово"}}}'
        """)
        defer { fixture.cleanup() }
        try fixture.replacePlaceholders()
        let provider = LauncherClaudeChatProvider(executableURL: fixture.executableURL)
        let image = AIChatAttachment(
            name: "graph.png",
            kind: .image,
            imageData: Data([0x01, 0x02, 0x03]),
            mimeType: "image/png"
        )

        _ = try await collect(provider.stream(messages: [
            AIChatMessage(role: .user, text: "Проверь график", attachments: [image])
        ], model: "sonnet"))

        let input = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.url("input.json"))) as? [String: Any]
        XCTAssertEqual(input?["type"] as? String, "user")
        let message = try XCTUnwrap(input?["message"] as? [String: Any])
        XCTAssertEqual(message["role"] as? String, "user")
        let content = try XCTUnwrap(message["content"] as? [[String: Any]])
        let textIndex = try XCTUnwrap(content.firstIndex(where: { ($0["text"] as? String)?.contains("Attached image: graph.png") == true }))
        let imageIndex = try XCTUnwrap(content.firstIndex(where: { $0["type"] as? String == "image" }))
        XCTAssertLessThan(textIndex, imageIndex)
        let source = try XCTUnwrap(content[imageIndex]["source"] as? [String: Any])
        XCTAssertEqual(source["type"] as? String, "base64")
        XCTAssertEqual(source["media_type"] as? String, "image/png")
        XCTAssertEqual(source["data"] as? String, "AQID")
    }

    func testUnsupportedImageRejectsBeforeClaudeGenerationStarts() async throws {
        let fixture = try makeFixture(script: """
        #!/bin/sh
        if [ "$1" = "auth" ]; then
          printf '%s\\n' '{"loggedIn":true,"authMethod":"oauth","apiProvider":"firstParty"}'
          exit 0
        fi
        touch \(shellQuote(fixturePathPlaceholder("generation-started")))
        """)
        defer { fixture.cleanup() }
        try fixture.replacePlaceholders()
        let provider = LauncherClaudeChatProvider(executableURL: fixture.executableURL)
        let image = AIChatAttachment(name: "scan.heic", kind: .image, imageData: Data([0x01]), mimeType: "image/heic")

        do {
            _ = try await collect(provider.stream(messages: [
                AIChatMessage(role: .user, text: "Проверь", attachments: [image])
            ], model: "sonnet"))
            XCTFail("Expected unsupported image")
        } catch let error as AIChatError {
            XCTAssertEqual(error, .unavailable("Это изображение нельзя отправить в Claude."))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url("generation-started").path))
    }

    func testUnexpectedToolUseFailsTheTextOnlyStream() async throws {
        let fixture = try makeFixture(script: """
        #!/bin/sh
        if [ "$1" = "auth" ]; then
          printf '%s\\n' '{"loggedIn":true,"authMethod":"oauth","apiProvider":"firstParty"}'
          exit 0
        fi
        printf '%s\\n' '{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"tool_use","name":"Bash"}}}'
        """)
        defer { fixture.cleanup() }
        let provider = LauncherClaudeChatProvider(executableURL: fixture.executableURL)

        do {
            _ = try await collect(
                provider.stream(messages: [AIChatMessage(role: .user, text: "test")], model: "sonnet")
            )
            XCTFail("Expected tool-use rejection")
        } catch let error as AIChatError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    func testCancelTerminatesOwnedProcessAndInterruptsStream() async throws {
        let fixture = try makeFixture(script: """
        #!/bin/sh
        if [ "$1" = "auth" ]; then
          printf '%s\\n' '{"loggedIn":true,"authMethod":"oauth","apiProvider":"firstParty"}'
          exit 0
        fi
        touch \(shellQuote(fixturePathPlaceholder("started")))
        sleep 5
        """)
        defer { fixture.cleanup() }
        try fixture.replacePlaceholders()
        let provider = LauncherClaudeChatProvider(executableURL: fixture.executableURL, timeout: 10)
        let stream = provider.stream(messages: [AIChatMessage(role: .user, text: "test")], model: "sonnet")
        let task = Task { () -> Error? in
            do {
                _ = try await self.collect(stream)
                return nil
            } catch {
                return error
            }
        }
        try await waitForFile(fixture.url("started"))

        provider.cancel()
        let error = await task.value

        XCTAssertEqual(error as? AIChatError, .interrupted)
    }

    func testCancelDuringAuthPreflightNeverStartsGeneration() async throws {
        let fixture = try makeFixture(script: """
        #!/bin/sh
        if [ "$1" = "auth" ]; then
          touch \(shellQuote(fixturePathPlaceholder("auth-started")))
          sleep 5
          exit 0
        fi
        touch \(shellQuote(fixturePathPlaceholder("generation-started")))
        """)
        defer { fixture.cleanup() }
        try fixture.replacePlaceholders()
        let provider = LauncherClaudeChatProvider(executableURL: fixture.executableURL)
        let stream = provider.stream(messages: [AIChatMessage(role: .user, text: "test")], model: "sonnet")
        let task = Task { () -> Error? in
            do {
                _ = try await self.collect(stream)
                return nil
            } catch {
                return error
            }
        }
        try await waitForFile(fixture.url("auth-started"))

        provider.cancel()
        let error = await task.value

        XCTAssertEqual(error as? AIChatError, .interrupted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url("generation-started").path))
    }

    func testTimeoutTerminatesOwnedProcess() async throws {
        let fixture = try makeFixture(script: """
        #!/bin/sh
        if [ "$1" = "auth" ]; then
          printf '%s\\n' '{"loggedIn":true,"authMethod":"oauth","apiProvider":"firstParty"}'
          exit 0
        fi
        sleep 5
        """)
        defer { fixture.cleanup() }
        let provider = LauncherClaudeChatProvider(executableURL: fixture.executableURL, timeout: 0.05)

        do {
            _ = try await collect(
                provider.stream(messages: [AIChatMessage(role: .user, text: "test")], model: "sonnet")
            )
            XCTFail("Expected timeout")
        } catch let error as AIChatError {
            XCTAssertEqual(error, .timeout)
        }
    }

    func testContextLimitRejectsBeforeStartingTheCLI() async throws {
        let fixture = try makeFixture(script: """
        #!/bin/sh
        touch \(shellQuote(fixturePathPlaceholder("was-started")))
        """)
        defer { fixture.cleanup() }
        try fixture.replacePlaceholders()
        let provider = LauncherClaudeChatProvider(executableURL: fixture.executableURL)

        do {
            _ = try await collect(
                provider.stream(
                    messages: [AIChatMessage(role: .user, text: String(repeating: "x", count: 24_001))],
                    model: "sonnet"
                )
            )
            XCTFail("Expected context limit")
        } catch let error as AIChatError {
            XCTAssertEqual(error, .contextTooLarge)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url("was-started").path))
    }

    func testErrorResultFailsEvenAfterPartialText() async throws {
        let fixture = try makeFixture(script: """
        #!/bin/sh
        if [ "$1" = "auth" ]; then
          printf '%s\\n' '{"loggedIn":true,"authMethod":"oauth","apiProvider":"firstParty"}'
          exit 0
        fi
        printf '%s\\n' '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"частично"}}}'
        printf '%s\\n' '{"type":"result","is_error":true,"subtype":"error_max_turns"}'
        """)
        defer { fixture.cleanup() }
        let provider = LauncherClaudeChatProvider(executableURL: fixture.executableURL)

        do {
            _ = try await collect(
                provider.stream(messages: [AIChatMessage(role: .user, text: "test")], model: "sonnet")
            )
            XCTFail("Expected result error")
        } catch let error as AIChatError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    private func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> [String] {
        var chunks: [String] = []
        for try await chunk in stream {
            chunks.append(chunk)
        }
        return chunks
    }

    private func waitForFile(_ url: URL) async throws {
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: url.path) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "AIChatClaudeProviderTests", code: 1)
    }

    private func makeFixture(script: String) throws -> ClaudeFixture {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotchAppTests-Claude-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let executableURL = directoryURL.appendingPathComponent("claude-stub")
        try script.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: executableURL.path)
        return ClaudeFixture(directoryURL: directoryURL, executableURL: executableURL)
    }

    private func fixturePathPlaceholder(_ filename: String) -> String {
        "__FIXTURE__/\(filename)"
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\\"'\\\"'"))'"
    }
}

private struct ClaudeFixture {
    let directoryURL: URL
    let executableURL: URL

    func url(_ filename: String) -> URL {
        directoryURL.appendingPathComponent(filename)
    }

    func replacePlaceholders() throws {
        var script = try String(contentsOf: executableURL, encoding: .utf8)
        script = script.replacingOccurrences(of: "__FIXTURE__", with: directoryURL.path)
        try script.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: executableURL.path)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

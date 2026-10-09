import AppKit
import Combine
import Darwin
import Foundation

struct CodeReviewHostAuthentication: Equatable, Identifiable, Sendable {
    let host: String
    let isAuthenticated: Bool

    var id: String { host }
}

struct CodeReviewIntegrationStatus: Equatable, Identifiable, Sendable {
    let provider: CodeHostKind
    let cliName: String
    let isInstalled: Bool
    let hosts: [CodeReviewHostAuthentication]

    var id: String { provider.rawValue }

    var isReady: Bool {
        isInstalled && hosts.isEmpty == false && hosts.allSatisfy(\.isAuthenticated)
    }
}

@MainActor
final class CodeReviewIntegrationStore: ObservableObject {
    @Published private(set) var statuses: [CodeReviewIntegrationStatus] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var message: String?

    private var refreshTask: Task<Void, Never>?
    private var workerTask: Task<[CodeReviewIntegrationStatus], Never>?
    private var cancellation: CodeReviewIntegrationCancellation?
    private var generation = 0

    func refresh(workspacePaths: [String]) {
        cancelRefresh()
        let currentGeneration = generation
        let cancellation = CodeReviewIntegrationCancellation()
        self.cancellation = cancellation
        isRefreshing = true
        message = nil
        let worker = Task.detached(priority: .utility) {
            CodeReviewIntegrationInspector.inspect(
                workspacePaths: workspacePaths,
                cancellation: cancellation
            )
        }
        workerTask = worker
        refreshTask = Task { @MainActor [weak self] in
            let statuses = await worker.value
            guard let self,
                  self.generation == currentGeneration,
                  Task.isCancelled == false,
                  cancellation.isCancelled == false else { return }
            self.statuses = statuses
            self.isRefreshing = false
            self.refreshTask = nil
            self.workerTask = nil
            self.cancellation = nil
        }
    }

    func stop() {
        cancelRefresh()
        isRefreshing = false
        statuses = []
    }

    private func cancelRefresh() {
        generation &+= 1
        cancellation?.cancel()
        workerTask?.cancel()
        refreshTask?.cancel()
        cancellation = nil
        workerTask = nil
        refreshTask = nil
    }

    func beginSetup(for status: CodeReviewIntegrationStatus, host: String?) {
        do {
            try CodeReviewSetupTerminal.open(
                cliName: status.cliName,
                host: host,
                isInstalled: status.isInstalled
            )
            message = status.isInstalled
                ? "Terminal открыт. После входа нажми «Проверить снова»."
                : "Terminal открыт для установки \(status.cliName)."
        } catch {
            message = "Не удалось открыть Terminal. Выполни настройку вручную."
        }
    }
}

private enum CodeReviewIntegrationInspector {
    static func inspect(
        workspacePaths: [String],
        cancellation: CodeReviewIntegrationCancellation
    ) -> [CodeReviewIntegrationStatus] {
        var gitLabHosts: Set<String> = []
        for path in Set(workspacePaths) where path.isEmpty == false {
            guard !cancellation.isCancelled, !Task.isCancelled else { return [] }
            guard let root = git(["-C", path, "rev-parse", "--show-toplevel"], cancellation: cancellation),
                  let remote = originRemote(root: root, cancellation: cancellation),
                  let repository = CodeReviewRemoteParser.repository(
                    rootPath: root,
                    branch: "integration-check",
                    remoteURL: remote
                  ) else { continue }
            if repository.hostKind == .gitlab {
                gitLabHosts.insert(repository.host)
            }
        }

        let definitions: [(CodeHostKind, String, [String])] = [
            (.github, "gh", ["github.com"]),
            (.gitlab, "glab", gitLabHosts.sorted())
        ]
        var statuses: [CodeReviewIntegrationStatus] = []
        for (provider, cliName, hosts) in definitions {
            guard !cancellation.isCancelled, !Task.isCancelled else { return [] }
            let executable = executable(named: cliName)
            var authentications: [CodeReviewHostAuthentication] = []
            for host in hosts {
                guard !cancellation.isCancelled, !Task.isCancelled else { return [] }
                authentications.append(CodeReviewHostAuthentication(
                    host: host,
                    isAuthenticated: executable.map {
                        authStatus(executable: $0, cliName: cliName, host: host,
                                   cancellation: cancellation)
                    } ?? false
                ))
            }
            statuses.append(CodeReviewIntegrationStatus(
                provider: provider,
                cliName: cliName,
                isInstalled: executable != nil,
                hosts: authentications
            ))
        }
        return statuses
    }

    private static func originRemote(root: String, cancellation: CodeReviewIntegrationCancellation) -> String? {
        if let origin = git(["-C", root, "remote", "get-url", "origin"], cancellation: cancellation),
           origin.isEmpty == false {
            return origin
        }
        guard let first = git(["-C", root, "remote"], cancellation: cancellation)?
            .split(separator: "\n").first else {
            return nil
        }
        return git(["-C", root, "remote", "get-url", String(first)], cancellation: cancellation)
    }

    private static func git(_ arguments: [String], cancellation: CodeReviewIntegrationCancellation) -> String? {
        guard let result = CodeReviewIntegrationCommandRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: arguments,
            cancellation: cancellation,
            capturesOutput: true
        ), result.exitCode == 0 else { return nil }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func executable(named name: String) -> URL? {
        ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
            .map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func authStatus(
        executable: URL,
        cliName: String,
        host: String,
        cancellation: CodeReviewIntegrationCancellation
    ) -> Bool {
        CodeReviewIntegrationCommandRunner.run(
            executable: executable,
            arguments: ["auth", "status", "--hostname", host],
            cancellation: cancellation,
            environmentOverrides: [cliName == "gh" ? "GH_PROMPT_DISABLED" : "GLAB_NO_PROMPT": "1"]
        )?.exitCode == 0
    }
}

/// Serializes cancellation with launch so a stopped inspection cannot start another command.
final class CodeReviewIntegrationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() { lock.withLock { cancelled = true } }

    func launch(_ process: Process) throws -> Bool {
        try lock.withLock {
            guard !cancelled else { return false }
            try process.run()
            return true
        }
    }
}

struct CodeReviewIntegrationCommandResult: Sendable {
    let exitCode: Int32
    let output: String
}

/// Only runs local read-only probes; each process has an eight-second limit.
enum CodeReviewIntegrationCommandRunner {
    static func run(
        executable: URL,
        arguments: [String],
        cancellation: CodeReviewIntegrationCancellation,
        capturesOutput: Bool = false,
        environmentOverrides: [String: String] = [:]
    ) -> CodeReviewIntegrationCommandResult? {
        guard !cancellation.isCancelled, !Task.isCancelled else { return nil }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardError = FileHandle.nullDevice
        if !environmentOverrides.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environmentOverrides) { _, new in new }
        }
        let output = capturesOutput ? Pipe() : nil
        if let output {
            process.standardOutput = output
        } else {
            process.standardOutput = FileHandle.nullDevice
        }

        do {
            guard try cancellation.launch(process) else { return nil }
        } catch {
            return nil
        }
        output?.fileHandleForWriting.closeFile()

        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while process.isRunning,
              !cancellation.isCancelled,
              !Task.isCancelled,
              ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.025)
        }
        let completedNormally = !cancellation.isCancelled && !Task.isCancelled
            && ProcessInfo.processInfo.systemUptime < deadline
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.1)
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()
        guard completedNormally, !cancellation.isCancelled, !Task.isCancelled else { return nil }
        let text = output.flatMap {
            String(data: $0.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        } ?? ""
        return CodeReviewIntegrationCommandResult(exitCode: process.terminationStatus, output: text)
    }
}

private enum CodeReviewSetupTerminal {
    @MainActor
    static func open(cliName: String, host: String?, isInstalled: Bool) throws {
        let command: String
        if isInstalled {
            guard let host else { return }
            command = "\(cliName) auth login --hostname \(shellQuote(host))"
        } else {
            command = "brew install \(shellQuote(cliName))"
        }

        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nool-setup-\(UUID().uuidString).command")
        let script = """
        #!/bin/zsh
        trap 'rm -f -- "$0"' EXIT
        export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
        clear
        echo "NooL App — настройка \(cliName)"
        echo
        \(command)
        result=$?
        echo
        if [ $result -eq 0 ]; then
          echo "Готово. Вернись в NooL App и нажми «Проверить снова»."
        else
          echo "Команда завершилась с ошибкой $result."
        fi
        echo
        read -k 1 "?Нажми любую клавишу, чтобы закрыть окно..."
        exit $result
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: scriptURL.path
        )
        guard NSWorkspace.shared.open(scriptURL) else {
            try? FileManager.default.removeItem(at: scriptURL)
            throw CocoaError(.fileNoSuchFile)
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

import AppKit
import Combine
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

    func refresh(workspacePaths: [String]) {
        refreshTask?.cancel()
        isRefreshing = true
        message = nil
        refreshTask = Task { @MainActor [weak self] in
            let statuses = await Task.detached(priority: .utility) {
                CodeReviewIntegrationInspector.inspect(workspacePaths: workspacePaths)
            }.value
            guard Task.isCancelled == false else { return }
            self?.statuses = statuses
            self?.isRefreshing = false
            self?.refreshTask = nil
        }
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
    static func inspect(workspacePaths: [String]) -> [CodeReviewIntegrationStatus] {
        var gitLabHosts: Set<String> = []
        for path in Set(workspacePaths) where path.isEmpty == false {
            guard let root = git(["-C", path, "rev-parse", "--show-toplevel"]),
                  let remote = originRemote(root: root),
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
        return definitions.map { provider, cliName, hosts in
            let executable = executable(named: cliName)
            return CodeReviewIntegrationStatus(
                provider: provider,
                cliName: cliName,
                isInstalled: executable != nil,
                hosts: hosts.map { host in
                    CodeReviewHostAuthentication(
                        host: host,
                        isAuthenticated: executable.map {
                            authStatus(executable: $0, cliName: cliName, host: host)
                        } ?? false
                    )
                }
            )
        }
    }

    private static func originRemote(root: String) -> String? {
        if let origin = git(["-C", root, "remote", "get-url", "origin"]),
           origin.isEmpty == false {
            return origin
        }
        guard let first = git(["-C", root, "remote"])?.split(separator: "\n").first else {
            return nil
        }
        return git(["-C", root, "remote", "get-url", String(first)])
    }

    private static func git(_ arguments: [String]) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    private static func executable(named name: String) -> URL? {
        ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
            .map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func authStatus(executable: URL, cliName: String, host: String) -> Bool {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["auth", "status", "--hostname", host]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment[cliName == "gh" ? "GH_PROMPT_DISABLED" : "GLAB_NO_PROMPT"] = "1"
        process.environment = environment
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
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
        echo "Nool Notch — настройка \(cliName)"
        echo
        \(command)
        result=$?
        echo
        if [ $result -eq 0 ]; then
          echo "Готово. Вернись в Nool Notch и нажми «Проверить снова»."
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

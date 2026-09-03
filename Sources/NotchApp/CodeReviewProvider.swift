import Foundation
import Darwin

enum CodeHostKind: String, Equatable, Sendable {
    case github = "GitHub"
    case gitlab = "GitLab"
}

enum CodeCICheckState: Equatable, Sendable {
    case none
    case pending
    case passed
    case failed
}

enum CodeMergeState: Equatable, Sendable {
    case unknown
    case ready
    case conflicting
}

struct CodeRepositoryContext: Equatable, Sendable {
    let rootPath: String
    let branch: String
    let remoteURL: String
    let host: String
    let projectPath: String
    let hostKind: CodeHostKind

    var displayName: String {
        projectPath.split(separator: "/").suffix(2).joined(separator: "/")
    }
}

struct CodeReviewRequest: Equatable, Sendable, Identifiable {
    let provider: CodeHostKind
    let number: String
    let title: String
    let url: URL
    let diffURL: URL
    let state: String
    let isDraft: Bool
    let authorLogin: String?
    let mergeState: CodeMergeState
    let ciState: CodeCICheckState
    let completedChecks: Int
    let totalChecks: Int
    let reviewerActivityIDs: Set<String>
    let updatedAt: Date?

    var id: String { "\(provider.rawValue):\(number):\(url.absoluteString)" }
    var reviewActivityCount: Int { reviewerActivityIDs.count }
}

struct CodeReviewSnapshot: Equatable, Sendable {
    let repository: CodeRepositoryContext
    let request: CodeReviewRequest?
}

enum CodeReviewError: Error, Equatable, Sendable {
    case noWorkspace
    case notRepository
    case detachedHead
    case noRemote
    case unsupportedHost(String)
    case missingCLI(String)
    case notAuthenticated(cli: String, host: String)
    case commandFailed(String)

    var userMessage: String {
        switch self {
        case .noWorkspace:
            "У сессии нет локального workspace."
        case .notRepository:
            "Workspace не является Git-репозиторием."
        case .detachedHead:
            "Репозиторий находится в detached HEAD."
        case .noRemote:
            "В репозитории не настроен remote."
        case .unsupportedHost(let host):
            "Хост \(host) пока не поддерживается."
        case .missingCLI(let cli):
            cli == "glab"
                ? "Установи GitLab CLI: brew install glab"
                : "Установи GitHub CLI: brew install gh"
        case .notAuthenticated(let cli, let host):
            "Выполни: \(cli) auth login --hostname \(host)"
        case .commandFailed(let operation):
            "Не удалось \(operation). Повтори обновление."
        }
    }
}

enum CodeReviewLoadState: Equatable, Sendable {
    case idle
    case loading(previous: CodeReviewSnapshot?)
    case loaded(CodeReviewSnapshot)
    case failed(CodeReviewError, previous: CodeReviewSnapshot?)

    var snapshot: CodeReviewSnapshot? {
        switch self {
        case .idle:
            nil
        case .loading(let previous), .failed(_, let previous):
            previous
        case .loaded(let snapshot):
            snapshot
        }
    }
}

protocol CodeReviewProviding: Sendable {
    func load(workspacePath: String) async -> Result<CodeReviewSnapshot, CodeReviewError>
}

struct LocalCodeReviewProvider: CodeReviewProviding {
    func load(workspacePath: String) async -> Result<CodeReviewSnapshot, CodeReviewError> {
        let cancellationToken = CodeReviewCancellationToken()
        return await withTaskCancellationHandler {
            await Task.detached(priority: .utility) {
                CodeReviewLoader.load(
                    workspacePath: workspacePath,
                    cancellationToken: cancellationToken
                )
            }.value
        } onCancel: {
            cancellationToken.cancel()
        }
    }
}

private final class CodeReviewCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func cancel() {
        lock.withLock { cancelled = true }
    }
}

enum CodeReviewRemoteParser {
    static func repository(
        rootPath: String,
        branch: String,
        remoteURL: String
    ) -> CodeRepositoryContext? {
        let hostAndPath: (String, String)?
        if let url = URL(string: remoteURL), let host = url.host {
            hostAndPath = (host, url.path)
        } else if let separator = remoteURL.firstIndex(of: ":"),
                  remoteURL[..<separator].contains("@") {
            let userAndHost = remoteURL[..<separator]
            let host = userAndHost.split(separator: "@").last.map(String.init) ?? ""
            hostAndPath = (host, String(remoteURL[remoteURL.index(after: separator)...]))
        } else {
            hostAndPath = nil
        }

        guard let (rawHost, rawPath) = hostAndPath else { return nil }
        let host = rawHost.lowercased()
        let path = rawPath
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .replacingOccurrences(of: ".git", with: "", options: [.anchored, .backwards])
        guard host.isEmpty == false, path.isEmpty == false else { return nil }

        let kind: CodeHostKind
        if host == "github.com" {
            kind = .github
        } else {
            // glab resolves the exact host from this repository's remote, including
            // self-managed GitLab installations and custom certificates/config.
            kind = .gitlab
        }
        return CodeRepositoryContext(
            rootPath: rootPath,
            branch: branch,
            remoteURL: remoteURL,
            host: host,
            projectPath: path,
            hostKind: kind
        )
    }
}

enum CodeReviewDecoder {
    static func github(data: Data) -> CodeReviewRequest? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let number = scalarString(object["number"]),
              let title = object["title"] as? String,
              let urlString = object["url"] as? String,
              let url = URL(string: urlString),
              let diffURL = URL(string: urlString + "/files") else { return nil }

        let checks = object["statusCheckRollup"] as? [[String: Any]] ?? []
        let completed = checks.filter { check in
            let status = normalized(check["status"])
            return status == "COMPLETED" || normalized(check["conclusion"]).isEmpty == false
        }.count
        let ciState = checkState(checks)
        let authorLogin = login(object["author"])
        let comments = reviewerEntries(object["comments"], excluding: authorLogin)
        let reviews = reviewerEntries(object["latestReviews"], excluding: authorLogin).filter {
            (($0["body"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        }
        let mergeable = normalized(object["mergeable"])
        let mergeState = normalized(object["mergeStateStatus"])

        return CodeReviewRequest(
            provider: .github,
            number: number,
            title: title,
            url: url,
            diffURL: diffURL,
            state: (object["state"] as? String) ?? "OPEN",
            isDraft: object["isDraft"] as? Bool ?? false,
            authorLogin: authorLogin,
            mergeState: mergeable == "CONFLICTING" || mergeState == "DIRTY"
                ? .conflicting
                : (mergeable == "MERGEABLE" ? .ready : .unknown),
            ciState: ciState,
            completedChecks: completed,
            totalChecks: checks.count,
            reviewerActivityIDs: activityIDs(comments, prefix: "comment")
                .union(activityIDs(reviews, prefix: "review")),
            updatedAt: parseDate(object["updatedAt"])
        )
    }

    static func gitlab(data: Data) -> CodeReviewRequest? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let number = scalarString(object["iid"] ?? object["id"]),
              let title = object["title"] as? String,
              let urlString = (object["web_url"] ?? object["webUrl"]) as? String,
              let url = URL(string: urlString),
              let diffURL = URL(string: urlString + "/diffs") else { return nil }

        let pipeline = (object["head_pipeline"] ?? object["pipeline"]) as? [String: Any]
        let pipelineStatus = normalized(pipeline?["status"])
        let ciState: CodeCICheckState = switch pipelineStatus {
        case "SUCCESS", "PASSED": .passed
        case "FAILED", "CANCELED", "CANCELLED": .failed
        case "", "SKIPPED": .none
        default: .pending
        }
        let authorLogin = login(object["author"])
        let notes = reviewerEntries(object["notes"], excluding: authorLogin).filter {
            ($0["system"] as? Bool) != true
        }
        let discussions = reviewerEntries(object["discussions"], excluding: authorLogin).filter {
            ($0["system"] as? Bool) != true
        }
        let reviewerActivityIDs: Set<String>
        if notes.isEmpty == false {
            reviewerActivityIDs = activityIDs(notes, prefix: "note")
        } else if discussions.isEmpty == false {
            reviewerActivityIDs = activityIDs(discussions, prefix: "discussion")
        } else {
            reviewerActivityIDs = Set((0..<(integer(object["user_notes_count"]) ?? 0)).map { "note-count:\($0)" })
        }
        let mergeStatus = normalized(object["detailed_merge_status"] ?? object["merge_status"])
        let mergeState: CodeMergeState
        if object["has_conflicts"] as? Bool == true || mergeStatus.contains("CONFLICT") {
            mergeState = .conflicting
        } else if object["has_conflicts"] as? Bool == false {
            mergeState = .ready
        } else {
            mergeState = .unknown
        }

        return CodeReviewRequest(
            provider: .gitlab,
            number: number,
            title: title,
            url: url,
            diffURL: diffURL,
            state: (object["state"] as? String) ?? "opened",
            isDraft: object["draft"] as? Bool
                ?? object["work_in_progress"] as? Bool
                ?? false,
            authorLogin: authorLogin,
            mergeState: mergeState,
            ciState: ciState,
            completedChecks: pipelineStatus.isEmpty ? 0 : (ciState == .pending ? 0 : 1),
            totalChecks: pipelineStatus.isEmpty ? 0 : 1,
            reviewerActivityIDs: reviewerActivityIDs,
            updatedAt: parseDate(object["updated_at"] ?? object["updatedAt"])
        )
    }

    private static func checkState(_ checks: [[String: Any]]) -> CodeCICheckState {
        guard checks.isEmpty == false else { return .none }
        let failed = Set(["FAILURE", "FAILED", "CANCELLED", "CANCELED", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE", "ERROR"])
        if checks.contains(where: { failed.contains(normalized($0["conclusion"] ?? $0["state"])) }) {
            return .failed
        }
        let pending = checks.contains { check in
            let status = normalized(check["status"])
            let conclusion = normalized(check["conclusion"])
            return status != "COMPLETED" && conclusion.isEmpty
        }
        return pending ? .pending : .passed
    }

    private static func normalized(_ value: Any?) -> String {
        (value as? String)?.uppercased() ?? ""
    }

    private static func scalarString(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    static func githubInlineReviewerCommentIDs(
        data: Data,
        excluding authorLogin: String?
    ) -> Set<String> {
        guard let value = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let pages: [[Any]]
        if let direct = value as? [Any], direct.first is [Any] {
            pages = direct.compactMap { $0 as? [Any] }
        } else if let direct = value as? [Any] {
            pages = [direct]
        } else {
            return []
        }
        let entries = pages.flatMap { $0 }.compactMap { $0 as? [String: Any] }.filter { entry in
            login(entry["user"] ?? entry["author"]) != authorLogin
        }
        return activityIDs(entries, prefix: "inline")
    }

    private static func reviewerEntries(
        _ value: Any?,
        excluding authorLogin: String?
    ) -> [[String: Any]] {
        var entries: [[String: Any]] = []
        for value in value as? [Any] ?? [] {
            guard let entry = value as? [String: Any] else { continue }
            if let notes = entry["notes"] as? [Any] {
                entries.append(contentsOf: notes.compactMap { $0 as? [String: Any] })
            } else {
                entries.append(entry)
            }
        }
        guard let authorLogin, authorLogin.isEmpty == false else { return entries }
        return entries.filter { login($0["author"] ?? $0["user"]) != authorLogin }
    }

    private static func login(_ value: Any?) -> String? {
        guard let object = value as? [String: Any] else { return nil }
        return (object["login"] ?? object["username"] ?? object["name"]) as? String
    }

    private static func activityIDs(
        _ entries: [[String: Any]],
        prefix: String
    ) -> Set<String> {
        Set(entries.enumerated().map { index, entry in
            let stableID = scalarString(entry["id"])
                ?? (entry["url"] as? String)
                ?? (entry["web_url"] as? String)
                ?? "fallback:\(index):\((entry["created_at"] ?? entry["createdAt"]) as? String ?? "")"
            return "\(prefix):\(stableID)"
        })
    }

    private static func parseDate(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        return ISO8601DateFormatter().date(from: string)
    }
}

private enum CodeReviewLoader {
    static func load(
        workspacePath: String,
        cancellationToken: CodeReviewCancellationToken
    ) -> Result<CodeReviewSnapshot, CodeReviewError> {
        guard workspacePath.isEmpty == false else { return .failure(.noWorkspace) }
        guard let root = git(
            ["-C", workspacePath, "rev-parse", "--show-toplevel"],
            cancellationToken: cancellationToken
        ) else {
            return .failure(.notRepository)
        }
        guard let branch = git(
            ["-C", root, "branch", "--show-current"],
            cancellationToken: cancellationToken
        ),
              branch.isEmpty == false else {
            return .failure(.detachedHead)
        }
        guard let remote = originRemote(root: root, cancellationToken: cancellationToken) else {
            return .failure(.noRemote)
        }
        guard let repository = CodeReviewRemoteParser.repository(
            rootPath: root,
            branch: branch,
            remoteURL: remote
        ) else { return .failure(.noRemote) }

        switch repository.hostKind {
        case .github:
            return loadGitHub(repository, cancellationToken: cancellationToken)
        case .gitlab:
            return loadGitLab(repository, cancellationToken: cancellationToken)
        }
    }

    private static func loadGitHub(
        _ repository: CodeRepositoryContext,
        cancellationToken: CodeReviewCancellationToken
    ) -> Result<CodeReviewSnapshot, CodeReviewError> {
        guard let executable = executable(named: "gh") else { return .failure(.missingCLI("gh")) }
        guard command(
            executable,
            ["auth", "status", "--hostname", repository.host],
            currentDirectory: repository.rootPath,
            cancellationToken: cancellationToken
        ).status == 0 else {
            return .failure(.notAuthenticated(cli: "gh", host: repository.host))
        }
        let response = command(
            executable,
            [
                "pr", "view", repository.branch,
                "--json", "number,title,url,state,isDraft,author,mergeable,mergeStateStatus,statusCheckRollup,comments,latestReviews,updatedAt"
            ],
            currentDirectory: repository.rootPath,
            cancellationToken: cancellationToken
        )
        guard response.status == 0 else {
            if response.errorText.localizedCaseInsensitiveContains("no pull requests found") {
                return .success(CodeReviewSnapshot(repository: repository, request: nil))
            }
            return .failure(.commandFailed("обновить GitHub PR"))
        }
        guard let request = CodeReviewDecoder.github(data: response.data) else {
            return .failure(.commandFailed("прочитать GitHub PR"))
        }
        let reviewComments = command(
            executable,
            [
                "api", "--paginate", "--slurp",
                "repos/\(repository.projectPath)/pulls/\(request.number)/comments"
            ],
            currentDirectory: repository.rootPath,
            cancellationToken: cancellationToken
        )
        let inlineCommentIDs = reviewComments.status == 0
            ? CodeReviewDecoder.githubInlineReviewerCommentIDs(
                data: reviewComments.data,
                excluding: request.authorLogin
            )
            : []
        let requestWithReviewComments = CodeReviewRequest(
            provider: request.provider,
            number: request.number,
            title: request.title,
            url: request.url,
            diffURL: request.diffURL,
            state: request.state,
            isDraft: request.isDraft,
            authorLogin: request.authorLogin,
            mergeState: request.mergeState,
            ciState: request.ciState,
            completedChecks: request.completedChecks,
            totalChecks: request.totalChecks,
            reviewerActivityIDs: request.reviewerActivityIDs.union(inlineCommentIDs),
            updatedAt: request.updatedAt
        )
        return .success(CodeReviewSnapshot(repository: repository, request: requestWithReviewComments))
    }

    private static func loadGitLab(
        _ repository: CodeRepositoryContext,
        cancellationToken: CodeReviewCancellationToken
    ) -> Result<CodeReviewSnapshot, CodeReviewError> {
        guard let executable = executable(named: "glab") else { return .failure(.missingCLI("glab")) }
        guard command(
            executable,
            ["auth", "status", "--hostname", repository.host],
            currentDirectory: repository.rootPath,
            cancellationToken: cancellationToken
        ).status == 0 else {
            return .failure(.notAuthenticated(cli: "glab", host: repository.host))
        }
        let response = command(
            executable,
            ["mr", "view", repository.branch, "--output", "json", "--comments"],
            currentDirectory: repository.rootPath,
            cancellationToken: cancellationToken
        )
        guard response.status == 0 else {
            let noMergeRequest = response.errorText.localizedCaseInsensitiveContains("no merge request")
                || response.errorText.localizedCaseInsensitiveContains("could not find merge request")
            if noMergeRequest {
                return .success(CodeReviewSnapshot(repository: repository, request: nil))
            }
            return .failure(.commandFailed("обновить GitLab MR"))
        }
        guard let request = CodeReviewDecoder.gitlab(data: response.data) else {
            return .failure(.commandFailed("прочитать GitLab MR"))
        }
        return .success(CodeReviewSnapshot(repository: repository, request: request))
    }

    private static func originRemote(
        root: String,
        cancellationToken: CodeReviewCancellationToken
    ) -> String? {
        if let origin = git(
            ["-C", root, "remote", "get-url", "origin"],
            cancellationToken: cancellationToken
        ), origin.isEmpty == false {
            return origin
        }
        guard let first = git(
            ["-C", root, "remote"],
            cancellationToken: cancellationToken
        )?.split(separator: "\n").first else {
            return nil
        }
        return git(
            ["-C", root, "remote", "get-url", String(first)],
            cancellationToken: cancellationToken
        )
    }

    private static func git(
        _ arguments: [String],
        cancellationToken: CodeReviewCancellationToken
    ) -> String? {
        let result = command(
            URL(fileURLWithPath: "/usr/bin/git"),
            arguments,
            currentDirectory: nil,
            cancellationToken: cancellationToken
        )
        guard result.status == 0 else { return nil }
        return String(data: result.data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func executable(named name: String) -> URL? {
        ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
            .map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func command(
        _ executable: URL,
        _ arguments: [String],
        currentDirectory: String?,
        cancellationToken: CodeReviewCancellationToken
    ) -> (status: Int32, data: Data, errorText: String) {
        guard cancellationToken.isCancelled == false else { return (-3, Data(), "") }
        let process = Process()
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nool-cli-out-\(UUID().uuidString)")
        let errorURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nool-cli-err-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        guard let output = try? FileHandle(forWritingTo: outputURL),
              let errorOutput = try? FileHandle(forWritingTo: errorURL) else {
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: errorURL)
            return (-1, Data(), "")
        }
        defer {
            try? output.close()
            try? errorOutput.close()
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: errorURL)
        }
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errorOutput
        if let currentDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
        }
        var environment = ProcessInfo.processInfo.environment
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["GLAB_NO_PROMPT"] = "1"
        environment["PAGER"] = "cat"
        process.environment = environment

        do {
            try process.run()
            let deadline = Date().addingTimeInterval(20)
            while process.isRunning,
                  cancellationToken.isCancelled == false,
                  Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                process.terminate()
                Thread.sleep(forTimeInterval: 0.1)
                if process.isRunning {
                    Darwin.kill(process.processIdentifier, SIGKILL)
                }
            }
            process.waitUntilExit()
            try? output.synchronize()
            try? errorOutput.synchronize()
            let data = (try? Data(contentsOf: outputURL)) ?? Data()
            let errorData = (try? Data(contentsOf: errorURL)) ?? Data()
            let errorText = String(data: errorData.prefix(16_384), encoding: .utf8) ?? ""
            return (process.terminationStatus, data, errorText)
        } catch {
            return (-1, Data(), "")
        }
    }
}

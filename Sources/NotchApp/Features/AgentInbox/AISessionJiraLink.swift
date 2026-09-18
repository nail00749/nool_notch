import Foundation

enum AISessionJiraLink {
    static func issueKey(for session: AISession) -> String? {
        if let workspacePath = session.workspacePath,
           let branch = GitBranchReader.branchName(at: workspacePath),
           let key = issueKey(in: branch) {
            return key
        }
        return session.workspacePath.flatMap(issueKey(in:))
    }

    static func issueKey(in text: String) -> String? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = issueKeyRegex.firstMatch(in: text, range: range),
              let swiftRange = Range(match.range, in: text) else { return nil }
        return String(text[swiftRange]).uppercased()
    }

    static func durationText(_ duration: TimeInterval?) -> String {
        guard let duration else { return "Время не определено" }
        let totalMinutes = max(0, Int(duration / 60))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return hours > 0 ? "\(hours) ч \(minutes) мин" : "\(minutes) мин"
    }

    static func suggestedWorklog(for session: AISession) -> JiraWorklogDraft? {
        guard let duration = session.activeDuration(), duration > 0 else { return nil }
        let roundedMinutes = min(24 * 60, max(5, Int(ceil(duration / 300)) * 5))
        return JiraWorklogDraft(
            hours: roundedMinutes / 60,
            minutes: roundedMinutes % 60,
            description: "Работа с AI-ассистентом"
        )
    }

    private static let issueKeyRegex = try! NSRegularExpression(
        pattern: "(?i)(?<![A-Z0-9_])[A-Z][A-Z0-9_]*-[0-9]+(?![A-Z0-9_])"
    )
}

private enum GitBranchReader {
    static func branchName(at workspacePath: String) -> String? {
        let fileManager = FileManager.default
        var directory = URL(fileURLWithPath: workspacePath, isDirectory: true)

        for _ in 0..<10 {
            let dotGit = directory.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
                let gitDirectory: URL?
                if isDirectory.boolValue {
                    gitDirectory = dotGit
                } else {
                    gitDirectory = gitDirectoryReferenced(by: dotGit, relativeTo: directory)
                }
                if let gitDirectory,
                   let branch = branchName(in: gitDirectory) {
                    return branch
                }
            }
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else { break }
            directory = parent
        }
        return nil
    }

    private static func gitDirectoryReferenced(by dotGit: URL, relativeTo root: URL) -> URL? {
        guard let contents = try? String(contentsOf: dotGit, encoding: .utf8),
              contents.hasPrefix("gitdir:") else { return nil }
        let path = contents.dropFirst("gitdir:".count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.isEmpty == false else { return nil }
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return root.appendingPathComponent(path, isDirectory: true).standardizedFileURL
    }

    private static func branchName(in gitDirectory: URL) -> String? {
        let headURL = gitDirectory.appendingPathComponent("HEAD")
        guard let head = try? String(contentsOf: headURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              head.hasPrefix("ref: refs/heads/") else { return nil }
        return String(head.dropFirst("ref: refs/heads/".count))
    }
}

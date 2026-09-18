import Darwin
import Foundation

enum CodexCLIHookInstallError: Error {
    case bridgeUnavailable
    case invalidHooksFile
    case writeFailed
}

enum CodexCLIHookInstaller {
    enum HooksFeatureState: String, Equatable {
        case absent
        case disabled
        case enabled
    }

    private static let managedMarker = "nool-agent-bridge"
    private static let codexEvents: [(name: String, timeout: Int)] = [
        ("SessionStart", 5),
        ("SessionEnd", 3),
        ("UserPromptSubmit", 5),
        ("PreToolUse", 5),
        ("PostToolUse", 5),
        ("PermissionRequest", 86_400),
        ("Stop", 5)
    ]
    private static let claudeEvents: [(name: String, timeout: Int)] = [
        ("SessionStart", 5),
        ("SessionEnd", 3),
        ("UserPromptSubmit", 5),
        ("PreToolUse", 5),
        ("PostToolUse", 5),
        ("PostToolUseFailure", 5),
        ("PermissionRequest", 86_400),
        ("Stop", 5)
    ]

    static func install() throws {
        let fileManager = FileManager.default
        let codexHome = codexHomeURL()
        let claudeHome = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
        let hasCodex = fileManager.fileExists(atPath: codexHome.path)
        let hasClaude = fileManager.fileExists(atPath: claudeHome.path)
        guard hasCodex || hasClaude else { return }

        let installDirectory = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".nool-notch/bin", isDirectory: true)
        try fileManager.createDirectory(
            at: installDirectory,
            withIntermediateDirectories: true
        )
        let installedBridge = installDirectory.appendingPathComponent(managedMarker)
        guard let bundledBridge = bundledBridgeURL() else {
            throw CodexCLIHookInstallError.bridgeUnavailable
        }
        let bridgeData = try Data(contentsOf: bundledBridge)
        try bridgeData.write(to: installedBridge, options: .atomic)
        guard chmod(installedBridge.path, 0o700) == 0 else {
            throw CodexCLIHookInstallError.writeFailed
        }

        let command = shellQuoted(installedBridge.path)
        if hasCodex {
            let configURL = codexHome.appendingPathComponent("config.toml")
            try installHooksJSON(
                at: codexHome.appendingPathComponent("hooks.json"),
                command: "\(command) --source codex-cli",
                events: codexEvents,
                matcher: nil
            )
            try captureHooksFeatureStateIfNeeded(at: configURL)
            try enableHooksFeature(at: configURL)
        }
        if hasClaude {
            try installHooksJSON(
                at: claudeHome.appendingPathComponent("settings.json"),
                command: "\(command) --source claude-code",
                events: claudeEvents,
                matcher: "*"
            )
        }
    }

    static func uninstall() throws {
        let fileManager = FileManager.default
        let codexHome = codexHomeURL()
        let codexHooks = codexHome.appendingPathComponent("hooks.json")
        let codexConfig = codexHome.appendingPathComponent("config.toml")
        let claudeHooks = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        let removedCodexHooks = try removeManagedHooks(at: codexHooks)
        try removeManagedHooks(at: claudeHooks)
        if let priorState = try priorHooksFeatureState(
            at: codexConfig,
            allowBackupFallback: removedCodexHooks
        ) {
            try restoreHooksFeature(priorState, at: codexConfig)
            try removeHooksFeatureState(at: codexConfig)
        }
    }

    private static func bundledBridgeURL() -> URL? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(managedMarker),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("NoolAgentBridge")
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func codexHomeURL() -> URL {
        if let configured = ProcessInfo.processInfo.environment["CODEX_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           configured.isEmpty == false {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
    }

    private static func installHooksJSON(
        at url: URL,
        command: String,
        events: [(name: String, timeout: Int)],
        matcher: String?
    ) throws {
        let fileManager = FileManager.default
        var existingData: Data?
        if fileManager.fileExists(atPath: url.path) {
            existingData = try Data(contentsOf: url)
            try createBackupIfNeeded(for: url)
        }

        let output = try mergedHooksData(
            existing: existingData,
            command: command,
            events: events,
            matcher: matcher
        )
        try output.write(to: url, options: .atomic)
    }

    static func mergedHooksData(
        existing: Data?,
        command: String,
        events: [(name: String, timeout: Int)],
        matcher: String?
    ) throws -> Data {
        let rootObject: [String: Any]
        if let existing, existing.isEmpty == false {
            guard let decoded = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] else {
                throw CodexCLIHookInstallError.invalidHooksFile
            }
            rootObject = decoded
        } else {
            rootObject = [:]
        }
        var root = rootObject

        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for event in events {
            var entries = hooks[event.name] as? [[String: Any]] ?? []
            entries.removeAll(where: containsManagedHook)
            var entry: [String: Any] = [
                "hooks": [[
                    "type": "command",
                    "command": command,
                    "timeout": event.timeout
                ]]
            ]
            if let matcher { entry["matcher"] = matcher }
            entries.append(entry)
            hooks[event.name] = entries
        }
        root["hooks"] = hooks

        let output = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
        return output
    }

    static func removingManagedHooksData(existing: Data) throws -> Data {
        guard String(decoding: existing, as: UTF8.self).contains(managedMarker) else {
            return existing
        }
        guard var root = try JSONSerialization.jsonObject(with: existing) as? [String: Any] else {
            throw CodexCLIHookInstallError.invalidHooksFile
        }
        guard var hooks = root["hooks"] as? [String: Any] else { return existing }

        for eventName in Array(hooks.keys) {
            guard var entries = hooks[eventName] as? [[String: Any]] else { continue }
            entries.removeAll(where: containsManagedHook)
            if entries.isEmpty {
                hooks.removeValue(forKey: eventName)
            } else {
                hooks[eventName] = entries
            }
        }
        if hooks.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = hooks
        }
        return try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    private static func containsManagedHook(_ entry: [String: Any]) -> Bool {
        if let command = entry["command"] as? String, command.contains(managedMarker) {
            return true
        }
        guard let hooks = entry["hooks"] as? [[String: Any]] else { return false }
        return hooks.contains { ($0["command"] as? String)?.contains(managedMarker) == true }
    }

    @discardableResult
    private static func removeManagedHooks(at url: URL) throws -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return false }
        let existing = try Data(contentsOf: url)
        let output = try removingManagedHooksData(existing: existing)
        guard output != existing else { return false }
        try createBackupIfNeeded(for: url)
        try output.write(to: url, options: .atomic)
        return true
    }

    private static func enableHooksFeature(at url: URL) throws {
        let fileManager = FileManager.default
        let contents = fileManager.fileExists(atPath: url.path)
            ? try String(contentsOf: url, encoding: .utf8)
            : ""
        let updated = settingHooksFeature(in: contents, to: .enabled)
        guard updated != contents else { return }

        if fileManager.fileExists(atPath: url.path) {
            try createBackupIfNeeded(for: url)
        }
        guard let data = updated.data(using: .utf8) else {
            throw CodexCLIHookInstallError.writeFailed
        }
        try data.write(to: url, options: .atomic)
    }

    static func hooksFeatureState(in contents: String) -> HooksFeatureState {
        let lines = contents.components(separatedBy: "\n")
        guard let featureStart = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "[features]"
        }) else { return .absent }
        let featureEnd = lines[(featureStart + 1)...].firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("[")
        }) ?? lines.endIndex
        guard let hooksLine = lines[(featureStart + 1)..<featureEnd].first(where: {
            $0.range(of: #"^\s*hooks\s*="#, options: .regularExpression) != nil
        }) else { return .absent }
        let value = hooksLine
            .split(separator: "#", maxSplits: 1)[0]
            .split(separator: "=", maxSplits: 1)
            .dropFirst()
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return value == "true" ? .enabled : .disabled
    }

    static func settingHooksFeature(
        in contents: String,
        to state: HooksFeatureState
    ) -> String {
        var lines = contents.components(separatedBy: "\n")

        if let featureStart = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "[features]"
        }) {
            let featureEnd = lines[(featureStart + 1)...].firstIndex(where: {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("[")
            }) ?? lines.endIndex
            let hooksLine = lines[(featureStart + 1)..<featureEnd].firstIndex(where: {
                $0.range(of: #"^\s*hooks\s*="#, options: .regularExpression) != nil
            })
            if let hooksLine {
                if state == .absent {
                    lines.remove(at: hooksLine)
                } else {
                    let comment = lines[hooksLine].split(separator: "#", maxSplits: 1)
                        .dropFirst().first.map { " #\($0)" } ?? ""
                    lines[hooksLine] = "hooks = \(state == .enabled ? "true" : "false")\(comment)"
                }
            } else if state != .absent {
                lines.insert("hooks = \(state == .enabled ? "true" : "false")", at: featureStart + 1)
            }
        } else if state != .absent {
            if lines.last?.isEmpty == false { lines.append("") }
            lines.append("[features]")
            lines.append("hooks = \(state == .enabled ? "true" : "false")")
        }
        return lines.joined(separator: "\n")
    }

    private static func restoreHooksFeature(
        _ state: HooksFeatureState,
        at url: URL
    ) throws {
        let fileManager = FileManager.default
        let contents = fileManager.fileExists(atPath: url.path)
            ? try String(contentsOf: url, encoding: .utf8)
            : ""
        let updated = settingHooksFeature(in: contents, to: state)
        guard updated != contents else { return }
        if fileManager.fileExists(atPath: url.path) {
            try createBackupIfNeeded(for: url)
        }
        guard let data = updated.data(using: .utf8) else {
            throw CodexCLIHookInstallError.writeFailed
        }
        try data.write(to: url, options: .atomic)
    }

    private static func captureHooksFeatureStateIfNeeded(at configURL: URL) throws {
        let fileManager = FileManager.default
        let stateURL = hooksFeatureStateURL(for: configURL)
        guard fileManager.fileExists(atPath: stateURL.path) == false else { return }
        let contents = fileManager.fileExists(atPath: configURL.path)
            ? try String(contentsOf: configURL, encoding: .utf8)
            : ""
        try Data(hooksFeatureState(in: contents).rawValue.utf8)
            .write(to: stateURL, options: .atomic)
    }

    private static func priorHooksFeatureState(
        at configURL: URL,
        allowBackupFallback: Bool
    ) throws -> HooksFeatureState? {
        let fileManager = FileManager.default
        let stateURL = hooksFeatureStateURL(for: configURL)
        if fileManager.fileExists(atPath: stateURL.path) {
            let rawValue = try String(contentsOf: stateURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let state = HooksFeatureState(rawValue: rawValue) else {
                throw CodexCLIHookInstallError.writeFailed
            }
            return state
        }
        guard allowBackupFallback else { return nil }
        let backupURL = configURL.appendingPathExtension("nool-backup")
        guard fileManager.fileExists(atPath: backupURL.path) else { return .absent }
        return hooksFeatureState(
            in: try String(contentsOf: backupURL, encoding: .utf8)
        )
    }

    private static func removeHooksFeatureState(at configURL: URL) throws {
        let stateURL = hooksFeatureStateURL(for: configURL)
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return }
        try FileManager.default.removeItem(at: stateURL)
    }

    private static func hooksFeatureStateURL(for configURL: URL) -> URL {
        configURL.appendingPathExtension("nool-state")
    }

    private static func createBackupIfNeeded(for url: URL) throws {
        let backupURL = url.appendingPathExtension("nool-backup")
        guard FileManager.default.fileExists(atPath: backupURL.path) == false else { return }
        try FileManager.default.copyItem(at: url, to: backupURL)
    }

    private static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

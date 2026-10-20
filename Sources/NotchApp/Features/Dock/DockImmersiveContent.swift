import AppKit
import Darwin
import IOKit.pwr_mgt

/// Full-screen content where reaching the bottom edge must not summon the Dock, like the
/// system Dock: games and playing video. Public signals only — no Accessibility or capture.
enum DockImmersiveContent {
    /// Players hold a display-sleep assertion only while video plays; a paused video, music
    /// and Electron's idle-sleep assertion do not count.
    static let videoAssertionTypes: Set<String> = ["PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion"]

    struct Options: Equatable, Sendable {
        var games = true
        var video = true
        /// Bundle identifiers the user excluded in settings: always inert in full screen.
        var excludedBundleIdentifiers: Set<String> = []
    }

    static func isImmersive(pid: Int32, options: Options) -> Bool {
        if !options.excludedBundleIdentifiers.isEmpty,
           let identifier = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
           options.excludedBundleIdentifiers.contains(identifier) { return true }
        return (options.games && isGame(pid: pid)) || (options.video && isPlayingVideo(pid: pid))
    }

    static func isGame(pid: Int32) -> Bool {
        guard let url = NSRunningApplication(processIdentifier: pid)?.bundleURL else { return false }
        let category = Bundle(url: url)?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String
        return isGame(category: category, bundlePath: url.path)
    }

    /// The category macOS uses for Game Mode, including its `*-games` subcategories, and
    /// Steam's install location for titles that declare no category.
    static func isGame(category: String?, bundlePath: String) -> Bool {
        if let category = category?.lowercased(), category == "public.app-category.games"
            || (category.hasPrefix("public.app-category.") && category.hasSuffix("-games")) { return true }
        return bundlePath.lowercased().contains("/steamapps/common/")
    }

    static func isPlayingVideo(pid: Int32) -> Bool {
        var raw: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&raw) == kIOReturnSuccess,
              let byProcess = raw?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return false }
        let bundlePath = NSRunningApplication(processIdentifier: pid)?.bundleURL?.path
        return holdsVideoAssertion(byProcess.map { (pid: $0.key.int32Value, assertions: $0.value) },
                                   owner: pid) { assertingPID in
            // Helper processes (for example browser renderers) live inside the application bundle.
            guard let bundlePath, let path = executablePath(assertingPID) else { return false }
            return path.hasPrefix(bundlePath + "/")
        }
    }

    static func holdsVideoAssertion(_ entries: [(pid: Int32, assertions: [[String: Any]])], owner: Int32,
                                    isHelper: (Int32) -> Bool = { _ in false }) -> Bool {
        entries.contains { entry in
            entry.assertions.contains { assertion in
                guard let type = assertion[kIOPMAssertionTypeKey] as? String,
                      videoAssertionTypes.contains(type) else { return false }
                let onBehalf = (assertion["AssertionOnBehalfOfPID"] as? NSNumber)?.int32Value
                return entry.pid == owner || onBehalf == owner || isHelper(entry.pid)
            }
        }
    }

    private static func executablePath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = Int(proc_pidpath(pid, &buffer, UInt32(buffer.count)))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(length).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

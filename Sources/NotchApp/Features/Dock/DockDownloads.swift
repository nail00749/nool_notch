import AppKit
import Carbon
import Combine

/// Download progress on the Downloads stack. Browsers and Finder publish NSProgress
/// for files in ~/Downloads; subscribing needs no permission and reads no content.
@MainActor
final class DockDownloadProgressModel: ObservableObject {
    /// Average completion of active downloads, nil when nothing is downloading.
    @Published private(set) var fraction: Double?
    /// Increments when a download finishes: the Downloads icon bounces once.
    @Published private(set) var finishedCount = 0
    private var subscriber: Any?
    private var tracker: DockProgressTracker?

    func start(directory: URL) {
        guard subscriber == nil else { return }
        let tracker = DockProgressTracker { [weak self] fraction, finished in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.fraction != fraction { self.fraction = fraction }
                if finished { self.finishedCount += 1 }
            }
        }
        self.tracker = tracker
        subscriber = Progress.addSubscriber(forFileURL: directory) { progress in
            tracker.add(progress)
            return { tracker.remove(progress) }
        }
    }

    func stop() {
        if let subscriber { Progress.removeSubscriber(subscriber) }
        subscriber = nil
        tracker?.invalidate()
        tracker = nil
        fraction = nil
    }
}

/// Foundation calls publishing handlers on its own queue; all state is locked.
private final class DockProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [ObjectIdentifier: (progress: Progress, observation: NSKeyValueObservation)] = [:]
    private var report: ((Double?, Bool) -> Void)?

    init(report: @escaping (Double?, Bool) -> Void) { self.report = report }

    func add(_ progress: Progress) {
        let observation = progress.observe(\.fractionCompleted) { [weak self] _, _ in self?.publish(finished: false) }
        lock.lock()
        guard entries.count < 64 else { lock.unlock(); observation.invalidate(); return }
        entries[ObjectIdentifier(progress)] = (progress, observation)
        lock.unlock()
        publish(finished: false)
    }

    func remove(_ progress: Progress) {
        lock.lock()
        let removed = entries.removeValue(forKey: ObjectIdentifier(progress))
        lock.unlock()
        removed?.observation.invalidate()
        publish(finished: removed != nil && !progress.isCancelled)
    }

    func invalidate() {
        lock.lock()
        let all = entries.values.map(\.observation)
        entries.removeAll()
        report = nil
        lock.unlock()
        all.forEach { $0.invalidate() }
    }

    private func publish(finished: Bool) {
        lock.lock()
        let values = entries.values.map { min(1, max(0, $0.progress.fractionCompleted)) }
        let report = report
        lock.unlock()
        report?(values.isEmpty ? nil : values.reduce(0, +) / Double(values.count), finished)
    }
}

/// Files dropped on a stack: moved within one volume, copied across volumes (or with ⌥), like Finder.
enum DockFileTransfer {
    static func transfer(_ urls: [URL], into directory: URL, forceCopy: Bool,
                         fileManager: FileManager = .default) -> [String] {
        let target = directory.standardizedFileURL.resolvingSymlinksInPath()
        let targetVolume = try? target.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
        var failures: [String] = []
        for source in urls.prefix(512) where source.isFileURL {
            let file = source.standardizedFileURL.resolvingSymlinksInPath()
            // Already in this folder, or a folder dropped into itself.
            guard file.deletingLastPathComponent().path != target.path,
                  target.path != file.path, !target.path.hasPrefix(file.path + "/") else { continue }
            let destination = uniqueDestination(for: file.lastPathComponent, in: target, fileManager: fileManager)
            let sourceVolume = try? file.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
            let sameVolume = sourceVolume != nil && sourceVolume == targetVolume
            do {
                if sameVolume && !forceCopy { try fileManager.moveItem(at: file, to: destination) }
                else { try fileManager.copyItem(at: file, to: destination) }
            } catch {
                failures.append(file.lastPathComponent)
            }
        }
        return failures
    }

    static func uniqueDestination(for name: String, in directory: URL, fileManager: FileManager = .default) -> URL {
        var candidate = directory.appendingPathComponent(name)
        guard fileManager.fileExists(atPath: candidate.path) else { return candidate }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        for index in 2...999 {
            let next = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            candidate = directory.appendingPathComponent(next)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        return directory.appendingPathComponent("\(base) \(UUID().uuidString.prefix(8))\(ext.isEmpty ? "" : ".\(ext)")")
    }
}

// Separate signature from the Launcher hotkey: each handler passes the other's events on.
private func dockHotKeyHandler(
    _ next: EventHandlerCallRef?, _ event: EventRef?, _ context: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let context else { return OSStatus(eventNotHandledErr) }
    var identifier = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                   MemoryLayout<EventHotKeyID>.size, nil, &identifier)
    guard status == noErr, identifier.signature == DockHotKey.signature else { return OSStatus(eventNotHandledErr) }
    let hotKey = Unmanaged<DockHotKey>.fromOpaque(context).takeUnretainedValue()
    MainActor.assumeIsolated { hotKey.onPress?() }
    return noErr
}

/// ⌥⌘D toggles automatic hiding, as in the system Dock. If macOS keeps the shortcut
/// for its own Dock, registration fails and the setting reports it.
@MainActor
final class DockHotKey {
    nonisolated static let signature: OSType = 0x4E44_4F43 // "NDOC"
    var onPress: (() -> Void)?
    private(set) var isRegistered = false
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        guard enabled != isRegistered else { return true }
        guard enabled else { stop(); return true }
        if handler == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            guard InstallEventHandler(GetApplicationEventTarget(), dockHotKeyHandler, 1, &type,
                                      Unmanaged.passUnretained(self).toOpaque(), &handler) == noErr else { return false }
        }
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_D), UInt32(cmdKey | optionKey),
                                         EventHotKeyID(signature: Self.signature, id: 1), GetApplicationEventTarget(), 0, &hotKey)
        isRegistered = status == noErr
        return isRegistered
    }

    func stop() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
        isRegistered = false
    }
}

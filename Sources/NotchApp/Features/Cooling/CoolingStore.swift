import AppKit
import Combine
import ServiceManagement
import NoolCoolingCore

enum CoolingServiceStatus: Sendable { case notInstalled, requiresApproval, enabled, unavailable }

/// Service Management may synchronously ask BTM over XPC. Keep this infrequent
/// permission lookup outside the main actor and separate from sensor polling.
private actor CoolingServiceStatusReader {
    private let service = SMAppService.daemon(plistName: "com.nool.cooling-helper.plist")
    func read(bundleURL: URL) -> CoolingServiceStatus {
        switch service.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered: .notInstalled
        case .notFound: CoolingStore.unregisteredStatus(bundleURL: bundleURL)
        @unknown default: .unavailable
        }
    }
}

private actor CoolingReadOnlySampler {
    private var hardware: CoolingSMC?
    func sample() throws -> CoolingSnapshot {
        if hardware == nil { hardware = CoolingSMC() }
        return try hardware!.snapshot()
    }
}

@MainActor
final class CoolingStore: ObservableObject {
    static let shared = CoolingStore()
    @Published private(set) var snapshot: CoolingSnapshot?
    @Published private(set) var history: [CoolingSnapshot] = []
    @Published private(set) var status: CoolingServiceStatus = .notInstalled
    @Published private(set) var message: String?
    @Published private(set) var isBusy = false
    private var client: any CoolingClientTransport = CoolingHelperClient()
    private var statusOverride: CoolingServiceStatus?
    private var unregisterServiceOverride: (@MainActor () async throws -> Void)?
    private let sampler = CoolingReadOnlySampler()
    private let service = SMAppService.daemon(plistName: "com.nool.cooling-helper.plist")
    private let statusReader = CoolingServiceStatusReader()
    private var lastStatusRead: TimeInterval?
    private var serviceMutationInProgress = false
    private let sessionID = UUID().uuidString
    private var observers = 0
    private var ownsControl = false
    private var stopping = false
    private var commandRevision = 0
    private var commandError: String?
    private var polling: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?
    private struct QueuedCommand {
        let request: CoolingControlRequest
        let manualSource: UUID?
    }
    private var pendingCommands: [QueuedCommand] = []
    private var manualDebounce: Task<Void, Never>?
    private var manualDebounceSource: UUID?
    private var manualDebounceRevision = UUID()
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    private let preview: Bool

    var canControl: Bool { !stopping && !serviceMutationInProgress && status == .enabled && snapshot?.controlAvailable == true }

    init() {
        preview = false
        let center = NSWorkspace.shared.notificationCenter
        sleepObserver = center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.suspendControl() }
        }
        wakeObserver = center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.stopping = false
                self?.lastStatusRead = nil
                self?.ensurePolling()
            }
        }
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                                   object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refreshStatus(force: true) }
        }
    }

    init(previewSnapshot: CoolingSnapshot, history: [CoolingSnapshot] = []) {
        preview = true
        snapshot = previewSnapshot
        self.history = history
        status = .enabled
    }

    /// Tests exercise session lifecycle without registering a daemon or touching SMC.
    init(testClient: any CoolingClientTransport, snapshot: CoolingSnapshot,
         unregisterService: (@MainActor () async throws -> Void)? = nil) {
        preview = false
        client = testClient
        self.snapshot = snapshot
        status = .enabled
        statusOverride = .enabled
        unregisterServiceOverride = unregisterService
    }

    func startObserving() { observers += 1; ensurePolling() }
    func stopObserving() {
        observers = max(0, observers - 1)
        stopPollingIfIdle()
    }

    private func refreshStatus(force: Bool = false) async {
        guard !preview else { return }
        if let statusOverride { status = statusOverride; return }
        guard CoolingHelperClient.signingTeam != nil else {
            status = .unavailable
            message = "Мониторинг доступен. Для управления нужна сборка с подписью разработчика."
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let interval: TimeInterval = status == .enabled ? 30 : 2
        if !force, let lastStatusRead, now >= lastStatusRead, now - lastStatusRead < interval { return }
        lastStatusRead = now
        let revision = commandRevision
        let result = await statusReader.read(bundleURL: Bundle.main.bundleURL)
        guard !stopping, revision == commandRevision else { lastStatusRead = nil; return }
        status = result
    }

    // On current macOS, BTM reports notFound before a bundled daemon has its
    // first registration record. This is distinct from missing bundle files.
    nonisolated static func unregisteredStatus(bundleURL: URL) -> CoolingServiceStatus {
        let plist = bundleURL.appendingPathComponent("Contents/Library/LaunchDaemons/com.nool.cooling-helper.plist")
        let executable = bundleURL.appendingPathComponent("Contents/MacOS/NoolCoolingHelper")
        return FileManager.default.fileExists(atPath: plist.path)
            && FileManager.default.isExecutableFile(atPath: executable.path) ? .notInstalled : .unavailable
    }

    private func ensurePolling() {
        guard !preview, !stopping, polling == nil, observers > 0 || ownsControl else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.sample()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    private func sample() async {
        guard !isBusy, !stopping else { return }
        let revision = commandRevision
        await refreshStatus()
        guard !Task.isCancelled, revision == commandRevision, !stopping else { return }
        do {
            let value: CoolingSnapshot
            if status == .enabled { value = try await client.snapshot() }
            else { value = try await sampler.sample() }
            guard !Task.isCancelled, revision == commandRevision, !stopping else { return }
            accept(value)
        } catch {
            guard !Task.isCancelled, revision == commandRevision, !stopping else { return }
            message = error.localizedDescription
            // A stale snapshot remains useful to read, but must never enable writes.
            if var stale = snapshot { stale.controlAvailable = false; snapshot = stale }
        }
    }

    private func accept(_ value: CoolingSnapshot) {
        snapshot = value
        history.append(value)
        history.removeAll { $0.sampledAt < value.sampledAt.addingTimeInterval(-120) }
        if history.count > 120 { history.removeFirst(history.count - 120) }
        if status == .unavailable {
            message = CoolingHelperClient.signingTeam == nil
                ? "Мониторинг доступен. Для управления нужна сборка с подписью разработчика."
                : "Служба охлаждения отсутствует в сборке. Переустановите NooL."
        } else { message = commandError ?? value.notice }
        if ownsControl && value.controlledFanIDs.isEmpty {
            setOwnsControl(false)
        }
    }

    private func setOwnsControl(_ owns: Bool) {
        ownsControl = owns
        if !owns {
            heartbeat?.cancel(); heartbeat = nil
            stopPollingIfIdle()
        }
    }

    private func stopPollingIfIdle() {
        guard observers == 0, !ownsControl else { return }
        polling?.cancel(); polling = nil
    }

    func enableControl() {
        guard !preview, !isBusy, !stopping else { return }
        isBusy = true
        serviceMutationInProgress = true
        commandRevision += 1
        commandTask = Task { [weak self] in
            guard let self else { return }
            defer { self.commandTask = nil; self.serviceMutationInProgress = false; self.isBusy = false }
            do {
                self.commandError = nil
                guard CoolingHelperClient.signingTeam != nil else {
                    throw CoolingError.unavailable("Для управления нужна сборка NooL с подписью разработчика.")
                }
                if self.service.status == .notRegistered || self.service.status == .notFound { try self.service.register() }
                await self.refreshStatus(force: true)
                if self.status == .requiresApproval { self.openApprovalSettings() }
                self.message = self.status == .requiresApproval ? "Разрешите службу NooL в разделе «Объекты входа и расширения»." : nil
            } catch { self.commandError = error.localizedDescription; self.message = self.commandError; await self.refreshStatus(force: true) }
            self.ensurePolling()
        }
    }

    func openApprovalSettings() { if !preview { SMAppService.openSystemSettingsLoginItems() } }

    func apply(fanIDs: [Int], mode: CoolingControlMode, percent: Double? = nil, duration: TimeInterval? = nil,
               sensorID: String? = nil, curve: [CoolingCurvePoint]? = nil) {
        guard !preview, canControl else { return }
        cancelPendingManual()
        let request = CoolingControlRequest(sessionID: sessionID, fanIDs: fanIDs, mode: mode,
                                            targetPercent: percent, durationSeconds: duration, sensorID: sensorID, curve: curve)
        enqueue(QueuedCommand(request: request, manualSource: nil))
    }

    /// Called only by a user-edited slider binding. Polling and draft selection
    /// never enter this path, and each presentation can revoke its own draft.
    func scheduleManual(fanIDs: [Int], percent: Double, sourceID: UUID) {
        guard !preview, canControl, percent.isFinite, (0...100).contains(percent), !fanIDs.isEmpty else { return }
        cancelPendingManual()
        let revision = UUID()
        manualDebounceRevision = revision
        manualDebounceSource = sourceID
        let request = CoolingControlRequest(sessionID: sessionID, fanIDs: fanIDs, mode: .manual, targetPercent: percent)
        manualDebounce = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard let self, self.manualDebounceRevision == revision, self.canControl else { return }
            self.manualDebounce = nil
            self.manualDebounceSource = nil
            self.enqueue(QueuedCommand(request: request, manualSource: sourceID))
        }
    }

    func cancelPendingManual(sourceID: UUID? = nil) {
        if sourceID == nil || manualDebounceSource == sourceID {
            manualDebounce?.cancel()
            manualDebounce = nil
            manualDebounceSource = nil
            manualDebounceRevision = UUID()
        }
        pendingCommands.removeAll { command in
            command.manualSource != nil && (sourceID == nil || command.manualSource == sourceID)
        }
    }

    private func enqueue(_ command: QueuedCommand) {
        guard canControl, !isBusy || commandTask != nil else { return }
        commandRevision += 1
        if command.request.mode == .automatic {
            // A reset must follow the active write even when its slider draft
            // was queued during that write. Later deliberate edits can follow it.
            pendingCommands.removeAll()
        } else {
            // Keep an already queued reset ahead of the newest desired target.
            pendingCommands.removeAll { $0.request.mode != .automatic }
        }
        pendingCommands.append(command)
        guard commandTask == nil else { return }
        isBusy = true
        commandTask = Task { [weak self] in
            guard let self else { return }
            defer { self.commandTask = nil; self.isBusy = false }
            while !self.pendingCommands.isEmpty, !self.stopping, self.canControl {
                let next = self.pendingCommands.removeFirst()
                do {
                    let value = try await self.client.apply(next.request)
                    self.commandError = nil
                    self.setOwnsControl(!value.controlledFanIDs.isEmpty)
                    self.accept(value)
                    self.ensureHeartbeat()
                    self.ensurePolling()
                } catch { self.commandError = error.localizedDescription; self.message = self.commandError }
            }
            self.pendingCommands.removeAll()
        }
    }

    func allAutomatic() {
        guard let snapshot else { return }
        let ids = snapshot.fans.filter(\.controlSupported).map(\.id)
        guard !ids.isEmpty else { return }
        apply(fanIDs: ids, mode: .automatic)
    }

    private func ensureHeartbeat() {
        guard ownsControl, heartbeat == nil else { return }
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                guard let self else { return }
                do { try await self.client.heartbeat(self.sessionID) }
                catch {
                    self.message = "Связь с управлением потеряна. Служба возвращает автоматический режим после истечения сеанса."
                    self.ownsControl = false
                    self.heartbeat = nil
                    self.stopPollingIfIdle()
                    return
                }
            }
        }
    }

    private func suspendControl() async {
        guard !preview else { return }
        stopping = true
        cancelPendingManual()
        pendingCommands.removeAll()
        commandRevision += 1
        await commandTask?.value
        heartbeat?.cancel(); heartbeat = nil
        if ownsControl {
            do { try await client.release(sessionID); ownsControl = false }
            catch { message = error.localizedDescription }
        }
        polling?.cancel(); polling = nil
        client.disconnect()
    }

    func shutdown() async { await suspendControl() }

    func uninstallControl() {
        guard !preview, !isBusy else { return }
        cancelPendingManual()
        isBusy = true
        serviceMutationInProgress = true
        commandRevision += 1
        commandTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.pendingCommands.removeAll()
                self.commandTask = nil; self.serviceMutationInProgress = false; self.isBusy = false
            }
            do {
                // Do not remove recovery while hardware may still be under our control.
                if self.ownsControl || self.service.status == .enabled {
                    try await self.client.release(self.sessionID)
                }
                self.ownsControl = false
                self.heartbeat?.cancel(); self.heartbeat = nil
                if let unregister = self.unregisterServiceOverride { try await unregister() }
                else { try await self.service.unregister() }
                self.client.disconnect()
                await self.refreshStatus(force: true)
            } catch { self.message = error.localizedDescription }
        }
    }
}

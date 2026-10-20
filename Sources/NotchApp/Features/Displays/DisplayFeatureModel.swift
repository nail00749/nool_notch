import AppKit
import Combine

struct DisplayPreferences: Codable {
    var defaultDimming: Double = 1
    var restoreModesOnReconnect = false
    var dimmingByUUID: [String: Double] = [:]
    var modesByUUID: [String: SavedDisplayMode] = [:]
    var softwareBrightnessUUIDs: Set<String>?
    var imageAdjustmentsByUUID: [String: DisplayImageAdjustment]?
}

/// Mode IDs are session-specific. Persist the mode's semantic identity instead.
struct SavedDisplayMode: Codable, Equatable {
    let width: Int
    let height: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let refreshRate: Double

    init(_ mode: DisplayModeOption) {
        width = mode.width; height = mode.height
        pixelWidth = mode.pixelWidth; pixelHeight = mode.pixelHeight
        refreshRate = mode.refreshRate
    }

    func matches(_ mode: DisplayModeOption) -> Bool {
        width == mode.width && height == mode.height && pixelWidth == mode.pixelWidth &&
        pixelHeight == mode.pixelHeight && abs(refreshRate - mode.refreshRate) < 0.01
    }
}

extension UserDefaultsAppPreferences {
    static let displayManagementKey = "displays.management.v1"
}

/// Cheap CoreGraphics view of the display configuration a refresh would read.
/// Gamma writes and Dock or menu bar changes post screen-parameter notifications
/// without changing it, so they must not trigger another refresh and gamma write.
struct DisplayScreenSignature: Equatable {
    struct Entry: Equatable {
        let displayID: CGDirectDisplayID
        let isActive: Bool
        let isMain: Bool
        let bounds: CGRect
        let mirrorMasterID: CGDirectDisplayID
        let modeID: Int32?
        let pixelSize: CGSize
        let refreshRate: Double
        let rotation: Double
        let colorSpace: CGColorSpace?
    }

    let entries: [Entry]

    static func current() -> DisplayScreenSignature {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return .init(entries: []) }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return .init(entries: []) }
        return .init(entries: ids.prefix(Int(count)).map { id in
            let mode = CGDisplayCopyDisplayMode(id)
            return Entry(displayID: id, isActive: CGDisplayIsActive(id) != 0, isMain: CGDisplayIsMain(id) != 0,
                         bounds: CGDisplayBounds(id), mirrorMasterID: CGDisplayMirrorsDisplay(id),
                         modeID: mode?.ioDisplayModeID,
                         pixelSize: CGSize(width: mode?.pixelWidth ?? 0, height: mode?.pixelHeight ?? 0),
                         refreshRate: mode?.refreshRate ?? 0, rotation: CGDisplayRotation(id),
                         colorSpace: CGDisplayCopyColorSpace(id))
        })
    }
}

@MainActor
final class DisplayFeatureModel: ObservableObject {
    static let shared = DisplayFeatureModel(hardware: DynamicDisplayHardwareBrightnessService(),
                                           colorProfiles: ColorSyncDisplayColorProfileService(),
                                           systemSettings: DisplaySystemSettingsModel(service: DynamicDisplaySystemSettingsService()),
                                           hdr: DynamicDisplayHDRService(),
                                           extraBrightness: MetalDisplayExtraBrightnessService(),
                                           referencePresets: DynamicDisplayReferencePresetService(),
                                           smoothScaling: SystemDisplaySmoothScalingService(),
                                           cursorCrossing: DisplayCursorCrossingModel(service: PublicDisplayCursorCrossingService()))
    @Published private(set) var displays: [DisplayInfo] = []
    @Published private(set) var enabled = false
    @Published private(set) var isPending = false {
        didSet { updateCursorCrossingSuspension() }
    }
    @Published private(set) var rollbackFailed = false
    @Published private(set) var disconnectPolicy: DisplayDisconnectPolicy
    @Published private var keptDisconnectedUUIDs: Set<String> = []
    @Published private var safetyEnabledUUIDs: Set<String> = []
    @Published var isArranging = false
    @Published var isManagingPresets = false
    @Published var adjustingDisplayUUID: String?
    let keepAwake = DisplayKeepAwakeModel()
    let systemSettings: DisplaySystemSettingsModel
    let cursorCrossing: DisplayCursorCrossingModel
    private var displaysSleeping = false
    private let hdr: (any DisplayHDRServing)?
    private let extraBrightness: (any DisplayExtraBrightnessServing)?
    @Published private var hdrStates: [String: DisplaySystemToggleState] = [:]
    private var hdrLoading: Set<String> = []
    private var hdrEpoch = 0
    private var hdrRefreshAgain = false
    private let referencePresets: (any DisplayReferencePresetServing)?
    private let smoothScaling: (any DisplaySmoothScalingServing)?
    @Published private var referenceStates: [String: DisplayReferencePresetState] = [:]
    @Published private var smoothScalingStates: [String: DisplaySmoothScalingState] = [:]
    @Published private var advancedLoading: Set<String> = []
    private var advancedEpoch = 0
    private var advancedRefreshAgain = false
    @Published private var advancedErrors: [String: String] = [:]
    @Published private(set) var isApplyingPreset = false {
        didSet { updateCursorCrossingSuspension() }
    }
    @Published private(set) var presets: [DisplayPreset] = []
    @Published private var colorStates: [String: DisplayColorProfileState] = [:]
    @Published private var colorLoading: Set<String> = []
    private let colorProfiles: (any DisplayColorProfileServing)?
    private var displayOperation: Task<Void, Never>?
    private var operationCancelled = false
    private var colorEpoch = 0
    private var recoveryAppearance: AppearanceRecovery?

    private struct AppearanceRecovery {
        let preferences: DisplayPreferences
        var profiles: [String: String]
        var readings: [String: DisplayHardwareBrightnessReading]
    }
    @Published var errorMessage: String?
    @Published var defaultDimming: Double {
        didSet {
            preferences.defaultDimming = Self.factor(defaultDimming)
            persist()
            if enabled { applyDimming() }
        }
    }
    @Published var restoreModesOnReconnect: Bool {
        didSet { preferences.restoreModesOnReconnect = restoreModesOnReconnect; persist() }
    }
    @Published private var dimmingByUUID: [String: Double]
    @Published private var hardwareReadings: [String: DisplayHardwareBrightnessReading] = [:]
    private let hardware: (any DisplayHardwareBrightnessServing)?
    private var hardwareTargets: [String: DisplayHardwareTarget] = [:]
    private var hardwareUnavailable: Set<String> = []
    private var hardwareEpochs: [String: Int] = [:]
    private var hardwareProbes: [String: Task<Void, Never>] = [:]
    private var hardwareWrites: [String: Task<Void, Never>] = [:]
    private var hardwareDesired: [String: (value: Double, revision: Int)] = [:]
    private var hardwareRevision = 0
    private var hardwareInputRevisions: [String: Int] = [:]
    private var preferences: DisplayPreferences
    private let defaults: UserDefaults
    private let service: any DisplayConfigurationServing
    private let brightness: any DisplayBrightnessServing
    let revertController: DisplayRevertController
    private var observations: [AnyCancellable] = []
    private let notifications: NotificationCenter
    private let screenSignature: () -> DisplayScreenSignature
    private let screenChangeDelay: RunLoop.SchedulerTimeType.Stride
    private var refreshedScreenSignature: DisplayScreenSignature?
    private var pending: Pending?
    private var isRefreshing = false

    private struct Pending {
        let snapshot: DisplayConfigurationSnapshot
        let change: DisplayChange
        let uuid: String
        let displayID: UInt32
        let selectedMode: DisplayModeOption?
        let participants: [String: UInt32]
        var preset: DisplayPreset? = nil
        var hdr: HDRTrial? = nil
        var referencePreset: String? = nil
    }

    private struct HDRTrial {
        let original: Bool
        let desired: Bool
    }

    init(service: any DisplayConfigurationServing = CoreGraphicsDisplayConfigurationService(),
         brightness: any DisplayBrightnessServing = GammaDisplayBrightnessService(),
         defaults: UserDefaults = .standard,
         revertController: DisplayRevertController = DisplayRevertController(),
         hardware: (any DisplayHardwareBrightnessServing)? = nil,
         colorProfiles: (any DisplayColorProfileServing)? = nil,
         systemSettings: DisplaySystemSettingsModel? = nil,
         hdr: (any DisplayHDRServing)? = nil,
         extraBrightness: (any DisplayExtraBrightnessServing)? = nil,
         referencePresets: (any DisplayReferencePresetServing)? = nil,
         smoothScaling: (any DisplaySmoothScalingServing)? = nil,
         cursorCrossing: DisplayCursorCrossingModel? = nil,
         notifications: NotificationCenter = .default,
         screenSignature: @escaping () -> DisplayScreenSignature = DisplayScreenSignature.current,
         screenChangeDelay: RunLoop.SchedulerTimeType.Stride = .milliseconds(120)) {
        self.service = service; self.brightness = brightness; self.defaults = defaults
        self.notifications = notifications
        self.screenSignature = screenSignature
        self.screenChangeDelay = screenChangeDelay
        disconnectPolicy = service.disconnectPolicy
        self.hardware = hardware
        self.colorProfiles = colorProfiles
        self.systemSettings = systemSettings ?? DisplaySystemSettingsModel()
        self.hdr = hdr
        self.extraBrightness = extraBrightness
        self.referencePresets = referencePresets
        self.smoothScaling = smoothScaling
        self.cursorCrossing = cursorCrossing ?? DisplayCursorCrossingModel(defaults: defaults)
        presets = DisplayPresetStore(defaults: defaults).load()
        self.revertController = revertController
        let stored = defaults.data(forKey: UserDefaultsAppPreferences.displayManagementKey)
            .flatMap { try? JSONDecoder().decode(DisplayPreferences.self, from: $0) } ?? DisplayPreferences()
        preferences = stored
        defaultDimming = Self.factor(stored.defaultDimming)
        restoreModesOnReconnect = stored.restoreModesOnReconnect
        dimmingByUUID = stored.dimmingByUUID.mapValues(Self.factor)
        self.systemSettings.canModify = { [weak self] in
            guard let self else { return false }
            return self.enabled && !self.isPending && !self.isApplyingPreset
        }
        self.systemSettings.availabilityOverride = { [weak self] control, target in
            guard control == .autoBrightness, let self, let target,
                  self.displays.contains(where: { $0.id == target.uuid && $0.displayID == target.displayID && $0.isEnabled }),
                  let state = self.referenceStates[target.uuid],
                  state.options.first(where: { $0.id == state.selectedID })?.allowsAutoBrightness == false else { return nil }
            return "Автояркость недоступна в выбранном пресете Apple."
        }
        self.extraBrightness?.onStateChange = { [weak self] in self?.objectWillChange.send() }
        // Night Shift and True Tone use system color adaptation independently
        // of the gamma table. Keep our original calibration baseline intact.
    }

    func start() {
        guard !enabled else { return }
        enabled = true
        displaysSleeping = false
        // Reconfiguration arrives as a burst; one refresh after it settles is enough.
        notifications.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .debounce(for: screenChangeDelay, scheduler: RunLoop.main).sink { [weak self] _ in
                self?.screenParametersChanged()
            }.store(in: &observations)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: RunLoop.main).sink { [weak self] _ in
                guard let self, self.enabled else { return }
                self.extraBrightness?.stop()
                self.displaysSleeping = false
                self.service.resetDisconnectReconciliationAttempts()
                self.brightness.invalidate()
                self.resetHardware()
                self.refresh()
                self.updateCursorCrossingSuspension()
                self.cursorCrossing.start(displays: self.displays)
                self.applyDimming()
                Task { [weak self] in await self?.refreshHDR() }
                Task { [weak self] in await self?.refreshAdvancedSettings() }
            }.store(in: &observations)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)
            .merge(with: NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.screensDidSleepNotification))
            .receive(on: RunLoop.main).sink { [weak self] _ in
                self?.extraBrightness?.stop()
                self?.displaysSleeping = true
                self?.updateCursorCrossingSuspension()
            }.store(in: &observations)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.screensDidWakeNotification)
            .receive(on: RunLoop.main).sink { [weak self] _ in
                guard let self, self.enabled else { return }
                self.displaysSleeping = false
                self.service.resetDisconnectReconciliationAttempts()
                self.refresh()
                self.updateCursorCrossingSuspension()
                self.cursorCrossing.start(displays: self.displays)
            }.store(in: &observations)
        refresh()
        applyDimming()
        systemSettings.start(displays: displays)
        updateCursorCrossingSuspension()
        cursorCrossing.start(displays: displays)
    }

    func stop() {
        cursorCrossing.stop()
        extraBrightness?.stop()
        keepAwake.stop()
        systemSettings.stop()
        adjustingDisplayUUID = nil
        guard enabled else { return }
        // Revert a trial before dropping the service lifecycle.
        operationCancelled = true
        colorEpoch += 1
        hdrEpoch += 1
        hdrLoading.removeAll()
        hdrRefreshAgain = false
        invalidateAdvancedSettings()
        if !isApplyingPreset { cancelChange() }
        isArranging = false
        isManagingPresets = false
        if !isApplyingPreset {
            do { try service.restoreManagedDisplays() }
            catch { errorMessage = error.localizedDescription }
        }
        observations.removeAll()
        resetHardware()
        brightness.restore()
        enabled = false
        displays = []
    }

    private func updateCursorCrossingSuspension() {
        cursorCrossing.setSuspended(isPending || isApplyingPreset || displaysSleeping)
    }

    func refresh() {
        guard enabled, !isRefreshing else { return }
        isRefreshing = true
        // Read before the service so a change during refresh still differs next time.
        refreshedScreenSignature = screenSignature()
        defer {
            isRefreshing = false
            updateCursorCrossingSuspension()
        }
        do {
            let previous = Set(displays.map(\.id))
            let previousTargets = Dictionary(uniqueKeysWithValues: displays.filter(\.isEnabled).map { ($0.id, $0.displayID) })
            var managedPowerAttempted = false
            var disconnectError: String?
            if pending == nil, !isApplyingPreset, !displaysSleeping {
                do {
                    _ = try service.reconcileDisconnectIntents(beforeChanging: { [self] in
                        managedPowerAttempted = true
                        extraBrightness?.stop()
                        cursorCrossing.setSuspended(true)
                    })
                } catch { disconnectError = error.localizedDescription }
                // Failed private commits can still have changed the native state.
                if managedPowerAttempted { brightness.invalidate(); resetHardware() }
            }
            displays = try service.displays()
            updateDisconnectPolicyState()
            cursorCrossing.update(displays: displays)
            let currentTargets = Dictionary(uniqueKeysWithValues: displays.filter(\.isEnabled).map { ($0.id, $0.displayID) })
            if previousTargets != currentTargets {
                hdrEpoch += 1
                hdrLoading.removeAll()
                hdrRefreshAgain = false
                hdrStates = hdrStates.filter { currentTargets[$0.key] == previousTargets[$0.key] }
                invalidateAdvancedSettings()
                referenceStates = referenceStates.filter { currentTargets[$0.key] == previousTargets[$0.key] }
                smoothScalingStates = smoothScalingStates.filter { currentTargets[$0.key] == previousTargets[$0.key] }
                Task { [weak self] in await self?.refreshAdvancedSettings() }
            }
            extraBrightness?.reconcile(displays.filter(\.isEnabled).map(hardwareTarget))
            systemSettings.updateDisplays(displays)
            hdrStates = hdrStates.filter { uuid, _ in displays.contains { $0.id == uuid && $0.isEnabled } }
            if hdr != nil, !isApplyingPreset, displays.contains(where: { $0.isEnabled && hdrStates[$0.id] == nil }) {
                Task { [weak self] in await self?.refreshHDR() }
            }
            if preferences.softwareBrightnessUUIDs == nil {
                preferences.softwareBrightnessUUIDs = Set(dimmingByUUID.filter { $0.value < 1 }.map(\.key))
                    .union(displays.filter { softwareDimming(for: $0) < 1 }.map(\.id))
                if defaults.data(forKey: UserDefaultsAppPreferences.displayManagementKey) != nil { persist() }
            }
            reconcileHardware()
            if managedPowerAttempted { applyDimming() }
            if let disconnectError { errorMessage = disconnectError }
            colorStates = colorStates.filter { key, _ in displays.contains { $0.id == key && $0.isEnabled } }
            if colorProfiles != nil, displays.contains(where: { $0.isEnabled && colorStates[$0.id] == nil }) {
                Task { [weak self] in await self?.refreshColorProfiles() }
            }
            if let pending, !participantsMatch(pending, displays: displays), !rollbackFailed, !isApplyingPreset {
                // The trial display disappeared. Restore surviving displays (e.g. mirror master).
                cancelChange()
            }
            revertController.reposition()
            if restoreModesOnReconnect, pending == nil {
                // Restore one display at a time through the same safe confirmation flow.
                for display in displays where display.isEnabled && !previous.contains(display.id) {
                    if let saved = preferences.modesByUUID[display.id],
                       let mode = display.modes.first(where: saved.matches),
                       display.currentMode?.id != mode.id {
                        request(.mode(displayID: display.displayID, modeID: mode.id), display: display)
                        break
                    }
                }
            }
        } catch {
            cursorCrossing.update(displays: [])
            errorMessage = error.localizedDescription
        }
    }

    private func screenParametersChanged() {
        // applyDimming's gamma write itself posts this notification; without the
        // signature check the model would loop refresh → gamma write → refresh.
        guard enabled, screenSignature() != refreshedScreenSignature else { return }
        brightness.invalidate()
        refresh()
        applyDimming()
        Task { [weak self] in await self?.refreshHDR() }
        Task { [weak self] in await self?.refreshAdvancedSettings() }
    }

    func dimming(for display: DisplayInfo) -> Double {
        if isHardwareBrightness(for: display), let reading = hardwareReadings[display.id] {
            return reading.value
        }
        return softwareDimming(for: display)
    }

    func imageAdjustment(for display: DisplayInfo) -> DisplayImageAdjustment {
        (preferences.imageAdjustmentsByUUID?[display.id] ?? .neutral).sanitized
    }

    func setImageAdjustment(_ adjustment: DisplayImageAdjustment, for display: DisplayInfo) {
        guard enabled, !isPending, !isApplyingPreset, !systemSettings.isBusy, display.isEnabled,
              displays.contains(where: { $0.id == display.id && $0.displayID == display.displayID && $0.isEnabled }) else { return }
        do {
            let value = adjustment.sanitized
            try brightness.setAppearance(dimming: isHardwareBrightness(for: display) ? 1 : softwareDimming(for: display),
                                         adjustment: value, displayID: display.displayID)
            if preferences.imageAdjustmentsByUUID == nil { preferences.imageAdjustmentsByUUID = [:] }
            preferences.imageAdjustmentsByUUID?[display.id] = value
            persist()
            errorMessage = nil
            objectWillChange.send()
        } catch { errorMessage = error.localizedDescription }
    }

    func setDimming(_ factor: Double, for display: DisplayInfo) {
        guard enabled, !isPending, !isApplyingPreset, display.isEnabled,
              displays.contains(where: { $0.id == display.id && $0.displayID == display.displayID && $0.isEnabled }) else { return }
        if isHardwareBrightness(for: display), let reading = hardwareReadings[display.id] {
            let value = Self.factor(factor)
            hardwareReadings[display.id] = DisplayHardwareBrightnessReading(value: value, backend: reading.backend)
            hardwareRevision += 1
            hardwareInputRevisions[display.id] = hardwareRevision
            hardwareDesired[display.id] = (value, hardwareRevision)
            scheduleHardwareWrite(for: display, backend: reading.backend)
            return
        }
        setSoftwareDimming(factor, for: display)
    }

    private func setSoftwareDimming(_ factor: Double, for display: DisplayInfo) {
        do {
            let value = Self.factor(factor)
            try brightness.setAppearance(dimming: value, adjustment: imageAdjustment(for: display), displayID: display.displayID)
            dimmingByUUID[display.id] = value
            preferences.dimmingByUUID = dimmingByUUID
            if preferences.softwareBrightnessUUIDs != nil {
                preferences.softwareBrightnessUUIDs?.insert(display.id)
            }
            persist()
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func request(_ change: DisplayChange, display: DisplayInfo) {
        guard enabled, pending == nil, !isApplyingPreset, !systemSettings.isBusy else { return }
        let liveDisplays: [DisplayInfo]
        do { liveDisplays = try service.displays() }
        catch { errorMessage = error.localizedDescription; return }
        guard let liveDisplay = liveDisplays.first(where: { $0.id == display.id && $0.displayID == display.displayID }) else {
            errorMessage = DisplayServiceError.disconnected.localizedDescription
            refresh()
            return
        }
        let selectedMode: DisplayModeOption?
        switch change {
        case let .mode(id, modeID):
            guard liveDisplay.isEnabled, id == liveDisplay.displayID,
                  let mode = liveDisplay.modes.first(where: { $0.id == modeID }) else { return }
            selectedMode = mode
        case let .main(id):
            guard liveDisplay.isEnabled, id == liveDisplay.displayID else { return }
            selectedMode = nil
        case let .mirror(id, masterID):
            guard liveDisplay.isEnabled, id == liveDisplay.displayID, masterID != id,
                  masterID == nil || liveDisplays.contains(where: { $0.displayID == masterID && $0.isEnabled }) else { return }
            selectedMode = nil
        case let .enabled(id, state):
            guard id == liveDisplay.displayID, liveDisplay.isEnabled != state,
                  service.canChangePower(for: liveDisplay) else { return }
            guard state || Self.canDisable(liveDisplay, among: liveDisplays) else {
                errorMessage = "Нельзя отключить последний доступный экран."
                return
            }
            selectedMode = nil
        case .arrangement:
            // Arrangement has multiple identity-bound participants, not one target.
            return
        }
        beginChange(change, display: liveDisplay, selectedMode: selectedMode,
                    participants: Dictionary(uniqueKeysWithValues: liveDisplays.map { ($0.id, $0.displayID) }))
    }

    func canTogglePower(for display: DisplayInfo) -> Bool {
        enabled && !isPending && !isApplyingPreset && service.canChangePower(for: display) &&
        displays.contains(where: { $0.id == display.id && $0.displayID == display.displayID }) &&
        (!display.isEnabled || Self.canDisable(display, among: displays))
    }

    func setDisplayEnabled(_ state: Bool, for display: DisplayInfo) {
        request(.enabled(displayID: display.displayID, enabled: state), display: display)
    }

    func isKeptDisconnected(for display: DisplayInfo) -> Bool {
        keptDisconnectedUUIDs.contains { $0.caseInsensitiveCompare(display.id) == .orderedSame }
    }

    func isSafetyEnabled(for display: DisplayInfo) -> Bool {
        safetyEnabledUUIDs.contains { $0.caseInsensitiveCompare(display.id) == .orderedSame }
    }

    private func updateDisconnectPolicyState() {
        disconnectPolicy = service.disconnectPolicy
        keptDisconnectedUUIDs = service.keptDisconnectedUUIDs
        safetyEnabledUUIDs = service.safetyEnabledUUIDs
    }

    func setDisconnectPolicy(_ policy: DisplayDisconnectPolicy) {
        guard !isPending, !isApplyingPreset, !systemSettings.isBusy else { return }
        do {
            try service.setDisconnectPolicy(policy)
            updateDisconnectPolicyState()
            errorMessage = nil
            if enabled { refresh() }
            else if policy == .restoreOnExit { try service.restoreManagedDisplays() }
        } catch { errorMessage = error.localizedDescription }
    }

    /// Safety may temporarily light a retained screen. Explicitly keeping that
    /// already-on screen changes intent only and needs no second power trial.
    func keepDisplayEnabled(_ display: DisplayInfo) {
        guard enabled, !isPending, !isApplyingPreset, !systemSettings.isBusy,
              display.isEnabled, isKeptDisconnected(for: display) else { return }
        do {
            let live = try service.displays()
            guard live.contains(where: { $0.id == display.id && $0.displayID == display.displayID && $0.isEnabled }) else {
                throw DisplayServiceError.disconnected
            }
            try service.confirmPowerState(uuid: display.id, enabled: true)
            updateDisconnectPolicyState()
            errorMessage = nil
            refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    private static func canDisable(_ display: DisplayInfo, among displays: [DisplayInfo]) -> Bool {
        // A mirror follower is not an independent usable desktop. If its master
        // is disabled too, it cannot serve as the confirmation/recovery screen.
        displays.contains { $0.isEnabled && $0.id != display.id && $0.mirrorMasterID == nil }
    }

    func requestArrangement(_ placements: [DisplayPlacement]) {
        guard enabled, pending == nil, !isApplyingPreset, !systemSettings.isBusy else { return }
        extraBrightness?.stop()
        cursorCrossing.setSuspended(true)
        defer { updateCursorCrossingSuspension() }
        var original: DisplayConfigurationSnapshot?
        do {
            let live = try service.displays()
            let participants = live.filter { $0.isEnabled && $0.mirrorMasterID == nil }
            let expected = displays.filter { $0.isEnabled && $0.mirrorMasterID == nil }
            guard participants.count >= 2,
                  Dictionary(uniqueKeysWithValues: participants.map { ($0.id, $0.displayID) }) ==
                  Dictionary(uniqueKeysWithValues: expected.map { ($0.id, $0.displayID) }),
                  Set(placements.map(\.uuid)) == Set(participants.map(\.id)),
                  placements.count == participants.count,
                  participants.contains(where: \.isMain) else {
                errorMessage = "Состав дисплеев изменился. Откройте расположение заново."
                refresh()
                return
            }
            // Arrangement is an explicit save from the editor. No second
            // confirmation or timer; keep a snapshot only for failure recovery.
            let snapshot = try service.snapshot()
            original = snapshot
            try service.apply(.arrangement(placements), permanently: true)
            errorMessage = nil
            isArranging = false
            refresh()
        } catch {
            let message = error.localizedDescription
            if let original {
                do { try service.restore(original) }
                catch {
                    let participants = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0.displayID) })
                    if let main = displays.first(where: \.isMain) {
                        pending = Pending(snapshot: original, change: .arrangement(placements), uuid: main.id,
                                          displayID: main.displayID, selectedMode: nil, participants: participants)
                        isPending = true
                        rollbackFailed = true
                    }
                    errorMessage = "\(message) Не удалось вернуть исходное расположение: \(error.localizedDescription)"
                    return
                }
            }
            errorMessage = message
        }
    }

    private func beginChange(_ change: DisplayChange, display: DisplayInfo,
                             selectedMode: DisplayModeOption?, participants: [String: UInt32]) {
        extraBrightness?.stop()
        cursorCrossing.setSuspended(true)
        defer { updateCursorCrossingSuspension() }
        do {
            let snapshot = try service.snapshot()
            // Private commits may mutate an output and still report failure.
            // Own recovery before submitting the first native change.
            pending = Pending(snapshot: snapshot, change: change, uuid: display.id,
                              displayID: display.displayID, selectedMode: selectedMode, participants: participants)
            isPending = true
            try service.apply(change, permanently: false)
            errorMessage = nil
            let survivors = try service.displays().filter(\.isEnabled)
            let confirmationDisplay = survivors.first(where: { $0.displayID == display.displayID }) ??
                survivors.first(where: \.isMain) ?? survivors.first
            revertController.present(displayID: confirmationDisplay?.displayID ?? display.displayID,
                                     confirm: { [weak self] in self?.confirmChange() },
                                     revert: { [weak self] in self?.cancelChange() })
            refresh()
        } catch {
            let message = error.localizedDescription
            if pending != nil { cancelChange() }
            errorMessage = rollbackFailed ? "\(message) \(errorMessage ?? "")" : message
        }
    }

    func confirmChange() {
        guard let pending else { return }
        // Reference presets commit immediately after verified readback. A retained
        // snapshot here only means recovery failed, never a main-display change.
        guard pending.referencePreset == nil else { return }
        if let trial = pending.hdr {
            guard !isApplyingPreset else { return }
            startDisplayOperation(refreshHardwareAfterward: true) { [weak self] in
                guard let self else { return }
                do {
                    try self.checkOperation()
                    let live = try self.service.displays()
                    guard self.participantsMatch(pending, displays: live),
                          let display = live.first(where: { $0.id == pending.uuid && $0.isEnabled }),
                          let hdr = self.hdr,
                          try await hdr.read(self.hardwareTarget(display)) == trial.desired else {
                        throw DisplayHDRError.notApplied
                    }
                    try self.checkOperation()
                    self.recoveryAppearance = nil
                    self.finishChange()
                    self.refresh()
                } catch {
                    let message = error.localizedDescription
                    await self.rollbackHDR()
                    if !self.rollbackFailed { self.errorMessage = message }
                }
            }
            return
        }
        if let preset = pending.preset {
            guard !isApplyingPreset else { return }
            startDisplayOperation { [weak self] in
                guard let self else { return }
                do {
                    try self.checkOperation()
                    try self.service.applyPreset(preset, permanently: true)
                    try self.service.confirmPowerStates(Dictionary(uniqueKeysWithValues: preset.displays.map { ($0.stableUUID, $0.enabled) }))
                    self.persist()
                    self.recoveryAppearance = nil
                    self.finishChange()
                    self.refresh()
                } catch {
                    let message = error.localizedDescription
                    await self.rollbackPreset()
                    self.errorMessage = message
                }
            }
            return
        }
        do {
            // Recheck live identity, rather than trusting a stale display ID.
            let live = try service.displays()
            guard participantsMatch(pending, displays: live) else {
                cancelChange(); return
            }
            let change: DisplayChange
            if case .enabled(_, let state) = pending.change {
                guard let target = live.first(where: { $0.id == pending.uuid }), target.isEnabled == state else {
                    cancelChange(); return
                }
                change = .enabled(displayID: target.displayID, enabled: state)
            } else { change = pending.change }
            try service.apply(change, permanently: true)
            if case .enabled(_, let enabled) = change {
                try service.confirmPowerState(uuid: pending.uuid, enabled: enabled)
            }
            if let mode = pending.selectedMode {
                preferences.modesByUUID[pending.uuid] = SavedDisplayMode(mode)
                persist()
            }
            finishChange()
            refresh()
        } catch {
            let message = error.localizedDescription
            cancelChange()
            errorMessage = message
        }
    }

    func cancelChange() {
        guard let pending else { return }
        if isApplyingPreset { operationCancelled = true; return }
        if pending.referencePreset != nil {
            startDisplayOperation(refreshHardwareAfterward: true) { [weak self] in await self?.rollbackReferencePreset() }
            return
        }
        if pending.hdr != nil {
            startDisplayOperation(refreshHardwareAfterward: true) { [weak self] in await self?.rollbackHDR() }
            return
        }
        if pending.preset != nil {
            startDisplayOperation { [weak self] in await self?.rollbackPreset() }
            return
        }
        do { try service.restore(pending.snapshot) }
        catch {
            // Keep the snapshot available for an explicit retry. Dropping it on
            // error would silently leave a temporary configuration in place.
            rollbackFailed = true
            errorMessage = "Не удалось вернуть настройки. \(error.localizedDescription)"
            revertController.dismiss()
            return
        }
        finishChange()
        errorMessage = nil
        refresh()
    }

    private func participantsMatch(_ pending: Pending, displays: [DisplayInfo]) -> Bool {
        pending.participants.allSatisfy { uuid, id in
            displays.contains {
                guard $0.id == uuid else { return false }
                if pending.preset != nil || pending.hdr != nil || pending.referencePreset != nil { return true }
                if case .enabled = pending.change, uuid == pending.uuid { return true }
                return $0.displayID == id
            }
        }
    }

    private func finishChange() {
        pending = nil
        isPending = false
        rollbackFailed = false
        revertController.dismiss()
    }

    private func applyDimming() {
        for display in displays where display.isEnabled {
            // Default brightness changes must leave an uncorrected hardware-controlled
            // display's calibration alone. Explicit reset is applied by the editor.
            if isHardwareBrightness(for: display), imageAdjustment(for: display).isNeutral { continue }
            do { try brightness.setAppearance(dimming: isHardwareBrightness(for: display) ? 1 : softwareDimming(for: display),
                                              adjustment: imageAdjustment(for: display), displayID: display.displayID) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func referencePresetState(for display: DisplayInfo) -> DisplayReferencePresetState? { referenceStates[display.id] }
    func smoothScalingState(for display: DisplayInfo) -> DisplaySmoothScalingState? { smoothScalingStates[display.id] }
    func isAdvancedSettingsLoading(for display: DisplayInfo) -> Bool { advancedLoading.contains(display.id) }
    func advancedSettingsError(for display: DisplayInfo) -> String? { advancedErrors[display.id] }

    private func invalidateAdvancedSettings() {
        advancedEpoch += 1
        advancedLoading.removeAll()
        advancedRefreshAgain = false
    }

    func refreshAdvancedSettings() async {
        guard enabled, !isApplyingPreset, referencePresets != nil || smoothScaling != nil else { return }
        if !advancedLoading.isEmpty { advancedRefreshAgain = true }
        defer {
            if advancedLoading.isEmpty, advancedRefreshAgain, enabled, !isApplyingPreset {
                advancedRefreshAgain = false
                Task { [weak self] in await self?.refreshAdvancedSettings() }
            }
        }
        let epoch = advancedEpoch
        for display in displays where display.isEnabled && !advancedLoading.contains(display.id) {
            advancedLoading.insert(display.id)
            var reference: DisplayReferencePresetState?
            var scaling: DisplaySmoothScalingState?
            var failures: [String] = []
            if let referencePresets {
                do { reference = try await referencePresets.read(hardwareTarget(display)) }
                catch { failures.append(error.localizedDescription) }
            }
            if let smoothScaling {
                do { scaling = try await smoothScaling.read(hardwareTarget(display)) }
                catch { failures.append(error.localizedDescription) }
            }
            guard epoch == advancedEpoch else { return }
            advancedLoading.remove(display.id)
            guard enabled, !isApplyingPreset, !Task.isCancelled else { return }
            guard displays.contains(where: { $0.id == display.id && $0.displayID == display.displayID && $0.isEnabled }) else { continue }
            referenceStates[display.id] = reference
            smoothScalingStates[display.id] = scaling
            advancedErrors[display.id] = failures.isEmpty ? nil : failures.joined(separator: " ")
        }
    }

    func setSmoothScaling(_ desired: Bool, for display: DisplayInfo) async {
        guard enabled, pending == nil, !isApplyingPreset, !systemSettings.isBusy, let smoothScaling,
              display.isEnabled, displays.contains(where: { $0.id == display.id && $0.displayID == display.displayID && $0.isEnabled }) else { return }
        extraBrightness?.stop()
        startDisplayOperation { [weak self] in
            guard let self else { return }
            do {
                try self.checkOperation()
                let state = try await smoothScaling.setEnabled(desired, for: self.hardwareTarget(display))
                // Installation is a persistent, explicit system-file change. Do not start
                // another administrator prompt to undo it if the module closes meanwhile.
                if self.enabled { self.smoothScalingStates[display.id] = state }
                self.errorMessage = nil
                self.refresh()
            } catch { self.errorMessage = error.localizedDescription }
        }
        await waitForOperations()
    }

    func selectReferencePreset(_ id: String, for requested: DisplayInfo) async {
        guard enabled, pending == nil, !isApplyingPreset, !systemSettings.isBusy, referencePresets != nil else { return }
        extraBrightness?.stop()
        startDisplayOperation(refreshHardwareAfterward: true) { [weak self] in
            guard let self else { return }
            do {
                try self.checkOperation()
                let live = try self.service.displays()
                guard let display = live.first(where: { $0.id == requested.id && $0.displayID == requested.displayID && $0.isEnabled }),
                      let referencePresets = self.referencePresets,
                      let original = try await referencePresets.read(self.hardwareTarget(display)),
                      original.options.contains(where: { $0.id == id }) else { throw DisplayServiceError.disconnected }
                try self.checkOperation()
                guard original.selectedID != id else { return }
                let snapshot = try self.service.snapshot()
                var profiles: [String: String] = [:]
                if let colorProfiles = self.colorProfiles {
                    for participant in live where participant.isEnabled {
                        profiles[participant.id] = try await colorProfiles.state(for: participant).selectedID
                        try self.checkOperation()
                    }
                }
                guard try self.service.displays() == live else { throw DisplayServiceError.disconnected }
                // A reference mode can change brightness independently of the slider.
                // Capture native state now, including when the first panel probe was
                // cancelled by this operation or another app changed brightness.
                var readings: [String: DisplayHardwareBrightnessReading] = [:]
                if let hardware = self.hardware {
                    readings[display.id] = try await hardware.read(self.hardwareTarget(display))
                    try self.checkOperation()
                }
                guard try self.service.displays() == live else { throw DisplayServiceError.disconnected }
                self.recoveryAppearance = AppearanceRecovery(preferences: self.preferences, profiles: profiles, readings: readings)
                self.pending = Pending(snapshot: snapshot, change: .main(displayID: display.displayID), uuid: display.id,
                    displayID: display.displayID, selectedMode: nil,
                    participants: Dictionary(uniqueKeysWithValues: live.map { ($0.id, $0.displayID) }), referencePreset: original.selectedID)
                self.isPending = true
                let state = try await referencePresets.select(id, for: self.hardwareTarget(display))
                try self.checkOperation()
                guard state.selectedID == id else { throw DisplayServiceError.unavailableMode }
                self.referenceStates[display.id] = state
                self.recoveryAppearance = nil
                self.finishChange()
                self.brightness.invalidate()
                self.colorStates.removeAll()
                self.resetHardware()
                self.refresh()
                self.applyDimming()
                await self.systemSettings.refresh()
                self.errorMessage = nil
            } catch {
                let message = error.localizedDescription
                if self.pending?.referencePreset != nil { await self.rollbackReferencePreset() }
                else { self.recoveryAppearance = nil }
                if !self.rollbackFailed { self.errorMessage = message }
            }
        }
        await waitForOperations()
    }

    private func rollbackReferencePreset() async {
        guard let pending, let original = pending.referencePreset, let referencePresets else { return }
        var failure: Error?
        do {
            guard let display = try service.displays().first(where: { $0.id == pending.uuid && $0.isEnabled }) else { throw DisplayServiceError.disconnected }
            let state = try await referencePresets.restore(original, for: hardwareTarget(display))
            guard state.selectedID == original else { throw DisplayServiceError.unavailableMode }
            referenceStates[display.id] = state
        } catch { failure = error }
        await rollbackPreset(initialFailure: failure)
    }

    func hdrState(for display: DisplayInfo) -> DisplaySystemToggleState {
        guard display.isEnabled else { return .unavailable }
        return hdrStates[display.id] ?? (hdr == nil ? .unavailable : .loading)
    }

    func extraBrightnessState(for display: DisplayInfo) -> DisplaySystemToggleState {
        guard display.isEnabled, let extraBrightness else { return .unavailable }
        let state = extraBrightness.capability(for: hardwareTarget(display))
        return .init(value: state.isSupported ? state.isEnabled : nil, unavailableReason: state.unavailableReason)
    }

    func setExtraBrightness(_ enabled: Bool, for display: DisplayInfo) async {
        guard self.enabled, pending == nil, !isApplyingPreset, !systemSettings.isBusy,
              display.isEnabled, let extraBrightness,
              displays.contains(where: { $0.id == display.id && $0.displayID == display.displayID && $0.isEnabled }) else { return }
        do {
            try extraBrightness.setEnabled(enabled, for: hardwareTarget(display))
            objectWillChange.send()
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func refreshHDR() async {
        guard enabled, !isApplyingPreset, let hdr else { return }
        if !hdrLoading.isEmpty { hdrRefreshAgain = true }
        defer {
            if hdrLoading.isEmpty, hdrRefreshAgain, enabled, !isApplyingPreset {
                hdrRefreshAgain = false
                Task { [weak self] in await self?.refreshHDR() }
            }
        }
        let token = hdrEpoch
        for display in displays where display.isEnabled && !hdrLoading.contains(display.id) {
            hdrLoading.insert(display.id)
            let state: DisplaySystemToggleState
            do {
                if let actual = try await hdr.read(hardwareTarget(display)) {
                    state = .init(value: actual, unavailableReason: nil)
                } else {
                    state = .init(value: nil, unavailableReason: display.isBuiltin
                        ? "Встроенный XDR-дисплей не имеет отдельного переключателя HDR."
                        : "HDR недоступен для этого дисплея или текущего подключения.")
                }
            } catch { state = .init(value: nil, unavailableReason: error.localizedDescription) }
            guard token == hdrEpoch else { return }
            hdrLoading.remove(display.id)
            guard enabled, !isApplyingPreset, !Task.isCancelled else { return }
            guard displays.contains(where: { $0.id == display.id && $0.displayID == display.displayID && $0.isEnabled }) else { continue }
            hdrStates[display.id] = state
        }
    }

    func requestHDR(_ desired: Bool, for display: DisplayInfo) async {
        guard enabled, pending == nil, !isApplyingPreset, !systemSettings.isBusy, hdr != nil else { return }
        extraBrightness?.stop()
        startDisplayOperation(refreshHardwareAfterward: true) { [weak self] in await self?.performHDR(desired, display: display) }
        await waitForOperations()
    }

    private func performHDR(_ desired: Bool, display requested: DisplayInfo) async {
        do {
            try checkOperation()
            let live = try service.displays()
            guard let display = live.first(where: {
                $0.id == requested.id && $0.displayID == requested.displayID && $0.isEnabled
            }), let hdr, let original = try await hdr.read(hardwareTarget(display)) else {
                throw DisplayHDRError.unavailable
            }
            try checkOperation()
            guard original != desired else { return }
            let snapshot = try service.snapshot()
            var profiles: [String: String] = [:]
            if let colorProfiles {
                for participant in live where participant.isEnabled {
                    profiles[participant.id] = try await colorProfiles.state(for: participant).selectedID
                    try checkOperation()
                }
            }
            guard try service.displays() == live else { throw DisplayHDRError.disconnected }
            recoveryAppearance = AppearanceRecovery(preferences: preferences, profiles: profiles, readings: hardwareReadings)
            pending = Pending(snapshot: snapshot, change: .main(displayID: display.displayID), uuid: display.id,
                displayID: display.displayID, selectedMode: nil,
                participants: Dictionary(uniqueKeysWithValues: live.map { ($0.id, $0.displayID) }),
                hdr: HDRTrial(original: original, desired: desired))
            isPending = true
            let actual = try await hdr.setHDR(desired, for: hardwareTarget(display))
            try checkOperation()
            guard actual == desired else { throw DisplayHDRError.notApplied }
            hdrStates[display.id] = .init(value: actual, unavailableReason: nil)
            brightness.invalidate()
            colorStates.removeAll()
            refresh()
            applyDimming()
            try checkOperation()
            let survivors = displays.filter { $0.isEnabled && $0.mirrorMasterID == nil }
            guard let confirmation = survivors.first(where: { $0.id != display.id }) ?? survivors.first else {
                throw DisplayHDRError.disconnected
            }
            revertController.present(displayID: confirmation.displayID,
                confirm: { [weak self] in self?.confirmChange() }, revert: { [weak self] in self?.cancelChange() })
            errorMessage = nil
        } catch {
            let message = error.localizedDescription
            if pending?.hdr != nil { await rollbackHDR() }
            else { recoveryAppearance = nil }
            if !rollbackFailed { errorMessage = message }
        }
    }

    private func rollbackHDR() async {
        guard let pending, let trial = pending.hdr, let hdr else { return }
        var failure: Error?
        do {
            guard let display = try service.displays().first(where: { $0.id == pending.uuid && $0.isEnabled }) else {
                throw DisplayHDRError.disconnected
            }
            guard try await hdr.restoreHDR(trial.original, for: hardwareTarget(display)) == trial.original else {
                throw DisplayHDRError.notApplied
            }
        } catch { failure = error }
        await rollbackPreset(initialFailure: failure)
    }

    private func hardwareTarget(_ display: DisplayInfo) -> DisplayHardwareTarget {
        DisplayHardwareTarget(uuid: display.id, displayID: display.displayID, isBuiltin: display.isBuiltin)
    }

    func colorProfileOptions(for display: DisplayInfo) -> [DisplayColorProfileOption] { colorStates[display.id]?.options ?? [] }
    func currentColorProfileID(for display: DisplayInfo) -> String? { colorStates[display.id]?.selectedID }
    func colorProfileName(for display: DisplayInfo) -> String {
        let state = colorStates[display.id]
        return state?.options.first(where: { $0.id == state?.selectedID })?.name ??
            (colorLoading.contains(display.id) ? "Загрузка…" : "Недоступен")
    }
    func isColorProfileLoading(for display: DisplayInfo) -> Bool { colorLoading.contains(display.id) }

    func refreshColorProfiles() async {
        guard enabled, !isApplyingPreset, let colorProfiles else { return }
        let epoch = colorEpoch
        for display in displays where display.isEnabled && !colorLoading.contains(display.id) {
            colorLoading.insert(display.id)
            defer { colorLoading.remove(display.id) }
            do {
                let state = try await colorProfiles.state(for: display)
                guard enabled, colorEpoch == epoch,
                      displays.contains(where: { $0.id == display.id && $0.displayID == display.displayID && $0.isEnabled }) else { continue }
                colorStates[display.id] = state
            } catch { /* Unsupported displays retain their other controls. */ }
        }
    }

    func selectColorProfile(_ profileID: String, for display: DisplayInfo) async {
        guard enabled, !isPending, !isApplyingPreset, !systemSettings.isBusy, let colorProfiles,
              colorStates[display.id]?.options.contains(where: { $0.id == profileID }) == true else { return }
        extraBrightness?.stop()
        startDisplayOperation { [weak self] in
            guard let self else { return }
            let original = self.colorStates[display.id]?.selectedID
            do {
                try self.checkOperation()
                try await colorProfiles.setProfile(profileID, for: display)
                try self.checkOperation()
                self.colorStates[display.id] = try await colorProfiles.state(for: display)
                try self.checkOperation()
                self.brightness.invalidate()
                self.applyDimming()
                self.errorMessage = nil
            } catch {
                if let original {
                    do { try await colorProfiles.setProfile(original, for: display) }
                    catch { self.errorMessage = "Не удалось вернуть цветовой профиль: \(error.localizedDescription)"; return }
                }
                self.errorMessage = error.localizedDescription
            }
        }
        await displayOperation?.value
    }

    func savePreset(named name: String) async {
        guard enabled, !isPending, !isApplyingPreset, !systemSettings.isBusy else { return }
        guard let name = DisplayPresetStore.validName(name) else {
            errorMessage = "Введите название от 1 до 80 символов."; return
        }
        startDisplayOperation { [weak self] in
            guard let self else { return }
            do {
                let live = try self.service.displays()
                guard !live.isEmpty else { throw DisplayServiceError.disconnected }
                var entries: [DisplayPresetEntry] = []
                for display in live {
                    var profileID: String?
                    if display.isEnabled, let profiles = self.colorProfiles {
                        profileID = try? await profiles.state(for: display).selectedID
                    }
                    var level = self.softwareDimming(for: display)
                    var useSoftware = true
                    if display.isEnabled, !self.isSoftwareBrightnessPreferred(for: display),
                       !self.hardwareUnavailable.contains(display.id), let hardware = self.hardware {
                        let reading = try await hardware.read(DisplayHardwareTarget(uuid: display.id,
                            displayID: display.displayID, isBuiltin: display.isBuiltin))
                        try self.checkOperation()
                        if let reading {
                            self.hardwareReadings[display.id] = reading
                            level = reading.value
                            useSoftware = false
                        }
                    }
                    try self.checkOperation()
                    entries.append(DisplayPresetEntry(stableUUID: display.id, enabled: display.isEnabled,
                        mode: display.currentMode.map(SavedDisplayMode.init), origin: display.frame.origin,
                        isMain: display.isMain,
                        mirrorMasterUUID: live.first(where: { $0.displayID == display.mirrorMasterID })?.id,
                        brightness: level, useSoftwareBrightness: useSoftware,
                        colorProfileID: profileID, imageAdjustment: self.imageAdjustment(for: display)))
                }
                guard try self.service.displays() == live else {
                    throw DisplayServiceError.disconnected
                }
                var updated = self.presets
                updated.append(DisplayPreset(name: name, displays: entries))
                try DisplayPresetStore(defaults: self.defaults).save(updated)
                self.presets = updated
                self.errorMessage = nil
            } catch { self.errorMessage = error.localizedDescription }
        }
        await displayOperation?.value
    }

    func renamePreset(id: UUID, to name: String) {
        guard !isApplyingPreset, !isPending else { return }
        guard let name = DisplayPresetStore.validName(name), let index = presets.firstIndex(where: { $0.id == id }) else {
            errorMessage = "Введите название от 1 до 80 символов."; return
        }
        var updated = presets
        updated[index].name = name
        storePresets(updated)
    }

    func deletePreset(id: UUID) {
        guard !isApplyingPreset, !isPending else { return }
        storePresets(presets.filter { $0.id != id })
    }

    private func storePresets(_ updated: [DisplayPreset]) {
        do { try DisplayPresetStore(defaults: defaults).save(updated); presets = updated; errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }

    func applyPreset(id: UUID) async {
        guard enabled, !isPending, !isApplyingPreset, !systemSettings.isBusy, let preset = presets.first(where: { $0.id == id }) else { return }
        extraBrightness?.stop()
        startDisplayOperation { [weak self] in await self?.performPreset(preset) }
        await displayOperation?.value
    }

    private func performPreset(_ preset: DisplayPreset) async {
        do {
            let live = try service.displays()
            guard colorProfiles != nil || preset.displays.allSatisfy({ $0.colorProfileID == nil }) else {
                throw DisplayColorProfileError.unavailable
            }
            guard let main = live.first(where: \.isMain) else { throw DisplayServiceError.disconnected }
            let snapshot = try service.snapshot()
            recoveryAppearance = AppearanceRecovery(preferences: preferences, profiles: [:], readings: [:])
            // Capture profiles before a preset can disable their screens.
            if let profiles = colorProfiles {
                for display in live where display.isEnabled && preset.displays.contains(where: { $0.stableUUID == display.id && $0.colorProfileID != nil }) {
                    let state = try await profiles.state(for: display)
                    guard let desired = preset.displays.first(where: { $0.stableUUID == display.id })?.colorProfileID,
                          state.options.contains(where: { $0.id == desired }) else { throw DisplayColorProfileError.invalidProfile }
                    recoveryAppearance?.profiles[display.id] = state.selectedID
                    try checkOperation()
                }
            }
            pending = Pending(snapshot: snapshot, change: .main(displayID: main.displayID), uuid: main.id,
                displayID: main.displayID, selectedMode: nil,
                participants: Dictionary(uniqueKeysWithValues: live.map { ($0.id, $0.displayID) }), preset: preset)
            isPending = true
            try checkOperation()
            try service.applyPreset(preset, permanently: false)
            let changed = try service.displays()
            for entry in preset.displays where entry.enabled {
                guard let display = changed.first(where: { $0.id == entry.stableUUID && $0.isEnabled }) else {
                    throw DisplayServiceError.disconnected
                }
                if let profiles = colorProfiles, let profileID = entry.colorProfileID {
                    if recoveryAppearance?.profiles[display.id] == nil {
                        recoveryAppearance?.profiles[display.id] = try await profiles.state(for: display).selectedID
                    }
                    try checkOperation()
                    try await profiles.setProfile(profileID, for: display)
                    try checkOperation()
                    colorStates[display.id] = try await profiles.state(for: display)
                }
                invalidateHardwareTasks(for: display.id)
                if preferences.imageAdjustmentsByUUID == nil { preferences.imageAdjustmentsByUUID = [:] }
                preferences.imageAdjustmentsByUUID?[display.id] = (entry.imageAdjustment ?? .neutral).sanitized
                if !entry.useSoftwareBrightness {
                    guard let hardware else { throw DisplayHardwareBrightnessError.unavailable }
                    let target = DisplayHardwareTarget(uuid: display.id, displayID: display.displayID, isBuiltin: display.isBuiltin)
                    guard let reading = try await hardware.read(target) else { throw DisplayHardwareBrightnessError.unavailable }
                    try checkOperation()
                    recoveryAppearance?.readings[display.id] = reading
                    try brightness.setAppearance(dimming: 1, adjustment: imageAdjustment(for: display), displayID: display.displayID)
                    try await hardware.write(entry.brightness, to: target, backend: reading.backend)
                    try checkOperation()
                    hardwareReadings[display.id] = .init(value: entry.brightness, backend: reading.backend)
                    preferences.softwareBrightnessUUIDs?.remove(display.id)
                } else {
                    dimmingByUUID[display.id] = Self.factor(entry.brightness)
                    preferences.softwareBrightnessUUIDs = (preferences.softwareBrightnessUUIDs ?? []).union([display.id])
                }
            }
            preferences.dimmingByUUID = dimmingByUUID
            brightness.invalidate()
            refresh()
            applyDimming()
            try checkOperation()
            guard let survivor = displays.first(where: { $0.isEnabled && $0.isMain }) ?? displays.first(where: \.isEnabled) else {
                throw DisplayServiceError.disconnected
            }
            isManagingPresets = false
            errorMessage = nil
            revertController.present(displayID: survivor.displayID, confirm: { [weak self] in self?.confirmChange() },
                                     revert: { [weak self] in self?.cancelChange() })
        } catch {
            let message = error.localizedDescription
            if pending?.preset != nil { await rollbackPreset() }
            else { recoveryAppearance = nil }
            errorMessage = rollbackFailed ? "\(message) \(errorMessage ?? "")" : message
        }
    }

    private func rollbackPreset(initialFailure: Error? = nil) async {
        extraBrightness?.stop()
        var failure: Error? = initialFailure
        let appearance = recoveryAppearance
        // Restore profiles of trial-enabled screens before they may be switched off.
        if let appearance {
            do {
                let live = try service.displays()
                for display in live where display.isEnabled {
                    if let profiles = colorProfiles, let original = appearance.profiles[display.id] {
                        do { try await profiles.setProfile(original, for: display) } catch { failure = error }
                    }
                    if let hardware, let reading = appearance.readings[display.id],
                       pending?.snapshot.entries.first(where: { $0.uuid == display.id })?.isEnabled == false {
                        do {
                            try await hardware.write(reading.value, to: DisplayHardwareTarget(uuid: display.id,
                                displayID: display.displayID, isBuiltin: display.isBuiltin), backend: reading.backend)
                        } catch { failure = error }
                    }
                }
            } catch { failure = error }
        }
        if let pending {
            do { try service.restore(pending.snapshot) } catch { failure = error }
        }
        if let appearance {
            preferences = appearance.preferences
            dimmingByUUID = appearance.preferences.dimmingByUUID
            do {
                let live = try service.displays()
                for display in live where display.isEnabled {
                    if let profiles = colorProfiles, let original = appearance.profiles[display.id] {
                        do { try await profiles.setProfile(original, for: display) } catch { failure = error }
                    }
                    if let hardware, let reading = appearance.readings[display.id] {
                        do {
                            try await hardware.write(reading.value, to: DisplayHardwareTarget(uuid: display.id,
                                displayID: display.displayID, isBuiltin: display.isBuiltin), backend: reading.backend)
                            hardwareReadings[display.id] = reading
                        } catch { failure = error }
                    }
                }
            } catch { failure = error }
            persist()
            colorStates.removeAll()
            brightness.invalidate()
            refresh()
            applyDimming()
        }
        if let failure {
            rollbackFailed = true
            revertController.dismiss()
            errorMessage = "Не удалось вернуть настройки: \(failure.localizedDescription)"
        } else {
            recoveryAppearance = nil
            finishChange()
            errorMessage = nil
            refresh()
        }
    }

    private func checkOperation() throws {
        guard enabled, !operationCancelled else { throw CancellationError() }
    }

    private func startDisplayOperation(refreshHardwareAfterward: Bool = false, _ body: @escaping @MainActor () async -> Void) {
        guard !isApplyingPreset else { return }
        for uuid in hardwareTargets.keys { invalidateHardwareTasks(for: uuid) }
        isApplyingPreset = true
        operationCancelled = false
        colorEpoch += 1
        hdrEpoch += 1
        hdrLoading.removeAll()
        hdrRefreshAgain = false
        invalidateAdvancedSettings()
        displayOperation = Task { [weak self] in
            await body()
            guard let self else { return }
            self.isApplyingPreset = false
            self.displayOperation = nil
            if self.enabled, refreshHardwareAfterward { self.refresh() }
            if self.enabled { Task { [weak self] in
                await self?.refreshColorProfiles()
                await self?.refreshHDR()
                await self?.refreshAdvancedSettings()
            } }
            if !self.enabled {
                do { try self.service.restoreManagedDisplays() }
                catch { self.errorMessage = error.localizedDescription }
            }
        }
    }

    func waitForOperations() async { await displayOperation?.value }

    private func softwareDimming(for display: DisplayInfo) -> Double {
        dimmingByUUID[display.id] ?? defaultDimming
    }

    func isSoftwareBrightnessPreferred(for display: DisplayInfo) -> Bool {
        // Preserve existing dimming choices when upgrading from the gamma-only feature.
        preferences.softwareBrightnessUUIDs?.contains(display.id) ?? (softwareDimming(for: display) < 1)
    }

    func isHardwareBrightness(for display: DisplayInfo) -> Bool {
        hardwareReadings[display.id] != nil && !isSoftwareBrightnessPreferred(for: display)
    }

    func hasHardwareBrightness(for display: DisplayInfo) -> Bool { hardwareReadings[display.id] != nil }

    func brightnessSourceLabel(for display: DisplayInfo) -> String {
        guard isHardwareBrightness(for: display), let reading = hardwareReadings[display.id] else {
            return "Программная яркость"
        }
        return reading.backend == .ddc ? "Аппаратная яркость · DDC/CI" : "Аппаратная яркость · macOS"
    }

    func useSoftwareBrightness(_ software: Bool, for display: DisplayInfo) {
        guard enabled, !isApplyingPreset, display.isEnabled,
              displays.contains(where: { $0.id == display.id && $0.displayID == display.displayID && $0.isEnabled }) else { return }
        invalidateHardwareTasks(for: display.id)
        var ids = preferences.softwareBrightnessUUIDs ?? Set(displays.filter { softwareDimming(for: $0) < 1 }.map(\.id))
        if software { ids.insert(display.id) } else { ids.remove(display.id) }
        preferences.softwareBrightnessUUIDs = ids
        persist()
        objectWillChange.send()
        if software {
            setSoftwareDimming(softwareDimming(for: display), for: display)
        } else {
            hardwareReadings.removeValue(forKey: display.id)
            hardwareUnavailable.remove(display.id)
            probeHardware(for: display)
        }
    }

    /// Read the current monitor value when opening the panel, including changes made with macOS keys.
    func refreshBrightness() {
        guard enabled, !isApplyingPreset else { return }
        for display in displays where display.isEnabled && hardwareWrites[display.id] == nil {
            probeHardware(for: display)
        }
    }

    private func reconcileHardware() {
        guard hardware != nil else { return }
        let current = Dictionary(uniqueKeysWithValues: displays.filter(\.isEnabled).map {
            ($0.id, DisplayHardwareTarget(uuid: $0.id, displayID: $0.displayID, isBuiltin: $0.isBuiltin))
        })
        for (uuid, target) in hardwareTargets where current[uuid] != target {
            invalidateHardwareTasks(for: uuid)
            hardwareReadings.removeValue(forKey: uuid)
            hardwareUnavailable.remove(uuid)
        }
        hardwareTargets = current
        guard !isApplyingPreset else { return }
        for display in displays where display.isEnabled && hardwareReadings[display.id] == nil && !hardwareUnavailable.contains(display.id) {
            probeHardware(for: display)
        }
    }

    private func probeHardware(for display: DisplayInfo) {
        guard let hardware, let target = hardwareTargets[display.id], hardwareProbes[display.id] == nil else { return }
        let uuid = display.id
        let epoch = hardwareEpochs[uuid, default: 0]
        let inputRevision = hardwareInputRevisions[uuid, default: 0]
        hardwareProbes[uuid] = Task { [weak self] in
            do {
                let reading = try await hardware.read(target)
                guard let self, !Task.isCancelled, self.matches(target, epoch: epoch) else { return }
                self.hardwareProbes.removeValue(forKey: uuid)
                guard self.hardwareInputRevisions[uuid, default: 0] == inputRevision else { return }
                guard self.hardwareDesired[uuid] == nil, self.hardwareWrites[uuid] == nil else { return }
                guard let reading, reading.value.isFinite, (0...1).contains(reading.value) else {
                    self.hardwareReadings.removeValue(forKey: uuid)
                    self.hardwareUnavailable.insert(uuid)
                    try self.brightness.setAppearance(dimming: self.softwareDimming(for: display),
                        adjustment: self.imageAdjustment(for: display), displayID: target.displayID)
                    return
                }
                if !self.isSoftwareBrightnessPreferred(for: display) {
                    try self.brightness.setAppearance(dimming: 1, adjustment: self.imageAdjustment(for: display), displayID: target.displayID)
                }
                self.hardwareReadings[uuid] = reading
            } catch {
                guard let self, !Task.isCancelled, self.matches(target, epoch: epoch) else { return }
                self.hardwareProbes.removeValue(forKey: uuid)
                guard self.hardwareInputRevisions[uuid, default: 0] == inputRevision,
                      self.hardwareDesired[uuid] == nil, self.hardwareWrites[uuid] == nil else { return }
                self.hardwareReadings.removeValue(forKey: uuid)
                self.hardwareUnavailable.insert(uuid)
                do { try self.brightness.setAppearance(dimming: self.softwareDimming(for: display),
                    adjustment: self.imageAdjustment(for: display), displayID: target.displayID) }
                catch { self.errorMessage = error.localizedDescription }
                // Unsupported hardware retains the existing gamma control without an error banner.
            }
        }
    }

    private func scheduleHardwareWrite(for display: DisplayInfo, backend: DisplayHardwareBackend) {
        guard let hardware, let target = hardwareTargets[display.id], hardwareWrites[display.id] == nil else { return }
        let uuid = display.id
        let epoch = hardwareEpochs[uuid, default: 0]
        hardwareWrites[uuid] = Task { [weak self] in
            while !Task.isCancelled {
                guard let request = self?.hardwareDesired[uuid] else { break }
                do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
                guard let self, self.matches(target, epoch: epoch), !Task.isCancelled else { return }
                guard self.hardwareDesired[uuid]?.revision == request.revision else { continue }
                do {
                    try await hardware.write(request.value, to: target, backend: backend)
                    guard !Task.isCancelled, self.matches(target, epoch: epoch) else { return }
                    if self.hardwareDesired[uuid]?.revision == request.revision {
                        self.hardwareDesired.removeValue(forKey: uuid)
                    }
                } catch {
                    guard !Task.isCancelled, self.matches(target, epoch: epoch) else { return }
                    let fallback = self.hardwareDesired[uuid]?.value ?? request.value
                    self.hardwareReadings.removeValue(forKey: uuid)
                    self.hardwareUnavailable.insert(uuid)
                    self.hardwareDesired.removeValue(forKey: uuid)
                    self.setSoftwareDimming(fallback, for: display)
                    self.errorMessage = "Аппаратная яркость не отвечает. Включено программное затемнение."
                    break
                }
            }
            guard let self, self.matches(target, epoch: epoch) else { return }
            self.hardwareWrites.removeValue(forKey: uuid)
        }
    }

    private func matches(_ target: DisplayHardwareTarget, epoch: Int) -> Bool {
        enabled && hardwareTargets[target.uuid] == target && hardwareEpochs[target.uuid, default: 0] == epoch
    }

    private func invalidateHardwareTasks(for uuid: String) {
        hardwareEpochs[uuid, default: 0] += 1
        hardwareProbes.removeValue(forKey: uuid)?.cancel()
        hardwareWrites.removeValue(forKey: uuid)?.cancel()
        hardwareDesired.removeValue(forKey: uuid)
    }

    private func resetHardware() {
        for uuid in hardwareTargets.keys { invalidateHardwareTasks(for: uuid) }
        hardwareTargets.removeAll()
        hardwareReadings.removeAll()
        hardwareUnavailable.removeAll()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(preferences) {
            defaults.set(data, forKey: UserDefaultsAppPreferences.displayManagementKey)
        }
    }

    private static func factor(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0.1, value)) : 1
    }
}

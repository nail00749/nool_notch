import AppKit
import CoreGraphics
import Darwin

@MainActor
protocol DisplayConfigurationServing {
    var supportsDisplayPower: Bool { get }
    func canChangePower(for display: DisplayInfo) -> Bool
    func displays() throws -> [DisplayInfo]
    func apply(_ change: DisplayChange, permanently: Bool) throws
    func applyPreset(_ preset: DisplayPreset, permanently: Bool) throws
    func restore(_ snapshot: DisplayConfigurationSnapshot) throws
    func snapshot() throws -> DisplayConfigurationSnapshot
    func restoreManagedDisplays() throws
    var disconnectPolicy: DisplayDisconnectPolicy { get }
    var keptDisconnectedUUIDs: Set<String> { get }
    var safetyEnabledUUIDs: Set<String> { get }
    func setDisconnectPolicy(_ policy: DisplayDisconnectPolicy) throws
    func confirmPowerState(uuid: String, enabled: Bool) throws
    func confirmPowerStates(_ states: [String: Bool]) throws
    func reconcileDisconnectIntents(beforeChanging: @MainActor () -> Void) throws -> Bool
    func resetDisconnectReconciliationAttempts()
}

extension DisplayConfigurationServing {
    var supportsDisplayPower: Bool { false }
    func canChangePower(for display: DisplayInfo) -> Bool { supportsDisplayPower }
    func restoreManagedDisplays() throws {}
    func applyPreset(_ preset: DisplayPreset, permanently: Bool) throws { throw DisplayPresetError.unavailable }
    var disconnectPolicy: DisplayDisconnectPolicy { .restoreOnExit }
    var keptDisconnectedUUIDs: Set<String> { [] }
    var safetyEnabledUUIDs: Set<String> { [] }
    func setDisconnectPolicy(_ policy: DisplayDisconnectPolicy) throws {}
    func confirmPowerState(uuid: String, enabled: Bool) throws {}
    func confirmPowerStates(_ states: [String: Bool]) throws {
        for (uuid, enabled) in states { try confirmPowerState(uuid: uuid, enabled: enabled) }
    }
    func reconcileDisconnectIntents(beforeChanging: @MainActor () -> Void) throws -> Bool { false }
    func reconcileDisconnectIntents() throws -> Bool { try reconcileDisconnectIntents(beforeChanging: {}) }
    func resetDisconnectReconciliationAttempts() {}
}

@MainActor
final class CoreGraphicsDisplayConfigurationService: DisplayConfigurationServing {
    private lazy var powerAPI = DisplayPowerSymbols()
    private let metadataDefaults: UserDefaults?
    private var managedDisplays: [String: DisplayManagedRecord]
    private var displayNamesByUUID: [String: String] = [:]
    private let disconnectController: DisplayDisconnectPolicyController
    private static let metadataKey = "displayManagement.managedDisabledDisplays.v1"

    init(metadataDefaults: UserDefaults? = .standard) {
        self.metadataDefaults = metadataDefaults
        let stored = metadataDefaults?.data(forKey: Self.metadataKey)
        managedDisplays = stored.flatMap { try? JSONDecoder().decode([String: DisplayManagedRecord].self, from: $0) } ?? [:]
        let store = DisplayDisconnectPolicyStore(defaults: metadataDefaults)
        disconnectController = DisplayDisconnectPolicyController(state: store.load(), save: store.save)
    }

    var disconnectPolicy: DisplayDisconnectPolicy { disconnectController.state.policy }
    var keptDisconnectedUUIDs: Set<String> { disconnectController.keptDisconnectedUUIDs }
    var safetyEnabledUUIDs: Set<String> { disconnectController.safetyEnabledUUIDs }

    func setDisconnectPolicy(_ policy: DisplayDisconnectPolicy) throws {
        try disconnectController.setPolicy(policy, devices: disconnectDevices())
    }

    func confirmPowerState(uuid: String, enabled: Bool) throws {
        try confirmPowerStates([uuid: enabled])
    }

    func confirmPowerStates(_ states: [String: Bool]) throws {
        let devices = try disconnectDevices()
        let owned = Set(managedDisplays.values.filter { record in
            guard record.restoreOnStop || disconnectController.retains(record) else { return false }
            return DisplayDisconnectPolicyController.match(DisplayDisconnectIntent(uuid: record.uuid, name: record.name,
                fingerprint: record.fingerprint), devices: devices) != nil
        }.map(\.uuid)).union(disconnectController.state.intents.values.compactMap { intent in
            DisplayDisconnectPolicyController.match(intent, devices: devices) == nil ? nil : intent.uuid
        })
        try disconnectController.confirm(states: states, devices: devices, ownedUUIDs: owned)
        // Only a confirmed explicit enable relinquishes retained identity.
        // Safety recovery and enable trials keep it for UUID-less native slots.
        for (uuid, enabled) in states where enabled {
            managedDisplays.removeValue(forKey: uuid)
        }
        try persistManagedDisplays()
    }

    func resetDisconnectReconciliationAttempts() { disconnectController.resetAttempts() }

    func reconcileDisconnectIntents(beforeChanging: @MainActor () -> Void) throws -> Bool {
        try disconnectController.reconcile(read: disconnectDevices, recoveryRecords: { Array(self.managedDisplays.values) }) { intent, enabled in
            let live = try self.disconnectDevices()
            guard let target = DisplayDisconnectPolicyController.match(intent, devices: live) else {
                throw DisplayServiceError.displayIdentityUnavailable
            }
            beforeChanging()
            try self.setEnabled(target.display.displayID, enabled: enabled, permanently: false, expectedIntent: intent)
        }
    }

    private func disconnectDevices() throws -> [DisplayDisconnectDevice] {
        // Power validation must not enumerate hundreds of modes per slot on
        // every refresh and again inside each native transaction. Keep the
        // same strict live identity rules as the public catalog, but query
        // only the current mode needed for a lossless recovery record.
        let online = Set(try onlineDisplayIDs())
        let ids = try connectedSlotIDs(online: Array(online))
        let fingerprints = ids.map { DisplayHardwareFingerprint(displayID: $0) }
        let records = Array(managedDisplays.values)
        return zip(ids, fingerprints).compactMap { id, fingerprint in
            let liveUUID = uuidIfAvailable(id)
            let cached = DisplayManagedRecord.match(in: records, fingerprint: fingerprint,
                liveUUID: liveUUID, allFingerprints: fingerprints)
            guard let uuid = liveUUID ?? cached?.uuid,
                  online.contains(id) || fingerprint.isRecoverable || cached != nil else { return nil }
            let active = CGDisplayIsActive(id) != 0
            let master = mirrorMaster(id)
            let enabled = online.contains(id) && (active || master != nil)
            let display = DisplayInfo(id: uuid, displayID: id,
                name: displayNamesByUUID[uuid] ?? cached?.name ?? "Дисплей \(id)",
                isBuiltin: fingerprint.isBuiltin, isMain: CGDisplayIsMain(id) != 0,
                mirrorMasterID: master, modes: [],
                currentMode: CGDisplayCopyDisplayMode(id).map(DisplayModeOption.init) ?? cached?.currentMode,
                frame: enabled ? CGDisplayBounds(id) : (cached?.frame ?? CGDisplayBounds(id)), isEnabled: enabled)
            return DisplayDisconnectDevice(display: display, fingerprint: fingerprint,
                liveUUID: liveUUID, isActive: active, isAsleep: CGDisplayIsAsleep(id) != 0)
        }
    }

    var supportsDisplayPower: Bool { powerAPI.configureEnabled != nil && powerAPI.displayList != nil }

    func canChangePower(for display: DisplayInfo) -> Bool {
        guard supportsDisplayPower else { return false }
        guard let live = try? displays(), let candidate = live.first(where: { $0.id == display.id && $0.displayID == display.displayID }) else { return false }
        if !candidate.isEnabled { return true }
        let fingerprint = DisplayHardwareFingerprint(displayID: candidate.displayID)
        let peers = live.map { DisplayHardwareFingerprint(displayID: $0.displayID) }
        return fingerprint.isRecoverable && peers.filter { $0.hasSameHardware(as: fingerprint) }.count == 1
    }

    func displays() throws -> [DisplayInfo] {
        let names = Dictionary(NSScreen.screens.compactMap { screen -> (UInt32, String)? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return (number.uint32Value, screen.localizedName)
        }, uniquingKeysWith: { first, _ in first })
        let online = try onlineDisplayIDs()
        let ids = try connectedSlotIDs(online: online)
        let fingerprints = ids.map { DisplayHardwareFingerprint(displayID: $0) }
        return ids.compactMap { id -> DisplayInfo? in
            let fingerprint = DisplayHardwareFingerprint(displayID: id)
            let liveUUID = uuidIfAvailable(id)
            let cached = DisplayManagedRecord.match(in: Array(managedDisplays.values), fingerprint: fingerprint,
                                                    liveUUID: liveUUID, allFingerprints: fingerprints)
            // Private enumeration contains empty slots. A missing UUID is only safe when a
            // unique live hardware signature proves that it is one of our disabled displays.
            guard let stableID = liveUUID ?? cached?.uuid,
                  online.contains(id) || fingerprint.isRecoverable || cached != nil else { return nil }
            let current = CGDisplayCopyDisplayMode(id).map(DisplayModeOption.init)
            let options = allModes(id).filter { $0.isUsableForDesktopGUI() }.map(DisplayModeOption.init)
            let master = mirrorMaster(id)
            let enabled = online.contains(id) && (CGDisplayIsActive(id) == 1 || master != nil)
            displayNamesByUUID[stableID] = names[id] ?? cached?.name ?? "Дисплей \(id)"
            return DisplayInfo(id: stableID, displayID: id, name: names[id] ?? cached?.name ?? "Дисплей \(id)",
                               isBuiltin: fingerprint.isBuiltin, isMain: CGDisplayIsMain(id) == 1,
                               mirrorMasterID: master,
                               modes: DisplayModeOption.deduplicated(options, currentModeID: current?.id),
                               currentMode: current ?? cached?.currentMode,
                               frame: enabled ? CGDisplayBounds(id) : (cached?.frame ?? CGDisplayBounds(id)), isEnabled: enabled,
                               physicalSize: physicalSize(id))
        }.sorted {
            if $0.isMain != $1.isMain { return $0.isMain }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func snapshot() throws -> DisplayConfigurationSnapshot {
        let current = try displays()
        return DisplayConfigurationSnapshot(entries: current.map { display in
            DisplayConfigurationSnapshot.Entry(displayID: display.displayID, uuid: display.id,
                mode: CGDisplayCopyDisplayMode(display.displayID), origin: display.frame.origin,
                mirrorMasterID: display.mirrorMasterID,
                mirrorMasterUUID: current.first(where: { $0.displayID == display.mirrorMasterID })?.id,
                isEnabled: display.isEnabled, wasManagedDisabled: managedDisplays[display.id]?.restoreOnStop ?? false)
        })
    }

    func apply(_ change: DisplayChange, permanently: Bool) throws {
        if case .enabled(let id, let enabled) = change {
            try setEnabled(id, enabled: enabled, permanently: permanently)
            return
        }
        let online = try onlineDisplayIDs()
        let live = try displays()
        if case .arrangement(let placements) = change {
            try DisplayArrangementPolicy.validate(placements, displays: live)
        }
        try transaction(permanently: permanently) { configuration in
            switch change {
            case .mode(let id, let modeID):
                guard live.contains(where: { $0.displayID == id && $0.isEnabled }) else { throw DisplayServiceError.disconnected }
                guard let mode = allModes(id).first(where: { UInt32(bitPattern: $0.ioDisplayModeID) == modeID && $0.isUsableForDesktopGUI() }) else {
                    throw DisplayServiceError.unavailableMode
                }
                try check(CGConfigureDisplayWithDisplayMode(configuration, id, mode, nil), "изменить режим")
            case .main(let id):
                guard live.contains(where: { $0.displayID == id && $0.isEnabled }) else { throw DisplayServiceError.disconnected }
                guard mirrorMaster(id) == nil else { throw DisplayServiceError.mirroredDisplayCannotBeMain }
                let newOrigin = CGDisplayBounds(id).origin
                let mirrorPairs = online.compactMap { displayID in mirrorMaster(displayID).map { (displayID, $0) } }
                // One translation preserves every relative position while making this screen primary.
                try configureOrigin(configuration, id, .zero)
                for displayID in online where displayID != id && live.contains(where: { $0.displayID == displayID && $0.isEnabled }) {
                    let origin = CGDisplayBounds(displayID).origin
                    try configureOrigin(configuration, displayID, CGPoint(x: origin.x - newOrigin.x, y: origin.y - newOrigin.y))
                }
                // Configuring an origin removes that display from its mirror set.
                for (displayID, masterID) in mirrorPairs {
                    try check(CGConfigureDisplayMirrorOfDisplay(configuration, displayID, masterID), "сохранить зеркалирование")
                }
            case .mirror(let id, let masterID):
                guard live.contains(where: { $0.displayID == id && $0.isEnabled }),
                      masterID.map({ candidate in live.contains(where: { $0.displayID == candidate && $0.isEnabled && $0.mirrorMasterID == nil }) && candidate != id }) ?? true else {
                    throw DisplayServiceError.disconnected
                }
                try check(CGConfigureDisplayMirrorOfDisplay(configuration, id, masterID ?? kCGNullDirectDisplay), "изменить зеркалирование")
            case .arrangement(let placements):
                let byUUID = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                for placement in placements {
                    guard let display = byUUID[placement.uuid] else { throw DisplayServiceError.disconnected }
                    try configureOrigin(configuration, display.displayID, placement.origin)
                }
                try restoreMirrorGroups(live, configuration: configuration)
            case .enabled:
                break // handled above, outside a mode/origin transaction
            }
        }
    }

    func applyPreset(_ preset: DisplayPreset, permanently: Bool) throws {
        let before = try displays()
        let powerChanges = before.filter { display in
            preset.displays.first(where: { $0.stableUUID == display.id })?.enabled != display.isEnabled
        }
        let powerChangeable = Set(powerChanges.filter { canChangePower(for: $0) }.map(\.id))
        let plan = try DisplayPresetConfigurationPlan.make(preset, displays: before,
            supportsDisplayPower: supportsDisplayPower, powerChangeableUUIDs: powerChangeable)

        // Resolve every currently readable driver mode before enabling anything. Disabled
        // screens can withhold their catalog, so those are resolved immediately after enable.
        var driverModes: [String: (displayID: UInt32, mode: CGDisplayMode)] = [:]
        for entry in plan.entries where entry.saved.enabled {
            let current = try presetParticipants(plan)
            guard let display = current[entry.saved.stableUUID] else { throw DisplayPresetError.displayChanged }
            if display.isEnabled, let saved = entry.saved.mode {
                driverModes[entry.saved.stableUUID] = (display.displayID,
                    try resolvePresetMode(saved, displayID: display.displayID, uuid: entry.saved.stableUUID))
            }
        }
        for entry in plan.entries where entry.saved.enabled {
            let current = try presetParticipants(plan)
            guard let display = current[entry.saved.stableUUID] else { throw DisplayPresetError.displayChanged }
            if !display.isEnabled {
                try setEnabled(display.displayID, enabled: true, permanently: permanently)
            }
        }

        let byUUID = try presetParticipants(plan)
        for entry in plan.entries where entry.saved.enabled {
            guard let display = byUUID[entry.saved.stableUUID] else { throw DisplayPresetError.displayChanged }
            // Enabling a screen may legitimately remap numeric IDs for any participant.
            // A mode object resolved for an old ID must be reacquired from the new catalog.
            if driverModes[entry.saved.stableUUID]?.displayID != display.displayID {
                driverModes.removeValue(forKey: entry.saved.stableUUID)
            }
            if let saved = entry.saved.mode {
                if driverModes[entry.saved.stableUUID] == nil {
                    driverModes[entry.saved.stableUUID] = (display.displayID,
                        try resolvePresetMode(saved, displayID: display.displayID, uuid: entry.saved.stableUUID))
                }
            }
        }
        let resolvedIDs = byUUID.mapValues(\.displayID)
        _ = try presetParticipants(plan, expectedDisplayIDs: resolvedIDs)
        try transaction(permanently: permanently) { configuration in
            let configuredParticipants = try presetParticipants(plan, expectedDisplayIDs: resolvedIDs)
            // Break the old groups before applying the requested topology. Origin calls
            // also break mirroring, so all desired groups are restored after the origins.
            for display in configuredParticipants.values where display.isEnabled && display.mirrorMasterID != nil {
                try check(CGConfigureDisplayMirrorOfDisplay(configuration, display.displayID, kCGNullDirectDisplay), "отключить зеркалирование")
            }
            for entry in plan.entries where entry.saved.enabled {
                guard let display = configuredParticipants[entry.saved.stableUUID] else { throw DisplayPresetError.displayChanged }
                if let cached = driverModes[entry.saved.stableUUID] {
                    try check(CGConfigureDisplayWithDisplayMode(configuration, display.displayID, cached.mode, nil), "применить режим пресета")
                }
                try configureOrigin(configuration, display.displayID, entry.saved.origin)
            }
            for placement in plan.temporaryPlacements {
                guard let display = configuredParticipants[placement.uuid] else { throw DisplayPresetError.displayChanged }
                try configureOrigin(configuration, display.displayID, placement.origin)
            }
            for entry in plan.entries where entry.saved.enabled {
                guard let display = configuredParticipants[entry.saved.stableUUID] else { throw DisplayPresetError.displayChanged }
                if let masterUUID = entry.saved.mirrorMasterUUID, let master = configuredParticipants[masterUUID] {
                    try check(CGConfigureDisplayMirrorOfDisplay(configuration, display.displayID, master.displayID), "применить зеркалирование пресета")
                }
            }
        }
        for entry in plan.entries where !entry.saved.enabled {
            // setEnabled skips no-ops and rechecks the live last-drawable-screen guard.
            let current = try presetParticipants(plan)
            if let display = current[entry.saved.stableUUID], display.isEnabled {
                try setEnabled(display.displayID, enabled: false, permanently: permanently)
            }
        }
    }

    private func presetParticipants(_ plan: DisplayPresetConfigurationPlan,
                                    expectedDisplayIDs: [String: UInt32]? = nil) throws -> [String: DisplayInfo] {
        try DisplayPresetParticipantIdentity.resolve(expectedUUIDs: Set(plan.entries.map { $0.saved.stableUUID }),
            displays: displays(), expectedDisplayIDs: expectedDisplayIDs)
    }

    private func resolvePresetMode(_ saved: SavedDisplayMode, displayID: UInt32, uuid: String) throws -> CGDisplayMode {
        if let mode = allModes(displayID).first(where: { $0.isUsableForDesktopGUI() && saved.matches(DisplayModeOption($0)) }) {
            return mode
        }
        if let mode = CGDisplayCopyDisplayMode(displayID), mode.isUsableForDesktopGUI(), saved.matches(DisplayModeOption(mode)) {
            return mode
        }
        throw DisplayPresetError.modeUnavailable(displayUUID: uuid)
    }

    func restore(_ snapshot: DisplayConfigurationSnapshot) throws {
        let before = try displays()
        var reenabledUUIDs: Set<String> = []
        // Enable first in separate transactions. Modes/origins are unavailable while disabled,
        // and some macOS versions reject a transaction containing a no-op enable request.
        for entry in snapshot.entries where entry.isEnabled {
            if let current = before.first(where: { $0.id == entry.uuid }), !current.isEnabled {
                try setEnabled(current.displayID, enabled: true, permanently: false)
                reenabledUUIDs.insert(entry.uuid)
            }
        }
        let live = try displays()
        var byUUID = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // CG's public list can lag a successful enable commit until its next run-loop delivery.
        // The pre-enable participants have already passed strict live slot identity matching.
        for display in before where reenabledUUIDs.contains(display.id) && byUUID[display.id] == nil {
            byUUID[display.id] = display
        }
        let connected = snapshot.entries.compactMap { entry -> (DisplayConfigurationSnapshot.Entry, DisplayInfo)? in
            byUUID[entry.uuid].map { (entry, $0) }
        }
        guard !connected.isEmpty else { return }
        try transaction(permanently: false) { configuration in
            // Break mirror groups first so each original mode and origin can be restored independently.
            for (entry, display) in connected where entry.isEnabled && (display.isEnabled || reenabledUUIDs.contains(entry.uuid)) && display.mirrorMasterID != nil {
                try check(CGConfigureDisplayMirrorOfDisplay(configuration, display.displayID, kCGNullDirectDisplay), "отключить зеркалирование")
            }
            for (entry, display) in connected where entry.isEnabled && (display.isEnabled || reenabledUUIDs.contains(entry.uuid)) {
                if let mode = entry.mode {
                    try check(CGConfigureDisplayWithDisplayMode(configuration, display.displayID, mode, nil), "восстановить режим")
                }
                try configureOrigin(configuration, display.displayID, entry.origin)
            }
            for (entry, display) in connected where entry.isEnabled && (display.isEnabled || reenabledUUIDs.contains(entry.uuid)) {
                if let masterUUID = entry.mirrorMasterUUID, let master = byUUID[masterUUID], master.isEnabled || reenabledUUIDs.contains(masterUUID) {
                    try check(CGConfigureDisplayMirrorOfDisplay(configuration, display.displayID, master.displayID), "восстановить зеркалирование")
                }
            }
        }
        // Restore disabled state last so a trial cannot remove the sole remaining screen
        // before another snapshot participant has been re-enabled.
        for (entry, display) in connected where !entry.isEnabled && display.isEnabled {
            try setEnabled(display.displayID, enabled: false, permanently: false, restoreOnStop: entry.wasManagedDisabled)
        }
    }

    func restoreManagedDisplays() throws {
        defer { disconnectController.endSession() }
        let records = managedDisplays.values.filter { $0.restoreOnStop && !disconnectController.retains($0) }
        var firstError: Error?
        for record in records {
            do {
                // Never use a remembered numeric ID unless current live identity agrees.
                let intent = DisplayDisconnectIntent(uuid: record.uuid, name: record.name, fingerprint: record.fingerprint)
                guard let display = DisplayDisconnectPolicyController.match(intent, devices: try disconnectDevices())?.display else { continue }
                if !display.isEnabled { try setEnabled(display.displayID, enabled: true, permanently: false, expectedIntent: intent) }
                else { managedDisplays.removeValue(forKey: record.uuid); try persistManagedDisplays() }
            } catch { if firstError == nil { firstError = error } }
        }
        if let firstError { throw firstError }
    }

    private func onlineDisplayIDs() throws -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        try check(CGGetOnlineDisplayList(0, nil, &count), "получить список дисплеев")
        guard count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        try check(CGGetOnlineDisplayList(count, &ids, &count), "получить список дисплеев")
        return Array(ids.prefix(Int(count)))
    }

    private func uuidIfAvailable(_ id: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    private func connectedSlotIDs(online: [UInt32]) throws -> [UInt32] {
        guard let list = powerAPI.displayList else { return online }
        let maximum: UInt32 = 256
        var ids = [UInt32](repeating: 0, count: Int(maximum))
        var count: UInt32 = 0
        try check(list(maximum, &ids, &count), "получить подключённые дисплеи")
        guard count <= maximum else { throw DisplayServiceError.displayPowerUnavailable }
        return Array(Set(ids.prefix(Int(count)).filter { $0 != kCGNullDirectDisplay }).union(online)).sorted()
    }

    private func setEnabled(_ id: UInt32, enabled: Bool, permanently: Bool, restoreOnStop: Bool = true,
                            expectedIntent: DisplayDisconnectIntent? = nil) throws {
        guard supportsDisplayPower, let configure = powerAPI.configureEnabled else { throw DisplayServiceError.displayPowerUnavailable }
        let devices = try disconnectDevices()
        let live = devices.map(\.display)
        guard let initial = devices.first(where: { $0.display.displayID == id }) else { throw DisplayServiceError.disconnected }
        let expected = expectedIntent ?? DisplayDisconnectIntent(uuid: initial.display.id, name: initial.display.name,
                                                                 fingerprint: initial.fingerprint)
        let target = try DisplayPowerIdentity.resolve(expected, displayID: id, devices: devices,
            allowUnrecoverableLiveUUID: expectedIntent == nil).display
        // SLS rejects some no-op enabled requests with illegalArgument for the entire transaction.
        guard target.isEnabled != enabled else {
            if enabled, !preservesDisabledIdentity(target.id) {
                managedDisplays.removeValue(forKey: target.id)
                try persistManagedDisplays()
            }
            return
        }
        let drawable = Set(devices.filter { !$0.isFallback && $0.isActive && !$0.isAsleep }.map { $0.display.displayID })
        try DisplayPowerPolicy.validate(displayID: id, enabled: enabled, displays: live, drawableDisplayIDs: drawable)
        // Equivalent to canChangePower's enabled-screen check, using this
        // already-fresh power snapshot rather than the full public mode list.
        if target.isEnabled {
            guard initial.fingerprint.isRecoverable,
                  devices.filter({ $0.fingerprint.hasSameHardware(as: initial.fingerprint) }).count == 1 else {
                throw DisplayServiceError.displayIdentityUnavailable
            }
        }
        let previous = managedDisplays
        var didAttemptNativePower = false
        do {
            if !enabled {
                managedDisplays[target.id] = DisplayManagedRecord(display: target, fingerprint: expected.fingerprint, restoreOnStop: restoreOnStop)
                // Persist identity before the API call can remove its public UUID and mode.
                try persistManagedDisplays()
            }
            try transaction(permanently: permanently) { configuration in
                let fresh = try disconnectDevices()
                let current = try DisplayPowerIdentity.resolve(expected, displayID: id, devices: fresh,
                    allowUnrecoverableLiveUUID: expectedIntent == nil)
                guard current.display.isEnabled != enabled else { throw DisplayDisconnectPolicyError.notApplied }
                try DisplayPowerPolicy.validate(displayID: id, enabled: enabled, displays: fresh.map(\.display),
                    drawableDisplayIDs: Set(fresh.filter(\.isDrawable).map { $0.display.displayID }))
                didAttemptNativePower = true
                try check(configure(configuration, id, enabled), enabled ? "включить дисплей" : "отключить дисплей")
            }
        } catch {
            if !didAttemptNativePower {
                // A failed begin/identity/last-screen check cannot have changed
                // power and must not claim ownership of an unrelated off state.
                managedDisplays = previous
                try persistManagedDisplays()
            }
            // A commit failure may still have changed hardware on private API implementations.
            // Keep the recovery record after a disable attempt rather than losing the handle.
            else if enabled { managedDisplays = previous }
            throw error
        }
        if enabled, !preservesDisabledIdentity(target.id), try disconnectDevices().contains(where: { $0.display.id == target.id && $0.display.isEnabled }) {
            managedDisplays.removeValue(forKey: target.id)
            try persistManagedDisplays()
        }
    }

    private func preservesDisabledIdentity(_ uuid: String) -> Bool {
        managedDisplays[uuid].map(disconnectController.retains) ?? false
    }

    private func persistManagedDisplays() throws {
        guard let metadataDefaults else { return }
        if managedDisplays.isEmpty { metadataDefaults.removeObject(forKey: Self.metadataKey) }
        else { metadataDefaults.set(try JSONEncoder().encode(managedDisplays), forKey: Self.metadataKey) }
    }

    private func restoreMirrorGroups(_ displays: [DisplayInfo], configuration: CGDisplayConfigRef) throws {
        for display in displays where display.isEnabled {
            if let master = display.mirrorMasterID {
                try check(CGConfigureDisplayMirrorOfDisplay(configuration, display.displayID, master), "сохранить зеркалирование")
            }
        }
    }

    private func allModes(_ id: CGDirectDisplayID) -> [CGDisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        return CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] ?? []
    }

    private func physicalSize(_ id: CGDirectDisplayID) -> CGSize? {
        let size = CGDisplayScreenSize(id)
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return nil }
        let rotation = CGDisplayRotation(id).truncatingRemainder(dividingBy: 180)
        return abs(rotation) == 90 ? CGSize(width: size.height, height: size.width) : size
    }

    private func mirrorMaster(_ id: CGDirectDisplayID) -> CGDirectDisplayID? {
        let master = CGDisplayMirrorsDisplay(id)
        return master == kCGNullDirectDisplay ? nil : master
    }

    private func configureOrigin(_ configuration: CGDisplayConfigRef, _ id: CGDirectDisplayID, _ origin: CGPoint) throws {
        guard let x = Int32(exactly: origin.x), let y = Int32(exactly: origin.y) else { throw DisplayServiceError.invalidOrigin }
        try check(CGConfigureDisplayOrigin(configuration, id, x, y), "восстановить расположение")
    }

    private func transaction(permanently: Bool, _ configure: (CGDisplayConfigRef) throws -> Void) throws {
        var reference: CGDisplayConfigRef?
        try check(CGBeginDisplayConfiguration(&reference), "начать настройку дисплея")
        guard let reference else { throw DisplayServiceError.disconnected }
        do {
            try configure(reference)
        } catch {
            CGCancelDisplayConfiguration(reference)
            throw error
        }
        // CGCompleteDisplayConfiguration disposes the transaction even when it fails.
        try check(CGCompleteDisplayConfiguration(reference, permanently ? .permanently : .forSession), "применить настройки дисплея")
    }

    private func check(_ error: CGError, _ operation: String) throws {
        guard error == .success else { throw DisplayServiceError.coreGraphics(operation: operation, code: error.rawValue) }
    }
}

enum DisplayPresetParticipantIdentity {
    /// UUID is the participant identity; numeric IDs are only bound while resolving one transaction.
    static func resolve(expectedUUIDs: Set<String>, displays: [DisplayInfo],
                        expectedDisplayIDs: [String: UInt32]? = nil) throws -> [String: DisplayInfo] {
        guard displays.count == expectedUUIDs.count, Set(displays.map(\.id)) == expectedUUIDs,
              Set(displays.map(\.displayID)).count == displays.count else { throw DisplayPresetError.displayChanged }
        if let expectedDisplayIDs {
            guard Set(expectedDisplayIDs.keys) == expectedUUIDs,
                  displays.allSatisfy({ expectedDisplayIDs[$0.id] == $0.displayID }) else {
                throw DisplayPresetError.displayChanged
            }
        }
        return Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0) })
    }
}

struct DisplayHardwareFingerprint: Codable, Equatable {
    let vendor: UInt32
    let model: UInt32
    let serial: UInt32
    let isBuiltin: Bool

    init(vendor: UInt32, model: UInt32, serial: UInt32, isBuiltin: Bool) {
        self.vendor = vendor
        self.model = model
        self.serial = serial
        self.isBuiltin = isBuiltin
    }

    init(displayID: UInt32) {
        self.init(vendor: CGDisplayVendorNumber(displayID), model: CGDisplayModelNumber(displayID),
                  serial: CGDisplaySerialNumber(displayID), isBuiltin: CGDisplayIsBuiltin(displayID) == 1)
    }

    var isRecoverable: Bool {
        vendor != 0 && vendor != .max && model != 0 && model != .max
            && serial != .max && (serial != 0 || isBuiltin)
    }

    func hasSameHardware(as other: DisplayHardwareFingerprint) -> Bool {
        isRecoverable && other.isRecoverable && self == other
    }
}

struct DisplayManagedRecord: Codable, Equatable {
    let uuid: String
    let name: String
    let fingerprint: DisplayHardwareFingerprint
    let frame: CGRect
    let currentMode: DisplayModeOption?
    let restoreOnStop: Bool

    init(display: DisplayInfo, fingerprint: DisplayHardwareFingerprint, restoreOnStop: Bool = true) {
        uuid = display.id
        name = display.name
        self.fingerprint = fingerprint
        frame = display.frame
        currentMode = display.currentMode
        self.restoreOnStop = restoreOnStop
    }

    private enum CodingKeys: String, CodingKey {
        case uuid, name, fingerprint, frame, currentMode, restoreOnStop
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try values.decode(String.self, forKey: .uuid)
        name = try values.decode(String.self, forKey: .name)
        fingerprint = try values.decode(DisplayHardwareFingerprint.self, forKey: .fingerprint)
        frame = try values.decode(CGRect.self, forKey: .frame)
        currentMode = try values.decodeIfPresent(DisplayModeOption.self, forKey: .currentMode)
        // Records written before ownership tracking represented only NooL-disabled screens.
        restoreOnStop = try values.decodeIfPresent(Bool.self, forKey: .restoreOnStop) ?? true
    }

    static func match(in records: [DisplayManagedRecord], fingerprint: DisplayHardwareFingerprint,
                      liveUUID: String?, allFingerprints: [DisplayHardwareFingerprint]) -> DisplayManagedRecord? {
        guard fingerprint.isRecoverable,
              allFingerprints.filter({ $0.hasSameHardware(as: fingerprint) }).count == 1 else { return nil }
        let candidates = records.filter { record in
            record.fingerprint.hasSameHardware(as: fingerprint)
                && (liveUUID.map { live in record.uuid.caseInsensitiveCompare(live) == .orderedSame } ?? true)
        }
        return candidates.count == 1 ? candidates.first : nil
    }
}

@MainActor
private final class DisplayPowerSymbols {
    typealias ConfigureEnabled = @convention(c) (CGDisplayConfigRef, UInt32, Bool) -> CGError
    typealias DisplayList = @convention(c) (UInt32, UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?) -> CGError
    let configureEnabled: ConfigureEnabled?
    let displayList: DisplayList?

    init() {
        // Handles intentionally remain open for process lifetime, as do the function pointers.
        let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL)
        let coreGraphics = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY | RTLD_LOCAL)
        func symbol(_ primary: String, _ fallback: String) -> UnsafeMutableRawPointer? {
            if let skyLight, let pointer = dlsym(skyLight, primary) ?? dlsym(skyLight, fallback) { return pointer }
            if let coreGraphics { return dlsym(coreGraphics, primary) ?? dlsym(coreGraphics, fallback) }
            return nil
        }
        configureEnabled = symbol("SLSConfigureDisplayEnabled", "CGSConfigureDisplayEnabled").map { unsafeBitCast($0, to: ConfigureEnabled.self) }
        displayList = symbol("SLSGetDisplayList", "CGSGetDisplayList").map { unsafeBitCast($0, to: DisplayList.self) }
    }
}

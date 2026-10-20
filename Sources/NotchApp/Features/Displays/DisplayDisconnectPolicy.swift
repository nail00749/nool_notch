import Foundation

enum DisplayDisconnectPolicy: String, CaseIterable, Codable {
    case restoreOnExit
    case keepDisabled
}

enum DisplayDisconnectPolicyError: LocalizedError {
    case notApplied
    var errorDescription: String? { "macOS не подтвердила изменение отключения дисплея." }
}

struct DisplayDisconnectIntent: Codable, Equatable {
    let uuid: String
    let name: String
    let fingerprint: DisplayHardwareFingerprint
}

struct DisplayDisconnectPolicyState: Codable, Equatable {
    var policy: DisplayDisconnectPolicy = .restoreOnExit
    var intents: [String: DisplayDisconnectIntent] = [:]
}

/// One preferences value commits policy and all confirmed intentions together.
@MainActor
final class DisplayDisconnectPolicyStore {
    static let key = "displayManagement.disconnectPolicy.v1"
    private let defaults: UserDefaults?
    init(defaults: UserDefaults?) { self.defaults = defaults }
    func load() -> DisplayDisconnectPolicyState {
        guard let data = defaults?.data(forKey: Self.key),
              let state = try? JSONDecoder().decode(DisplayDisconnectPolicyState.self, from: data),
              state.intents.allSatisfy({ $0.key == $0.value.uuid && !$0.key.isEmpty && $0.value.fingerprint.isRecoverable }) else {
            return DisplayDisconnectPolicyState()
        }
        // A restore policy must never adopt leftover off intentions.
        return state.policy == .restoreOnExit ? DisplayDisconnectPolicyState() : state
    }
    func save(_ state: DisplayDisconnectPolicyState) throws {
        let data = try JSONEncoder().encode(state)
        defaults?.set(data, forKey: Self.key)
    }
}

struct DisplayDisconnectDevice {
    let display: DisplayInfo
    let fingerprint: DisplayHardwareFingerprint
    /// Unlike display.id, this has not been reconstructed from saved metadata.
    let liveUUID: String?
    let isActive: Bool
    let isAsleep: Bool

    var isFallback: Bool { fingerprint.vendor == 0x756E6B6E && fingerprint.model == 0x76697274 }
    var isDrawable: Bool {
        display.isEnabled && display.mirrorMasterID == nil && isActive && !isAsleep && !isFallback
    }
}

@MainActor
enum DisplayPowerIdentity {
    static func resolve(_ expected: DisplayDisconnectIntent, displayID: UInt32,
                        devices: [DisplayDisconnectDevice], allowUnrecoverableLiveUUID: Bool = false) throws -> DisplayDisconnectDevice {
        if let device = DisplayDisconnectPolicyController.match(expected, devices: devices), device.display.displayID == displayID {
            return device
        }
        // An explicit manual enable may recover an externally disabled display
        // whose serial is unavailable, but only with its actual current UUID.
        // Automatic recovery never accepts this less complete hardware identity.
        if allowUnrecoverableLiveUUID, !expected.fingerprint.isRecoverable {
            let matches = devices.filter {
                $0.liveUUID?.caseInsensitiveCompare(expected.uuid) == .orderedSame
                    && $0.display.id.caseInsensitiveCompare(expected.uuid) == .orderedSame
                    && $0.fingerprint == expected.fingerprint
            }
            if matches.count == 1, let device = matches.first, device.display.displayID == displayID { return device }
        }
        throw DisplayServiceError.displayIdentityUnavailable
    }
}

/// Desired state is independent of the recovery cache: temporary enable trials,
/// safety recovery, and macOS wake must not erase a confirmed off intention.
@MainActor
final class DisplayDisconnectPolicyController {
    private(set) var state: DisplayDisconnectPolicyState
    private(set) var safetyEnabledUUIDs: Set<String> = []
    private var confirmedDisabled: [String: DisplayDisconnectIntent] = [:]
    private var startupRecoveryRecords: [String: DisplayManagedRecord]?
    private var attempts: Set<String> = []
    private var physicalTopology: String?
    private let save: (DisplayDisconnectPolicyState) throws -> Void

    init(state: DisplayDisconnectPolicyState = .init(), save: @escaping (DisplayDisconnectPolicyState) throws -> Void) {
        self.state = state
        self.save = save
    }

    var keptDisconnectedUUIDs: Set<String> { Set(state.intents.keys) }

    func setPolicy(_ policy: DisplayDisconnectPolicy, devices: [DisplayDisconnectDevice]) throws {
        guard policy != state.policy else { return }
        var next = DisplayDisconnectPolicyState(policy: policy)
        if policy == .keepDisabled {
            for intent in confirmedDisabled.values {
                if let device = Self.match(intent, devices: devices), !device.display.isEnabled {
                    next.intents[intent.uuid] = intent
                }
            }
        }
        try commit(next)
        safetyEnabledUUIDs.removeAll()
        physicalTopology = nil
        resetAttempts()
    }

    func confirm(states: [String: Bool], devices: [DisplayDisconnectDevice], ownedUUIDs: Set<String>) throws {
        guard !states.isEmpty else { return }
        var next = state
        var confirmed = confirmedDisabled
        var safety = safetyEnabledUUIDs
        for (uuid, enabled) in states {
            guard devices.filter({ $0.display.id == uuid }).count == 1,
                  let device = devices.first(where: { $0.display.id == uuid }), device.display.isEnabled == enabled else {
                throw DisplayServiceError.disconnected
            }
            if enabled {
                next.intents.removeValue(forKey: uuid)
                confirmed.removeValue(forKey: uuid)
                safety.remove(uuid)
            } else if ownedUUIDs.contains(uuid) {
                let intent = DisplayDisconnectIntent(uuid: uuid, name: device.display.name, fingerprint: device.fingerprint)
                guard Self.match(intent, devices: devices) != nil else { throw DisplayServiceError.displayIdentityUnavailable }
                if state.policy == .keepDisabled { next.intents[uuid] = intent }
                confirmed[uuid] = intent
            }
        }
        // No session ownership changes until all participants validate and the
        // single persisted state write succeeds (also used for preset confirm).
        try commit(next)
        confirmedDisabled = confirmed
        safetyEnabledUUIDs = safety
        for uuid in states.keys { startupRecoveryRecords?.removeValue(forKey: uuid) }
    }

    /// A lifecycle wake may explicitly open a new bounded attempt window.
    /// Ordinary refresh never resets failures or starts a retry loop.
    func resetAttempts() { attempts.removeAll() }

    func endSession() {
        confirmedDisabled.removeAll()
        startupRecoveryRecords = nil
        safetyEnabledUUIDs.removeAll()
        physicalTopology = nil
        resetAttempts()
    }

    func retains(_ record: DisplayManagedRecord) -> Bool {
        guard state.policy == .keepDisabled, let intent = state.intents[record.uuid] else { return false }
        return intent.fingerprint.hasSameHardware(as: record.fingerprint)
    }

    @discardableResult
    func reconcile(read: () throws -> [DisplayDisconnectDevice],
                   recoveryRecords: () -> [DisplayManagedRecord],
                   setEnabled: (DisplayDisconnectIntent, Bool) throws -> Void) throws -> Bool {
        var changed = false
        var attemptedRecovery = false
        var firstError: Error?
        let initial = try read()
        observeTopology(initial)
        let physical = initial.filter { !$0.isFallback }
        // A screen-parameter notification can precede the workspace sleep
        // notification. Never wake outputs as a side effect of that race.
        if !physical.isEmpty && physical.allSatisfy(\.isAsleep) { return false }
        if startupRecoveryRecords == nil {
            startupRecoveryRecords = Dictionary(recoveryRecords().filter { $0.restoreOnStop && !retains($0) }
                .map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })
        }
        if let pending = startupRecoveryRecords {
            // Only NooL-owned recovery records qualify. A snapshot of an
            // externally disabled screen must never become our restore policy.
            for record in pending.values.sorted(by: { $0.uuid < $1.uuid }) {
                do {
                    if retains(record) { startupRecoveryRecords?.removeValue(forKey: record.uuid); continue }
                    let devices = try read()
                    let intent = DisplayDisconnectIntent(uuid: record.uuid, name: record.name, fingerprint: record.fingerprint)
                    guard let device = Self.match(intent, devices: devices) else { continue }
                    if device.display.isEnabled { startupRecoveryRecords?.removeValue(forKey: record.uuid); continue }
                    guard reserveAttempt(uuid: record.uuid) else { continue }
                    attemptedRecovery = true
                    try setEnabled(intent, true)
                    guard Self.match(intent, devices: try read())?.display.isEnabled == true else {
                        throw DisplayDisconnectPolicyError.notApplied
                    }
                    changed = true
                    startupRecoveryRecords?.removeValue(forKey: record.uuid)
                } catch { if firstError == nil { firstError = error } }
            }
        }
        let devices = attemptedRecovery ? try read() : initial
        // Sleep is not a zero-output fault. Wait for an explicit wake callback.
        let presentPhysical = devices.filter { !$0.isFallback }
        if !presentPhysical.isEmpty && presentPhysical.allSatisfy(\.isAsleep) {
            if let firstError { throw firstError }
            return changed
        }
        let drawable = devices.filter(\.isDrawable)
        if drawable.isEmpty {
            // Recover one known owned output even under keepDisabled. Never
            // count WindowServer's unkn/virt replacement as visible hardware.
            let owned = recoveryRecords().filter(\.restoreOnStop).map {
                DisplayDisconnectIntent(uuid: $0.uuid, name: $0.name, fingerprint: $0.fingerprint)
            } + Array(state.intents.values)
            let candidates = owned.compactMap { Self.match($0, devices: devices) }
                .filter { !$0.display.isEnabled && !$0.isFallback }
                .sorted { lhs, rhs in
                    if lhs.fingerprint.isBuiltin != rhs.fingerprint.isBuiltin { return lhs.fingerprint.isBuiltin }
                    return lhs.display.id < rhs.display.id
                }
            var visited: Set<String> = []
            for candidate in candidates where visited.insert(candidate.display.id).inserted {
                do {
                    let fresh = try read()
                    if fresh.contains(where: \.isDrawable) { break }
                    let physical = fresh.filter { !$0.isFallback }
                    if !physical.isEmpty && physical.allSatisfy(\.isAsleep) { break }
                    let intent = DisplayDisconnectIntent(uuid: candidate.display.id, name: candidate.display.name,
                                                         fingerprint: candidate.fingerprint)
                    guard let current = Self.match(intent, devices: fresh), !current.display.isEnabled,
                          reserveAttempt(uuid: candidate.display.id) else { continue }
                    try setEnabled(intent, true)
                    let after = try read()
                    guard Self.match(intent, devices: after)?.display.isEnabled == true else {
                        throw DisplayDisconnectPolicyError.notApplied
                    }
                    changed = true
                    if state.intents[candidate.display.id] != nil { safetyEnabledUUIDs.insert(candidate.display.id) }
                    if after.contains(where: \.isDrawable) { break }
                } catch { if firstError == nil { firstError = error } }
            }
            if let firstError { throw firstError }
            return changed
        }
        guard state.policy == .keepDisabled else {
            if let firstError { throw firstError }
            return changed
        }
        for intent in state.intents.values.sorted(by: { $0.uuid < $1.uuid }) {
            do {
                let fresh = try read()
                guard let target = Self.match(intent, devices: fresh), !target.isFallback else { continue }
                if !target.display.isEnabled { safetyEnabledUUIDs.remove(intent.uuid); continue }
                // A mirror follower never provides an independent surviving
                // desktop after its master is removed.
                guard fresh.contains(where: { $0.display.id != target.display.id && $0.isDrawable }) else {
                    safetyEnabledUUIDs.insert(intent.uuid)
                    continue
                }
                guard reserveAttempt(uuid: intent.uuid) else { continue }
                try setEnabled(intent, false)
                guard Self.match(intent, devices: try read())?.display.isEnabled == false else {
                    throw DisplayDisconnectPolicyError.notApplied
                }
                changed = true
                safetyEnabledUUIDs.remove(intent.uuid)
            } catch { if firstError == nil { firstError = error } }
        }
        if let firstError { throw firstError }
        return changed
    }

    private func commit(_ next: DisplayDisconnectPolicyState) throws {
        try save(next)
        state = next
    }

    private func observeTopology(_ devices: [DisplayDisconnectDevice]) {
        // Observe even absent-device/no-action periods: A -> absent -> A is a
        // new reconnect epoch. Numeric IDs, enabled state, frames and phantom
        // replacements can change because of our own commits and are excluded.
        let topology = devices.filter { !$0.isFallback }.map {
            "\($0.display.id.lowercased()):\($0.fingerprint.vendor):\($0.fingerprint.model):\($0.fingerprint.serial):\($0.fingerprint.isBuiltin)"
        }.sorted().joined(separator: "|")
        if topology != physicalTopology { resetAttempts(); physicalTopology = topology }
    }

    private func reserveAttempt(uuid: String) -> Bool {
        guard attempts.count < 1_024 else { return false }
        return attempts.insert(uuid.lowercased()).inserted
    }

    static func match(_ intent: DisplayDisconnectIntent, devices: [DisplayDisconnectDevice]) -> DisplayDisconnectDevice? {
        let matches = devices.filter { $0.fingerprint.hasSameHardware(as: intent.fingerprint) }
        guard matches.count == 1, let device = matches.first, device.display.id.caseInsensitiveCompare(intent.uuid) == .orderedSame,
              device.liveUUID.map({ $0.caseInsensitiveCompare(intent.uuid) == .orderedSame }) ?? true else { return nil }
        return device
    }
}

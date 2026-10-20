import Combine
import Foundation
import IOKit.pwr_mgt

protocol DisplayKeepAwakeDriving: Sendable {
    func create(keepsDisplaysAwake: Bool, timeout: TimeInterval?) throws -> UInt32
    func release(_ assertionID: UInt32) throws
}

protocol DisplayKeepAwakeCancellation: Sendable {
    func cancel()
}

typealias DisplayKeepAwakeSchedule = @MainActor (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> any DisplayKeepAwakeCancellation

@MainActor
final class DisplayKeepAwakeModel: ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var keepsDisplaysAwake = false
    @Published private(set) var expiresAt: Date?
    @Published private(set) var errorMessage: String?

    private let driver: any DisplayKeepAwakeDriving
    private let now: @MainActor () -> Date
    private let schedule: DisplayKeepAwakeSchedule
    private var assertionID: UInt32?
    private var pendingCleanup = Set<UInt32>()
    private var timer: (any DisplayKeepAwakeCancellation)?
    private var timerGeneration = UUID()
    private var cleanupRetryAttempt = 0

    init(driver: any DisplayKeepAwakeDriving = SystemDisplayKeepAwakeDriver(),
         now: @escaping @MainActor () -> Date = Date.init,
         schedule: @escaping DisplayKeepAwakeSchedule = DisplayKeepAwakeModel.scheduleExpiry) {
        self.driver = driver
        self.now = now
        self.schedule = schedule
    }

    deinit {
        timer?.cancel()
        var ids = pendingCleanup
        if let assertionID { ids.insert(assertionID) }
        for id in ids { try? driver.release(id) }
    }

    /// Only explicit user starts create an assertion. Sessions are never restored
    /// from preferences, and nil means until the user turns this session off.
    func start(minutes: Int? = 60) {
        if let minutes, ![15, 30, 60, 120].contains(minutes) {
            errorMessage = "Выберите 15, 30, 60 или 120 минут либо отключение вручную."
            return
        }
        let duration = minutes.map { TimeInterval($0) * 60 }
        replaceAssertion(keepsDisplaysAwake: keepsDisplaysAwake, duration: duration,
                         deadline: duration.map { now().addingTimeInterval($0) })
    }

    func stop() {
        timer?.cancel()
        timer = nil
        timerGeneration = UUID()
        var ids = pendingCleanup
        if let assertionID { ids.insert(assertionID) }
        var failed = Set<UInt32>()
        for id in ids {
            do { try driver.release(id) }
            catch { failed.insert(id) }
        }
        if let assertionID, !failed.contains(assertionID) { self.assertionID = nil }
        pendingCleanup = failed.subtracting(assertionID.map { [$0] } ?? [])
        isActive = !failed.isEmpty
        if !isActive {
            expiresAt = nil
            cleanupRetryAttempt = 0
        } else {
            // A disabled module can no longer expose a retry button. Keep
            // retrying owned IDs without retaining the feature model forever.
            let delays: [TimeInterval] = [1, 2, 5, 10, 30]
            let delay = delays[min(cleanupRetryAttempt, delays.count - 1)]
            cleanupRetryAttempt = min(cleanupRetryAttempt + 1, delays.count - 1)
            let generation = timerGeneration
            timer = schedule(delay) { [weak self] in
                guard let self, self.timerGeneration == generation else { return }
                self.stop()
            }
        }
        errorMessage = failed.isEmpty ? nil : "Не удалось завершить режим бодрствования. Повторите отключение."
    }

    func shutdown() { stop() }

    func setKeepsDisplaysAwake(_ enabled: Bool) {
        guard enabled != keepsDisplaysAwake else { return }
        guard isActive else {
            keepsDisplaysAwake = enabled
            errorMessage = nil
            return
        }
        let remaining = expiresAt.map { $0.timeIntervalSince(now()) }
        if let remaining, remaining <= 0 {
            stop()
            if !isActive { keepsDisplaysAwake = enabled }
            return
        }
        replaceAssertion(keepsDisplaysAwake: enabled, duration: remaining, deadline: expiresAt)
    }

    private func replaceAssertion(keepsDisplaysAwake enabled: Bool, duration: TimeInterval?, deadline: Date?) {
        // A failed rollback must remain owned and retryable. Do not accumulate
        // replacement assertions while one of them still needs cleanup.
        for id in Array(pendingCleanup) {
            do { try driver.release(id); pendingCleanup.remove(id) }
            catch {
                errorMessage = "Не удалось освободить предыдущий режим бодрствования. Повторите отключение."
                return
            }
        }
        let replacement: UInt32
        do { replacement = try driver.create(keepsDisplaysAwake: enabled, timeout: duration) }
        catch {
            errorMessage = "Не удалось включить режим бодрствования."
            return
        }
        if let assertionID {
            do { try driver.release(assertionID) }
            catch {
                do { try driver.release(replacement) }
                catch { pendingCleanup.insert(replacement) }
                errorMessage = "Не удалось изменить режим бодрствования. Предыдущий режим остаётся включённым."
                return
            }
        }
        assertionID = replacement
        keepsDisplaysAwake = enabled
        isActive = true
        expiresAt = deadline
        errorMessage = nil
        cleanupRetryAttempt = 0
        timer?.cancel()
        timer = nil
        timerGeneration = UUID()
        if let duration {
            let generation = timerGeneration
            timer = schedule(duration) { [weak self] in
                guard let self, self.timerGeneration == generation else { return }
                self.stop()
            }
        }
    }

    private static func scheduleExpiry(_ duration: TimeInterval,
                                       action: @escaping @MainActor @Sendable () -> Void) -> any DisplayKeepAwakeCancellation {
        DisplayKeepAwakeTaskTimer(task: Task { @MainActor in
            do { try await Task.sleep(for: .seconds(duration)) }
            catch { return }
            guard !Task.isCancelled else { return }
            action()
        })
    }
}

private struct DisplayKeepAwakeTaskTimer: DisplayKeepAwakeCancellation {
    let task: Task<Void, Never>
    func cancel() { task.cancel() }
}

struct SystemDisplayKeepAwakeDriver: DisplayKeepAwakeDriving {
    func create(keepsDisplaysAwake: Bool, timeout: TimeInterval?) throws -> UInt32 {
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithProperties(Self.properties(keepsDisplaysAwake: keepsDisplaysAwake,
                                                                      timeout: timeout) as CFDictionary, &id)
        guard result == kIOReturnSuccess else { throw DisplayKeepAwakeDriverError.operationFailed(result) }
        return id
    }

    func release(_ assertionID: UInt32) throws {
        let result = IOPMAssertionRelease(assertionID)
        guard result == kIOReturnSuccess || result == kIOReturnNotFound else {
            throw DisplayKeepAwakeDriverError.operationFailed(result)
        }
    }

    static func properties(keepsDisplaysAwake: Bool, timeout: TimeInterval?) -> [String: Any] {
        var properties: [String: Any] = [
            kIOPMAssertionTypeKey: keepsDisplaysAwake
                ? kIOPMAssertionTypePreventUserIdleDisplaySleep : kIOPMAssertionTypePreventUserIdleSystemSleep,
            kIOPMAssertionNameKey: "NooL App — Keep Awake",
            kIOPMAssertionLevelKey: kIOPMAssertionLevelOn,
        ]
        if let timeout {
            properties[kIOPMAssertionTimeoutKey] = timeout
            // The OS turns the assertion off even if our timer cannot run. Keep
            // ownership of its ID so stop/expiry release it exactly once.
            properties[kIOPMAssertionTimeoutActionKey] = kIOPMAssertionTimeoutActionTurnOff
        }
        return properties
    }
}

private enum DisplayKeepAwakeDriverError: Error {
    case operationFailed(IOReturn)
}

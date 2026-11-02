import Foundation

/// All methods are called on one helper-owned serial queue. Neither client
/// timers nor visibility of an app window own the fan control lifecycle.
public final class CoolingController {
    private struct Active {
        var request: CoolingControlRequest
        var endsAt: Date?
        var lastPercent: Double
    }
    private let hardware: CoolingHardware
    private let persistOwned: (Set<Int>) throws -> Void
    private let thermalPressureIsHigh: () -> Bool
    private var active: [Int: Active] = [:]
    private var pendingRecovery: Set<Int> = []
    private var session: String?
    private var lastHeartbeat: TimeInterval = 0
    private var lastTick: TimeInterval?
    private var notice: String?

    public init(hardware: CoolingHardware, persistOwned: @escaping (Set<Int>) throws -> Void = { _ in },
                thermalPressureIsHigh: @escaping () -> Bool = {
                    let state = ProcessInfo.processInfo.thermalState
                    return state == .serious || state == .critical
                }) {
        self.hardware = hardware; self.persistOwned = persistOwned; self.thermalPressureIsHigh = thermalPressureIsHigh
    }

    public func snapshot() throws -> CoolingSnapshot {
        var result = try hardware.snapshot()
        result.controlledFanIDs = active.keys.sorted()
        for index in result.fans.indices {
            if let state = active[result.fans[index].id] {
                result.fans[index].mode = state.request.mode
                result.fans[index].boostEndsAt = state.endsAt
                result.fans[index].sensorID = state.request.sensorID
                result.fans[index].curve = state.request.curve
            }
        }
        if let notice { result.notice = notice }
        return result
    }

    @discardableResult
    public func apply(_ request: CoolingControlRequest, now: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) throws -> CoolingSnapshot {
        guard request.protocolVersion == CoolingService.protocolVersion else { throw CoolingError.invalidRequest("Обновите помощник управления охлаждением.") }
        guard UUID(uuidString: request.sessionID) != nil, !request.fanIDs.isEmpty,
              request.fanIDs.count <= 10, Set(request.fanIDs).count == request.fanIDs.count else {
            throw CoolingError.invalidRequest("Некорректный запрос управления.")
        }
        if let session, session != request.sessionID { throw CoolingError.sessionBusy }
        guard pendingRecovery.isEmpty else { throw CoolingError.hardware("Восстанавливаем автоматическое управление. Повторите после завершения.") }
        let current = try hardware.snapshot()
        if request.mode != .automatic {
            guard !current.fans.contains(where: { $0.mode != .automatic && active[$0.id] == nil }) else {
                throw CoolingError.unavailable("Ручным охлаждением уже управляет другая программа. Верните её в автоматический режим.")
            }
            guard !thermalPressureIsHigh(), !current.sensors.isEmpty else {
                throw CoolingError.unavailable("Ручное управление недоступно при перегреве или отсутствии датчиков температуры.")
            }
        }
        let fans = try request.fanIDs.map { id -> CoolingFan in
            guard let fan = current.fans.first(where: { $0.id == id }), fan.controlSupported else {
                throw CoolingError.unavailable("Управление этим вентилятором недоступно.")
            }
            return fan
        }
        let initialPercent = try Self.validate(request, snapshot: current)
        // Persist ownership BEFORE the first SMC mutation. A root helper restart
        // can then restore only fans we actually intended to control.
        let previousIDs = Set(active.keys)
        if request.mode != .automatic { try persistOwned(previousIDs.union(request.fanIDs)) }
        do {
            for fan in fans {
                if request.mode == .automatic {
                    try hardware.setAutomatic(fanID: fan.id)
                    active.removeValue(forKey: fan.id)
                } else {
                    let rpm = Self.rpm(percent: initialPercent, fan: fan)
                    try hardware.setTarget(fanID: fan.id, rpm: rpm)
                    active[fan.id] = Active(request: request,
                        endsAt: request.mode == .boost ? now.addingTimeInterval(request.durationSeconds ?? 120) : nil,
                        lastPercent: initialPercent)
                }
            }
            if active.isEmpty { try hardware.finishControl(); session = nil }
            else { session = request.sessionID; lastHeartbeat = uptime; lastTick = uptime }
            try persistOwned(Set(active.keys))
            notice = nil
        } catch {
            // Includes a fan whose write failed halfway through enabling mode.
            let recoveryIDs = Set(active.keys).union(previousIDs).union(request.mode == .automatic ? [] : request.fanIDs)
            try? restore(ids: recoveryIDs)
            throw error
        }
        return try snapshot()
    }

    public func heartbeat(sessionID: String, uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) throws {
        guard let session else { return }
        guard session == sessionID else { throw CoolingError.sessionBusy }
        lastHeartbeat = uptime
    }

    public func release(sessionID: String) throws {
        if let session, session != sessionID { throw CoolingError.sessionBusy }
        try restoreAll()
    }

    public func tick(now: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        if !pendingRecovery.isEmpty { try? restore(ids: pendingRecovery.union(active.keys)); return }
        guard !active.isEmpty else { lastTick = uptime; return }
        let interrupted = lastTick.map { uptime < $0 || uptime - $0 > 5 } ?? false
        lastTick = uptime
        guard !interrupted, uptime >= lastHeartbeat, uptime - lastHeartbeat < CoolingService.leaseDuration else {
            do {
                try restore(ids: Set(active.keys))
                notice = "Связь с приложением потеряна. Автоматическое управление восстановлено."
            } catch { notice = "Не удалось подтвердить автоматический режим. Помощник повторяет восстановление." }
            return
        }
        do {
            let current = try hardware.snapshot()
            guard !thermalPressureIsHigh(), !current.sensors.isEmpty else {
                throw CoolingError.hardware("Температурная защита macOS или потеря датчиков температуры.")
            }
            for (id, state) in active {
                if let end = state.endsAt, end <= now { try restore(ids: [id]); continue }
                guard let fan = current.fans.first(where: { $0.id == id }), fan.controlSupported else {
                    throw CoolingError.hardware("Данные вентилятора недоступны.")
                }
                guard fan.mode == .manual, let target = fan.targetRPM, target.isFinite,
                      abs(target - Self.rpm(percent: state.lastPercent, fan: fan)) <= 50 else {
                    throw CoolingError.hardware("SMC изменил режим или целевые обороты после применения команды.")
                }
                if state.request.mode == .curve {
                    guard let sensor = current.sensors.first(where: { $0.id == state.request.sensorID }), sensor.controlEligible,
                          sensor.celsius.isFinite, sensor.celsius > 0, sensor.celsius < 125 else {
                        throw CoolingError.hardware("Датчик температурной кривой недоступен.")
                    }
                    let desired = Self.interpolate(temperature: sensor.celsius, points: state.request.curve ?? [])
                    // Fast increase, slower decrease prevents audible oscillation.
                    let next = min(state.lastPercent + 15, max(state.lastPercent - 3, desired))
                    if abs(next - state.lastPercent) >= 1 {
                        try hardware.setTarget(fanID: id, rpm: Self.rpm(percent: next, fan: fan))
                        active[id]?.lastPercent = next
                    }
                }
            }
        } catch {
            let reason = error.localizedDescription
            do { try restore(ids: Set(active.keys)); notice = "\(reason) Включено автоматическое управление." }
            catch { notice = "Не удалось подтвердить автоматический режим. Помощник повторяет восстановление." }
        }
    }

    /// Called on power sleep, shutdown, last controlling connection invalidation.
    public func restoreAll() throws { try restore(ids: Set(active.keys).union(pendingRecovery)) }

    private func restore(ids: Set<Int>) throws {
        var failure: Error?
        for id in ids {
            do { try hardware.setAutomatic(fanID: id); active.removeValue(forKey: id) }
            catch { failure = error }
        }
        if active.isEmpty && failure == nil {
            do { try hardware.finishControl(); session = nil }
            catch { failure = error }
        }
        // On failed restore retain the marker and the active entry: the next
        // watchdog tick/startup recovery retries instead of declaring success.
        if failure == nil {
            let remaining = pendingRecovery.subtracting(ids)
            do { try persistOwned(Set(active.keys).union(remaining)); pendingRecovery = remaining }
            catch { pendingRecovery.formUnion(ids); throw error }
        } else { pendingRecovery.formUnion(ids) }
        if let failure { throw failure }
    }

    public static func validate(_ request: CoolingControlRequest, snapshot: CoolingSnapshot) throws -> Double {
        switch request.mode {
        case .automatic: return 0
        case .manual:
            guard let value = request.targetPercent, value.isFinite, (0...100).contains(value) else {
                throw CoolingError.invalidRequest("Выберите уровень вентилятора от 0 до 100%.")
            }
            return value
        case .boost:
            guard let duration = request.durationSeconds, duration.isFinite, (10...900).contains(duration) else {
                throw CoolingError.invalidRequest("Продолжительность охлаждения должна быть от 10 секунд до 15 минут.")
            }
            return 100
        case .curve:
            guard let id = request.sensorID, let sensor = snapshot.sensors.first(where: { $0.id == id }), sensor.controlEligible,
                  sensor.celsius.isFinite, sensor.celsius > 0, sensor.celsius < 125,
                  let points = request.curve, (2...12).contains(points.count) else {
                throw CoolingError.invalidRequest("Выберите доступный датчик и задайте от 2 до 12 точек кривой.")
            }
            var previousTemperature = -Double.infinity
            var previousPercent = -Double.infinity
            for point in points {
                guard point.temperature.isFinite, point.percent.isFinite, (20...110).contains(point.temperature),
                      (0...100).contains(point.percent), point.temperature > previousTemperature,
                      point.percent >= previousPercent else {
                    throw CoolingError.invalidRequest("Температуры кривой должны возрастать, а обороты не должны уменьшаться.")
                }
                previousTemperature = point.temperature; previousPercent = point.percent
            }
            return interpolate(temperature: sensor.celsius, points: points)
        }
    }

    public static func interpolate(temperature: Double, points: [CoolingCurvePoint]) -> Double {
        guard temperature.isFinite, let first = points.first else { return 100 }
        if temperature <= first.temperature { return first.percent }
        for (left, right) in zip(points, points.dropFirst()) where temperature <= right.temperature {
            let span = right.temperature - left.temperature
            guard span > 0 else { return 100 }
            return left.percent + (right.percent - left.percent) * (temperature - left.temperature) / span
        }
        return points.last?.percent ?? 100
    }
    private static func rpm(percent: Double, fan: CoolingFan) -> Double {
        fan.minimumRPM + (fan.maximumRPM - fan.minimumRPM) * min(100, max(0, percent)) / 100
    }
}

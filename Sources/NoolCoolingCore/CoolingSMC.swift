import Foundation
import IOKit

// AppleSMC's user-client wire layout and fan key conventions are based on Stats
// (MIT, Serhiy Mytrovtsiy). See third_party/stats-smc-LICENSE. The SMC protocol is
// undocumented: unknown data types and unsupported fan layouts remain read-only.
public final class CoolingSMC: CoolingHardware, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var connection: io_connect_t = 0
    private var temperatureKeys: [String]?
    private var information: [String: (UInt32, UInt32)] = [:]
    private var unlockedTestMode = false

    public init() {}
    deinit { if connection != 0 { IOServiceClose(connection) } }

    private func connect() throws {
        if connection != 0 { return }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw CoolingError.unavailable("Датчики AppleSMC недоступны на этом Mac.") }
        defer { IOObjectRelease(service) }
        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard result == kIOReturnSuccess else { connection = 0; throw CoolingError.unavailable("Нет доступа к датчикам AppleSMC (\(result)).") }
    }

    public func snapshot() throws -> CoolingSnapshot {
        lock.lock(); defer { lock.unlock() }
        try connect()
        #if arch(arm64)
        let externalGate = number("Ftst") == 1 && !unlockedTestMode
        #else
        let externalGate = false
        #endif
        let rawCount = number("FNum") ?? 0
        let fanCount = rawCount.isFinite && rawCount >= 0 ? Int(min(10, rawCount)) : 0
        let fans = (0..<fanCount).compactMap { id -> CoolingFan? in
            guard let current = number("F\(id)Ac"), current.isFinite, current >= 0 else { return nil }
            let minimum = number("F\(id)Mn") ?? 0
            let maximum = number("F\(id)Mx") ?? 0
            let mode = number(modeKey(id))
            let target = number("F\(id)Tg")
            let supported = minimum.isFinite && maximum.isFinite && minimum >= 0 && maximum > minimum
                && mode != nil && target != nil && !externalGate
            var name = "Вентилятор \(id + 1)"
            if let value = try? read("F\(id)ID"), value.bytes.count > 4,
               let text = String(bytes: value.bytes.dropFirst(4).prefix { $0 != 0 }, encoding: .utf8), !text.isEmpty {
                name = text.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if fanCount == 2 { name = id == 0 ? "Левый" : "Правый" }
            return CoolingFan(id: id, name: name, currentRPM: current, minimumRPM: max(0, minimum), maximumRPM: max(0, maximum),
                              targetRPM: target, mode: mode == 1 ? .manual : .automatic, controlSupported: supported)
        }
        let sensors = discoverTemperatureKeys().compactMap { key -> CoolingSensor? in
            guard let value = number(key), value.isFinite, value >= 10, value < 125 else { return nil }
            return CoolingSensor(id: key, name: Self.sensorName(key), celsius: value, controlEligible: Self.cpuKeys.contains(key) || Self.gpuKeys.contains(key))
        }.sorted {
            if $0.controlEligible != $1.controlEligible { return $0.controlEligible }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return CoolingSnapshot(fans: fans, sensors: sensors, controlAvailable: fans.contains(where: \.controlSupported),
                               notice: externalGate ? "Охлаждением уже управляет другая программа. Верните её в автоматический режим." :
                                (fans.isEmpty ? "Вентиляторы не обнаружены. На Mac с пассивным охлаждением доступны только датчики." : nil))
    }

    public func setTarget(fanID: Int, rpm: Double) throws {
        lock.lock(); defer { lock.unlock() }
        guard (0..<10).contains(fanID), rpm.isFinite,
              let minimum = number("F\(fanID)Mn"), let maximum = number("F\(fanID)Mx"),
              minimum >= 0, maximum > minimum, (minimum...maximum).contains(rpm) else {
            throw CoolingError.invalidRequest("Обороты выходят за поддерживаемый диапазон вентилятора.")
        }
        let key = modeKey(fanID)
        var unlock: (() throws -> Void)?
        #if arch(arm64)
        if number("Ftst") != nil {
            unlock = { [self] in
                if number("Ftst") == 1 && !unlockedTestMode {
                    throw CoolingError.unavailable("Управление охлаждением уже занято другой программой (Ftst).")
                }
                // Record our responsibility before a write: even an error may
                // follow a partial device-side change, requiring rollback.
                unlockedTestMode = true
                if number("Ftst") != 1 {
                    try writeNumber("Ftst", 1)
                    // Global unlock is shared by linked fans. Wait only on the
                    // actual 0 -> 1 transition, rather than once per fan.
                    Thread.sleep(forTimeInterval: 3)
                }
                guard number("Ftst") == 1 else {
                    throw CoolingError.hardware("SMC не подтвердил передачу управления охлаждением (Ftst).")
                }
            }
        }
        #endif
        #if arch(x86_64)
        if let mask = number("FS! "), mask.isFinite, (0...65535).contains(mask) { try writeNumber("FS! ", Double(UInt16(mask) | (UInt16(1) << fanID))) }
        #endif
        try CoolingFanModeTransition.applyTarget(rpm: rpm,
            readMode: { self.number(key) }, readTarget: { self.number("F\(fanID)Tg") },
            writeManual: { try self.writeNumber(key, 1) },
            writeTarget: { try self.writeNumber("F\(fanID)Tg", rpm) }, unlock: unlock)
    }

    public func setAutomatic(fanID: Int) throws {
        lock.lock(); defer { lock.unlock() }
        guard (0..<10).contains(fanID) else { throw CoolingError.invalidRequest("Неизвестный вентилятор.") }
        try writeNumber(modeKey(fanID), 0)
        #if arch(arm64)
        try writeNumber("F\(fanID)Tg", 0)
        #else
        if let mask = number("FS! "), mask.isFinite, (0...65535).contains(mask) { try writeNumber("FS! ", Double(UInt16(mask) & ~(UInt16(1) << fanID))) }
        #endif
        try CoolingFanModeTransition.verifyAutomatic(readMode: { self.number(self.modeKey(fanID)) })
    }

    public func finishControl() throws {
        lock.lock(); defer { lock.unlock() }
        #if arch(arm64)
        // Called only after all fans owned by this controller were restored.
        if unlockedTestMode {
            try writeNumber("Ftst", 0)
            try CoolingFanModeTransition.verifySystemGate(readGate: { self.number("Ftst") })
            unlockedTestMode = false
        }
        #endif
    }

    /// Startup recovery has its own persisted ownership evidence, so can reset
    /// the global unlock after a helper crash without touching unrelated sessions.
    public func recoverControl(fanIDs: [Int]) throws {
        lock.lock(); defer { lock.unlock() }
        var failure: Error?
        for id in fanIDs { do { try setAutomatic(fanID: id) } catch { failure = error } }
        #if arch(arm64)
        if number("Ftst") != nil {
            do {
                try writeNumber("Ftst", 0)
                try CoolingFanModeTransition.verifySystemGate(readGate: { self.number("Ftst") })
            } catch { failure = error }
        }
        #endif
        if let failure { throw failure }
    }

    private func modeKey(_ id: Int) -> String {
        #if arch(arm64)
        return (try? read("F\(id)md")) != nil ? "F\(id)md" : "F\(id)Md"
        #else
        return "F\(id)Md"
        #endif
    }

    private func discoverTemperatureKeys() -> [String] {
        if let temperatureKeys { return temperatureKeys }
        var keys = Set(["TC0P", "TC0D", "TC0E", "TC0F", "TCGC", "TG0P", "TG0D", "TB0T", "Tp0P", "Tp01", "Tp05", "Tp09", "Tp0D", "Tg0f"])
        if let count = number("#KEY"), count.isFinite, count >= 0 {
            for index in 0..<Int(min(4096, count)) {
                var request = [UInt8](repeating: 0, count: 80)
                request[42] = 8; Self.put(UInt32(index), into: &request, at: 44)
                if let response = try? call(request), let key = Self.key(Self.get(response, at: 0)), key.hasPrefix("T") { keys.insert(key) }
            }
        }
        let found = keys.filter { key in
            guard let value = try? read(key) else { return false }
            return value.type == Self.code("sp78") || value.type == Self.code("flt ")
        }.sorted { left, right in
            // A lexical cap can drop all Tg/Tp zones behind hundreds of other
            // T keys. Keep recognized CPU/GPU sensors before optional readings.
            let leftKnown = Self.cpuKeys.contains(left) || Self.gpuKeys.contains(left)
            let rightKnown = Self.cpuKeys.contains(right) || Self.gpuKeys.contains(right)
            return leftKnown == rightKnown ? left < right : leftKnown
        }
        temperatureKeys = Array(found.prefix(128))
        return temperatureKeys ?? []
    }

    // Sensor families used as CPU/GPU zones by Stats' maintained Sensors map.
    // A zone's exact core/cluster changes across SoCs, so we retain the real key
    // and deliberately avoid inventing individual core numbering.
    private static let cpuKeys: Set<String> = ["TC0P", "TC0D", "TC0E", "TC0F", "TCGC", "Tp00", "Tp01", "Tp04", "Tp05", "Tp07", "Tp08", "Tp09", "Tp0C", "Tp0D", "Tp0E", "Tp0G", "Tp0H", "Tp0I", "Tp0K", "Tp0L", "Tp0O", "Tp0P", "Tp0R", "Tp0T", "Tp0U", "Tp0V", "Tp0X", "Tp0Y", "Tp0a", "Tp0b", "Tp0d", "Tp0e", "Tp0f", "Tp0g", "Tp0j", "Tp0m", "Tp0p", "Tp0u", "Tp0y", "Tp1h", "Tp1t", "Tp1p", "Tp1l", "Te05", "Te07", "Te08", "Te09", "Te0L", "Te0P", "Te0S", "Te0H", "Te0c", "Te0h", "Te0i", "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E", "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E"]
    private static let gpuKeys: Set<String> = ["TG0P", "TG0D", "Tg05", "Tg07", "Tg09", "Tg0D", "Tg0G", "Tg0H", "Tg0K", "Tg0L", "Tg0T", "Tg0U", "Tg0X", "Tg0a", "Tg0b", "Tg0c", "Tg0d", "Tg0e", "Tg0f", "Tg0g", "Tg0j", "Tg0k", "Tg1U", "Tg1Y", "Tg1c", "Tg1d", "Tg1e", "Tg1f", "Tg1g", "Tg1h", "Tg1k", "Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A"]
    private static func sensorName(_ key: String) -> String {
        let names = ["TC0P": "CPU — близость", "TC0D": "CPU — кристалл", "TC0E": "CPU", "TC0F": "CPU", "TCGC": "CPU — графика", "TG0P": "GPU — близость", "TG0D": "GPU — кристалл", "TB0T": "Аккумулятор"]
        // Apple changes sensor identifiers between SoCs. Keep the real key visible
        // instead of claiming that a thermal zone is an individual CPU core.
        if let name = names[key] { return "\(name) (\(key))" }
        if cpuKeys.contains(key) { return "CPU — зона \(key)" }
        if gpuKeys.contains(key) { return "GPU — зона \(key)" }
        return "Датчик \(key)"
    }

    private struct Value { var type: UInt32; var bytes: [UInt8] }
    private func number(_ key: String) -> Double? {
        guard let value = try? read(key) else { return nil }
        let bytes = value.bytes
        switch value.type {
        case Self.code("ui8 "): return bytes.first.map(Double.init)
        case Self.code("ui16"): guard bytes.count >= 2 else { return nil }; return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case Self.code("ui32"): guard bytes.count >= 4 else { return nil }; return Double(bytes.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        case Self.code("fpe2"): guard bytes.count >= 2 else { return nil }; return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        case Self.code("sp78"): guard bytes.count >= 2 else { return nil }; return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        case Self.code("flt "):
            guard bytes.count >= 4 else { return nil }
            let bits = bytes.prefix(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
            let number = Double(Float(bitPattern: bits)); return number.isFinite ? number : nil
        default: return nil
        }
    }

    private func writeNumber(_ key: String, _ number: Double) throws {
        guard number.isFinite, number >= 0 else { throw CoolingError.invalidRequest("Недопустимое значение SMC.") }
        let old = try read(key)
        var bytes = old.bytes
        switch old.type {
        case Self.code("ui8 "):
            guard number <= 255, bytes.count == 1 else { throw CoolingError.hardware("Неизвестный формат режима вентилятора.") }; bytes[0] = UInt8(number)
        case Self.code("ui16"):
            guard number <= 65535, bytes.count == 2 else { throw CoolingError.hardware("Неизвестный формат режима вентилятора.") }
            bytes[0] = UInt8(UInt16(number) >> 8); bytes[1] = UInt8(UInt16(number) & 255)
        case Self.code("fpe2"):
            guard number <= 16383, bytes.count == 2 else { throw CoolingError.hardware("Неизвестный формат оборотов.") }
            let value = UInt16(number * 4); bytes[0] = UInt8(value >> 8); bytes[1] = UInt8(value & 255)
        case Self.code("flt "):
            guard bytes.count == 4, number <= Double(Float.greatestFiniteMagnitude) else { throw CoolingError.hardware("Неизвестный формат оборотов.") }
            let bits = Float(number).bitPattern
            for i in 0..<4 { bytes[i] = UInt8((bits >> (i * 8)) & 255) }
        default: throw CoolingError.hardware("Формат управления этим вентилятором не поддерживается.")
        }
        var request = [UInt8](repeating: 0, count: 80)
        Self.put(Self.code(key), into: &request, at: 0); Self.put(UInt32(bytes.count), into: &request, at: 28)
        request[42] = 6
        request.replaceSubrange(48..<(48 + bytes.count), with: bytes)
        _ = try call(request)
    }

    private func read(_ key: String) throws -> Value {
        try connect()
        guard key.utf8.count == 4 else { throw CoolingError.hardware("Некорректный ключ SMC.") }
        var request = [UInt8](repeating: 0, count: 80)
        Self.put(Self.code(key), into: &request, at: 0)
        let info: (UInt32, UInt32)
        if let cached = information[key] { info = cached }
        else {
            request[42] = 9
            let response = try call(request)
            info = (Self.get(response, at: 28), Self.get(response, at: 32))
            guard info.0 > 0 && info.0 <= 32 else { throw CoolingError.hardware("Некорректный размер данных SMC.") }
            information[key] = info
        }
        Self.put(info.0, into: &request, at: 28); request[42] = 5
        let response = try call(request)
        return Value(type: info.1, bytes: Array(response[48..<(48 + Int(info.0))]))
    }

    private func call(_ request: [UInt8]) throws -> [UInt8] {
        var response = [UInt8](repeating: 0, count: 80)
        var size = 80
        let result = request.withUnsafeBytes { input in
            response.withUnsafeMutableBytes { output in
                IOConnectCallStructMethod(connection, 2, input.baseAddress, input.count, output.baseAddress, &size)
            }
        }
        guard result == kIOReturnSuccess, size == 80, response[40] == 0 else {
            throw CoolingError.hardware("AppleSMC отклонил запрос (\(result), \(response[40])).")
        }
        return response
    }
    private static func code(_ key: String) -> UInt32 { key.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }
    private static func key(_ code: UInt32) -> String? { String(bytes: [UInt8((code >> 24) & 255), UInt8((code >> 16) & 255), UInt8((code >> 8) & 255), UInt8(code & 255)], encoding: .ascii) }
    private static func put(_ value: UInt32, into bytes: inout [UInt8], at offset: Int) {
        for i in 0..<4 { bytes[offset + i] = UInt8((value >> (i * 8)) & 255) }
    }
    private static func get(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << ($1 * 8) }
    }
}

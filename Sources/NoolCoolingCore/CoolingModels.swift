import Foundation

public enum CoolingService {
    public static let machServiceName = "com.nool.cooling-helper"
    public static let protocolVersion = 1
    public static let leaseDuration: TimeInterval = 12
}

@objc public protocol NoolCoolingHelperProtocol {
    func snapshot(reply: @escaping (Data?, String?) -> Void)
    func apply(_ request: Data, reply: @escaping (Data?, String?) -> Void)
    func heartbeat(_ sessionID: String, reply: @escaping (String?) -> Void)
    func release(_ sessionID: String, reply: @escaping (String?) -> Void)
}

public enum CoolingControlMode: String, Codable, Sendable, CaseIterable {
    case automatic, manual, boost, curve
}

public struct CoolingCurvePoint: Codable, Sendable, Equatable, Identifiable {
    public var temperature: Double
    public var percent: Double
    public var id: Double { temperature }
    public init(temperature: Double, percent: Double) { self.temperature = temperature; self.percent = percent }
}

public struct CoolingSensor: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var celsius: Double
    public var controlEligible: Bool
    public init(id: String, name: String, celsius: Double, controlEligible: Bool = true) {
        self.id = id; self.name = name; self.celsius = celsius; self.controlEligible = controlEligible
    }
}

public struct CoolingFan: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var name: String
    public var currentRPM: Double
    public var minimumRPM: Double
    public var maximumRPM: Double
    public var targetRPM: Double?
    public var mode: CoolingControlMode
    public var controlSupported: Bool
    public var boostEndsAt: Date?
    public var sensorID: String?
    public var curve: [CoolingCurvePoint]?
    public var targetPercent: Double? {
        guard let targetRPM, maximumRPM > minimumRPM else { return nil }
        return min(100, max(0, (targetRPM - minimumRPM) / (maximumRPM - minimumRPM) * 100))
    }
    public init(id: Int, name: String, currentRPM: Double, minimumRPM: Double, maximumRPM: Double,
                targetRPM: Double? = nil, mode: CoolingControlMode = .automatic, controlSupported: Bool = false,
                boostEndsAt: Date? = nil, sensorID: String? = nil, curve: [CoolingCurvePoint]? = nil) {
        self.id = id; self.name = name; self.currentRPM = currentRPM; self.minimumRPM = minimumRPM
        self.maximumRPM = maximumRPM; self.targetRPM = targetRPM; self.mode = mode
        self.controlSupported = controlSupported; self.boostEndsAt = boostEndsAt; self.sensorID = sensorID; self.curve = curve
    }
}

public struct CoolingSnapshot: Codable, Sendable, Equatable {
    public var protocolVersion: Int
    public var sampledAt: Date
    public var fans: [CoolingFan]
    public var sensors: [CoolingSensor]
    public var controlAvailable: Bool
    public var controlledFanIDs: [Int] = []
    public var notice: String?
    public init(sampledAt: Date = Date(), fans: [CoolingFan] = [], sensors: [CoolingSensor] = [], controlAvailable: Bool = false, notice: String? = nil) {
        self.protocolVersion = CoolingService.protocolVersion; self.sampledAt = sampledAt; self.fans = fans
        self.sensors = sensors; self.controlAvailable = controlAvailable; self.notice = notice
    }
}

public struct CoolingControlRequest: Codable, Sendable, Equatable {
    public var protocolVersion: Int
    public var sessionID: String
    public var fanIDs: [Int]
    public var mode: CoolingControlMode
    public var targetPercent: Double?
    public var durationSeconds: Double?
    public var sensorID: String?
    public var curve: [CoolingCurvePoint]?
    public init(sessionID: String, fanIDs: [Int], mode: CoolingControlMode, targetPercent: Double? = nil,
                durationSeconds: Double? = nil, sensorID: String? = nil, curve: [CoolingCurvePoint]? = nil) {
        self.protocolVersion = CoolingService.protocolVersion; self.sessionID = sessionID; self.fanIDs = fanIDs
        self.mode = mode; self.targetPercent = targetPercent; self.durationSeconds = durationSeconds
        self.sensorID = sensorID; self.curve = curve
    }
}

public enum CoolingError: LocalizedError {
    case unavailable(String), invalidRequest(String), hardware(String), sessionBusy
    public var errorDescription: String? {
        switch self {
        case .unavailable(let text), .invalidRequest(let text), .hardware(let text): return text
        case .sessionBusy: return "Управление уже используется другим сеансом NooL."
        }
    }
}

public protocol CoolingHardware: AnyObject {
    func snapshot() throws -> CoolingSnapshot
    func setTarget(fanID: Int, rpm: Double) throws
    func setAutomatic(fanID: Int) throws
    func finishControl() throws
}

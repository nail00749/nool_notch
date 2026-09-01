import Foundation

public enum QuotaUnit: String, Codable, Sendable {
    case requests
    case messages
    case tokens
    case credits
    case percentage
    case unknown

    public var shortLabel: String {
        switch self {
        case .requests: "запросов"
        case .messages: "сообщений"
        case .tokens: "токенов"
        case .credits: "кредитов"
        case .percentage: "осталось"
        case .unknown: "единиц"
        }
    }
}

public enum ProviderConnectionState: String, Codable, Sendable {
    case live
    case stale
    case unavailable
    case requiresAuthentication

    public var label: String {
        switch self {
        case .live: "LIVE"
        case .stale: "DEMO / STALE"
        case .unavailable: "UNAVAILABLE"
        case .requiresAuthentication: "AUTH REQUIRED"
        }
    }
}

public struct QuotaWindow: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let label: String
    public let limit: Double?
    public let remaining: Double?
    public let resetAt: Date?
    public let unit: QuotaUnit

    public init(
        id: String,
        label: String,
        limit: Double?,
        remaining: Double?,
        resetAt: Date?,
        unit: QuotaUnit
    ) {
        self.id = id
        self.label = label
        self.limit = limit
        self.remaining = remaining
        self.resetAt = resetAt
        self.unit = unit
    }

    public var remainingRatio: Double? {
        guard let limit, let remaining, limit > 0 else { return nil }
        return min(max(remaining / limit, 0), 1)
    }
}

public struct QuotaSnapshot: Codable, Equatable, Sendable {
    public let providerID: String
    public let providerName: String
    public let windows: [QuotaWindow]
    public let connection: ProviderConnectionState
    public let updatedAt: Date
    public let sourceURL: URL?
    public let message: String?

    public init(
        providerID: String,
        providerName: String,
        windows: [QuotaWindow],
        connection: ProviderConnectionState,
        updatedAt: Date,
        sourceURL: URL?,
        message: String?
    ) {
        self.providerID = providerID
        self.providerName = providerName
        self.windows = windows
        self.connection = connection
        self.updatedAt = updatedAt
        self.sourceURL = sourceURL
        self.message = message
    }

    public static func unavailable(
        providerID: String,
        providerName: String,
        sourceURL: URL?,
        message: String
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            providerID: providerID,
            providerName: providerName,
            windows: [],
            connection: .unavailable,
            updatedAt: Date(),
            sourceURL: sourceURL,
            message: message
        )
    }

    public static func requiresAuthentication(
        providerID: String,
        providerName: String,
        sourceURL: URL?,
        message: String
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            providerID: providerID,
            providerName: providerName,
            windows: [],
            connection: .requiresAuthentication,
            updatedAt: Date(),
            sourceURL: sourceURL,
            message: message
        )
    }
}

public protocol QuotaProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    var sourceURL: URL? { get }
    func loadSnapshot() async -> QuotaSnapshot
}

public enum PanelID: String, CaseIterable, Identifiable, Sendable {
    case limits
    case calendar
    case music
    case jira

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .limits: "Лимиты"
        case .calendar: "Календарь"
        case .music: "Музыка"
        case .jira: "Jira"
        }
    }

    public var iconName: String {
        switch self {
        case .limits: "gauge.with.dots.needle.67percent"
        case .calendar: "calendar"
        case .music: "waveform"
        case .jira: "checkmark.square"
        }
    }
}

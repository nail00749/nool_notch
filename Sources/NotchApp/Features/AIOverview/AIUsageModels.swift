import Foundation

struct AIUsageEvent: Identifiable, Equatable, Sendable {
    let id: String
    let date: Date
    let sessionID: String
    let model: String
    let project: String
    let inputTokens: Int64
    let cachedInputTokens: Int64
    let outputTokens: Int64

    // Cached input and reasoning output are subsets, not additional tokens.
    var totalTokens: Int64 { inputTokens + outputTokens }
}

struct AIUsageSnapshot: Equatable, Sendable {
    let events: [AIUsageEvent]
    let loadedAt: Date
    let isPartial: Bool
    let scannedSessionCount: Int
    let skippedSessionCount: Int
}

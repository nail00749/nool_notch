import Foundation
import NotchCore

struct QuotaAlertOptions: Codable, Equatable, Sendable {
    var enabled = false
    var atTwenty = true
    var atTen = true
    var onRecovery = true
}

struct QuotaAlertEvent: Equatable, Sendable {
    enum Kind: String, Sendable { case twenty, ten, recovered }
    let providerID: String
    let providerName: String
    let windowID: String
    let windowLabel: String
    let percent: Int
    let kind: Kind

    var title: String {
        kind == .recovered ? "\(providerName): лимит восстановлен" : "\(providerName): осталось \(percent)%"
    }
    var body: String {
        "\(windowLabel): доступно \(percent)% лимита."
    }
}

/// Persistent edge detection: one warning per threshold in a quota cycle, including across launches.
struct QuotaAlertPolicy: Codable, Sendable {
    struct WindowState: Codable, Sendable {
        var ratio: Double
        var resetAt: Date?
        var updatedAt: Date
        var warnedTwenty = false
        var warnedTen = false
        var reportedRecovery = false
    }
    var states: [String: [String: WindowState]] = [:]

    mutating func consume(_ snapshot: QuotaSnapshot, options: QuotaAlertOptions, now: Date) -> [QuotaAlertEvent] {
        guard options.enabled, snapshot.connection == .live,
              now.timeIntervalSince(snapshot.updatedAt) < 15 * 60,
              snapshot.updatedAt.timeIntervalSince(now) <= 60 else { return [] }
        var result: [QuotaAlertEvent] = []
        var providerStates = states[snapshot.providerID] ?? [:]
        let windows = snapshot.windows.prefix(16)
        for window in windows {
            guard window.unit == .percentage, let ratio = window.remainingRatio, ratio.isFinite,
                  window.resetAt.map({ $0 > now }) ?? true else { continue }
            let previous = providerStates[window.id]
            if let previous, previous.updatedAt >= snapshot.updatedAt { continue }
            let newCycle: Bool
            if let previous, let oldReset = previous.resetAt, let reset = window.resetAt {
                newCycle = reset.timeIntervalSince(oldReset) > 60
                    && (oldReset <= now || ratio > previous.ratio)
            } else { newCycle = false }
            var state = newCycle || previous == nil
                ? WindowState(ratio: ratio, resetAt: window.resetAt, updatedAt: snapshot.updatedAt)
                : previous!
            var kind: QuotaAlertEvent.Kind?
            if ratio <= 0.10, !state.warnedTen, options.atTen {
                kind = .ten
            } else if ratio <= 0.20, !state.warnedTwenty, options.atTwenty {
                kind = .twenty
            } else if let previous, previous.ratio <= 0.20, ratio > 0.20,
                      !state.reportedRecovery, options.onRecovery {
                kind = .recovered
                state.reportedRecovery = true
            }
            if ratio <= 0.20 { state.warnedTwenty = true }
            if ratio <= 0.10 { state.warnedTen = true }
            state.ratio = ratio
            state.resetAt = window.resetAt
            state.updatedAt = snapshot.updatedAt
            providerStates[window.id] = state
            if let kind {
                result.append(QuotaAlertEvent(providerID: snapshot.providerID, providerName: snapshot.providerName,
                    windowID: window.id, windowLabel: window.label, percent: Int((ratio * 100).rounded()), kind: kind))
            }
        }
        // Partial provider responses must not erase the warning history of a missing window.
        states[snapshot.providerID] = Dictionary(uniqueKeysWithValues: providerStates.sorted {
            $0.value.updatedAt > $1.value.updatedAt
        }.prefix(32).map { ($0.key, $0.value) })
        return result
    }
}

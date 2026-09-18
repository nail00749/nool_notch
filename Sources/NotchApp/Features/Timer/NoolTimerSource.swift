import Combine
import Foundation

struct NoolTimerSnapshot: Equatable, Sendable {
    let id: String
    let title: String
    let duration: TimeInterval
    let remaining: TimeInterval
    let state: LiveActivityState
    let endsAt: Date?

    var countdownText: String {
        let seconds = max(0, Int(ceil(remaining)))
        let hours = seconds / 3_600
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, (seconds / 60) % 60, seconds % 60)
        }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

@MainActor
final class NoolTimerSource: ObservableObject, LiveActivitySource {
    static let maximumDuration: TimeInterval = 24 * 60 * 60

    let id = "nool-timers"
    let displayName = "Таймер"

    @Published private(set) var snapshot: NoolTimerSnapshot?
    var onChange: (([LiveActivity]) -> Void)?
    var onCompletion: (() -> Void)?

    private let now: () -> Date
    private var tickTask: Task<Void, Never>?
    private var isStarted = false
    private var completionWasDelivered = false

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    deinit {
        tickTask?.cancel()
    }

    func start() {
        isStarted = true
        refresh()
        scheduleTickIfNeeded()
    }

    func stop() {
        isStarted = false
        invalidateTickTimer()
    }

    @discardableResult
    func create(duration: TimeInterval) -> Bool {
        guard duration.isFinite,
              duration > 0,
              duration <= Self.maximumDuration else {
            return false
        }

        let currentDate = now()
        snapshot = NoolTimerSnapshot(
            id: "nool-timer",
            title: "Таймер",
            duration: duration,
            remaining: duration,
            state: .active,
            endsAt: currentDate.addingTimeInterval(duration)
        )
        completionWasDelivered = false
        scheduleTickIfNeeded()
        emitChange(at: currentDate)
        return true
    }

    func toggle() {
        guard let currentSnapshot = snapshot else { return }

        switch currentSnapshot.state {
        case .active:
            refresh()
            guard let refreshedSnapshot = snapshot,
                  refreshedSnapshot.state == .active else {
                return
            }
            snapshot = NoolTimerSnapshot(
                id: refreshedSnapshot.id,
                title: refreshedSnapshot.title,
                duration: refreshedSnapshot.duration,
                remaining: refreshedSnapshot.remaining,
                state: .paused,
                endsAt: nil
            )
            invalidateTickTimer()
            emitChange(at: now())
        case .paused:
            let currentDate = now()
            snapshot = NoolTimerSnapshot(
                id: currentSnapshot.id,
                title: currentSnapshot.title,
                duration: currentSnapshot.duration,
                remaining: currentSnapshot.remaining,
                state: .active,
                endsAt: currentDate.addingTimeInterval(currentSnapshot.remaining)
            )
            scheduleTickIfNeeded()
            emitChange(at: currentDate)
        case .completed, .notification:
            break
        }
    }

    func cancel() {
        snapshot = nil
        invalidateTickTimer()
        emitChange(at: now())
    }

    func refresh() {
        guard let currentSnapshot = snapshot else {
            emitChange(at: now())
            return
        }

        guard currentSnapshot.state == .active,
              let endsAt = currentSnapshot.endsAt else {
            emitChange(at: now())
            return
        }

        let currentDate = now()
        let remaining = endsAt.timeIntervalSince(currentDate)
        guard remaining > 0 else {
            snapshot = NoolTimerSnapshot(
                id: currentSnapshot.id,
                title: currentSnapshot.title,
                duration: currentSnapshot.duration,
                remaining: 0,
                state: .completed,
                endsAt: endsAt
            )
            invalidateTickTimer()
            emitChange(at: currentDate)
            if completionWasDelivered == false {
                completionWasDelivered = true
                onCompletion?()
            }
            return
        }

        snapshot = NoolTimerSnapshot(
            id: currentSnapshot.id,
            title: currentSnapshot.title,
            duration: currentSnapshot.duration,
            remaining: min(currentSnapshot.duration, remaining),
            state: .active,
            endsAt: endsAt
        )
        emitChange(at: currentDate)
    }

    private func scheduleTickIfNeeded() {
        invalidateTickTimer()
        guard isStarted, snapshot?.state == .active else { return }

        tickTask = Task { [weak self] in
            while Task.isCancelled == false {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard Task.isCancelled == false,
                      let self else {
                    return
                }
                self.refresh()
                guard self.isStarted, self.snapshot?.state == .active else {
                    return
                }
            }
        }
    }

    private func invalidateTickTimer() {
        tickTask?.cancel()
        tickTask = nil
    }

    private func emitChange(at date: Date) {
        guard let snapshot else {
            onChange?([])
            return
        }

        let progress = snapshot.duration > 0
            ? min(1, max(0, 1 - snapshot.remaining / snapshot.duration))
            : nil
        onChange?([
            LiveActivity(
                id: snapshot.id,
                sourceID: id,
                kind: .timer,
                title: snapshot.title,
                detail: snapshot.countdownText,
                state: snapshot.state,
                progress: progress,
                startedAt: snapshot.endsAt?.addingTimeInterval(-snapshot.duration),
                endsAt: snapshot.endsAt,
                updatedAt: date,
                isCompactEligible: snapshot.state == .active || snapshot.state == .paused
            )
        ])
    }
}

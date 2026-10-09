import Combine
import Foundation

enum NoolTimerMode: String, CaseIterable, Sendable {
    case timer, pomodoro, stopwatch
}

enum NoolPomodoroPhase: String, Sendable {
    case focus, shortBreak, longBreak
}

struct NoolTimerSnapshot: Equatable, Sendable {
    let id: String
    let title: String
    let duration: TimeInterval
    let remaining: TimeInterval
    let state: LiveActivityState
    let endsAt: Date?
    var mode: NoolTimerMode = .timer
    var elapsed: TimeInterval = 0
    var pomodoroPhase: NoolPomodoroPhase? = nil
    var pomodoroRound: Int = 1

    var countdownText: String {
        let seconds = max(0, Int(mode == .stopwatch ? floor(elapsed) : ceil(remaining)))
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
    private var stopwatchAnchor: Date?
    private var stopwatchAccumulated: TimeInterval = 0
    private var pomodoroConfiguration: PomodoroConfiguration?

    private struct PomodoroConfiguration {
        let focusDuration: TimeInterval
        let shortBreakDuration: TimeInterval
        let longBreakDuration: TimeInterval
        let sessionsBeforeLongBreak: Int

        func duration(for phase: NoolPomodoroPhase) -> TimeInterval {
            switch phase {
            case .focus: focusDuration
            case .shortBreak: shortBreakDuration
            case .longBreak: longBreakDuration
            }
        }
    }

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
        guard Self.isValidDuration(duration) else { return false }
        pomodoroConfiguration = nil
        beginCountdown(duration: duration, phase: nil, round: 1)
        return true
    }

    func startStopwatch() {
        let currentDate = now()
        pomodoroConfiguration = nil
        stopwatchAccumulated = 0
        stopwatchAnchor = currentDate
        snapshot = NoolTimerSnapshot(
            id: "nool-timer", title: "Секундомер", duration: 0,
            remaining: 0, state: .active, endsAt: nil, mode: .stopwatch
        )
        completionWasDelivered = false
        scheduleTickIfNeeded()
        emitChange(at: currentDate)
    }

    @discardableResult
    func startPomodoro(
        focusDuration: TimeInterval = 1_500,
        shortBreakDuration: TimeInterval = 300,
        longBreakDuration: TimeInterval = 900,
        sessionsBeforeLongBreak: Int = 4
    ) -> Bool {
        guard [focusDuration, shortBreakDuration, longBreakDuration].allSatisfy(Self.isValidDuration),
              sessionsBeforeLongBreak > 0 else { return false }
        pomodoroConfiguration = PomodoroConfiguration(
            focusDuration: focusDuration, shortBreakDuration: shortBreakDuration,
            longBreakDuration: longBreakDuration, sessionsBeforeLongBreak: sessionsBeforeLongBreak
        )
        beginCountdown(duration: focusDuration, phase: .focus, round: 1)
        return true
    }

    func advancePomodoro() {
        guard let current = snapshot, current.mode == .pomodoro,
              current.state == .completed, let phase = current.pomodoroPhase,
              let configuration = pomodoroConfiguration else { return }
        let nextPhase: NoolPomodoroPhase
        let nextRound: Int
        if phase == .focus {
            nextPhase = current.pomodoroRound % configuration.sessionsBeforeLongBreak == 0
                ? .longBreak : .shortBreak
            nextRound = current.pomodoroRound
        } else {
            nextPhase = .focus
            nextRound = current.pomodoroRound + 1
        }
        beginCountdown(duration: configuration.duration(for: nextPhase), phase: nextPhase, round: nextRound)
    }

    func restart() {
        guard let current = snapshot else { return }
        switch current.mode {
        case .timer:
            _ = create(duration: current.duration)
        case .stopwatch:
            startStopwatch()
        case .pomodoro:
            guard let phase = current.pomodoroPhase else { return }
            beginCountdown(duration: current.duration, phase: phase, round: current.pomodoroRound)
        }
    }

    private static func isValidDuration(_ duration: TimeInterval) -> Bool {
        duration.isFinite && duration > 0 && duration <= maximumDuration
    }

    private func beginCountdown(duration: TimeInterval, phase: NoolPomodoroPhase?, round: Int) {
        let currentDate = now()
        stopwatchAnchor = nil
        stopwatchAccumulated = 0
        let title: String
        switch phase {
        case .focus: title = "Фокус"
        case .shortBreak: title = "Перерыв"
        case .longBreak: title = "Длинный перерыв"
        case nil: title = "Таймер"
        }
        snapshot = NoolTimerSnapshot(
            id: "nool-timer",
            title: title,
            duration: duration,
            remaining: duration,
            state: .active,
            endsAt: currentDate.addingTimeInterval(duration),
            mode: phase == nil ? .timer : .pomodoro,
            pomodoroPhase: phase,
            pomodoroRound: round
        )
        completionWasDelivered = false
        scheduleTickIfNeeded()
        emitChange(at: currentDate)
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
            snapshot = updated(refreshedSnapshot, state: .paused, endsAt: nil)
            if refreshedSnapshot.mode == .stopwatch {
                stopwatchAccumulated = refreshedSnapshot.elapsed
                stopwatchAnchor = nil
            }
            invalidateTickTimer()
            emitChange(at: now())
        case .paused:
            let currentDate = now()
            if currentSnapshot.mode == .stopwatch { stopwatchAnchor = currentDate }
            snapshot = updated(currentSnapshot, state: .active, endsAt: currentSnapshot.mode == .stopwatch
                ? nil : currentDate.addingTimeInterval(currentSnapshot.remaining))
            scheduleTickIfNeeded()
            emitChange(at: currentDate)
        case .completed, .notification:
            break
        }
    }

    func cancel() {
        snapshot = nil
        stopwatchAnchor = nil
        stopwatchAccumulated = 0
        pomodoroConfiguration = nil
        invalidateTickTimer()
        emitChange(at: now())
    }

    func refresh() {
        guard let currentSnapshot = snapshot else {
            emitChange(at: now())
            return
        }

        guard currentSnapshot.state == .active else {
            emitChange(at: now())
            return
        }

        let currentDate = now()
        if currentSnapshot.mode == .stopwatch {
            let interval = stopwatchAnchor.map { max(0, currentDate.timeIntervalSince($0)) } ?? 0
            snapshot = updated(currentSnapshot, state: .active, endsAt: nil,
                elapsed: max(currentSnapshot.elapsed, stopwatchAccumulated + interval))
            emitChange(at: currentDate)
            return
        }
        guard let endsAt = currentSnapshot.endsAt else { return }
        let remaining = endsAt.timeIntervalSince(currentDate)
        guard remaining > 0 else {
            snapshot = updated(currentSnapshot, state: .completed, endsAt: endsAt,
                remaining: 0, elapsed: currentSnapshot.duration)
            invalidateTickTimer()
            emitChange(at: currentDate)
            if completionWasDelivered == false {
                completionWasDelivered = true
                onCompletion?()
            }
            return
        }

        let boundedRemaining = min(currentSnapshot.duration, remaining)
        snapshot = updated(currentSnapshot, state: .active, endsAt: endsAt,
            remaining: boundedRemaining, elapsed: currentSnapshot.duration - boundedRemaining)
        emitChange(at: currentDate)
    }

    private func updated(
        _ current: NoolTimerSnapshot, state: LiveActivityState, endsAt: Date?,
        remaining: TimeInterval? = nil, elapsed: TimeInterval? = nil
    ) -> NoolTimerSnapshot {
        NoolTimerSnapshot(
            id: current.id, title: current.title, duration: current.duration,
            remaining: remaining ?? current.remaining, state: state, endsAt: endsAt,
            mode: current.mode, elapsed: elapsed ?? current.elapsed,
            pomodoroPhase: current.pomodoroPhase, pomodoroRound: current.pomodoroRound
        )
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

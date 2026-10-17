import Combine
import Foundation

@MainActor
final class LiveActivityCenter: ObservableObject {
    @Published private(set) var activities: [LiveActivity] = []
    @Published private(set) var updatedAt: Date?

    let timerSource: NoolTimerSource
    private let sources: [any LiveActivitySource]
    private var activitiesBySource: [String: [LiveActivity]] = [:]
    private var isStarted = false

    init(
        timerSource: NoolTimerSource = NoolTimerSource(),
        additionalSources: [any LiveActivitySource] = [
            SystemCallActivitySource(),
            SystemDownloadActivitySource(),
            BluetoothAudioActivitySource(),
            ExternalLiveActivitySource(),
            SystemBatteryActivitySource()
        ]
    ) {
        self.timerSource = timerSource
        self.sources = [timerSource] + additionalSources

        for source in sources {
            let sourceID = source.id
            source.onChange = { [weak self] activities in
                self?.receive(activities, from: sourceID)
            }
        }
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        sources.forEach { $0.start() }
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        sources.forEach { $0.stop() }
        activitiesBySource.removeAll()
        activities = []
        updatedAt = nil
    }

    private func receive(_ activities: [LiveActivity], from sourceID: String) {
        guard isStarted else { return }
        let now = Date.now
        // Sources poll every few seconds. Publishing an identical feed re-renders every
        // observing view, so only publish real changes. The freshness label shows
        // minutes, so an unchanged feed refreshes updatedAt once per minute.
        if activitiesBySource[sourceID] == activities, let updatedAt,
           Calendar.current.isDate(updatedAt, equalTo: now, toGranularity: .minute) {
            return
        }
        activitiesBySource[sourceID] = activities
        let merged = sources
            .flatMap { activitiesBySource[$0.id] ?? [] }
            .sorted {
                if $0.kind.priority != $1.kind.priority {
                    return $0.kind.priority > $1.kind.priority
                }
                return $0.updatedAt > $1.updatedAt
            }
        if merged != self.activities { self.activities = merged }
        updatedAt = now
    }
}

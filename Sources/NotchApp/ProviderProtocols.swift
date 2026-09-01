import Foundation

@MainActor
protocol CalendarProviding: AnyObject {
    func loadUpcomingEvents() async -> CalendarLoadState
    func loadEvents(for month: Date) async -> [CalendarEvent]
}

@MainActor
protocol JiraProviding: AnyObject {
    var onChange: ((JiraProviderState) -> Void)? { get set }
    func start()
    func stop()
    func setVisible(_ isVisible: Bool)
    func refresh()
    func checkConnection(
        baseURLText: String,
        token: String
    ) async -> Result<JiraUser, JiraAPIError>
    func connect(
        baseURLText: String,
        token: String
    ) async -> Result<JiraUser, JiraAPIError>
    func disconnect()
    func setSelectedProjectKeys(_ keys: Set<String>)
    func loadTransitions(for issueKey: String) async
    func performTransition(issueKey: String, transition: JiraTransition) async
}

enum NowPlayingSource: String, Equatable, Sendable {
    case unavailable
    case mediaRemote
    case accessibility
}

enum NowPlayingHealth: Equatable, Sendable {
    case active
    case playerNotFound
    case accessibilityRequired
    case stale
}

struct NowPlayingDiagnostics: Equatable, Sendable {
    var source: NowPlayingSource
    var applicationName: String?
    var requiresAccessibilityAccess: Bool
    var lastSuccessfulUpdate: Date?

    static let unavailable = NowPlayingDiagnostics(
        source: .unavailable,
        applicationName: nil,
        requiresAccessibilityAccess: false,
        lastSuccessfulUpdate: nil
    )

    func health(
        at date: Date,
        staleAfter: TimeInterval = 60
    ) -> NowPlayingHealth {
        if requiresAccessibilityAccess {
            return .accessibilityRequired
        }
        guard source != .unavailable,
              let lastSuccessfulUpdate else {
            return .playerNotFound
        }
        return date.timeIntervalSince(lastSuccessfulUpdate) > staleAfter
            ? .stale
            : .active
    }

    func recordingObservation(
        source: NowPlayingSource,
        applicationName: String?,
        hasSnapshot: Bool,
        requiresAccessibilityAccess: Bool,
        at date: Date
    ) -> NowPlayingDiagnostics {
        NowPlayingDiagnostics(
            source: hasSnapshot || requiresAccessibilityAccess ? source : .unavailable,
            applicationName: hasSnapshot ? applicationName : nil,
            requiresAccessibilityAccess: requiresAccessibilityAccess,
            lastSuccessfulUpdate: hasSnapshot ? date : lastSuccessfulUpdate
        )
    }
}

enum NowPlayingPollingMode: Equatable, Sendable {
    case visibleMusic
    case background

    var interval: TimeInterval {
        switch self {
        case .visibleMusic: 2
        case .background: 30
        }
    }
}

@MainActor
protocol NowPlayingProviding: AnyObject {
    var onChange: ((NowPlayingSnapshot?) -> Void)? { get set }
    var onAccessStateChange: ((Bool) -> Void)? { get set }
    var onDiagnosticsChange: ((NowPlayingDiagnostics) -> Void)? { get set }

    func start()
    func stop()
    func refresh()
    func setPollingMode(_ mode: NowPlayingPollingMode)
    func togglePlayPause()
    func previousTrack()
    func nextTrack()
    func seek(to time: TimeInterval)
    func openPlayer()
}

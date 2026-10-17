import AppKit
import Combine
import EventKit

@MainActor
final class CalendarFeatureModel: ObservableObject {
    @Published private(set) var calendarState: CalendarLoadState = .idle
    @Published private(set) var upcomingMeetingReminder: MeetingReminder?
    @Published private(set) var calendarEventsByMonth: [CalendarMonthKey: [CalendarEvent]] = [:]
    @Published private(set) var loadingCalendarMonth: CalendarMonthKey?
    @Published private(set) var calendarRefreshedAt: Date?
    private(set) var reminderEvents: [CalendarEvent] = []
    private let calendarProvider: any CalendarProviding
    private var calendarTask: Task<Void, Never>?
    private var calendarMonthTask: Task<Void, Never>?
    private var cachedMonthsTask: Task<Void, Never>?
    private var reminderTimer: AnyCancellable?
    private var reminderCalendarRefreshAt = Date.distantPast
    private var hasLoadedCalendar = false
    private var isEnabled = false
    private var isStarted = false
    private var isStopped = false
    private var cancellables = Set<AnyCancellable>()

    init(provider: any CalendarProviding) { calendarProvider = provider }

    func start(enabled: Bool) {
        guard !isStarted else { return }
        isStarted = true
        isStopped = false
        isEnabled = enabled
        startMeetingReminders()
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        updateReminderTimer()
        refreshMeetingReminderCalendar()
    }

    func refreshCalendar() { refreshCalendar(inBackground: false) }

    /// Expanding the notch keeps loaded content on screen; other months reload lazily when shown.
    func refreshCalendarKeepingContent() {
        guard case .loaded = calendarState else {
            refreshCalendar()
            return
        }
        calendarMonthTask?.cancel()
        calendarMonthTask = nil
        loadingCalendarMonth = nil
        let currentMonth = CalendarMonthKey(date: Date())
        calendarEventsByMonth = calendarEventsByMonth.filter { $0.key == currentMonth }
        refreshCalendar(inBackground: true)
    }

    func stop() {
        isStopped = true
        isStarted = false
        calendarTask?.cancel()
        calendarTask = nil
        calendarMonthTask?.cancel()
        calendarMonthTask = nil
        cachedMonthsTask?.cancel()
        cachedMonthsTask = nil
        loadingCalendarMonth = nil
        reminderTimer = nil
        cancellables.removeAll()
    }

    deinit {
        calendarTask?.cancel()
        calendarMonthTask?.cancel()
        cachedMonthsTask?.cancel()
    }

    private func startMeetingReminders() {
        refreshMeetingReminderCalendar()
        updateReminderTimer()
        NotificationCenter.default.publisher(for: .EKEventStoreChanged)
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.handleStoreChange() }
            .store(in: &cancellables)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshMeetingReminderCalendar() }
            .store(in: &cancellables)
    }

    /// The per-second reminder clock runs only while meeting reminders are enabled.
    private func updateReminderTimer() {
        guard isStarted, isEnabled else {
            reminderTimer = nil
            return
        }
        guard reminderTimer == nil else { return }
        reminderTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
            .sink { [weak self] date in
                guard let self else { return }
                self.updateMeetingReminder(at: date)
                if date.timeIntervalSince(self.reminderCalendarRefreshAt) >= 60 {
                    self.refreshMeetingReminderCalendar()
                }
            }
    }

    /// An edit can land in any month, so loaded content and every cached month reload in place.
    private func handleStoreChange() {
        refreshMeetingReminderCalendar()
        guard !isStopped, case .loaded = calendarState else { return }
        if calendarTask == nil { refreshCalendar(inBackground: true) }
        let currentMonth = CalendarMonthKey(date: Date())
        let months = calendarEventsByMonth.keys.filter { $0 != currentMonth }
        guard !months.isEmpty else { return }
        let provider = calendarProvider
        cachedMonthsTask?.cancel()
        cachedMonthsTask = Task { @MainActor [weak self] in
            for month in months {
                let events = await provider.loadEvents(for: month.startDate)
                guard let self, !Task.isCancelled else { return }
                if self.calendarEventsByMonth[month] != nil { self.calendarEventsByMonth[month] = events }
            }
            self?.cachedMonthsTask = nil
        }
    }

    private func refreshMeetingReminderCalendar() {
        guard !isStopped else { return }
        reminderCalendarRefreshAt = .now
        let needsCalendar = isEnabled
        guard needsCalendar, calendarProvider.canLoadWithoutPrompt else {
            if needsCalendar == false {
                calendarTask?.cancel()
                calendarTask = nil
            }
            reminderEvents = []
            upcomingMeetingReminder = nil
            return
        }
        guard calendarTask == nil else { return }
        refreshCalendar(inBackground: true)
    }

    private func updateMeetingReminder(at date: Date) {
        let reminder = MeetingReminder.select(from: reminderEvents, at: date)
        if upcomingMeetingReminder != reminder { upcomingMeetingReminder = reminder }
    }

    func loadCalendarIfNeeded() {
        guard hasLoadedCalendar == false else { return }
        refreshCalendar()
    }

    func calendarEvents(for month: Date) -> [CalendarEvent] {
        calendarEventsByMonth[CalendarMonthKey(date: month)] ?? []
    }

    func loadCalendarMonthIfNeeded(for month: Date) {
        guard !isStopped, case .loaded = calendarState else { return }

        let monthKey = CalendarMonthKey(date: month)
        guard calendarEventsByMonth[monthKey] == nil else { return }

        calendarMonthTask?.cancel()
        loadingCalendarMonth = monthKey
        let provider = calendarProvider
        calendarMonthTask = Task { @MainActor [weak self] in
            let events = await provider.loadEvents(for: month)
            guard let self else { return }
            guard Task.isCancelled == false else { return }
            self.calendarEventsByMonth[monthKey] = events
            if self.loadingCalendarMonth == monthKey {
                self.loadingCalendarMonth = nil
            }
            self.calendarMonthTask = nil
        }
    }

    private func refreshCalendar(inBackground: Bool) {
        guard !isStopped else { return }
        hasLoadedCalendar = true
        calendarTask?.cancel()
        if inBackground == false {
            calendarMonthTask?.cancel()
            calendarEventsByMonth.removeAll()
            loadingCalendarMonth = nil
            calendarState = .loading
        }
        let provider = calendarProvider
        calendarTask = Task { @MainActor [weak self] in
            let state = await provider.loadUpcomingEvents()
            guard let self else { return }
            guard Task.isCancelled == false else { return }
            self.calendarState = state
            if case .loaded(let snapshot) = state {
                self.reminderEvents = snapshot.upcomingEvents
                self.calendarEventsByMonth[CalendarMonthKey(date: Date())] = snapshot.monthEvents
                self.calendarRefreshedAt = .now
            } else {
                self.reminderEvents = []
            }
            self.updateMeetingReminder(at: .now)
            self.calendarTask = nil
        }
    }

}

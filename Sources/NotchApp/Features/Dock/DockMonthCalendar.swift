import Foundation
import SwiftUI

/// Calendar dates are advanced in calendar days, never fixed 24-hour intervals.
/// Its calendar is injected so locale, first weekday and time zone stay coherent.
struct DockMonthGrid {
    let calendar: Calendar
    let interval: DateInterval
    let cells: [Date?]

    init(month: Date, calendar: Calendar = .current) {
        self.calendar = calendar
        let start = calendar.dateInterval(of: .month, for: month)?.start ?? calendar.startOfDay(for: month)
        let end = calendar.date(byAdding: .month, value: 1, to: start) ?? start
        interval = DateInterval(start: start, end: end)
        let leading = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
        var days = Array<Date?>(repeating: nil, count: leading)
        if let range = calendar.range(of: .day, in: .month, for: start) {
            for offset in 0..<range.count {
                guard let day = calendar.date(byAdding: .day, value: offset, to: start), day < end else { continue }
                days.append(day)
            }
        }
        let count = max(35, ((days.count + 6) / 7) * 7)
        days.append(contentsOf: repeatElement(nil, count: max(0, count - days.count)))
        cells = days
    }

    var rowCount: Int { cells.count / 7 }
    var weekdayTitles: [String] {
        let symbols = calendar.shortStandaloneWeekdaySymbols
        return (0..<7).map { symbols[(calendar.firstWeekday - 1 + $0) % 7] }
    }
    var title: String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale ?? .current
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMMM y")
        return formatter.string(from: interval.start).localizedCapitalized
    }
    func shiftedMonth(by offset: Int) -> Date? {
        calendar.date(byAdding: .month, value: offset, to: interval.start)
    }

    static func events(on day: Date, from events: [CalendarEvent], calendar: Calendar = .current) -> [CalendarEvent] {
        guard let interval = calendar.dateInterval(of: .day, for: day) else { return [] }
        struct Identity: Hashable { let id: String; let start: Date; let end: Date }
        var seen = Set<Identity>()
        return events.filter { event in
            let overlaps = event.startDate < interval.end && event.endDate > interval.start
            let pointEvent = event.startDate == event.endDate && interval.start <= event.startDate && event.startDate < interval.end
            return (overlaps || pointEvent) && seen.insert(Identity(id: event.id, start: event.startDate, end: event.endDate)).inserted
        }.sorted {
            if $0.isAllDay != $1.isAllDay { return $0.isAllDay }
            if $0.startDate != $1.startDate { return $0.startDate < $1.startDate }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }
}

struct DockMonthCalendar: View {
    @ObservedObject var model: NotchViewModel
    let interactionChanged: (Bool) -> Void
    private let calendar: Calendar
    @State private var displayedMonth: Date
    @State private var selectedDate: Date

    init(model: NotchViewModel, interactionChanged: @escaping (Bool) -> Void,
         calendar: Calendar = .current, now: Date = .now) {
        self.model = model
        self.interactionChanged = interactionChanged
        self.calendar = calendar
        _displayedMonth = State(initialValue: calendar.dateInterval(of: .month, for: now)?.start ?? now)
        _selectedDate = State(initialValue: calendar.startOfDay(for: now))
    }

    private var grid: DockMonthGrid { DockMonthGrid(month: displayedMonth, calendar: calendar) }
    /// Read cached data only. Opening this surface never requests calendar access.
    private var knownEvents: [CalendarEvent] { model.calendarEventsByMonth.values.flatMap { $0 } + model.dockCalendarEvents }
    private var selectedEvents: [CalendarEvent] { DockMonthGrid.events(on: selectedDate, from: knownEvents, calendar: calendar) }

    var body: some View {
        let cached = knownEvents
        let eventDays = Set(grid.cells.compactMap { day -> Date? in
            guard let day, !DockMonthGrid.events(on: day, from: cached, calendar: calendar).isEmpty else { return nil }
            return day
        })
        VStack(spacing: 12) {
            header
            VStack(spacing: 6) {
                HStack(spacing: 0) {
                    ForEach(Array(grid.weekdayTitles.enumerated()), id: \.offset) { _, title in
                        Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.45))
                            .frame(maxWidth: .infinity)
                    }
                }.frame(height: 16)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 3) {
                    ForEach(grid.cells.indices, id: \.self) { index in
                        if let day = grid.cells[index] { dayButton(day, hasEvents: eventDays.contains(day)) }
                        else { Color.clear.frame(height: 29).accessibilityHidden(true) }
                    }
                }.frame(height: CGFloat(grid.rowCount) * 29 + CGFloat(grid.rowCount - 1) * 3)
            }
            Rectangle().fill(.white.opacity(0.1)).frame(height: 0.5)
            events
            Button {
                model.refreshCalendar()
                model.openReminderCalendar()
            } label: {
                HStack {
                    Text("Открыть календарь")
                    Spacer()
                    Image(systemName: "arrow.up.right")
                }.font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 10).frame(height: 30)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(.plain)
        }.padding(14).frame(width: 306).foregroundStyle(.white).preferredColorScheme(.dark)
            .onAppear { interactionChanged(true) }.onDisappear { interactionChanged(false) }
    }

    private var header: some View {
        HStack(spacing: 3) {
            Text(grid.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading).accessibilityAddTraits(.isHeader)
            Button("Сегодня") {
                let now = Date()
                displayedMonth = DockMonthGrid(month: now, calendar: calendar).interval.start
                selectedDate = calendar.startOfDay(for: now)
            }.font(.system(size: 10, weight: .medium)).buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.55)).padding(.horizontal, 5)
            monthButton("chevron.left", label: "Предыдущий месяц", offset: -1)
            monthButton("chevron.right", label: "Следующий месяц", offset: 1)
        }.frame(height: 28)
    }

    private func monthButton(_ symbol: String, label: String, offset: Int) -> some View {
        Button {
            guard let month = grid.shiftedMonth(by: offset) else { return }
            displayedMonth = month
            selectedDate = calendar.isDate(month, equalTo: Date(), toGranularity: .month)
                ? calendar.startOfDay(for: Date()) : month
        } label: {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).frame(width: 24, height: 26)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(label).help(label)
    }

    private func dayButton(_ day: Date, hasEvents: Bool) -> some View {
        let isToday = calendar.isDateInToday(day)
        let selected = calendar.isDate(day, inSameDayAs: selectedDate)
        return Button { selectedDate = day } label: {
            ZStack(alignment: .bottom) {
                Text("\(calendar.component(.day, from: day))")
                    .font(.system(size: 12, weight: selected || isToday ? .semibold : .regular)).monospacedDigit()
                    .frame(width: 29, height: 29)
                    .background {
                        Circle().fill(isToday ? Color.red.opacity(0.9) : selected ? .white.opacity(0.13) : .clear)
                    }
                    .overlay { Circle().strokeBorder(.white.opacity(isToday && selected ? 0.55 : 0), lineWidth: 1) }
                if hasEvents { Circle().fill(.white.opacity(0.7)).frame(width: 2.5, height: 2.5).offset(y: -2) }
            }.frame(maxWidth: .infinity).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(day.formatted(date: .complete, time: .omitted))
            .accessibilityAddTraits(selected ? .isSelected : [])
            .help(day.formatted(date: .complete, time: .omitted))
    }

    private var events: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(selectedDate.formatted(.dateTime.day().month(.wide).locale(calendar.locale ?? .current)))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.65))
            if selectedEvents.isEmpty {
                Text(emptyEventsText).font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(selectedEvents) { event in
                            HStack(alignment: .top, spacing: 9) {
                                Text(event.isAllDay ? "Весь день" : event.startDate.formatted(date: .omitted, time: .shortened))
                                    .font(.system(size: 10)).monospacedDigit().foregroundStyle(.white.opacity(0.45)).frame(width: 48, alignment: .leading)
                                Text(event.title).font(.system(size: 11)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                if let url = event.joinURL {
                                    Button { model.openMeetingURL(url) } label: {
                                        Image(systemName: "video").font(.system(size: 11)).frame(width: 24, height: 22)
                                    }.buttonStyle(.plain).accessibilityLabel("Подключиться к \(event.title)")
                                }
                            }.frame(minHeight: 22)
                        }
                    }
                }.frame(height: min(96, CGFloat(selectedEvents.count) * 30))
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyEventsText: String {
        switch model.calendarState {
        case .loaded:
            model.calendarEventsByMonth[CalendarMonthKey(date: selectedDate)] == nil
                ? "Откройте календарь, чтобы показать события" : "Событий нет"
        case .loading: "События загружаются…"
        case .denied: "Нет доступа к событиям календаря"
        case .idle: "Откройте календарь, чтобы показать события"
        }
    }
}

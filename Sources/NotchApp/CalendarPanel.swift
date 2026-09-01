import SwiftUI

struct CalendarPanel: View {
    @ObservedObject var model: NotchViewModel

    var body: some View {
        Group {
            switch model.calendarState {
            case .idle:
                CalendarMessagePanel(
                    icon: "calendar",
                    title: "Календарь",
                    detail: "Готовлю ближайшие события…"
                )
            case .loading:
                CalendarMessagePanel(
                    icon: "calendar",
                    title: "Загружаю события…",
                    detail: "Запрашиваю доступ к macOS Calendar.",
                    showsProgress: true
                )
            case .denied:
                CalendarMessagePanel(
                    icon: "calendar.badge.exclamationmark",
                    title: "Нет доступа к календарю",
                    detail: "Разрешите NotchApp доступ к календарям в системных настройках.",
                    actionTitle: "Повторить",
                    action: model.refreshCalendar
                )
            case .loaded(let snapshot):
                CalendarPanelContent(model: model, snapshot: snapshot)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if model.selectedPanel == .calendar {
                model.loadCalendarIfNeeded()
            }
        }
        .onChange(of: model.selectedPanel) { _, panel in
            if panel == .calendar {
                model.loadCalendarIfNeeded()
            }
        }
    }
}

private struct CalendarPanelContent: View {
    @ObservedObject var model: NotchViewModel
    let snapshot: CalendarSnapshot

    @State private var displayedMonth = CalendarMonthKey(date: Date()).startDate
    @State private var selectedDate: Date?

    var body: some View {
        Group {
            switch model.calendarViewMode {
            case .list:
                CalendarEventsList(
                    events: snapshot.upcomingEvents,
                    viewMode: $model.calendarViewMode,
                    onRefresh: model.refreshCalendar
                )
            case .month:
                CalendarMonthView(
                    model: model,
                    displayedMonth: $displayedMonth,
                    selectedDate: $selectedDate,
                    viewMode: $model.calendarViewMode
                )
            }
        }
        .onAppear {
            selectInitialDate()
            model.loadCalendarMonthIfNeeded(for: displayedMonth)
        }
        .onChange(of: displayedMonth) { _, month in
            selectedDate = CalendarMonthKey(date: month).startDate
            model.loadCalendarMonthIfNeeded(for: month)
        }
        .onChange(of: snapshot) { _, _ in
            model.loadCalendarMonthIfNeeded(for: displayedMonth)
        }
    }

    private func selectInitialDate() {
        guard selectedDate == nil else { return }

        let month = CalendarMonthKey(date: displayedMonth)
        selectedDate = CalendarMonthKey(date: Date()).year == month.year
            && CalendarMonthKey(date: Date()).month == month.month
            ? Date()
            : month.startDate
    }
}

private struct CalendarViewModePicker: View {
    @Binding var selection: CalendarViewMode

    var body: some View {
        HStack(spacing: 2) {
            ForEach(CalendarViewMode.allCases) { mode in
                Button {
                    withAnimation(.easeOut(duration: 0.16)) {
                        selection = mode
                    }
                } label: {
                    Image(systemName: mode.iconName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(selection == mode ? .white : .white.opacity(0.46))
                        .frame(width: 40, height: 40)
                        .background(
                            selection == mode ? Color.white.opacity(0.14) : .clear,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                }
                .buttonStyle(NotchButtonStyle())
                .accessibilityLabel(mode.accessibilityLabel)
                .accessibilityAddTraits(selection == mode ? .isSelected : [])
            }
        }
        .padding(2)
        .background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct CalendarMonthView: View {
    @ObservedObject var model: NotchViewModel
    @Binding var displayedMonth: Date
    @Binding var selectedDate: Date?
    @Binding var viewMode: CalendarViewMode

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "ru_RU")
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 1
        return calendar
    }

    private var monthKey: CalendarMonthKey {
        CalendarMonthKey(date: displayedMonth)
    }

    private var monthEvents: [CalendarEvent] {
        model.calendarEvents(for: displayedMonth)
    }

    private var monthTitle: String {
        displayedMonth.formatted(
            Date.FormatStyle()
                .locale(Locale(identifier: "ru_RU"))
                .month(.wide)
                .year()
        )
    }

    private var weekdayTitles: [String] {
        let symbols = calendar.shortStandaloneWeekdaySymbols
        let firstWeekdayIndex = calendar.firstWeekday - 1
        return (0..<7).map { offset in
            symbols[(firstWeekdayIndex + offset) % symbols.count]
        }
    }

    private var monthCells: [Date?] {
        let startDate = monthKey.startDate
        guard let dayRange = calendar.range(of: .day, in: .month, for: startDate) else {
            return []
        }

        let leadingEmptyDays = (calendar.component(.weekday, from: startDate) - calendar.firstWeekday + 7) % 7
        var cells = Array(repeating: Optional<Date>.none, count: leadingEmptyDays)
        cells += dayRange.compactMap { day in
            calendar.date(byAdding: .day, value: day - 1, to: startDate)
        }

        while cells.count % 7 != 0 {
            cells.append(nil)
        }
        return cells
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                CalendarViewModePicker(selection: $viewMode)

                Spacer(minLength: 4)

                Button {
                    shiftMonth(by: -1)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(NotchButtonStyle())
                .foregroundStyle(.white.opacity(0.7))
                .accessibilityLabel("Предыдущий месяц")

                Text(monthTitle)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .frame(minWidth: 108, alignment: .center)

                Button {
                    shiftMonth(by: 1)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(NotchButtonStyle())
                .foregroundStyle(.white.opacity(0.7))
                .accessibilityLabel("Следующий месяц")
            }

            HStack(alignment: .top, spacing: 10) {
                VStack(spacing: 3) {
                    HStack(spacing: 2) {
                        ForEach(weekdayTitles, id: \.self) { weekday in
                            Text(weekday)
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.36))
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(height: 16)

                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7),
                        spacing: 2
                    ) {
                        ForEach(Array(monthCells.enumerated()), id: \.offset) { item in
                            if let date = item.element {
                                CalendarDayCell(
                                    date: date,
                                    isSelected: selectedDate.map { calendar.isDate($0, inSameDayAs: date) } ?? false,
                                    isToday: calendar.isDateInToday(date),
                                    hasEvents: events(on: date).isEmpty == false,
                                    onSelect: { selectedDate = date }
                                )
                            } else {
                                Color.clear
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 40)
                            }
                        }
                    }
                }
                .frame(width: 300)

                CalendarDayDetails(
                    date: selectedDate,
                    events: selectedDate.map(events(on:)) ?? [],
                    isLoading: model.loadingCalendarMonth == monthKey
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .padding(.horizontal, 14)
    }

    private func shiftMonth(by value: Int) {
        guard let nextMonth = calendar.date(byAdding: .month, value: value, to: displayedMonth) else {
            return
        }
        withAnimation(.easeInOut(duration: 0.18)) {
            displayedMonth = nextMonth
        }
    }

    private func events(on date: Date) -> [CalendarEvent] {
        let dayStart = calendar.startOfDay(for: date)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
            return []
        }

        return monthEvents.filter { event in
            event.startDate < dayEnd && event.endDate >= dayStart
        }
    }
}

private struct CalendarDayCell: View {
    let date: Date
    let isSelected: Bool
    let isToday: Bool
    let hasEvents: Bool
    let onSelect: () -> Void

    private var calendar: Calendar { Calendar(identifier: .gregorian) }

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 2) {
                Text("\(calendar.component(.day, from: date))")
                    .font(.system(size: 11, weight: isToday ? .bold : .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(
                        isToday ? Color.signalMint : (isSelected ? .white : .white.opacity(0.72))
                    )

                Circle()
                    .fill(hasEvents ? Color.signalMint : .clear)
                    .frame(width: 4, height: 4)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(
                isSelected ? Color.white.opacity(0.15) : .clear,
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
        }
        .buttonStyle(NotchButtonStyle())
        .accessibilityLabel(date.formatted(.dateTime.day().month(.wide)))
        .accessibilityHint(hasEvents ? "Есть события" : "Нет событий")
    }
}

private struct CalendarDayDetails: View {
    let date: Date?
    let events: [CalendarEvent]
    let isLoading: Bool

    private var dateTitle: String {
        guard let date else { return "Выберите день" }
        return date.formatted(
            Date.FormatStyle()
                .locale(Locale(identifier: "ru_RU"))
                .weekday(.wide)
                .day()
                .month(.wide)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(dateTitle)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(2)

            if isLoading {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(Color.signalMint)
                    Text("Загружаю…")
                }
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.42))
            } else if events.isEmpty {
                Text("Нет событий")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.36))
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(events) { event in
                            CalendarDayEventRow(event: event)
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(0.06))
        )
    }
}

private struct CalendarDayEventRow: View {
    let event: CalendarEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: event.isAllDay ? "sun.max" : "clock")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Color.signalMint)

                if event.isAllDay {
                    Text("Весь день")
                } else {
                    Text(event.startDate, style: .time)
                    Text("–")
                    Text(event.endDate, style: .time)
                }
            }
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.52))

            Text(event.title)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(2)

            Text(event.calendarTitle)
                .font(.system(size: 8, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.32))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CalendarEventsList: View {
    let events: [CalendarEvent]
    @Binding var viewMode: CalendarViewMode
    let onRefresh: () -> Void

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("Ближайшие события")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.76))

                    Spacer()

                    CalendarViewModePicker(selection: $viewMode)

                    Button(action: onRefresh) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 40, height: 40)
                    }
                    .buttonStyle(NotchButtonStyle())
                    .foregroundStyle(.white.opacity(0.64))
                    .accessibilityLabel("Обновить календарь")
                }

                if events.isEmpty {
                    CalendarMessagePanel(
                        icon: "calendar",
                        title: "Свободное расписание",
                        detail: "Ближайшие 14 дней без событий."
                    )
                    .frame(maxWidth: .infinity, minHeight: 90)
                } else {
                    ForEach(events) { event in
                        CalendarEventRow(event: event)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 4)
        }
    }
}

private struct CalendarEventRow: View {
    let event: CalendarEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: event.isAllDay ? "sun.max" : "clock")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.signalMint)

                if event.isAllDay {
                    Text(event.startDate, format: .dateTime.day().month(.abbreviated))
                } else {
                    Text(event.startDate, format: .dateTime.day().month(.abbreviated))
                    Text("·")
                    Text(event.startDate, style: .time)
                    Text("–")
                    Text(event.endDate, style: .time)
                }
            }
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.58))

            Text(event.title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(2)

            Text(event.calendarTitle)
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.36))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(0.07))
        )
        .accessibilityElement(children: .combine)
    }
}

private struct CalendarMessagePanel: View {
    let icon: String
    let title: String
    let detail: String
    var showsProgress = false
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 11) {
            if showsProgress {
                ProgressView()
                    .controlSize(.small)
                    .tint(Color.signalMint)
            } else {
                Image(systemName: icon)
                    .font(.system(size: 25, weight: .light))
                    .foregroundStyle(Color.signalMint)
            }

            Text(title)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)

            Text(detail)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.42))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 270)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.signalMint)
                    .frame(minWidth: 40, minHeight: 40)
                    .buttonStyle(NotchButtonStyle())
            }
        }
        .padding(20)
    }
}

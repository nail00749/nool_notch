import SwiftUI
import Charts

struct AIUsagePanel: View {
    @ObservedObject var store: AIUsageStore
    let isActive: Bool
    @State private var isExpanded = false
    @State private var dayCount = 7
    @State private var groupsByProject = false
    @State private var showsAllGroups = false
    @State private var selectedDate: Date?

    private var shouldLoad: Bool { isExpanded && isActive }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { isExpanded.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chart.bar.xaxis").foregroundStyle(NotchPalette.accent)
                    Text("История использования").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text("Codex").font(.system(size: 10)).foregroundStyle(NotchPalette.secondary)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                }
                .frame(minHeight: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("История использования Codex")
            .accessibilityValue(isExpanded ? "Развёрнуто" : "Свёрнуто")

            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Picker("Период истории", selection: $dayCount) {
                            Text("7 дней").tag(7)
                            Text("30 дней").tag(30)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 170)
                        Spacer()
                        if store.isLoading { ProgressView().controlSize(.small) }
                        Button {
                            Task { await store.refresh(force: true) }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .frame(width: 40, height: 40)
                        }
                        .buttonStyle(NotchButtonStyle())
                        .disabled(store.isLoading || !isActive)
                        .accessibilityLabel("Обновить историю использования")
                    }
                    if let message = store.errorMessage {
                        Text(message + (store.snapshot == nil ? "" : " Показаны предыдущие данные."))
                            .font(.system(size: 10)).foregroundStyle(NotchPalette.secondary)
                    }
                    if let summary = store.summaries[dayCount] {
                        if store.snapshot?.isPartial == true {
                            Label("Неполная история", systemImage: "info.circle")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(NotchPalette.secondary)
                        }
                        if summary.totals.sessions.isEmpty {
                            Text("За этот период нет доступных событий расхода токенов.")
                                .font(.system(size: 11)).foregroundStyle(NotchPalette.secondary)
                        } else {
                            report(summary)
                        }
                    } else if store.isLoading {
                        Text("Читаем локальную историю…")
                            .font(.system(size: 11)).foregroundStyle(NotchPalette.secondary)
                    }
                    if let snapshot = store.snapshot {
                        Text(snapshot.isPartial
                             ? "Часть истории недоступна или не вошла в выборку. Суммы могут быть неполными."
                             : "По доступной локальной истории Codex Desktop и CLI.")
                            .font(.system(size: 10)).foregroundStyle(NotchPalette.secondary)
                        Text("Без дочерних агентов. Токены не равны оплате подписки; API-стоимость не рассчитана.")
                            .font(.system(size: 9)).foregroundStyle(NotchPalette.secondary)
                        Text("Обновлено \(snapshot.loadedAt.formatted(date: .omitted, time: .shortened))")
                            .font(.system(size: 9)).foregroundStyle(NotchPalette.secondary)
                    }
                }
                .padding(.bottom, 12)
            }
        }
        .padding(.horizontal, 12)
        .background(NotchPalette.raised, in: RoundedRectangle(cornerRadius: 14))
        .task(id: shouldLoad) {
            if shouldLoad { await store.refresh() }
            else { store.cancel() }
        }
        .onDisappear { store.cancel() }
        .onChange(of: dayCount) { _, _ in selectedDate = nil; showsAllGroups = false }
        .onChange(of: groupsByProject) { _, _ in showsAllGroups = false }
    }

    private func report(_ summary: AIUsageSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(summary.totals.total.formatted(.number.notation(.compactName)))
                    .font(.system(size: 23, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("токенов").font(.system(size: 10)).foregroundStyle(NotchPalette.secondary)
                Spacer()
                Text("\(summary.totals.sessions.count) сессий")
                    .font(.system(size: 10)).foregroundStyle(NotchPalette.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(summary.totals.total) токенов, \(summary.totals.sessions.count) сессий")

            HStack {
                metric("Вход", value: summary.totals.input.formatted(.number.notation(.compactName)))
                Spacer()
                metric("Выход", value: summary.totals.output.formatted(.number.notation(.compactName)))
                Spacer()
                metric("Кэш входа", value: summary.totals.cacheRatio.formatted(.percent.precision(.fractionLength(0))))
            }

            Chart(summary.days) { day in
                BarMark(x: .value("День", day.date, unit: .day), y: .value("Токены", day.totals.total))
                    .foregroundStyle(NotchPalette.accent)
                    .cornerRadius(3)
                    .opacity(selectedDate == nil || Calendar.current.isDate(day.date, inSameDayAs: selectedDate!) ? 1 : 0.4)
                    .accessibilityLabel(day.date.formatted(date: .abbreviated, time: .omitted))
                    .accessibilityValue("\(day.totals.total) токенов")
            }
            .chartXSelection(value: $selectedDate)
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: dayCount == 7 ? 2 : 7)) {
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                }
            }
            .frame(height: 82)
            if let date = selectedDate,
               let day = summary.days.first(where: { Calendar.current.isDate($0.date, inSameDayAs: date) }) {
                Text("\(day.date.formatted(date: .abbreviated, time: .omitted)) · \(day.totals.total.formatted()) токенов")
                    .font(.system(size: 10)).monospacedDigit()
            }

            Picker("Разбивка использования", selection: $groupsByProject) {
                Text("Модели").tag(false)
                Text("Проекты").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            groups(groupsByProject ? summary.projects : summary.models, total: summary.totals.total)
        }
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).foregroundStyle(NotchPalette.secondary)
            Text(value).monospacedDigit()
        }
        .font(.system(size: 10, weight: .medium))
        .accessibilityElement(children: .combine)
    }

    private func groups(_ groups: [AIUsageGroup], total: Int64) -> some View {
        VStack(spacing: 9) {
            ForEach(showsAllGroups ? groups : Array(groups.prefix(5))) { group in
                VStack(spacing: 4) {
                    HStack {
                        Text(group.title).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(group.totals.total.formatted(.number.notation(.compactName))).monospacedDigit()
                    }
                    .font(.system(size: 10, weight: .medium))
                    GeometryReader { geometry in
                        Capsule().fill(NotchPalette.track)
                            .overlay(alignment: .leading) {
                                Capsule().fill(NotchPalette.accent)
                                    .frame(width: geometry.size.width * (total > 0 ? Double(group.totals.total) / Double(total) : 0))
                            }
                    }
                    .frame(height: 4)
                }
                .help(groupsByProject ? group.id : group.title)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(group.title), \(group.totals.total) токенов")
            }
            if groups.count > 5 {
                Button(showsAllGroups ? "Свернуть список" : "Ещё \(groups.count - 5)") {
                    showsAllGroups.toggle()
                }
                .font(.system(size: 10, weight: .medium))
                .frame(minHeight: 40)
                .buttonStyle(.plain)
            }
        }
    }
}

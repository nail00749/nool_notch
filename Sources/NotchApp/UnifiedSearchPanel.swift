import SwiftUI

struct UnifiedSearchPanel: View {
    @ObservedObject var model: NotchViewModel
    @State private var query = ""
    @State private var selectedEvent: CalendarEvent?
    @FocusState private var isFocused: Bool

    private var results: [UnifiedSearchResult] { model.searchResults(query: query) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Color.signalMint)
                TextField("Задача, сессия или событие", text: $query)
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                    .onSubmit {
                        if let first = results.first { open(first) }
                    }
                    .accessibilityLabel("Общий поиск")
                if query.isEmpty == false {
                    Button {
                        query = ""
                        selectedEvent = nil
                        isFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .frame(width: 28, height: 32)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Очистить поиск")
                }
            }
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .padding(.horizontal, 10)
            .frame(height: 40)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))

            Text("По загруженным данным Jira, AI-сессий и календаря")
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(.white.opacity(0.45))

            if let event = selectedEvent {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Button("← К результатам") { selectedEvent = nil }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.signalMint)
                        Text(event.title).font(.headline)
                        Text(event.calendarTitle).foregroundStyle(.secondary)
                        Text(event.startDate, format: .dateTime.day().month(.wide).hour().minute())
                        if let url = event.joinURL {
                            Button("Подключиться") { model.openMeetingURL(url) }
                                .buttonStyle(.borderedProminent)
                                .tint(Color.signalMint)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                }
            } else if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                message("Введите название или ключ задачи", icon: "magnifyingglass")
            } else if results.isEmpty {
                message("В загруженных данных ничего не найдено", icon: "doc.text.magnifyingglass")
            } else {
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(results) { result in
                            Button { open(result) } label: {
                                HStack(alignment: .top, spacing: 9) {
                                    Image(systemName: result.iconName)
                                        .foregroundStyle(Color.signalMint)
                                        .frame(width: 18)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(result.title)
                                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                                            .foregroundStyle(.white)
                                            .lineLimit(2)
                                        Text(result.subtitle)
                                            .font(.system(size: 10, design: .rounded))
                                            .foregroundStyle(.white.opacity(0.5))
                                            .lineLimit(2)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { isFocused = true }
        .onChange(of: query) { _, _ in selectedEvent = nil }
        .onExitCommand { model.closeUtility() }
    }

    private func open(_ result: UnifiedSearchResult) {
        switch result {
        case .issue(let issue): model.openJiraIssue(issue)
        case .session(let session): model.openAISession(session)
        case .event(let event): selectedEvent = event
        }
    }

    private func message(_ title: String, icon: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.title2)
            Text(title).font(.system(size: 12, design: .rounded))
        }
        .foregroundStyle(.white.opacity(0.5))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

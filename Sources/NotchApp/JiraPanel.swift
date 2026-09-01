import AppKit
import SwiftUI

struct JiraPanel: View {
    @ObservedObject var model: NotchViewModel
    let onOpenSettings: () -> Void

    @State private var searchText = ""
    @State private var sortOption = JiraIssueSortOption.priority
    @State private var quickFilters: Set<JiraIssueQuickFilter> = []
    @State private var isShowingSearch = false
    @State private var isShowingFilters = false

    var body: some View {
        Group {
            if showsSplitLayout {
                splitContent
            } else {
                stateContent
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    private var showsSplitLayout: Bool {
        switch model.jiraState.connection {
        case .ready, .connected:
            true
        default:
            false
        }
    }

    private var splitContent: some View {
        HStack(spacing: 10) {
            projectSidebar

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 1)

            VStack(spacing: 8) {
                taskHeader
                stateContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var projectSidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ПРОЕКТЫ")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.38))
                .padding(.horizontal, 8)

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 5) {
                    JiraProjectListRow(
                        title: "Все",
                        subtitle: "Мои задачи",
                        isSelected: model.jiraState.selectedProjectKeys.isEmpty
                    ) {
                        model.setJiraSelectedProjectKeys([])
                    }

                    ForEach(model.jiraState.projects) { project in
                        JiraProjectListRow(
                            title: project.key,
                            subtitle: project.name,
                            isSelected: model.jiraState.selectedProjectKeys.contains(project.key)
                        ) {
                            toggleProject(project.key)
                        }
                    }
                }
            }
        }
        .frame(width: 104)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private var taskHeader: some View {
        HStack(spacing: 8) {
            Label("Задачи", systemImage: "checklist")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.78))

            Spacer(minLength: 0)

            Menu {
                ForEach(JiraIssueSortOption.allCases) { option in
                    Button {
                        sortOption = option
                    } label: {
                        if option == sortOption {
                            Label(option.title, systemImage: "checkmark")
                        } else {
                            Text(option.title)
                        }
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.76))
                    .frame(width: 40, height: 40)
                    .background(
                        Color.white.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .accessibilityLabel("Сортировка задач: \(sortOption.title)")

            Button {
                isShowingFilters = true
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(
                            quickFilters.isEmpty ? Color.white.opacity(0.76) : Color.signalMint
                        )
                        .frame(width: 40, height: 40)

                    if quickFilters.isEmpty == false {
                        Text("\(quickFilters.count)")
                            .font(.system(size: 8, weight: .black, design: .monospaced))
                            .foregroundStyle(.black.opacity(0.82))
                            .frame(width: 13, height: 13)
                            .background(Color.signalMint, in: Circle())
                            .overlay {
                                Circle()
                                    .stroke(Color.black.opacity(0.55), lineWidth: 1)
                            }
                            .padding(3)
                            .accessibilityHidden(true)
                    }
                }
                .background(
                    Color.white.opacity(quickFilters.isEmpty ? 0.08 : 0.12),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
            }
            .buttonStyle(NotchButtonStyle())
            .popover(isPresented: $isShowingFilters, arrowEdge: .bottom) {
                JiraFilterPopover(activeFilters: $quickFilters)
            }
            .accessibilityLabel("Фильтры задач Jira")
            .accessibilityValue(
                quickFilters.isEmpty ? "Не выбраны" : "Выбрано: \(quickFilters.count)"
            )

            Button {
                isShowingSearch = true
            } label: {
                Image(systemName: searchText.isEmpty ? "magnifyingglass" : "line.3.horizontal.decrease.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(searchText.isEmpty ? .white.opacity(0.76) : Color.signalMint)
                    .frame(width: 40, height: 40)
                    .background(
                        Color.white.opacity(searchText.isEmpty ? 0.08 : 0.12),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
            }
            .buttonStyle(NotchButtonStyle())
            .popover(isPresented: $isShowingSearch, arrowEdge: .bottom) {
                JiraSearchPopover(text: $searchText)
            }
            .accessibilityLabel(searchText.isEmpty ? "Поиск задач Jira" : "Изменить поиск задач Jira")

            Button(action: model.refreshJira) {
                Group {
                    if isLoadingIssues {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                    }
                }
                .foregroundStyle(.white.opacity(0.76))
                .frame(width: 40, height: 40)
                .background(
                    Color.white.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
            }
            .buttonStyle(NotchButtonStyle())
            .disabled(isLoadingIssues)
            .accessibilityLabel("Обновить задачи Jira")
        }
    }

    private var isLoadingIssues: Bool {
        if case .loading = model.jiraState.list { return true }
        return false
    }

    @ViewBuilder
    private var stateContent: some View {
        switch model.jiraState.connection {
        case .notConfigured:
            if let presentation = JiraPanelConnectionRecoveryPolicy.presentation(
                for: model.jiraState.connection
            ) {
                recoveryMessage(presentation, icon: "gearshape")
            }
        case .validating:
            JiraProgressMessage(text: "Проверяю подключение…")
        case .validated(let user):
            JiraPanelMessage(
                icon: "checkmark.circle",
                title: "Подключение проверено",
                detail: "Сохраните подключение для \(user.displayName) в Настройках."
            )
        case .failed(let error):
            let recovery = JiraPanelConnectionRecoveryPolicy.presentation(
                for: model.jiraState.connection
            )
            JiraListContent(
                model: model,
                state: model.jiraState.list,
                searchText: searchText,
                sortOption: sortOption,
                quickFilters: quickFilters,
                leadingError: recovery?.title ?? error.safeRussianMessage,
                recovery: recovery,
                onRecovery: perform
            )
        case .ready, .connected:
            JiraListContent(
                model: model,
                state: model.jiraState.list,
                searchText: searchText,
                sortOption: sortOption,
                quickFilters: quickFilters
            )
        }
    }

    private func toggleProject(_ key: String) {
        var keys = model.jiraState.selectedProjectKeys
        if keys.contains(key) {
            keys.remove(key)
        } else {
            keys.insert(key)
        }
        model.setJiraSelectedProjectKeys(keys)
    }

    private func recoveryMessage(
        _ presentation: JiraPanelConnectionRecoveryPresentation,
        icon: String
    ) -> some View {
        JiraPanelMessage(
            icon: icon,
            title: presentation.title,
            detail: presentation.detail,
            actionTitle: presentation.actionTitle
        ) {
            perform(presentation.intent)
        }
    }

    private func perform(_ intent: JiraPanelConnectionIntent) {
        switch intent {
        case .openSettings:
            onOpenSettings()
        }
    }
}

private enum JiraIssueSortOption: String, CaseIterable, Identifiable {
    case priority
    case dueDate
    case updated

    var id: String { rawValue }

    var title: String {
        switch self {
        case .priority: "Приоритет"
        case .dueDate: "Срок"
        case .updated: "Обновление"
        }
    }
}

enum JiraIssueQuickFilter: String, CaseIterable, Identifiable {
    case inProgress
    case overdue
    case highPriority

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inProgress: "В работе"
        case .overdue: "Просрочено"
        case .highPriority: "Высокий приоритет"
        }
    }

    var systemImage: String {
        switch self {
        case .inProgress: "clock.arrow.circlepath"
        case .overdue: "calendar.badge.exclamationmark"
        case .highPriority: "flag.fill"
        }
    }
}

enum JiraIssueFilterPolicy {
    static func filteredIssues(
        _ issues: [JiraIssue],
        active filters: Set<JiraIssueQuickFilter>,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [JiraIssue] {
        guard filters.isEmpty == false else { return issues }

        return issues.filter { issue in
            filters.allSatisfy { filter in
                switch filter {
                case .inProgress:
                    return issue.status.categoryKey.lowercased() == "indeterminate"
                case .overdue:
                    guard let dueDate = issue.dueDate else { return false }
                    return JiraIssuePresentation.isOverdue(
                        dueDate,
                        relativeTo: now,
                        calendar: calendar
                    )
                case .highPriority:
                    return isHighPriority(issue.priorityName)
                }
            }
        }
    }

    static func isHighPriority(_ name: String?) -> Bool {
        guard let name else { return false }
        return ["high", "highest", "critical"].contains(
            name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        )
    }
}

enum JiraIssuePresentation {
    static func dueDateText(
        _ dueDate: Date,
        relativeTo now: Date = .now,
        calendar: Calendar = .current
    ) -> String {
        let today = calendar.startOfDay(for: now)
        let dueDay = calendar.startOfDay(for: dueDate)
        let dayDifference = calendar.dateComponents([.day], from: today, to: dueDay).day ?? 0

        switch dayDifference {
        case ..<0:
            return "Просрочено на \(abs(dayDifference)) д."
        case 0:
            return "Сегодня"
        case 1:
            return "Завтра"
        default:
            return dueDate.formatted(date: .abbreviated, time: .omitted)
        }
    }

    static func isOverdue(
        _ dueDate: Date,
        relativeTo now: Date = .now,
        calendar: Calendar = .current
    ) -> Bool {
        calendar.startOfDay(for: dueDate) < calendar.startOfDay(for: now)
    }
}

private struct JiraFilterPopover: View {
    @Binding var activeFilters: Set<JiraIssueQuickFilter>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Фильтры задач")
                .font(.system(size: 12, weight: .semibold, design: .rounded))

            ForEach(JiraIssueQuickFilter.allCases) { filter in
                Button {
                    toggle(filter)
                } label: {
                    HStack(spacing: 9) {
                        Image(
                            systemName: activeFilters.contains(filter)
                                ? "checkmark.square.fill"
                                : "square"
                        )
                        .foregroundStyle(
                            activeFilters.contains(filter) ? Color.signalMint : .secondary
                        )

                        Text(filter.title)
                            .foregroundStyle(.primary)

                        Spacer(minLength: 8)

                        Image(systemName: filter.systemImage)
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .frame(minHeight: 40)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(filter.title)
                .accessibilityValue(activeFilters.contains(filter) ? "Включен" : "Выключен")
            }

            Divider()

            Button("Сбросить") {
                activeFilters.removeAll()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(activeFilters.isEmpty ? .secondary : Color.signalCoral)
            .frame(minHeight: 40, alignment: .leading)
            .disabled(activeFilters.isEmpty)
        }
        .padding(14)
        .frame(width: 250)
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func toggle(_ filter: JiraIssueQuickFilter) {
        if activeFilters.contains(filter) {
            activeFilters.remove(filter)
        } else {
            activeFilters.insert(filter)
        }
    }
}

private struct JiraSearchPopover: View {
    @Binding var text: String
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Поиск задач")
                .font(.system(size: 12, weight: .semibold, design: .rounded))

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Ключ, название, статус…", text: $text)
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                if text.isEmpty == false {
                    Button {
                        text = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Очистить поиск")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 40)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(14)
        .frame(width: 260)
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            Task { @MainActor in isFocused = true }
        }
    }
}

enum JiraPanelConnectionIntent: Equatable {
    case openSettings
}

struct JiraPanelConnectionRecoveryPresentation: Equatable {
    let title: String
    let detail: String
    let actionTitle: String
    let intent: JiraPanelConnectionIntent
}

enum JiraPanelConnectionRecoveryPolicy {
    static func presentation(
        for state: JiraConnectionState
    ) -> JiraPanelConnectionRecoveryPresentation? {
        switch state {
        case .notConfigured:
            JiraPanelConnectionRecoveryPresentation(
                title: "Подключите Jira",
                detail: "Откройте Настройки и укажите Base URL и PAT.",
                actionTitle: "Подключить Jira",
                intent: .openSettings
            )
        case .failed(.unauthorized):
            JiraPanelConnectionRecoveryPresentation(
                title: "PAT недействителен",
                detail: "Укажите новый PAT в настройках Jira.",
                actionTitle: "Открыть настройки",
                intent: .openSettings
            )
        default:
            nil
        }
    }
}

private struct JiraProjectListRow: View {
    let title: String
    let subtitle: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(isSelected ? Color.signalMint : Color.clear)
                    .frame(width: 3, height: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(isSelected ? Color.signalMint : .white.opacity(0.72))
                        .lineLimit(1)

                    Text(subtitle)
                        .font(.system(size: 8, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(isSelected ? 0.52 : 0.34))
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .black))
                        .foregroundStyle(Color.signalMint)
                }
            }
            .padding(.horizontal, 8)
            .frame(width: 104, alignment: .leading)
            .frame(minHeight: 42, alignment: .leading)
            .background(
                isSelected ? Color.signalMint.opacity(0.13) : Color.white.opacity(0.04),
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(NotchButtonStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel("Проект \(title), \(subtitle)")
    }
}

private struct JiraListContent: View {
    @ObservedObject var model: NotchViewModel
    let state: JiraListState
    let searchText: String
    let sortOption: JiraIssueSortOption
    let quickFilters: Set<JiraIssueQuickFilter>
    var leadingError: String?
    var recovery: JiraPanelConnectionRecoveryPresentation?
    var onRecovery: ((JiraPanelConnectionIntent) -> Void)?

    init(
        model: NotchViewModel,
        state: JiraListState,
        searchText: String = "",
        sortOption: JiraIssueSortOption = .priority,
        quickFilters: Set<JiraIssueQuickFilter> = [],
        leadingError: String? = nil,
        recovery: JiraPanelConnectionRecoveryPresentation? = nil,
        onRecovery: ((JiraPanelConnectionIntent) -> Void)? = nil
    ) {
        self.model = model
        self.state = state
        self.searchText = searchText
        self.sortOption = sortOption
        self.quickFilters = quickFilters
        self.leadingError = leadingError
        self.recovery = recovery
        self.onRecovery = onRecovery
    }

    var body: some View {
        switch state {
        case .idle:
            if let leadingError {
                failureMessage(
                    icon: "exclamationmark.triangle",
                    title: "Не удалось подключиться",
                    detail: leadingError
                )
            } else {
                JiraPanelMessage(
                    icon: "gearshape",
                    title: "Jira готова к подключению",
                    detail: "Откройте Настройки, чтобы проверить сохранённое подключение."
                )
            }
        case .loading(let previous):
            if let previous, previous.isEmpty == false {
                issueList(
                    presentedIssues(previous),
                    notice: leadingError ?? "Обновляю задачи…",
                    showsProgress: leadingError == nil
                )
            } else {
                JiraProgressMessage(text: "Загружаю задачи…")
            }
        case .loaded(let issues, let total):
            let presented = presentedIssues(issues)
            let countNotice = JiraLoadedIssueNoticePolicy.text(
                visibleCount: issues.count,
                total: total
            )
            let notices = [leadingError, countNotice].compactMap { $0 }
            let notice = notices.isEmpty ? nil : notices.joined(separator: " • ")
            if issues.isEmpty {
                VStack(spacing: 7) {
                    if let notice {
                        JiraInlineNotice(text: notice)
                    }
                    if recovery != nil {
                        failureMessage(
                            icon: "exclamationmark.triangle",
                            title: "Не удалось подключиться",
                            detail: leadingError ?? "Проверьте подключение Jira."
                        )
                    } else {
                        JiraPanelMessage(
                            icon: "checkmark.circle",
                            title: "Задач нет",
                            detail: "Для выбранных проектов очередь пуста."
                        )
                    }
                }
            } else if presented.isEmpty {
                emptyResultsMessage()
            } else {
                issueList(presented, notice: notice)
            }
        case .failed(let error, let previous):
            if let previous, previous.isEmpty == false {
                let presented = presentedIssues(previous)
                if presented.isEmpty {
                    emptyResultsMessage(usesStaleData: true)
                } else {
                    issueList(presented, notice: leadingError ?? error.safeRussianMessage)
                }
            } else {
                failureMessage(
                    icon: "exclamationmark.triangle",
                    title: "Не удалось загрузить задачи",
                    detail: error.safeRussianMessage
                )
            }
        }
    }

    private func presentedIssues(_ issues: [JiraIssue]) -> [JiraIssue] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let searchMatches = query.isEmpty ? issues : issues.filter { issue in
            [
                issue.key,
                issue.summary,
                issue.projectKey,
                issue.projectName,
                issue.status.name,
                issue.priorityName ?? ""
            ].contains { $0.localizedCaseInsensitiveContains(query) }
        }
        let filtered = JiraIssueFilterPolicy.filteredIssues(
            searchMatches,
            active: quickFilters
        )

        switch sortOption {
        case .priority:
            return filtered
        case .dueDate:
            return filtered.sorted { left, right in
                switch (left.dueDate, right.dueDate) {
                case let (leftDate?, rightDate?) where leftDate != rightDate:
                    return leftDate < rightDate
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    return left.key < right.key
                }
            }
        case .updated:
            return filtered.sorted { left, right in
                switch (left.updatedAt, right.updatedAt) {
                case let (leftDate?, rightDate?) where leftDate != rightDate:
                    return leftDate > rightDate
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    return left.key < right.key
                }
            }
        }
    }

    private func emptyResultsMessage(usesStaleData: Bool = false) -> some View {
        if quickFilters.isEmpty == false {
            JiraPanelMessage(
                icon: "line.3.horizontal.decrease.circle",
                title: "Нет задач по выбранным фильтрам",
                detail: usesStaleData
                    ? "Старые данные сохранены. Измените или сбросьте фильтры."
                    : "Измените или сбросьте фильтры."
            )
        } else {
            JiraPanelMessage(
                icon: "magnifyingglass",
                title: "Ничего не найдено",
                detail: usesStaleData
                    ? "Старые данные сохранены, но запросу ничего не соответствует."
                    : "Измените поисковый запрос или очистите его."
            )
        }
    }

    private func issueList(
        _ issues: [JiraIssue],
        notice: String? = nil,
        showsProgress: Bool = false
    ) -> some View {
        VStack(spacing: 7) {
            if let notice {
                JiraInlineNotice(text: notice, showsProgress: showsProgress)
            }

            if let recovery {
                recoveryButton(recovery)
            }

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 7) {
                    ForEach(issues) { issue in
                        JiraIssueRow(model: model, issue: issue)
                    }
                }
            }
        }
    }

    private func failureMessage(
        icon: String,
        title: String,
        detail: String
    ) -> some View {
        JiraPanelMessage(
            icon: icon,
            title: recovery?.title ?? title,
            detail: recovery?.detail ?? detail,
            actionTitle: recovery?.actionTitle,
            action: recovery.map { presentation in
                { onRecovery?(presentation.intent) }
            }
        )
    }

    private func recoveryButton(
        _ presentation: JiraPanelConnectionRecoveryPresentation
    ) -> some View {
        Button {
            onRecovery?(presentation.intent)
        } label: {
            Label(presentation.actionTitle, systemImage: "gearshape")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.signalMint)
        }
        .buttonStyle(NotchButtonStyle())
    }
}

enum JiraLoadedIssueNoticePolicy {
    static func text(visibleCount: Int, total: Int) -> String? {
        guard total > visibleCount else { return nil }
        return "Показано \(visibleCount) из \(total) задач"
    }
}

private struct JiraInlineNotice: View {
    let text: String
    var showsProgress = false

    var body: some View {
        HStack(spacing: 7) {
            if showsProgress {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.signalAmber)
            }
            Text(text)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.system(size: 10, weight: .medium, design: .rounded))
        .foregroundStyle(.white.opacity(0.6))
        .padding(.horizontal, 2)
    }
}

private struct JiraIssueRow: View {
    @ObservedObject var model: NotchViewModel
    let issue: JiraIssue

    @State private var isShowingTransitions = false
    @State private var didCopyKey = false

    private var transitionState: JiraTransitionState {
        model.jiraState.transitionsByIssueKey[issue.key] ?? .idle
    }

    private var isTransitionBusy: Bool {
        switch transitionState {
        case .loading, .submitting:
            true
        default:
            false
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(categoryColor)
                .frame(width: 4)

            Button(action: openIssue) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(issue.key)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.signalCyan)

                    Text(issue.summary)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    if issue.priorityName != nil || issue.dueDate != nil {
                        HStack(spacing: 8) {
                            if let priority = issue.priorityName {
                                Label(priority, systemImage: "flag.fill")
                                    .foregroundStyle(priorityColor(for: priority))
                            }
                            if let dueDate = issue.dueDate {
                                Label(
                                    JiraIssuePresentation.dueDateText(dueDate),
                                    systemImage: "calendar"
                                )
                                .foregroundStyle(
                                    JiraIssuePresentation.isOverdue(dueDate)
                                        ? Color.signalCoral
                                        : Color.white.opacity(0.4)
                                )
                            }
                        }
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(NotchButtonStyle())
            .accessibilityLabel("Открыть \(issue.key): \(issue.summary)")

            HStack(spacing: 4) {
                Button(action: copyIssueKey) {
                    Image(systemName: didCopyKey ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(didCopyKey ? Color.signalMint : .white.opacity(0.58))
                        .frame(width: 30, height: 30)
                        .background(
                            Color.white.opacity(0.07),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .padding(5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(NotchButtonStyle())
                .help(didCopyKey ? "Ключ скопирован" : "Скопировать \(issue.key)")
                .accessibilityLabel("Скопировать ключ \(issue.key)")

                Button {
                    isShowingTransitions = true
                    Task { await model.loadJiraTransitions(for: issue.key) }
                } label: {
                    Group {
                        if isTransitionBusy {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: statusIconName)
                                .font(.system(size: 10, weight: .semibold))
                        }
                    }
                    .foregroundStyle(statusCategoryColor)
                    .frame(width: 30, height: 30)
                    .background(
                        Color.white.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .padding(5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(NotchButtonStyle())
                .disabled(isTransitionBusy)
                .help("Текущий статус: \(issue.status.name)")
                .popover(isPresented: $isShowingTransitions, arrowEdge: .bottom) {
                    JiraTransitionPopover(
                        model: model,
                        issue: issue,
                        state: transitionState,
                        dismiss: { isShowingTransitions = false }
                    )
                }
                .accessibilityLabel(
                    "Изменить статус \(issue.key). Текущий статус: \(issue.status.name)"
                )
            }
        }
        .padding(10)
        .background(
            Color.white.opacity(0.055),
            in: RoundedRectangle(cornerRadius: 15, style: .continuous)
        )
    }

    private var categoryColor: Color {
        if isOverdue { return Color.signalCoral }
        return statusCategoryColor
    }

    private var statusCategoryColor: Color {
        return switch issue.status.categoryKey.lowercased() {
        case "new": Color.signalCyan
        case "indeterminate": Color.signalAmber
        case "done": Color.signalMint
        default: Color.white.opacity(0.45)
        }
    }

    private var statusIconName: String {
        switch issue.status.categoryKey.lowercased() {
        case "new": "circle"
        case "indeterminate": "clock.arrow.circlepath"
        case "done": "checkmark.circle.fill"
        default: "arrow.triangle.2.circlepath"
        }
    }

    private var isOverdue: Bool {
        guard let dueDate = issue.dueDate else { return false }
        return JiraIssuePresentation.isOverdue(dueDate)
    }

    private func priorityColor(for priority: String) -> Color {
        switch priority.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "critical", "highest": Color.signalCoral
        case "high": Color.signalAmber
        case "medium": Color.signalCyan
        case "low", "lowest": Color.white.opacity(0.34)
        default: Color.white.opacity(0.44)
        }
    }

    private func openIssue() {
        guard let baseURL = model.configuredJiraBaseURLString,
              let url = issue.browserURL(baseURL: baseURL) else { return }
        NSWorkspace.shared.open(url)
    }

    private func copyIssueKey() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(issue.key, forType: .string)
        didCopyKey = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            didCopyKey = false
        }
    }
}

private struct JiraTransitionPopover: View {
    @ObservedObject var model: NotchViewModel
    let issue: JiraIssue
    let state: JiraTransitionState
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(issue.key)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)

            switch state {
            case .idle, .loading:
                progress("Загружаю переходы…")
            case .loaded(let transitions):
                transitionButtons(transitions)
            case .submitting(let transitions):
                progress("Применяю статус…")
                transitionButtons(transitions, disabled: true)
            case .failed(let error, let previous):
                Text(error.safeRussianMessage)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                if let previous {
                    transitionButtons(previous)
                }
            }
        }
        .padding(12)
        .frame(width: 230)
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text)
                .font(.system(size: 10, weight: .medium, design: .rounded))
        }
    }

    @ViewBuilder
    private func transitionButtons(
        _ transitions: [JiraTransition],
        disabled: Bool = false
    ) -> some View {
        if transitions.isEmpty {
            Text("Доступных переходов нет")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        } else {
            ForEach(transitions) { transition in
                Button(transition.name) {
                    dismiss()
                    Task {
                        await model.submitJiraTransition(
                            issueKey: issue.key,
                            transition: transition
                        )
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .disabled(disabled)
            }
        }
    }
}

private struct JiraProgressMessage: View {
    let text: String

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text(text)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.52))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct JiraPanelMessage: View {
    let icon: String
    let title: String
    let detail: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 25, weight: .light))
                .foregroundStyle(Color.signalMint)
            Text(title)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            Text(detail)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.45))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 290)
            if let actionTitle, let action {
                Button(action: action) {
                    Label(actionTitle, systemImage: "arrow.right.circle.fill")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.signalMint)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 34)
                        .background(
                            Color.white.opacity(0.07),
                            in: Capsule()
                        )
                }
                .buttonStyle(NotchButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension JiraAPIError {
    var safeRussianMessage: String {
        switch self {
        case .invalidBaseURL: "Проверьте адрес Jira."
        case .notConfigured: "Подключите Jira в Настройках."
        case .unauthorized: "Проверьте PAT."
        case .forbidden: "Недостаточно прав Jira."
        case .rateLimited: "Слишком много запросов. Попробуйте позже."
        case .server: "Jira временно недоступна."
        case .http: "Jira вернула ошибку."
        case .invalidResponse, .decoding: "Не удалось прочитать ответ Jira."
        case .network: "Нет связи с Jira."
        }
    }
}

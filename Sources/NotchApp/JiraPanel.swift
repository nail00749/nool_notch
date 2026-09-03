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
    @State private var mode = JiraPanelMode.mine

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
        .onChange(of: model.transientSurfaceDismissalRequest) { _, _ in
            isShowingFilters = false
            isShowingSearch = false
        }
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
            if mode == .mine {
                projectSidebar

                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 1)
            }

            VStack(spacing: 8) {
                taskHeader
                Group {
                    if mode == .mine {
                        stateContent
                    } else {
                        JiraPinnedPanel(
                            model: model,
                            searchText: searchText,
                            sortOption: sortOption,
                            quickFilters: quickFilters,
                            onOpenSettings: onOpenSettings
                        )
                    }
                }
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
            HStack(spacing: 2) {
                ForEach(JiraPanelMode.allCases) { candidate in
                    Button {
                        mode = candidate
                        if candidate == .pinned,
                           let source = model.jiraState.pinned.selectedSource
                                ?? model.jiraState.pinned.availableSources.first {
                            model.selectJiraPinnedSource(source)
                        }
                    } label: {
                        Text(candidate.title)
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundStyle(mode == candidate ? .white : .white.opacity(0.42))
                            .frame(width: 50, height: 30)
                            .background(
                                mode == candidate ? Color.white.opacity(0.13) : .clear,
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                            )
                    }
                    .buttonStyle(NotchButtonStyle())
                    .accessibilityAddTraits(mode == candidate ? .isSelected : [])
                }
            }
            .padding(2)
            .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 11))

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
                model.transientSurfaceDidPresent(.jiraFilters)
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
                    .onDisappear {
                        model.transientSurfaceDidDisappear(.jiraFilters)
                    }
            }
            .accessibilityLabel("Фильтры задач Jira")
            .accessibilityValue(
                quickFilters.isEmpty ? "Не выбраны" : "Выбрано: \(quickFilters.count)"
            )

            Button {
                model.transientSurfaceDidPresent(.jiraSearch)
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
                    .onDisappear {
                        model.transientSurfaceDidDisappear(.jiraSearch)
                    }
            }
            .accessibilityLabel(searchText.isEmpty ? "Поиск задач Jira" : "Изменить поиск задач Jira")

            Button(action: refreshSelectedMode) {
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
        if mode == .pinned,
           let source = model.jiraState.pinned.selectedSource,
           case .loading = model.jiraState.pinned.sourceStates[source] {
            return true
        }
        if case .loading = model.jiraState.list { return true }
        return false
    }

    private func refreshSelectedMode() {
        if mode == .pinned {
            model.refreshJiraPinnedSource()
        } else {
            model.refreshJira()
        }
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

enum JiraPanelMode: String, CaseIterable, Identifiable {
    case mine
    case pinned

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mine: "Мои"
        case .pinned: "Закреп."
        }
    }
}

enum JiraIssueSortOption: String, CaseIterable, Identifiable {
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

struct JiraListContent: View {
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

struct JiraWorklogIcon: View {
    static let symbolNames = ["clock", "plus.circle.fill"]

    var size: CGFloat = 12

    var body: some View {
        ZStack {
            Image(systemName: Self.symbolNames[0])
                .font(.system(size: size, weight: .semibold))

            Image(systemName: Self.symbolNames[1])
                .font(.system(size: size * 0.56, weight: .bold))
                .offset(x: size * 0.42, y: size * 0.42)
        }
        .frame(width: size * 1.55, height: size * 1.55)
        .accessibilityHidden(true)
    }
}

enum JiraWorklogPopoverAnimationPolicy {
    static func disablesAnimations(isPresented: Bool) -> Bool {
        !isPresented
    }
}

private enum JiraStatusVisuals {
    static func color(for status: JiraStatus) -> Color {
        switch status.categoryKey.lowercased() {
        case "new": Color.signalCyan
        case "indeterminate": Color.signalAmber
        case "done": Color.signalMint
        default: Color.white.opacity(0.55)
        }
    }

    static func iconName(for status: JiraStatus) -> String {
        switch status.categoryKey.lowercased() {
        case "new": "circle"
        case "indeterminate": "clock.arrow.circlepath"
        case "done": "checkmark.circle.fill"
        default: "arrow.triangle.2.circlepath"
        }
    }
}

private struct JiraStatusBadge: View {
    let status: JiraStatus
    var showsCurrentMark = false

    private var color: Color {
        JiraStatusVisuals.color(for: status)
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(
                systemName: showsCurrentMark
                    ? "checkmark"
                    : JiraStatusVisuals.iconName(for: status)
            )
            .font(.system(size: 8, weight: .bold))

            Text(status.name)
                .lineLimit(1)
        }
        .font(.system(size: 9, weight: .semibold, design: .rounded))
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.13), in: Capsule())
        .help("Текущий статус: \(status.name)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Текущий статус: \(status.name)")
    }
}

private struct JiraIssueRow: View {
    @ObservedObject var model: NotchViewModel
    let issue: JiraIssue

    @State private var isShowingTransitions = false
    @State private var isShowingWorklog = false
    @State private var isShowingAssignee = false
    @State private var didCopyKey = false
    @State private var didAddWorklog = false
    @State private var isSubmittingWorklog = false

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

    private var assigneeState: JiraAssigneeState {
        model.jiraState.assigneesByIssueKey[issue.key] ?? .idle
    }

    private var isAssigneeBusy: Bool {
        if case .submitting = assigneeState { return true }
        return false
    }

    private var worklogPresentation: Binding<Bool> {
        Binding(
            get: { isShowingWorklog },
            set: { isPresented in
                var transaction = Transaction()
                transaction.disablesAnimations =
                    JiraWorklogPopoverAnimationPolicy.disablesAnimations(
                        isPresented: isPresented
                    )
                withTransaction(transaction) {
                    isShowingWorklog = isPresented
                }
            }
        )
    }

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(categoryColor)
                .frame(width: 4)

            Button(action: openIssue) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Text(issue.key)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.signalCyan)

                        JiraStatusBadge(status: issue.status)
                    }

                    Text(issue.summary)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 8) {
                        Label(
                            issue.assignee?.displayName ?? "Без исполнителя",
                            systemImage: issue.assignee == nil ? "person.slash" : "person.fill"
                        )
                        .foregroundStyle(Color.white.opacity(0.48))

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
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(NotchButtonStyle())
            .accessibilityLabel(
                "Открыть \(issue.key): \(issue.summary). Статус: \(issue.status.name)"
            )

            Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                GridRow {
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
                        guard !isAssigneeBusy else { return }
                        model.transientSurfaceDidPresent(.jiraAssignee(issue.key))
                        isShowingAssignee = true
                    } label: {
                        Group {
                            if isAssigneeBusy {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: issue.assignee == nil ? "person.badge.plus" : "person.crop.circle")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                        }
                        .foregroundStyle(Color.signalCyan)
                        .frame(width: 30, height: 30)
                        .background(
                            Color.white.opacity(0.07),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .padding(5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(NotchButtonStyle())
                    .disabled(isAssigneeBusy)
                    .help("Изменить исполнителя \(issue.key)")
                    .popover(isPresented: $isShowingAssignee, arrowEdge: .bottom) {
                        JiraAssigneePopover(
                            model: model,
                            issue: issue,
                            state: assigneeState,
                            dismiss: { isShowingAssignee = false }
                        )
                        .onDisappear {
                            model.transientSurfaceDidDisappear(.jiraAssignee(issue.key))
                        }
                    }
                    .accessibilityLabel(
                        "Изменить исполнителя \(issue.key). Сейчас: \(issue.assignee?.displayName ?? "без исполнителя")"
                    )
                }

                GridRow {
                    Button {
                        guard !isSubmittingWorklog else { return }
                        model.transientSurfaceDidPresent(.jiraWorklog(issue.key))
                        isShowingWorklog = true
                    } label: {
                        Group {
                            if isSubmittingWorklog {
                                ProgressView()
                                    .controlSize(.small)
                            } else if didAddWorklog {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .semibold))
                            } else {
                                JiraWorklogIcon(size: 10)
                            }
                        }
                        .foregroundStyle(
                            didAddWorklog ? Color.signalMint : .white.opacity(0.58)
                        )
                        .frame(width: 30, height: 30)
                        .background(
                            Color.white.opacity(0.07),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .padding(5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(NotchButtonStyle())
                    .disabled(isSubmittingWorklog)
                    .help(
                        isSubmittingWorklog
                            ? "Списание времени в \(issue.key)…"
                            : "Списать время в \(issue.key)"
                    )
                    .popover(isPresented: worklogPresentation, arrowEdge: .bottom) {
                        JiraWorklogPopover(
                            model: model,
                            issue: issue,
                            isSubmitting: $isSubmittingWorklog
                        ) {
                            isSubmittingWorklog = false
                            worklogPresentation.wrappedValue = false
                            didAddWorklog = true
                            Task { @MainActor in
                                try? await Task.sleep(for: .seconds(1.2))
                                didAddWorklog = false
                            }
                        }
                        .onDisappear {
                            model.transientSurfaceDidDisappear(.jiraWorklog(issue.key))
                        }
                    }
                    .accessibilityLabel("Списать время в задачу \(issue.key)")

                    Button {
                        model.transientSurfaceDidPresent(.jiraTransitions(issue.key))
                        isShowingTransitions = true
                        Task { await model.loadJiraTransitions(for: issue.key) }
                    } label: {
                        Group {
                            if isTransitionBusy {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
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
                        .onDisappear {
                            model.transientSurfaceDidDisappear(.jiraTransitions(issue.key))
                        }
                    }
                    .accessibilityLabel(
                        "Изменить статус \(issue.key). Текущий статус: \(issue.status.name)"
                    )
                }
            }
        }
        .padding(10)
        .background(
            Color.white.opacity(0.055),
            in: RoundedRectangle(cornerRadius: 15, style: .continuous)
        )
        .onChange(of: model.transientSurfaceDismissalRequest) { _, _ in
            worklogPresentation.wrappedValue = false
            isShowingTransitions = false
            isShowingAssignee = false
        }
    }

    private var categoryColor: Color {
        if isOverdue { return Color.signalCoral }
        return statusCategoryColor
    }

    private var statusCategoryColor: Color {
        JiraStatusVisuals.color(for: issue.status)
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

private struct JiraDurationWheel: View {
    let title: String
    let unit: String
    let values: [Int]
    @Binding var selection: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scrollPosition: Int?

    private let rowHeight: CGFloat = 40

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)

            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.signalMint.opacity(0.12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(Color.signalMint.opacity(0.18), lineWidth: 1)
                    }
                    .frame(height: rowHeight)

                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(values, id: \.self) { value in
                            Button {
                                select(value)
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 4) {
                                    Text(String(format: "%02d", value))
                                        .monospacedDigit()
                                    Text(unit)
                                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                                        .foregroundStyle(.secondary)
                                }
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .foregroundStyle(value == selection ? .primary : .secondary)
                                .opacity(value == selection ? 1 : 0.42)
                                .scaleEffect(value == selection ? 1 : 0.88)
                                .frame(maxWidth: .infinity, minHeight: rowHeight)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .id(value)
                        }
                    }
                    .scrollTargetLayout()
                }
                .contentMargins(.vertical, rowHeight, for: .scrollContent)
                .scrollPosition(id: $scrollPosition, anchor: .center)
                .scrollTargetBehavior(.viewAligned)
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black, location: 0.18),
                            .init(color: .black, location: 0.82),
                            .init(color: .clear, location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
            }
            .frame(height: rowHeight * 3)
            .background(
                Color.primary.opacity(0.045),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(selection) \(unit)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                adjust(by: 1)
            case .decrement:
                adjust(by: -1)
            @unknown default:
                break
            }
        }
        .focusable()
        .focusEffectDisabled()
        .onMoveCommand { direction in
            switch direction {
            case .up:
                adjust(by: -1)
            case .down:
                adjust(by: 1)
            default:
                break
            }
        }
        .onAppear {
            scrollPosition = selection
        }
        .onChange(of: scrollPosition) { _, newValue in
            guard let newValue, values.contains(newValue) else { return }
            selection = newValue
        }
        .onChange(of: selection) { oldValue, newValue in
            guard oldValue != newValue else { return }
            NotchHaptics.wheelSelectionChanged()
            guard scrollPosition != newValue else { return }
            scrollPosition = newValue
        }
    }

    private func adjust(by offset: Int) {
        guard let currentIndex = values.firstIndex(of: selection) else { return }
        let newIndex = min(max(currentIndex + offset, values.startIndex), values.index(before: values.endIndex))
        select(values[newIndex])
    }

    private func select(_ value: Int) {
        guard values.contains(value) else { return }
        if reduceMotion {
            selection = value
            scrollPosition = value
        } else {
            withAnimation(.easeOut(duration: 0.16)) {
                selection = value
                scrollPosition = value
            }
        }
    }
}

private struct JiraWorklogPopover: View {
    @ObservedObject var model: NotchViewModel
    let issue: JiraIssue
    @Binding var isSubmitting: Bool
    let onSuccess: () -> Void

    @State private var hours = 1
    @State private var minutes = 0
    @State private var description = ""
    @State private var errorMessage: String?
    @FocusState private var isDescriptionFocused: Bool

    private var draft: JiraWorklogDraft {
        JiraWorklogDraft(
            hours: hours,
            minutes: minutes,
            description: description
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                JiraWorklogIcon(size: 13)
                    .foregroundStyle(Color.signalMint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Списать время")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                    Text(issue.key)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                JiraDurationWheel(
                    title: "Часы",
                    unit: "ч",
                    values: JiraWorklogDurationOptions.hourValues,
                    selection: $hours
                )
                JiraDurationWheel(
                    title: "Минуты",
                    unit: "мин",
                    values: JiraWorklogDurationOptions.minuteValues,
                    selection: $minutes
                )
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Что сделано")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)

                ZStack(alignment: .topLeading) {
                    if description.isEmpty {
                        Text("Кратко опишите выполненную работу")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary.opacity(0.7))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 9)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $description)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .focused($isDescriptionFocused)
                        .accessibilityLabel("Что сделано")
                        .accessibilityHint("Кратко опишите выполненную работу")
                }
                .frame(height: 76)
                .background(
                    Color.primary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.signalCoral)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: submit) {
                HStack(spacing: 7) {
                    if isSubmitting {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "clock.badge.checkmark")
                    }
                    Text(isSubmitting ? "Списываю…" : "Списать время")
                }
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(draft.isValid ? Color.black.opacity(0.82) : .secondary)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(
                    draft.isValid ? Color.signalMint : Color.primary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
            }
            .buttonStyle(NotchButtonStyle())
            .disabled(!draft.isValid || isSubmitting)
        }
        .padding(14)
        .frame(width: 290)
        .onAppear { isDescriptionFocused = true }
    }

    private func submit() {
        guard draft.isValid, !isSubmitting else { return }
        let submittedDraft = draft
        isSubmitting = true
        errorMessage = nil

        Task {
            let result = await model.submitJiraWorklog(
                issueKey: issue.key,
                draft: submittedDraft
            )
            switch result {
            case .success:
                onSuccess()
            case .failure(let error):
                errorMessage = error.safeRussianMessage
                isSubmitting = false
            }
        }
    }
}

private struct JiraAssigneePopover: View {
    @ObservedObject var model: NotchViewModel
    let issue: JiraIssue
    let state: JiraAssigneeState
    let dismiss: () -> Void

    @State private var query = ""
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var isSearchFocused: Bool

    private var visibleUsers: [JiraAssignee] {
        switch state {
        case .loaded(let users), .submitting(let users):
            users
        case .loading(let previous), .failed(_, let previous):
            previous ?? []
        case .idle:
            []
        }
    }

    private var isLoading: Bool {
        if case .loading = state { return true }
        return false
    }

    private var isSubmitting: Bool {
        if case .submitting = state { return true }
        return false
    }

    private var error: JiraAPIError? {
        if case .failed(let error, _) = state { return error }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(issue.key)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 5) {
                Text("Текущий исполнитель")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)

                Label(
                    issue.assignee?.displayName ?? "Без исполнителя",
                    systemImage: issue.assignee == nil ? "person.slash" : "person.fill"
                )
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.signalCyan)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.signalCyan.opacity(0.12), in: Capsule())
            }

            HStack(spacing: 6) {
                quickAction(
                    title: "На себя",
                    icon: "person.crop.circle.badge.checkmark",
                    selection: .currentUser,
                    disabled: false
                )
                quickAction(
                    title: "Снять",
                    icon: "person.crop.circle.badge.minus",
                    selection: .unassigned,
                    disabled: issue.assignee == nil
                )
            }

            TextField("Поиск по имени", text: $query)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .focused($isSearchFocused)
                .disabled(isSubmitting)

            if let error {
                Text(error.safeRussianMessage)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.signalCoral)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isLoading, visibleUsers.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Ищу доступных пользователей…")
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
            } else if visibleUsers.isEmpty {
                Text(query.isEmpty ? "Доступных пользователей нет" : "Ничего не найдено")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
            } else {
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(visibleUsers) { user in
                            userButton(user)
                        }
                    }
                }
                .frame(maxHeight: 400)
                .overlay(alignment: .topTrailing) {
                    if isLoading {
                        ProgressView()
                            .controlSize(.mini)
                            .padding(5)
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 300)
        .onAppear {
            scheduleSearch(immediate: true)
            isSearchFocused = true
        }
        .onChange(of: query) { _, _ in
            scheduleSearch(immediate: false)
        }
        .onDisappear {
            searchTask?.cancel()
        }
    }

    private func quickAction(
        title: String,
        icon: String,
        selection: JiraAssigneeSelection,
        disabled: Bool
    ) -> some View {
        Button {
            submit(selection)
        } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(
                    Color.white.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled || isSubmitting)
        .opacity(disabled ? 0.4 : 1)
    }

    private func userButton(_ user: JiraAssignee) -> some View {
        let isCurrent = issue.assignee?.username == user.username
        return Button {
            submit(.user(user))
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isCurrent ? "checkmark.circle.fill" : "person.crop.circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isCurrent ? Color.signalMint : Color.signalCyan)

                Text(user.displayName)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .lineLimit(1)

                Spacer(minLength: 4)
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            .padding(.horizontal, 9)
            .background(
                Color.white.opacity(isCurrent ? 0.09 : 0.055),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isCurrent || isSubmitting)
        .opacity(isSubmitting ? 0.55 : 1)
    }

    private func scheduleSearch(immediate: Bool) {
        searchTask?.cancel()
        let requestedQuery = query
        searchTask = Task { @MainActor in
            if immediate == false {
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard Task.isCancelled == false else { return }
            await model.searchJiraAssignees(
                issueKey: issue.key,
                projectKey: issue.projectKey,
                query: requestedQuery
            )
        }
    }

    private func submit(_ selection: JiraAssigneeSelection) {
        guard isSubmitting == false else { return }
        searchTask?.cancel()
        Task { @MainActor in
            if case .success = await model.assignJiraIssue(
                issueKey: issue.key,
                selection: selection
            ) {
                dismiss()
            }
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

            VStack(alignment: .leading, spacing: 5) {
                Text("Текущий статус")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)

                JiraStatusBadge(status: issue.status, showsCurrentMark: true)
            }

            Divider()
                .overlay(Color.white.opacity(0.08))

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
        let presentation = JiraStatusSelectionPresentation(
            currentStatus: issue.status,
            transitions: transitions
        )

        if presentation.availableTransitions.isEmpty {
            Text("Других доступных статусов нет")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        } else {
            Text("Перевести в")
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)

            ForEach(presentation.availableTransitions) { transition in
                Button {
                    dismiss()
                    Task {
                        await model.submitJiraTransition(
                            issueKey: issue.key,
                            transition: transition
                        )
                    }
                } label: {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(JiraStatusVisuals.color(for: transition.toStatus))
                            .frame(width: 6, height: 6)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(transition.toStatus.name)
                                .font(.system(size: 11, weight: .semibold, design: .rounded))

                            if transition.name != transition.toStatus.name {
                                Text(transition.name)
                                    .font(.system(size: 8, weight: .medium, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer(minLength: 4)

                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                    .padding(.horizontal, 9)
                    .background(
                        Color.white.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(disabled)
                .opacity(disabled ? 0.55 : 1)
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
        case .invalidWorklog: "Укажите время и описание работы."
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

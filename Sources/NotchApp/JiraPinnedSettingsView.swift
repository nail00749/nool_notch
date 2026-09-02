import SwiftUI

struct JiraPinnedSettingsView: View {
    @ObservedObject var model: NotchViewModel

    @State private var searchText = ""
    @State private var issueKey = ""

    var body: some View {
        VStack(spacing: 12) {
            SettingsCard(title: "Проекты и доски", icon: "pin") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        TextField("Поиск по названию, ключу или ID", text: $searchText)
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 11)
                            .frame(height: 40)
                            .background(
                                Color.white.opacity(0.07),
                                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                            )

                        Button(action: model.refreshJiraPinnedCatalog) {
                            Image(systemName: "arrow.clockwise")
                                .frame(width: 40, height: 40)
                        }
                        .buttonStyle(NotchButtonStyle())
                        .disabled(isCatalogLoading)
                        .accessibilityLabel("Обновить проекты и доски")
                    }

                    if catalogItems.isEmpty {
                        Text(catalogEmptyText)
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.4))
                            .padding(.vertical, 8)
                    } else {
                        VStack(spacing: 4) {
                            ForEach(catalogItems.prefix(20)) { container in
                                catalogRow(container)
                            }
                        }
                    }

                    if model.jiraState.pinned.containers.isEmpty == false {
                        Divider().overlay(Color.white.opacity(0.08))
                        Text("Закреплено")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.42))
                        ForEach(Array(model.jiraState.pinned.containers.enumerated()), id: \.element.id) { index, container in
                            pinnedContainerRow(container, index: index)
                        }
                    }
                }
            }

            SettingsCard(title: "Задачи", icon: "pin.circle") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        TextField("NPA-123", text: $issueKey)
                            .textFieldStyle(.plain)
                            .textCase(.uppercase)
                            .padding(.horizontal, 11)
                            .frame(height: 40)
                            .background(
                                Color.white.opacity(0.07),
                                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                            )
                            .onSubmit(addIssue)

                        Button(action: addIssue) {
                            Group {
                                if model.jiraState.pinned.isPinningIssue {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "plus")
                                }
                            }
                            .frame(width: 40, height: 40)
                        }
                        .buttonStyle(NotchButtonStyle())
                        .disabled(normalizedIssueKey.isEmpty || model.jiraState.pinned.isPinningIssue)
                        .accessibilityLabel("Закрепить задачу")
                    }

                    if let error = model.jiraState.pinned.pinIssueError {
                        Text(errorText(error))
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.signalCoral)
                    }

                    ForEach(Array(model.jiraState.pinned.issues.enumerated()), id: \.element.id) { index, issue in
                        pinnedIssueRow(issue, index: index)
                    }
                }
            }
        }
        .onAppear {
            model.refreshJiraPinnedCatalog()
        }
    }

    private var catalogItems: [JiraPinnedContainer] {
        let projects = model.jiraState.pinned.catalog.projects.map(JiraPinnedContainer.project)
        let boards = model.jiraState.pinned.catalog.boards.map(JiraPinnedContainer.board)
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return (projects + boards)
            .filter { container in
                query.isEmpty
                    || container.name.lowercased().contains(query)
                    || container.reference.lowercased().contains(query)
                    || container.detail.lowercased().contains(query)
            }
            .sorted { lhs, rhs in
                if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    private var isCatalogLoading: Bool {
        if case .loading = model.jiraState.pinned.catalog { return true }
        return false
    }

    private var catalogEmptyText: String {
        switch model.jiraState.pinned.catalog {
        case .idle, .loading:
            "Загружаю доступные проекты и доски…"
        case .loaded:
            searchText.isEmpty ? "Нет доступных проектов и досок" : "Ничего не найдено"
        case .failed(let error, _, _):
            errorText(error)
        }
    }

    private var normalizedIssueKey: String {
        issueKey.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private func addIssue() {
        let key = normalizedIssueKey
        guard key.isEmpty == false else { return }
        Task { @MainActor in
            await model.pinJiraIssue(key: key)
            if model.jiraState.pinned.pinIssueError == nil {
                issueKey = ""
            }
        }
    }

    private func catalogRow(_ container: JiraPinnedContainer) -> some View {
        let isPinned = model.jiraState.pinned.containers.contains { $0.id == container.id }
        return Button {
            model.toggleJiraPinnedContainer(container)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: container.kind == .board ? "rectangle.split.3x1" : "shippingbox")
                    .foregroundStyle(isPinned ? Color.signalMint : .white.opacity(0.48))
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(container.name)
                        .foregroundStyle(.white.opacity(0.82))
                    Text("\(container.kind == .board ? "Доска" : "Проект") · \(container.detail)")
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.36))
                }
                Spacer()
                Image(systemName: isPinned ? "pin.fill" : "pin")
                    .foregroundStyle(isPinned ? Color.signalMint : .white.opacity(0.4))
            }
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .padding(.horizontal, 10)
            .frame(minHeight: 40)
            .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(NotchButtonStyle())
    }

    private func pinnedContainerRow(_ container: JiraPinnedContainer, index: Int) -> some View {
        HStack(spacing: 8) {
            Text(container.name)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .lineLimit(1)
            Spacer()
            orderButton("chevron.up", disabled: index == 0) {
                model.moveJiraPinnedContainer(container, by: -1)
            }
            orderButton(
                "chevron.down",
                disabled: index == model.jiraState.pinned.containers.count - 1
            ) {
                model.moveJiraPinnedContainer(container, by: 1)
            }
            Button {
                model.toggleJiraPinnedContainer(container)
            } label: {
                Image(systemName: "xmark").frame(width: 34, height: 34)
            }
            .buttonStyle(NotchButtonStyle())
        }
        .foregroundStyle(.white.opacity(0.72))
        .frame(minHeight: 40)
    }

    private func pinnedIssueRow(_ issue: JiraPinnedIssue, index: Int) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(issue.key).foregroundStyle(Color.signalCyan)
                Text(issue.summary).foregroundStyle(.white.opacity(0.52)).lineLimit(1)
            }
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            Spacer()
            orderButton("chevron.up", disabled: index == 0) {
                model.moveJiraPinnedIssue(issue, by: -1)
            }
            orderButton(
                "chevron.down",
                disabled: index == model.jiraState.pinned.issues.count - 1
            ) {
                model.moveJiraPinnedIssue(issue, by: 1)
            }
            Button {
                model.removeJiraPinnedIssue(issue)
            } label: {
                Image(systemName: "xmark").frame(width: 34, height: 34)
            }
            .buttonStyle(NotchButtonStyle())
        }
        .frame(minHeight: 40)
    }

    private func orderButton(
        _ symbol: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 34, height: 34)
        }
        .buttonStyle(NotchButtonStyle())
        .disabled(disabled)
    }

    private func errorText(_ error: JiraAPIError) -> String {
        switch error {
        case .notConfigured: "Сначала подключите Jira"
        case .unauthorized: "Токен Jira недействителен"
        case .forbidden: "Недостаточно прав"
        case .http(404): "Объект не найден"
        case .rateLimited: "Jira временно ограничила запросы"
        default: "Не удалось загрузить данные Jira"
        }
    }
}

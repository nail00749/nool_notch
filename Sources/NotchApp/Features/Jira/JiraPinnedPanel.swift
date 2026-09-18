import SwiftUI

struct JiraPinnedPanel: View {
    @ObservedObject var model: NotchViewModel
    let searchText: String
    let sortOption: JiraIssueSortOption
    let quickFilters: Set<JiraIssueQuickFilter>
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            if sources.isEmpty {
                emptyState
            } else {
                sourceSwitcher
                JiraListContent(
                    model: model,
                    state: selectedListState,
                    searchText: searchText,
                    sortOption: sortOption,
                    quickFilters: quickFilters
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: selectInitialSource)
        .onChange(of: sources) { _, _ in
            selectInitialSource()
        }
    }

    private var sources: [JiraPinnedSourceID] {
        model.jiraState.pinned.availableSources
    }

    private var selectedSource: JiraPinnedSourceID? {
        let selected = model.jiraState.pinned.selectedSource
        return selected.flatMap { sources.contains($0) ? $0 : nil } ?? sources.first
    }

    private var selectedListState: JiraListState {
        guard let selectedSource else { return .idle }
        switch model.jiraState.pinned.sourceStates[selectedSource] ?? .idle {
        case .idle:
            return JiraListState.loading(previous: nil)
        case .loading(let previous):
            return JiraListState.loading(previous: previous)
        case .loaded(let issues, let total):
            return JiraListState.loaded(issues: issues, total: total)
        case .failed(let error, let previous):
            return JiraListState.failed(error: error, previous: previous)
        }
    }

    private var sourceSwitcher: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(sources) { source in
                    let isSelected = source == selectedSource
                    Button {
                        model.selectJiraPinnedSource(source)
                    } label: {
                        Label(sourceTitle(source), systemImage: sourceIcon(source))
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(isSelected ? .white : .white.opacity(0.48))
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .frame(height: 30)
                            .background(
                                isSelected ? Color.white.opacity(0.14) : Color.white.opacity(0.055),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                    }
                    .buttonStyle(NotchButtonStyle())
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 9) {
            Image(systemName: "pin")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.signalMint)
            Text("Нет закреплений")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
            Text("Закрепите доски, проекты или задачи в настройках Jira.")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.42))
                .multilineTextAlignment(.center)
            Button("Открыть настройки", action: onOpenSettings)
                .buttonStyle(NotchButtonStyle())
                .foregroundStyle(Color.signalMint)
                .frame(minHeight: 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func selectInitialSource() {
        guard let selectedSource else { return }
        model.selectJiraPinnedSource(selectedSource)
    }

    private func sourceTitle(_ source: JiraPinnedSourceID) -> String {
        switch source {
        case .issues:
            "Задачи"
        case .container(let id):
            model.jiraState.pinned.containers.first { $0.id == id }?.name ?? "Источник"
        }
    }

    private func sourceIcon(_ source: JiraPinnedSourceID) -> String {
        switch source {
        case .issues:
            return "pin.circle"
        case .container(let id):
            guard let container = model.jiraState.pinned.containers.first(where: { $0.id == id }) else {
                return "pin"
            }
            return container.kind == .board ? "rectangle.split.3x1" : "shippingbox"
        }
    }
}

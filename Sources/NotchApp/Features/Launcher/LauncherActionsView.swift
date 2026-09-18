import SwiftUI

struct LauncherActionsView: View {
    @ObservedObject var model: LauncherModel
    let perform: (LauncherResultAction, LauncherResult) -> Void

    var body: some View {
        if let result = model.actionResult {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Действия").font(.headline)
                        Text(result.title).font(.caption).foregroundStyle(NotchPalette.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button("Esc  Назад", action: model.closeActions).buttonStyle(.plain)
                }.padding(.horizontal, 14).padding(.top, 12)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(Array(model.resultActions(for: result).enumerated()), id: \.element) { index, action in
                                Button { perform(action, result) } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: action.symbol).frame(width: 22)
                                        Text(action.title)
                                        Spacer()
                                        if index == model.selectedActionIndex { Text("↵") }
                                    }
                                    .font(.system(size: 13, weight: .medium))
                                    .padding(.horizontal, 14).frame(minHeight: 38)
                                    .background(index == model.selectedActionIndex ? NotchPalette.raised : .clear,
                                                in: RoundedRectangle(cornerRadius: 9))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(index == model.selectedActionIndex ? [.isSelected] : [])
                                .id(index)
                            }
                        }.padding(10)
                    }
                    .onChange(of: model.selectedActionIndex) { _, index in proxy.scrollTo(index) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

struct LauncherJiraActionView: View {
    @ObservedObject var source: NotchViewModel
    let destination: LauncherJiraDestination
    let close: () -> Void
    @State private var isSubmitting = false

    private var transitionState: JiraTransitionState { source.jiraState.transitionsByIssueKey[destination.issue.key] ?? .idle }
    private var isTransitionSubmitting: Bool {
        if case .submitting = transitionState { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(destination.issue.summary).lineLimit(1)
                Spacer()
                Button("Esc  Назад", action: close).disabled(isSubmitting)
            }.font(.caption).padding(12)
            ScrollView {
                if destination.action == .jiraWorklog {
                    JiraWorklogPopover(model: source, issue: destination.issue, isSubmitting: $isSubmitting, onSuccess: close)
                } else {
                    JiraTransitionPopover(model: source, issue: destination.issue,
                                          state: transitionState,
                                          dismiss: {})
                }
            }
        }
        .task(id: destination.id) {
            if destination.action == .jiraStatus { await source.loadJiraTransitions(for: destination.issue.key) }
        }
        .onChange(of: isTransitionSubmitting) { wasSubmitting, submitting in
            if wasSubmitting, !submitting, case .idle = transitionState { close() }
        }
    }
}

import SwiftUI

struct AISessionsPanel: View {
    @ObservedObject var model: NotchViewModel

    var body: some View {
        VStack(spacing: 7) {
            if let notice = healthNotice {
                HStack(spacing: 6) {
                    Circle()
                        .fill(notice.color)
                        .frame(width: 6, height: 6)
                    Text(notice.message)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.48))
                .padding(.horizontal, 18)
            }

            sessionContent
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    @ViewBuilder
    private var sessionContent: some View {
        if model.aiSessions.isEmpty {
            emptyState
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 10) {
                    ForEach(InboxGroup.allCases) { group in
                        let sessions = group.sessions(from: model.aiSessions)
                        if sessions.isEmpty == false {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 5) {
                                    Text(group.title)
                                    Text("\(sessions.count)")
                                        .monospacedDigit()
                                        .foregroundStyle(group.color)
                                }
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.38))
                                .padding(.horizontal, 4)

                                ForEach(sessions) { session in
                                    AISessionRow(
                                        model: model,
                                        session: session,
                                        sourceName: model.aiSourceName(for: session),
                                        isResponding: model.respondingAISessionIDs.contains(session.id),
                                        responseError: model.aiResponseErrors[session.id],
                                        onOpen: { model.openAISession(session) },
                                        onRespond: { model.respondToAISession(session, response: $0) }
                                    )
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, 4)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Color.signalMint.opacity(0.72))
            Text(emptyTitle)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.8))
            Text("Запусти задачу в подключённом coding agent — она появится здесь автоматически.")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.4))
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 28)
    }

    private var healthNotice: (message: String, color: Color)? {
        let notices = model.aiSourceHealth.compactMap { sourceID, health -> (String, Color)? in
            let sourceName = model.aiSourceNames[sourceID] ?? sourceID
            switch health {
            case .live:
                return nil
            case .stale(let message):
                return ("\(sourceName): \(message ?? "данные могут быть неактуальны")", .signalAmber)
            case .unavailable(let message):
                return ("\(sourceName): \(message ?? "источник недоступен")", .signalCoral)
            }
        }
        if notices.count == 1 { return notices[0] }
        if notices.count > 1 { return ("Некоторые источники агентов недоступны", .signalAmber) }
        return model.aiSourceNames.isEmpty ? ("Нет подключённых источников агентов", .signalCoral) : nil
    }

    private var emptyTitle: String {
        model.aiSourceNames.isEmpty ? "Подключи coding agent" : "Inbox пуст"
    }
}

private enum InboxGroup: CaseIterable, Identifiable {
    case attention
    case active
    case recent

    var id: Self { self }

    var title: String {
        switch self {
        case .attention: "НУЖНО ВНИМАНИЕ"
        case .active: "В РАБОТЕ"
        case .recent: "НЕДАВНИЕ"
        }
    }

    var color: Color {
        switch self {
        case .attention: .signalAmber
        case .active: .signalMint
        case .recent: .white.opacity(0.4)
        }
    }

    func sessions(from sessions: [AISession]) -> [AISession] {
        sessions.filter { session in
            switch self {
            case .attention: session.status.needsAttention
            case .active: session.status == .running
            case .recent: session.status.isActive == false
            }
        }
    }
}

private struct AISessionRow: View {
    @ObservedObject var model: NotchViewModel
    let session: AISession
    let sourceName: String
    let isResponding: Bool
    let responseError: String?
    let onOpen: () -> Void
    let onRespond: (AISessionResponse) -> Void

    @State private var answers: [String: String] = [:]

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 6) {
                Button(action: onOpen) {
                    HStack(spacing: 10) {
                        ZStack {
                            Circle()
                                .fill(statusColor.opacity(0.15))
                                .frame(width: 28, height: 28)
                            Circle()
                                .fill(statusColor)
                                .frame(width: 8, height: 8)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 7) {
                                Text(statusLabel)
                                    .font(.system(size: 9, weight: .bold, design: .rounded))
                                    .foregroundStyle(statusColor)
                                Text(sourceName.uppercased())
                                    .font(.system(size: 7, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.3))
                                if session.isStale {
                                    Text("STALE")
                                        .font(.system(size: 7, weight: .bold, design: .monospaced))
                                        .foregroundStyle(Color.signalAmber.opacity(0.8))
                                }
                            }

                            Text(session.title)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.9))
                                .lineLimit(1)

                            if let jiraTitle = model.linkedJiraIssue(for: session)?.summary {
                                HStack(spacing: 4) {
                                    Image(systemName: "link")
                                        .foregroundStyle(Color.signalCyan.opacity(0.72))
                                    Text(jiraTitle)
                                        .lineLimit(1)
                                }
                                .font(.system(size: 9, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.5))
                            }

                            HStack(spacing: 5) {
                                if let workspace = session.workspaceName {
                                    Image(systemName: "folder")
                                    Text(workspace)
                                }
                                if let modelName = session.modelName, modelName.isEmpty == false {
                                    if session.workspaceName != nil { Text("·") }
                                    Text(modelName)
                                }
                            }
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.36))
                            .lineLimit(1)
                        }
                    }
                    .padding(.leading, 11)
                    .padding(.vertical, 8)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: model.jiraIssueKey(for: session) == nil ? 62 : 108,
                        alignment: .topLeading
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(NotchButtonStyle())
                .accessibilityLabel("\(statusLabel), \(session.title)")
                .accessibilityHint("Открыть сессию в \(sourceName)")

                sessionActivityColumn

                if let issueKey = model.jiraIssueKey(for: session) {
                    AISessionJiraAccessory(
                        model: model,
                        session: session,
                        issueKey: issueKey
                    )
                }
            }
            .padding(.trailing, 7)

            if let request = session.attentionRequest {
                Divider()
                    .overlay(.white.opacity(0.06))
                    .padding(.horizontal, 10)
                attentionControls(request)
                    .padding(8)
            } else if session.status.needsAttention {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.forward.app")
                    Text("Открой \(sourceName), чтобы ответить")
                    Spacer(minLength: 0)
                }
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.38))
                .padding(.horizontal, 11)
                .padding(.bottom, 9)
            }

            if let responseError {
                Text(responseError)
                    .font(.system(size: 8, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.signalCoral)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 11)
                    .padding(.bottom, 8)
            }

        }
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 15))
    }

    private var sessionActivityColumn: some View {
        VStack(spacing: 3) {
            HStack(spacing: 3) {
                Text(codeReviewLabel)
                    .font(.system(size: 7, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.3))
                Spacer(minLength: 2)
                Text(session.lastActivity, style: .relative)
                    .font(.system(size: 8, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.34))
            }

            if showsCodeReviewAccessory {
                AISessionCodeReviewAccessory(
                    state: model.codeReviewState(for: session),
                    newActivityCount: model.newReviewActivityCount(for: session),
                    onOpen: { request in model.openCodeReview(request, for: session) }
                )
            }
        }
        .padding(4)
        .frame(width: 118, alignment: .top)
        .frame(minHeight: 60, alignment: .top)
        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.white.opacity(0.055), lineWidth: 1)
        }
        .padding(.vertical, 6)
    }

    private var codeReviewLabel: String {
        switch model.codeReviewState(for: session).snapshot?.request?.provider {
        case .github: "GITHUB"
        case .gitlab: "GITLAB"
        case nil: "GIT"
        }
    }

    private var showsCodeReviewAccessory: Bool {
        guard session.workspacePath?.isEmpty == false else { return false }
        if case .idle = model.codeReviewState(for: session) { return false }
        return true
    }

    @ViewBuilder
    private func attentionControls(_ request: AISessionAttentionRequest) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: request.kind == .approval ? "lock.shield" : "text.bubble")
                    .foregroundStyle(statusColor)
                Text(request.title)
                    .lineLimit(1)
                if isResponding {
                    Spacer(minLength: 4)
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white.opacity(0.7))
                }
            }
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(.white.opacity(0.82))

            if let detail = request.detail, detail.isEmpty == false {
                Text(detail)
                    .font(.system(size: 9, weight: .medium, design: request.kind == .approval ? .monospaced : .rounded))
                    .foregroundStyle(.white.opacity(0.58))
                    .lineLimit(3)
                    .textSelection(.enabled)
            }

            if let context = request.context, context.isEmpty == false {
                Label(URL(fileURLWithPath: context).lastPathComponent, systemImage: "folder")
                    .font(.system(size: 8, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.32))
            }

            switch request.kind {
            case .approval:
                approvalButtons(request)
            case .input:
                inputControls(request)
            }
        }
        .padding(8)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
    }

    private func approvalButtons(_ request: AISessionAttentionRequest) -> some View {
        HStack(spacing: 6) {
            ActionButton(title: "Отклонить", color: .signalCoral, disabled: isResponding) {
                onRespond(.deny)
            }
            ActionButton(title: "Разрешить", color: .signalMint, disabled: isResponding) {
                onRespond(.approveOnce)
            }
            if request.supportsSessionApproval {
                ActionButton(title: "На сессию", color: .signalCyan, disabled: isResponding) {
                    onRespond(.approveForSession)
                }
            }
        }
    }

    private func inputControls(_ request: AISessionAttentionRequest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(request.questions) { question in
                VStack(alignment: .leading, spacing: 5) {
                    if request.questions.count > 1 {
                        Text(question.prompt)
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.52))
                    }

                    if question.options.isEmpty == false {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 5) {
                                ForEach(question.options, id: \.self) { option in
                                    Button(option) { answers[question.id] = option }
                                        .buttonStyle(AnswerOptionStyle(isSelected: answers[question.id] == option))
                                }
                            }
                        }
                    }

                    if question.allowsFreeform || question.options.isEmpty {
                        TextField(
                            question.title,
                            text: Binding(
                                get: { answers[question.id, default: ""] },
                                set: { answers[question.id] = $0 }
                            )
                        )
                        .textFieldStyle(.plain)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.86))
                        .padding(.horizontal, 9)
                        .frame(minHeight: 34)
                        .background(.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))
                        .onSubmit { submitAnswers(request) }
                    }
                }
            }

            ActionButton(
                title: "Ответить",
                color: .signalMint,
                disabled: isResponding || hasAllAnswers(request) == false
            ) {
                submitAnswers(request)
            }
        }
    }

    private func submitAnswers(_ request: AISessionAttentionRequest) {
        guard hasAllAnswers(request) else { return }
        onRespond(.answers(answers))
    }

    private func hasAllAnswers(_ request: AISessionAttentionRequest) -> Bool {
        request.questions.allSatisfy {
            answers[$0.id]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
    }

    private var statusLabel: String {
        switch session.status {
        case .running: "Работает"
        case .waitingForApproval: "Ждёт подтверждения"
        case .waitingForInput: "Ждёт ответа"
        case .completed: "Готово"
        case .failed: "Ошибка"
        case .unknown: "Неизвестно"
        }
    }

    private var statusColor: Color {
        switch session.status {
        case .running: .signalMint
        case .waitingForApproval: .signalAmber
        case .waitingForInput: .signalCyan
        case .completed: .white.opacity(0.42)
        case .failed: .signalCoral
        case .unknown: .white.opacity(0.28)
        }
    }
}

private struct AISessionCodeReviewAccessory: View {
    let state: CodeReviewLoadState
    let newActivityCount: Int
    let onOpen: (CodeReviewRequest) -> Void

    @ViewBuilder
    var body: some View {
        if let request = state.snapshot?.request {
            HStack(spacing: 2) {
                statusIcon(
                    ciIcon(request.ciState),
                    color: ciColor(request.ciState),
                    help: ciHelp(request)
                )
                statusIcon(
                    mergeIcon(request.mergeState),
                    color: mergeColor(request.mergeState),
                    help: mergeHelp(request.mergeState)
                )
                statusIcon(
                    "text.bubble",
                    color: newActivityCount > 0 ? .signalAmber : .white.opacity(0.38),
                    help: newActivityCount > 0
                        ? "Новая reviewer activity"
                        : "Нет новой reviewer activity",
                    showsBadge: newActivityCount > 0
                )
                actionButton(
                    "arrow.up.right.square",
                    help: request.provider == .github ? "Открыть PR" : "Открыть MR"
                ) {
                    onOpen(request)
                }
            }
        } else {
            switch state {
            case .idle:
                EmptyView()
            case .loading:
                ProgressView()
                    .controlSize(.mini)
                    .tint(.white.opacity(0.46))
                    .frame(width: 40, height: 40)
                    .accessibilityLabel("Загружаю PR или MR")
            case .loaded(let snapshot):
                statusIcon(
                    "arrow.triangle.branch",
                    color: .white.opacity(0.3),
                    help: "Для ветки \(snapshot.repository.branch) нет открытого PR или MR"
                )
                .frame(width: 40, height: 40)
            case .failed(let error, _):
                statusIcon(
                    "exclamationmark.circle",
                    color: .signalAmber,
                    help: error.userMessage
                )
                .frame(width: 40, height: 40)
            }
        }
    }

    private func statusIcon(
        _ name: String,
        color: Color,
        help: String,
        showsBadge: Bool = false
    ) -> some View {
        Image(systemName: name)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 22, height: 22)
            .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if showsBadge {
                    Circle()
                        .fill(Color.signalAmber)
                        .frame(width: 5, height: 5)
                }
            }
            .help(help)
            .accessibilityLabel(help)
    }

    private func actionButton(
        _ name: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.7))
                .frame(width: 26, height: 26)
                .background(
                    Color.white.opacity(0.065),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(NotchButtonStyle())
        .help(help)
        .accessibilityLabel(help)
    }

    private func ciIcon(_ state: CodeCICheckState) -> String {
        switch state {
        case .none: "minus.circle"
        case .pending: "clock"
        case .passed: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        }
    }

    private func ciColor(_ state: CodeCICheckState) -> Color {
        switch state {
        case .none: .white.opacity(0.32)
        case .pending: .signalAmber
        case .passed: .signalMint
        case .failed: .signalCoral
        }
    }

    private func ciHelp(_ request: CodeReviewRequest) -> String {
        switch request.ciState {
        case .none: "Нет CI"
        case .pending: "CI выполняется"
        case .passed: "CI пройден"
        case .failed: "CI упал"
        }
    }

    private func mergeIcon(_ state: CodeMergeState) -> String {
        switch state {
        case .unknown: "questionmark.circle"
        case .ready: "arrow.triangle.merge"
        case .conflicting: "exclamationmark.triangle.fill"
        }
    }

    private func mergeColor(_ state: CodeMergeState) -> Color {
        switch state {
        case .unknown: .white.opacity(0.32)
        case .ready: .signalMint
        case .conflicting: .signalCoral
        }
    }

    private func mergeHelp(_ state: CodeMergeState) -> String {
        switch state {
        case .unknown: "Статус конфликтов неизвестен"
        case .ready: "Без конфликтов"
        case .conflicting: "Есть конфликты"
        }
    }
}

private struct AISessionJiraAccessory: View {
    @ObservedObject var model: NotchViewModel
    let session: AISession
    let issueKey: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isShowingTransitions = false
    @State private var isShowingAssignee = false
    @State private var isShowingWorklog = false
    @State private var isSubmittingWorklog = false
    @State private var didAddWorklog = false

    private var issue: JiraIssue? {
        model.linkedJiraIssue(for: session)
    }

    private var transitionState: JiraTransitionState {
        model.jiraState.transitionsByIssueKey[issueKey] ?? .idle
    }

    private var assigneeState: JiraAssigneeState {
        model.jiraState.assigneesByIssueKey[issueKey] ?? .idle
    }

    private var suggestedWorklog: JiraWorklogDraft? {
        AISessionJiraLink.suggestedWorklog(for: session)
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
        VStack(spacing: 4) {
            HStack(spacing: 3) {
                Text("JIRA")
                    .foregroundStyle(.white.opacity(0.3))
                Text(issueKey)
                    .fontDesign(.monospaced)
                    .foregroundStyle(Color.signalCyan)
                    .lineLimit(1)
                Spacer(minLength: 1)
                if let issue {
                    Circle()
                        .fill(JiraStatusVisuals.color(for: issue.status))
                        .frame(width: 5, height: 5)
                        .help(issue.status.name)
                        .accessibilityLabel("Статус Jira: \(issue.status.name)")
                }
            }
            .font(.system(size: 7, weight: .bold, design: .rounded))
            .frame(width: 82)

            jiraContent
        }
        .padding(5)
        .frame(width: 94, alignment: .top)
        .frame(minHeight: 108, alignment: .top)
        .background(
            LinearGradient(
                colors: [Color.signalCyan.opacity(0.09), Color.white.opacity(0.03)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.signalCyan.opacity(0.13), lineWidth: 1)
        }
        .padding(.vertical, 6)
        .help(issue?.summary ?? "Jira \(issueKey)")
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.18),
            value: issue?.id
        )
        .onChange(of: model.transientSurfaceDismissalRequest) { _, _ in
            isShowingTransitions = false
            isShowingAssignee = false
            worklogPresentation.wrappedValue = false
        }
    }

    @ViewBuilder
    private var jiraContent: some View {
        if let issue {
            LazyVGrid(
                columns: [GridItem(.fixed(40)), GridItem(.fixed(40))],
                spacing: 2
            ) {
                jiraActionButton(
                    title: "Jira",
                    icon: "arrow.up.forward.app",
                    tint: .signalCyan,
                    help: "Открыть \(issue.key)"
                ) {
                    model.openJiraIssue(issue)
                }

                jiraActionButton(
                    title: "Статус",
                    icon: "arrow.triangle.2.circlepath",
                    tint: JiraStatusVisuals.color(for: issue.status),
                    help: "Изменить статус"
                ) {
                    model.transientSurfaceDidPresent(.jiraTransitions(issue.key))
                    isShowingTransitions = true
                    Task { await model.loadJiraTransitions(for: issue.key) }
                }
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

                jiraActionButton(
                    title: "Исп.",
                    icon: "person.crop.circle",
                    tint: .white.opacity(0.64),
                    help: "Изменить исполнителя"
                ) {
                    model.transientSurfaceDidPresent(.jiraAssignee(issue.key))
                    isShowingAssignee = true
                }
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

                if session.status == .completed, let suggestedWorklog {
                    worklogButton(issue: issue, draft: suggestedWorklog)
                }
            }
        } else if model.isLinkedJiraIssueLoading(for: session) {
            ProgressView()
                .controlSize(.mini)
                .tint(.white.opacity(0.46))
                .frame(width: 82, height: 82)
                .accessibilityLabel("Загружаю задачу Jira")
        } else if let error = model.linkedJiraError(for: session) {
            Button { model.retryLinkedJiraIssue(for: session) } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.signalAmber)
                    .frame(width: 28, height: 28)
                    .background(Color.signalAmber.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(NotchButtonStyle())
            .help(error == .notConfigured ? "Подключи Jira в настройках" : error.safeRussianMessage)
            .accessibilityLabel("Повторить загрузку Jira")
            .frame(width: 82, height: 82)
        }
    }

    private func worklogButton(
        issue: JiraIssue,
        draft: JiraWorklogDraft
    ) -> some View {
        Button {
            model.transientSurfaceDidPresent(.jiraWorklog(issue.key))
            isShowingWorklog = true
        } label: {
            JiraWorklogIcon(size: 10)
                .foregroundStyle(didAddWorklog ? Color.signalMint : Color.black.opacity(0.82))
                .frame(width: 28, height: 28)
            .background(
                didAddWorklog ? Color.signalMint.opacity(0.12) : Color.signalMint,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .frame(width: 40, height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(NotchButtonStyle())
        .disabled(isSubmittingWorklog || didAddWorklog)
        .help(didAddWorklog ? "Worklog добавлен" : "Добавить worklog")
        .accessibilityLabel(didAddWorklog ? "Worklog добавлен" : "Добавить worklog")
        .popover(isPresented: worklogPresentation, arrowEdge: .bottom) {
            JiraWorklogPopover(
                model: model,
                issue: issue,
                isSubmitting: $isSubmittingWorklog,
                initialDraft: draft
            ) {
                isSubmittingWorklog = false
                worklogPresentation.wrappedValue = false
                didAddWorklog = true
            }
            .onDisappear {
                model.transientSurfaceDidDisappear(.jiraWorklog(issue.key))
            }
        }
    }

    private func jiraActionButton(
        title: String,
        icon: String,
        tint: Color,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                .frame(width: 40, height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(NotchButtonStyle())
        .help(help)
        .accessibilityLabel(title)
    }
}

private struct ActionButton: View {
    let title: String
    let color: Color
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(disabled ? .white.opacity(0.28) : color)
                .frame(maxWidth: .infinity, minHeight: 34)
                .background(color.opacity(disabled ? 0.04 : 0.12), in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(NotchButtonStyle())
        .disabled(disabled)
    }
}

private struct AnswerOptionStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .foregroundStyle(isSelected ? Color.black : Color.white.opacity(0.58))
            .padding(.horizontal, 9)
            .frame(minHeight: 30)
            .background(
                isSelected ? Color.signalCyan : Color.white.opacity(configuration.isPressed ? 0.1 : 0.055),
                in: Capsule()
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

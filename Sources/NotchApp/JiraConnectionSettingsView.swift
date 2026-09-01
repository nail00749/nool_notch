import SwiftUI

struct JiraConnectionSettingsView: View {
    @ObservedObject var model: NotchViewModel

    @State private var baseURLText: String
    @State private var token = ""
    @State private var validation: ValidationResult?
    @State private var isBusy = false
    @State private var validatedDraft: ValidatedDraft?
    @FocusState private var focusedField: CredentialField?

    init(model: NotchViewModel) {
        self.model = model
        _baseURLText = State(initialValue: model.configuredJiraBaseURLString ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Base URL")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.62))
                credentialFieldSurface(field: .baseURL) {
                    Image(systemName: "link")
                        .foregroundStyle(.white.opacity(0.42))
                        .frame(width: 16)
                    TextField("https://jira.example.com", text: $baseURLText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .focused($focusedField, equals: .baseURL)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Personal Access Token")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.62))
                credentialFieldSurface(field: .token) {
                    Image(systemName: "key.fill")
                        .foregroundStyle(.white.opacity(0.42))
                        .frame(width: 16)
                    SecureField("PAT", text: $token)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .focused($focusedField, equals: .token)
                }
            }

            if let statusText {
                HStack(alignment: .top, spacing: 7) {
                    if isBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Circle()
                            .fill(statusIsHealthy ? Color.signalMint : Color.signalAmber)
                            .frame(width: 6, height: 6)
                            .padding(.top, 3)
                    }
                    Text(statusText)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.58))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 7) {
                actionButton(title: "Проверить", icon: "checkmark.shield") {
                    checkConnection()
                }
                .disabled(isBusy || hasDraft == false)

                actionButton(title: "Сохранить", icon: "key.fill", isAccent: canSave) {
                    saveConnection()
                }
                .disabled(isBusy || canSave == false)

                if isConfigured {
                    actionButton(
                        title: "Отключить",
                        icon: "xmark.circle",
                        isDestructive: true,
                        action: disconnect
                    )
                    .disabled(
                        JiraConnectionInteractionPolicy.canDisconnect(
                            isConfigured: isConfigured,
                            isBusy: isBusy
                        ) == false
                    )
                }
            }
        }
        .onChange(of: baseURLText) { _, _ in invalidateValidatedDraft() }
        .onChange(of: token) { _, _ in invalidateValidatedDraft() }
    }

    private var hasDraft: Bool {
        baseURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            && token.isEmpty == false
    }

    private var canSave: Bool {
        validatedDraft == ValidatedDraft(baseURLText: baseURLText, token: token)
    }

    private var isConfigured: Bool {
        model.configuredJiraBaseURLString != nil
    }

    private var statusText: String? {
        if isBusy { return "Проверяю подключение…" }
        if let validation {
            switch validation {
            case .success(let displayName):
                return "Подключение подтверждено: \(displayName)"
            case .failure(let error):
                return error.safeRussianMessage
            }
        }

        switch model.jiraState.connection {
        case .notConfigured:
            return "Введите оба значения, нажмите «Проверить», затем «Сохранить»."
        case .ready:
            return "Подключение сохранено. Для изменения введите новый PAT."
        case .validating:
            return "Проверяю подключение…"
        case .validated(let user), .connected(let user):
            return "Подключено: \(user.displayName)"
        case .failed(let error):
            return error.safeRussianMessage
        }
    }

    private var statusIsHealthy: Bool {
        if case .success = validation { return true }
        return switch model.jiraState.connection {
        case .ready, .validated, .connected:
            true
        default:
            false
        }
    }

    private func checkConnection() {
        let draft = ValidatedDraft(baseURLText: baseURLText, token: token)
        isBusy = true
        validation = nil
        validatedDraft = nil

        Task {
            let result = await model.checkJiraConnection(
                baseURLText: draft.baseURLText,
                token: draft.token
            )
            isBusy = false
            guard JiraConnectionResultAcceptancePolicy.shouldAccept(
                submittedDraft: draft,
                currentDraft: ValidatedDraft(baseURLText: baseURLText, token: token)
            ) else {
                return
            }
            switch result {
            case .success(let user):
                validatedDraft = draft
                validation = .success(user.displayName)
            case .failure(let error):
                validation = .failure(error)
            }
        }
    }

    private func saveConnection() {
        guard let draft = validatedDraft,
              draft == ValidatedDraft(baseURLText: baseURLText, token: token) else { return }
        isBusy = true

        Task {
            let result = await model.connectJira(
                baseURLText: draft.baseURLText,
                token: draft.token
            )
            isBusy = false
            switch result {
            case .success(let user):
                token = ""
                validatedDraft = nil
                validation = .success(user.displayName)
            case .failure(let error):
                validatedDraft = nil
                validation = .failure(error)
            }
        }
    }

    private func disconnect() {
        model.disconnectJira()
        baseURLText = ""
        token = ""
        validation = nil
        validatedDraft = nil
        isBusy = false
    }

    private func invalidateValidatedDraft() {
        validatedDraft = nil
        if validation != nil {
            validation = nil
        }
    }

    private func actionButton(
        title: String,
        icon: String,
        isAccent: Bool = false,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(
                    isDestructive
                        ? Color.signalCoral
                        : (isAccent ? Color.signalMint : .white.opacity(0.72))
                )
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(
                    Color.white.opacity(0.09),
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                )
        }
        .buttonStyle(NotchButtonStyle())
    }

    private func credentialFieldSurface<Content: View>(
        field: CredentialField,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let isFocused = focusedField == field
        return HStack(spacing: 9) {
            content()
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(
            Color.white.opacity(isFocused ? 0.11 : 0.075),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    isFocused ? Color.signalMint.opacity(0.82) : .white.opacity(0.13),
                    lineWidth: isFocused ? 1.5 : 1
                )
        }
        .shadow(
            color: isFocused ? Color.signalMint.opacity(0.13) : .clear,
            radius: 8
        )
        .animation(.easeOut(duration: 0.14), value: isFocused)
    }
}

private enum CredentialField: Hashable {
    case baseURL
    case token
}

enum JiraConnectionInteractionPolicy {
    static func canDisconnect(isConfigured: Bool, isBusy: Bool) -> Bool {
        isConfigured && isBusy == false
    }
}

enum JiraConnectionResultAcceptancePolicy {
    static func shouldAccept<Draft: Equatable>(
        submittedDraft: Draft,
        currentDraft: Draft
    ) -> Bool {
        submittedDraft == currentDraft
    }
}

private struct ValidatedDraft: Equatable {
    let baseURLText: String
    let token: String
}

private enum ValidationResult {
    case success(String)
    case failure(JiraAPIError)
}

import SwiftUI

struct AISessionsPanel: View {
    @ObservedObject var model: NotchViewModel

    var body: some View {
        VStack(spacing: 6) {
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

            if model.aiSessions.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "terminal")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(Color.signalMint.opacity(0.72))
                    Text(emptyTitle)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.8))
                    Text(emptyMessage)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.4))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 28)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 6) {
                        ForEach(model.aiSessions) { session in
                            AISessionRow(session: session) {
                                model.openAISession(session)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 4)
                }
            }
        }
    }

    private var healthNotice: (message: String, color: Color)? {
        guard let health = model.aiSourceHealth[CodexStateReader.sourceID] else {
            return ("Ищу сессии Codex…", .signalCyan)
        }
        switch health {
        case .live:
            return nil
        case .stale(let message):
            return (message ?? "Данные могут быть неактуальны", .signalAmber)
        case .unavailable(let message):
            return (message ?? "Codex Desktop недоступен", .signalCoral)
        }
    }

    private var emptyTitle: String {
        guard let health = model.aiSourceHealth[CodexStateReader.sourceID] else {
            return "Подключаю Codex"
        }
        if case .unavailable = health { return "Сессии недоступны" }
        return "Нет недавних сессий"
    }

    private var emptyMessage: String {
        "Запусти task в Codex Desktop — он появится здесь автоматически."
    }
}

private struct AISessionRow: View {
    let session: AISession
    let onOpen: () -> Void

    var body: some View {
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
                        if session.isStale {
                            Text("STALE")
                                .font(.system(size: 7, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color.signalAmber.opacity(0.8))
                        }
                        Spacer(minLength: 4)
                        Text(session.lastActivity, style: .relative)
                            .font(.system(size: 8, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.3))
                    }

                    Text(session.title)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)

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

                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.28))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 13))
            .contentShape(RoundedRectangle(cornerRadius: 13))
        }
        .buttonStyle(NotchButtonStyle())
        .accessibilityLabel("\(statusLabel), \(session.title)")
        .accessibilityHint("Открыть сессию в Codex")
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

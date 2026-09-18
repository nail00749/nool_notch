import AppKit
import SwiftUI

struct LauncherQuickAIButton: View {
    @ObservedObject var model: LauncherModel
    @ObservedObject var store: AIChatStore

    var body: some View {
        Button(action: model.askAI) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                VStack(alignment: .leading, spacing: 1) {
                    Text("Спросить AI").font(.system(size: 11, weight: .semibold))
                    Text(store.selectedProvider.title).font(.system(size: 9))
                        .foregroundStyle(NotchPalette.secondary)
                }
                Text("⌥↵").font(.system(size: 11, design: .monospaced))
            }
            .foregroundStyle(NotchPalette.accent)
            .padding(.horizontal, 10).frame(height: 40)
            .background(NotchPalette.raised, in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .disabled(!model.canAskAI || store.isStreaming || store.isImportingAttachments)
        .opacity(model.canAskAI && !store.isStreaming && !store.isImportingAttachments ? 1 : 0.45)
        .help("Отправить текст строки поиска в новый чат с \(store.selectedProvider.title) — ⌥Enter")
        .accessibilityLabel("Спросить AI: \(store.selectedProvider.title)")
    }
}

struct LauncherQuickAIView: View {
    @ObservedObject var model: LauncherModel
    @ObservedObject var store: AIChatStore
    let openSettings: () -> Void

    private var ownsConversation: Bool {
        guard let id = model.quickAIConversationID else { return false }
        return store.activeConversationID == id
    }

    private var answer: AIChatMessage? {
        ownsConversation ? store.messages.last(where: { $0.role == .assistant }) : nil
    }

    private var error: String? {
        model.quickAIError ?? (ownsConversation ? store.errorMessage : nil)
    }

    private var isWorking: Bool {
        model.isPreparingQuickAI || (ownsConversation && store.isStreaming)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(NotchPalette.accent)
                Text(store.selectedProvider.title).font(.system(size: 12, weight: .semibold))
                if let title = store.selectedModels.first(where: { $0.id == store.selectedModelID })?.title {
                    Text(title).font(.system(size: 10)).foregroundStyle(NotchPalette.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if isWorking {
                    Button("Остановить", action: model.stopQuickAI)
                        .accessibilityLabel("Остановить быстрый ответ AI")
                } else if let answer, !answer.text.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(answer.text, forType: .string)
                    } label: { Label("Копировать", systemImage: "doc.on.doc") }
                    .accessibilityLabel("Копировать быстрый ответ AI")
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .frame(minHeight: 40)
            .padding(.horizontal, 24)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(model.quickAIQuestion)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(NotchPalette.secondary)
                        .textSelection(.enabled)
                    if let answer, !answer.text.isEmpty {
                        Text(answer.text)
                            .font(.system(size: 14))
                            .lineSpacing(5)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if isWorking {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(model.isPreparingQuickAI ? "Проверяю подключение…" : "AI отвечает…")
                                .font(.system(size: 12)).foregroundStyle(NotchPalette.secondary)
                        }
                    } else if answer?.state == .interrupted {
                        Text("Ответ остановлен").font(.system(size: 11)).foregroundStyle(NotchPalette.secondary)
                    }
                    if let error {
                        Text(error).font(.system(size: 12)).foregroundStyle(Color.signalAmber)
                        HStack(spacing: 16) {
                            Button("Открыть AI") { model.category = .ai }
                            Button("Настройки подключений", action: openSettings)
                        }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(NotchPalette.accent)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

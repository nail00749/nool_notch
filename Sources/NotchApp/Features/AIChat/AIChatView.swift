import AppKit
import SwiftUI

struct AIChatView: View {
    @ObservedObject var store: AIChatStore
    @ObservedObject var selection: LauncherTextSelection
    let close: () -> Void
    let cycle: (Bool) -> Void
    let focusComposer: () -> Void
    let openSettings: () -> Void
    let requestSelectionAccess: () -> Void
    let pasteResponse: (String) -> Void
    let chooseAttachments: () -> Void
    @State private var showsHistory = false
    @State private var dropTargeted = false
    @State private var composerHeight: CGFloat = 52
    @State private var composerFocused = false

    private var modelTitle: String {
        store.selectedModels.first { $0.id == store.selectedModelID }?.title ?? "Выбрать модель"
    }
    private var unavailable: Bool { store.selectedStatus?.isAvailable == false }
    private var checking: Bool { store.checking.contains(store.selectedProvider) }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if showsHistory {
                AIChatHistoryView(store: store) { _ in
                    showsHistory = false
                    focusComposer()
                }
            } else if store.messages.isEmpty {
                GeometryReader { geometry in
                    ScrollView {
                        Group {
                            if store.draftAttachments.isEmpty { welcome }
                            else {
                                VStack(spacing: 5) {
                                    Text("Материалы добавлены").font(.system(size: 15, weight: .medium))
                                    Text("Добавьте вопрос или отправьте вложения для разбора.")
                                        .font(.system(size: 11)).foregroundStyle(NotchPalette.secondary)
                                }.padding(12)
                            }
                        }.frame(maxWidth: .infinity)
                            .frame(minHeight: geometry.size.height)
                    }
                }
            } else {
                transcript
            }
            if !showsHistory, let error = store.errorMessage {
                notice(error, isError: true)
            } else if !showsHistory, let error = store.historyError {
                notice(error, isError: true)
            } else if !showsHistory, let issue = store.attachmentIssue {
                notice(issue, isError: false)
            } else if !showsHistory && unavailable && !store.messages.isEmpty {
                notice(store.selectedStatus?.message ?? "Подключение недоступно.", isError: false)
            }
            if !showsHistory { composer }
        }
        .onAppear { store.refreshAvailability(); focusComposer() }
        .dropDestination(for: URL.self) { urls, _ in
            guard !store.isStreaming, !store.isImportingAttachments, !urls.isEmpty else { return false }
            showsHistory = false
            store.importAttachments(urls)
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 16).strokeBorder(NotchPalette.accent, style: StrokeStyle(lineWidth: 2, dash: [7]))
                    .background(NotchPalette.accent.opacity(0.08)).allowsHitTesting(false)
            }
        }
        .onChange(of: showsHistory) { _, visible in
            if !visible {
                Task { @MainActor in
                    await Task.yield()
                    focusComposer()
                }
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(AIChatProviderID.allCases) { provider in
                    Button {
                        store.selectProvider(provider)
                        focusComposer()
                    } label: {
                        if store.selectedProvider == provider {
                            Label(provider.title, systemImage: "checkmark")
                        } else {
                            Text(provider.title)
                        }
                    }
                }
                Divider()
                Button("Настройки подключений", action: openSettings)
            } label: {
                HStack(spacing: 8) {
                    AIChatProviderIcon(provider: store.selectedProvider, size: 18)
                    Text(store.selectedProvider.chatTitle).font(.system(size: 12, weight: .medium))
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(NotchPalette.secondary)
                }
                .padding(.horizontal, 11).frame(height: 36)
                .background(NotchPalette.text.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .padding(.horizontal, 9).frame(height: 36)
            .background(NotchPalette.text.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityLabel("Провайдер: \(store.selectedProvider.title)")
            .help("Выбрать провайдера. Смена начнёт новый чат.")

            if !store.selectedModels.isEmpty && (store.selectedProvider != .apple || store.selectedModels.count > 1) {
                Menu {
                    ForEach(store.selectedModels) { model in
                        Button {
                            store.selectModel(model.id)
                            focusComposer()
                        } label: {
                            if store.selectedModelID == model.id {
                                Label(model.title + (model.supportsImages ? " · Фото" : ""), systemImage: "checkmark")
                            } else {
                                Text(model.title + (model.supportsImages ? " · Фото" : ""))
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(modelTitle).font(.system(size: 11)).lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                    }
                    .foregroundStyle(NotchPalette.text.opacity(0.6))
                    .padding(.horizontal, 8).frame(height: 36)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .frame(maxWidth: 205, alignment: .leading)
                .accessibilityLabel("Модель: \(modelTitle)")
                .help("Выбрать модель. Смена начнёт новый чат.")
            }
            if checking { ProgressView().controlSize(.mini).padding(.leading, 2) }
            Spacer(minLength: 4)
            selectionMenu
            Button { showsHistory.toggle() } label: {
                Image(systemName: showsHistory ? "bubble.left" : "clock.arrow.circlepath").frame(width: 40, height: 40)
            }
            .buttonStyle(AIChatQuietButtonStyle()).help(showsHistory ? "Вернуться в чат" : "История чатов")
            .accessibilityLabel(showsHistory ? "Вернуться в чат" : "История чатов")
            Button {
                store.newChat()
                showsHistory = false
                focusComposer()
            } label: {
                Image(systemName: "square.and.pencil").font(.system(size: 15, weight: .regular))
                    .frame(width: 40, height: 40).contentShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(AIChatQuietButtonStyle()).help("Новый чат")
            .accessibilityLabel("Новый чат")
        }
        .padding(.horizontal, 18).padding(.vertical, 5)
    }

    private var selectionMenu: some View {
        Menu {
            if let text = selection.text {
                Text(String(text.prefix(80))).lineLimit(2)
                Divider()
                ForEach(LauncherTextAction.allCases) { action in
                    Button(action.title) {
                        store.newChat()
                        showsHistory = false
                        store.draft = action.prompt(text)
                        focusComposer()
                    }.disabled(store.isStreaming)
                }
            } else {
                Text(selection.isReading ? "Читаю выделение…" : selection.message)
                if selection.needsPermission {
                    Button("Разрешить доступ к выделению", action: requestSelectionAccess)
                }
            }
        } label: {
            Image(systemName: "text.cursor")
                .foregroundStyle(selection.text == nil ? NotchPalette.secondary : NotchPalette.accent)
                .frame(width: 36, height: 40)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("AI-действия над выделенным текстом")
        .accessibilityLabel("Действия над выделением")
    }

    private var welcome: some View {
        VStack(spacing: 11) {
            AIChatProviderIcon(provider: store.selectedProvider, size: 24)
                .frame(width: 46, height: 46)
                .background(NotchPalette.text.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(NotchPalette.text.opacity(0.07)))
            VStack(spacing: 6) {
                Text(unavailable ? "Подключите модель" : "С чего начнём?")
                    .font(.system(size: 21, weight: .medium, design: .rounded))
                    .foregroundStyle(NotchPalette.text.opacity(0.92))
                Text(unavailable ? (store.selectedStatus?.message ?? "") :
                        "Задайте вопрос, разберите идею или поработайте с текстом.")
                    .font(.system(size: 12)).foregroundStyle(NotchPalette.secondary)
                    .multilineTextAlignment(.center).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 395)
            }
            if unavailable {
                HStack(spacing: 8) {
                    Button("Открыть настройки", action: openSettings)
                        .buttonStyle(AIChatSuggestionStyle())
                    Button(action: store.refreshAvailability) {
                        Image(systemName: "arrow.clockwise").frame(width: 40, height: 40)
                    }
                    .buttonStyle(AIChatQuietButtonStyle()).help("Проверить подключение")
                    .accessibilityLabel("Проверить подключение")
                }
            } else if store.draft.isEmpty {
                HStack(spacing: 8) {
                    suggestion("Разобрать идею", icon: "lightbulb",
                               draft: "Помоги разобрать идею: ")
                    suggestion("Улучшить текст", icon: "text.alignleft",
                               draft: "Помоги улучшить этот текст: ")
                }
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 14)
    }

    private func suggestion(_ title: String, icon: String, draft: String) -> some View {
        Button {
            store.draft = draft
            focusComposer()
        } label: {
            Label(title, systemImage: icon).font(.system(size: 11, weight: .medium))
        }
        .buttonStyle(AIChatSuggestionStyle())
        .disabled(!store.draft.isEmpty || store.isStreaming)
        .help("Добавить начало сообщения")
    }

    private var transcript: some View {
        GeometryReader { geometry in
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(store.messages) { message in
                        AIChatMessageRow(message: message, provider: store.selectedProvider,
                                         paste: selection.text == nil ? nil : pasteResponse).id(message.id)
                    }
                    Color.clear.frame(height: 1).id("chat-bottom")
                }
                .frame(width: max(0, geometry.size.width - 44), alignment: .leading)
                .padding(.horizontal, 22).padding(.top, 12).padding(.bottom, 10)
            }
            .onChange(of: store.messages.last?.text) { _, _ in proxy.scrollTo("chat-bottom", anchor: .bottom) }
            .onChange(of: store.messages.count) { _, _ in proxy.scrollTo("chat-bottom", anchor: .bottom) }
            .onAppear { proxy.scrollTo("chat-bottom", anchor: .bottom) }
        }
        }
    }

    private func notice(_ message: String, isError: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: isError ? "exclamationmark.circle" : "info.circle")
                .font(.system(size: 12)).padding(.top, 1)
            Text(message).font(.system(size: 11)).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(isError ? Color.signalCoral : NotchPalette.text.opacity(0.6))
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background((isError ? Color.signalCoral : NotchPalette.text).opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 18).padding(.bottom, 8)
    }

    private var composer: some View {
        VStack(spacing: 8) {
            VStack(spacing: 0) {
                if !store.draftAttachments.isEmpty {
                    AIChatAttachmentStrip(attachments: store.draftAttachments, remove: store.removeAttachment)
                        .padding(.horizontal, 10).padding(.top, 8)
                }
                composerInput
                composerActions
            }
            .background {
                RoundedRectangle(cornerRadius: 16).fill(NotchPalette.raised.opacity(composerFocused ? 1 : 0.7))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(composerFocused ? NotchPalette.accent.opacity(0.32) : NotchPalette.text.opacity(0.1))
            }
            .shadow(color: Color.black.opacity(0.12), radius: 10, y: 4)
            privacyFooter
        }
        .padding(.horizontal, 18).padding(.top, 4).padding(.bottom, 12)
    }

    private var composerInput: some View {
        ZStack(alignment: .topLeading) {
            AIChatComposer(text: $store.draft, height: $composerHeight, focused: $composerFocused,
                           submit: store.send, close: close, cycle: cycle)
                .frame(height: composerHeight)
            if store.draft.isEmpty {
                Text("Напишите сообщение…")
                    .font(.system(size: 14)).foregroundStyle(NotchPalette.secondary)
                    .padding(.leading, 14).padding(.top, 12).allowsHitTesting(false)
            }
        }
    }

    private var composerActions: some View {
        HStack(spacing: 6) {
            Button(action: chooseAttachments) {
                Image(systemName: "paperclip").font(.system(size: 14)).frame(width: 32, height: 36)
            }
            .buttonStyle(AIChatQuietButtonStyle())
            .disabled(store.isStreaming || store.isImportingAttachments || store.draftAttachments.count >= 4)
            .help("Добавить файл или скриншот · можно перетащить в чат")
            .accessibilityLabel("Прикрепить файлы")
            if store.isImportingAttachments { ProgressView().controlSize(.mini) }
            Text("↵ отправить").foregroundStyle(NotchPalette.text.opacity(0.48))
            Text("·  ⇧↵ новая строка").foregroundStyle(NotchPalette.text.opacity(0.3))
            Spacer()
            if store.draft.count > 7_000 {
                Text("\(store.draft.count)/8000").monospacedDigit()
                    .foregroundStyle(store.draft.count > 8_000 ? Color.signalCoral : NotchPalette.secondary)
            }
            sendButton
        }
        .font(.system(size: 10))
        .padding(.leading, 14).padding(.trailing, 6).padding(.bottom, 4)
    }

    private var sendButton: some View {
        Button {
            if store.isStreaming { store.stop() } else { store.send() }
        } label: {
            Image(systemName: store.isStreaming ? "stop.fill" : "arrow.up")
                .font(.system(size: store.isStreaming ? 12 : 16, weight: .semibold))
                .foregroundStyle(store.isStreaming || store.canSend ? Color.black.opacity(0.85) : NotchPalette.text.opacity(0.25))
                .frame(width: 32, height: 32)
                .background {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(store.isStreaming || store.canSend ? NotchPalette.accent : NotchPalette.text.opacity(0.07))
                }
                .frame(width: 40, height: 40).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!store.isStreaming && !store.canSend)
        .help(store.isStreaming ? "Остановить ответ" : "Отправить сообщение")
        .accessibilityLabel(store.isStreaming ? "Остановить ответ" : "Отправить сообщение")
    }

    private var privacyFooter: some View {
        HStack(spacing: 5) {
            Image(systemName: isLocal ? "lock" : "cloud")
            Text(isLocal ? "Локально на Mac" : "\(store.selectedProvider.chatTitle) · облако")
            Spacer()
            Text("История на этом Mac")
                .help("Диалоги сохраняются локально. Найти, закрепить или удалить чат можно в истории.")
        }
        .font(.system(size: 10)).foregroundStyle(NotchPalette.secondary)
        .padding(.horizontal, 4)
    }
    private var isLocal: Bool { store.selectedProvider == .apple || store.selectedProvider == .ollama }
}

private struct AIChatMessageRow: View {
    let message: AIChatMessage
    let provider: AIChatProviderID
    let paste: ((String) -> Void)?
    @State private var copied = false
    @State private var resetCopyTask: Task<Void, Never>?

    var body: some View {
        Group {
            if message.role == .user {
                HStack {
                    Spacer(minLength: 64)
                    VStack(alignment: .leading, spacing: 8) {
                    if !message.attachments.isEmpty {
                        AIChatAttachmentStrip(attachments: message.attachments, remove: nil)
                    }
                    Text(verbatim: message.text)
                        .font(.system(size: 14)).lineSpacing(4).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(NotchPalette.text.opacity(0.9))
                    }
                        .padding(.horizontal, 15).padding(.vertical, 11)
                        .background(NotchPalette.raised, in: RoundedRectangle(cornerRadius: 15))
                }
                .accessibilityLabel("Вы: \(message.text)")
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        AIChatProviderIcon(provider: provider, size: 17)
                        Text(provider.chatTitle).font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(NotchPalette.text.opacity(0.7))
                        if message.state == .streaming { ProgressView().controlSize(.mini) }
                        Spacer()
                        if !message.text.isEmpty {
                            if message.state == .complete, let paste {
                                Button { paste(message.text) } label: {
                                    Image(systemName: "arrow.uturn.backward").frame(width: 40, height: 40)
                                }
                                .buttonStyle(AIChatQuietButtonStyle())
                                .help("Заменить выделенный текст ответом")
                                .accessibilityLabel("Вставить ответ вместо выделения")
                            }
                            Button(action: copy) {
                                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 12))
                                    .foregroundStyle(copied ? NotchPalette.accent : NotchPalette.secondary)
                                    .frame(width: 40, height: 40)
                            }
                            .buttonStyle(AIChatQuietButtonStyle())
                            .help(copied ? "Скопировано" : "Скопировать ответ")
                            .accessibilityLabel(copied ? "Скопировано" : "Скопировать ответ")
                        }
                    }.frame(height: 40)
                    if message.text.isEmpty && message.state == .streaming {
                        Text("Готовлю ответ…").font(.system(size: 13)).foregroundStyle(NotchPalette.text.opacity(0.42))
                            .padding(.top, 5)
                    } else {
                        Text(LocalizedStringKey(message.text))
                            .font(.system(size: 14)).lineSpacing(5).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .foregroundStyle(NotchPalette.text.opacity(0.86)).tint(NotchPalette.accent)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if message.state == .interrupted || message.state == .failed {
                        Label("Ответ не завершён", systemImage: "pause.circle")
                            .font(.system(size: 10)).foregroundStyle(NotchPalette.secondary).padding(.top, 6)
                    }
                }
            }
        }
        .onDisappear { resetCopyTask?.cancel() }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(message.text, forType: .string) else { return }
        copied = true
        resetCopyTask?.cancel()
        resetCopyTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            copied = false
        }
    }
}

private struct AIChatAttachmentStrip: View {
    let attachments: [AIChatAttachment]
    let remove: ((UUID) -> Void)?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(attachments) { attachment in
                    HStack(spacing: 8) {
                        if let data = attachment.imageData, let image = NSImage(data: data) {
                            Image(nsImage: image).resizable().scaledToFill()
                                .frame(width: 38, height: 38).clipped().clipShape(RoundedRectangle(cornerRadius: 6))
                        } else {
                            Image(systemName: "doc.text").font(.system(size: 18)).foregroundStyle(NotchPalette.accent)
                                .frame(width: 30, height: 38)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(attachment.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                            Text(attachment.kind == .image ? "Изображение" : "\(attachment.text.count) символов")
                                .font(.system(size: 10)).foregroundStyle(NotchPalette.secondary)
                        }.frame(maxWidth: 135, alignment: .leading)
                        if let remove {
                            Button { remove(attachment.id) } label: {
                                Image(systemName: "xmark").font(.system(size: 10)).frame(width: 28, height: 32)
                            }.buttonStyle(.plain).help("Удалить вложение")
                                .accessibilityLabel("Удалить \(attachment.name)")
                        }
                    }
                    .foregroundStyle(NotchPalette.text.opacity(0.85)).padding(6)
                    .background(NotchPalette.text.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
                    .help(attachment.name)
                }
            }
        }.frame(height: 50)
    }
}

private struct AIChatProviderIcon: View {
    let provider: AIChatProviderID
    let size: CGFloat
    var body: some View {
        Group {
            switch provider {
            case .apple:
                Image(systemName: appleSymbol).font(.system(size: size, weight: .medium))
                    .foregroundStyle(Color.signalMint)
            case .codex:
                Image("QuotaChatGPT", bundle: .module).resizable().renderingMode(.template).scaledToFit()
                    .foregroundStyle(NotchPalette.text.opacity(0.85))
            case .claude:
                Image("QuotaClaude", bundle: .module).resizable().renderingMode(.template).scaledToFit()
                    .foregroundStyle(Color(red: 0.85, green: 0.56, blue: 0.43))
            case .ollama:
                Image("QuotaOllama", bundle: .module).resizable().renderingMode(.template).scaledToFit()
                    .foregroundStyle(NotchPalette.text.opacity(0.85))
            }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }

    private var appleSymbol: String {
        if #available(macOS 15.0, *) { "apple.intelligence" } else { "sparkles" }
    }
}

private extension AIChatProviderID {
    var chatTitle: String {
        switch self {
        case .apple: "Apple Intelligence"
        case .codex: "Codex"
        case .claude: "Claude"
        case .ollama: "Ollama"
        }
    }
}

private struct AIChatQuietButtonStyle: ButtonStyle {
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(NotchPalette.text.opacity(hovered ? 0.9 : 0.55))
            .background(NotchPalette.text.opacity(configuration.isPressed ? 0.1 : (hovered ? 0.055 : 0)),
                        in: RoundedRectangle(cornerRadius: 10))
            .onHover { hovered = $0 }
    }
}

private struct AIChatSuggestionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(NotchPalette.text.opacity(enabled ? (hovered ? 0.9 : 0.65) : 0.3))
            .padding(.horizontal, 13).frame(height: 40)
            .background(NotchPalette.text.opacity(configuration.isPressed ? 0.09 : (hovered ? 0.07 : 0.035)),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(NotchPalette.text.opacity(0.06)))
            .onHover { hovered = $0 }
    }
}

struct AIChatSettingsView: View {
    @ObservedObject var store: AIChatStore
    var body: some View {
        GroupBox("AI-чат") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Apple Intelligence и Ollama работают на Mac. Codex и Claude используют вход в установленных CLI и отправляют сообщения своим сервисам.")
                    .font(.caption).foregroundStyle(NotchPalette.secondary)
                Toggle("Подключить Codex CLI", isOn: $store.codexEnabled)
                Toggle("Подключить Claude CLI", isOn: $store.claudeEnabled)
                ForEach(AIChatProviderID.allCases) { provider in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(provider.title).font(.system(size: 12, weight: .medium))
                            if store.checking.contains(provider) { ProgressView().controlSize(.mini) }
                        }
                        Text(store.statuses[provider]?.message ?? "Нажмите «Проверить подключения».")
                            .font(.caption).foregroundStyle(NotchPalette.secondary)
                    }
                }
                Button("Проверить подключения", action: store.refreshAvailability)
                Text("Для Ollama запустите локальный сервер на 127.0.0.1:11434. Nool показывает установленные локальные модели и не скачивает их автоматически.")
                    .font(.caption).foregroundStyle(NotchPalette.secondary)
                Text("Для входа используйте установленный CLI: codex login или claude auth login. Nool не сохраняет их ключи и не меняет конфиги.")
                    .font(.caption).foregroundStyle(NotchPalette.secondary).textSelection(.enabled)
            }.padding(8)
        }
        .onAppear { store.refreshAvailability() }
    }
}

private struct AIChatComposer: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    @Binding var focused: Bool
    let submit: () -> Void
    let close: () -> Void
    let cycle: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 52))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let editor = ChatTextView(frame: scroll.bounds)
        editor.isRichText = false
        editor.drawsBackground = false
        editor.textColor = NSColor(NotchPalette.text)
        editor.insertionPointColor = NSColor(NotchPalette.accent)
        editor.font = .systemFont(ofSize: 14)
        editor.textContainerInset = NSSize(width: 14, height: 12)
        editor.textContainer?.lineFragmentPadding = 0
        editor.minSize = NSSize(width: 0, height: 52)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.allowsUndo = true
        editor.identifier = NSUserInterfaceItemIdentifier("nool.launcher.chat-composer")
        editor.setAccessibilityLabel("Сообщение AI")
        editor.delegate = context.coordinator
        editor.onFocusChange = { [weak coordinator = context.coordinator] focused in
            Task { @MainActor in coordinator?.parent.focused = focused }
        }
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? NSTextView else { return }
        if editor.string != text { editor.string = text }
        context.coordinator.measure(editor)
    }

    private final class ChatTextView: NSTextView {
        var onFocusChange: ((Bool) -> Void)?
        override func becomeFirstResponder() -> Bool {
            let result = super.becomeFirstResponder()
            if result { onFocusChange?(true) }
            return result
        }
        override func resignFirstResponder() -> Bool {
            let result = super.resignFirstResponder()
            if result { onFocusChange?(false) }
            return result
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AIChatComposer
        init(_ parent: AIChatComposer) { self.parent = parent }

        func measure(_ editor: NSTextView) {
            guard let layout = editor.layoutManager, let container = editor.textContainer else { return }
            layout.ensureLayout(for: container)
            let desired = min(112, max(52, ceil(layout.usedRect(for: container).height + 24)))
            guard abs(parent.height - desired) > 0.5 else { return }
            Task { @MainActor [weak self] in self?.parent.height = desired }
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
            measure(view)
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            switch NSStringFromSelector(selector) {
            case "insertNewline:":
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { return false }
                parent.submit()
            case "cancelOperation:": parent.close()
            case "insertTab:": parent.cycle(false)
            case "insertBacktab:": parent.cycle(true)
            default: return false
            }
            return true
        }
    }
}

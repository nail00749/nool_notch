import AppKit
import SwiftUI

struct LauncherView: View {
    @ObservedObject var model: LauncherModel
    let activate: (LauncherResult, Bool) -> Void
    let reveal: (LauncherResult) -> Void
    let close: () -> Void
    let openSettings: () -> Void
    let focusInput: () -> Void
    let requestSelectionAccess: () -> Void
    let pasteAIResponse: (String) -> Void
    let chooseAttachments: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: model.category == .ai ? "sparkles" : "magnifyingglass")
                    .font(.system(size: model.category == .ai ? 19 : 24, weight: .light))
                    .foregroundStyle(Color.signalMint)
                if model.category == .ai {
                    Text("Nool AI").font(.system(size: 18, weight: .medium, design: .rounded))
                    Spacer()
                } else {
                    LauncherSearchField(text: $model.query, move: model.move, submit: submit,
                                        cancel: cancel, cycle: model.cycleCategory)
                        .frame(height: 38)
                }
                if model.isSearching {
                    ProgressView().controlSize(.small).accessibilityLabel("Поиск")
                }
                Button(action: openSettings) {
                    Image(systemName: "slider.horizontal.3").frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Настройки Launcher")
                .accessibilityLabel("Настройки Launcher")
            }
            .padding(.horizontal, 24)
            .padding(.vertical, model.category == .ai ? 7 : 14)

            HStack(spacing: 6) {
                ForEach(LauncherCategory.allCases) { category in
                    Button { model.category = category } label: {
                        Text(category.title)
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 12)
                            .frame(height: 34)
                            .background(model.category == category ? Color.white.opacity(0.1) : .clear,
                                        in: RoundedRectangle(cornerRadius: 9))
                            .foregroundStyle(model.category == category ? .white : .white.opacity(0.48))
                    }
                    .buttonStyle(.plain)
                    .help("\(category.title) — \(category.keyboardShortcutHint)")
                    .accessibilityAddTraits(model.category == category ? [.isSelected] : [])
                }
                Spacer()
                Text("⌘1–5 · ⌃⇥").font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.3)).padding(.trailing, 8)
                    .help("⌘1–⌘5 — выбрать вкладку; Ctrl+Tab / Ctrl+Shift+Tab — следующая / предыдущая")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            Divider().overlay(.white.opacity(0.04))

            if model.category == .ai {
                AIChatView(store: model.aiChat, selection: model.textSelection, close: close, cycle: model.cycleCategory,
                           focusComposer: focusInput, openSettings: openSettings,
                           requestSelectionAccess: requestSelectionAccess, pasteResponse: pasteAIResponse,
                           chooseAttachments: chooseAttachments)
            } else if let event = model.selectedNoolEvent {
                LauncherMeetingDetail(event: event, back: { model.selectedNoolEvent = nil },
                                      join: model.joinSelectedMeeting)
            } else if model.results.isEmpty {
                emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 3) {
                            ForEach(model.results) { result in
                                LauncherResultRow(result: result, selected: model.selectedID == result.id,
                                                  icons: model.icons, clipboardData: clipboardData(for: result))
                                    .contentShape(Rectangle())
                                    .onTapGesture(count: 2) { activate(result, false) }
                                    .onTapGesture { model.selectedID = result.id }
                                    .accessibilityElement(children: .combine)
                                    .accessibilityAddTraits(model.selectedID == result.id ? [.isSelected] : [])
                                    .accessibilityAction { activate(result, false) }
                                    .contextMenu {
                                        Button(primaryTitle(result)) { activate(result, false) }
                                        switch result.payload {
                                        case .file, .application:
                                            Button("Показать в Finder") { reveal(result) }
                                        case .clipboard:
                                            Button("Вставить в предыдущее приложение") { activate(result, true) }
                                        case .calculation, .nool: EmptyView()
                                        }
                                    }
                                    .id(result.id)
                            }
                        }
                        .padding(10)
                    }
                    .onChange(of: model.selectedID) { _, id in
                        if let id { proxy.scrollTo(id, anchor: nil) }
                    }
                }
            }

            if model.category != .ai, let message = model.message ?? model.sourceError {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.signalMint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 22).padding(.vertical, 8)
                    .accessibilityLabel(message)
            }

            if model.category != .ai {
            Divider().overlay(.white.opacity(0.04))
            HStack(spacing: 8) {
                Text("NOOL").font(.system(size: 10, weight: .bold, design: .rounded)).tracking(2)
                    .foregroundStyle(Color.signalMint.opacity(0.8))
                Text(model.results.isEmpty ? "Launcher" : "\(model.results.count) результатов")
                    .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                if model.selectedNoolEvent != nil {
                    Button("Esc  Назад") { model.selectedNoolEvent = nil }
                        .buttonStyle(.plain).font(.system(size: 12)).frame(minHeight: 36)
                } else if let selected = model.selectedResult {
                    if case .clipboard = selected.payload {
                        Button("⌘ ↵  Вставить") { activate(selected, true) }
                            .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                            .frame(minHeight: 36)
                    }
                    Button { activate(selected, false) } label: {
                        HStack(spacing: 8) {
                            Text(primaryTitle(selected))
                            Text("↵").foregroundStyle(Color.signalMint)
                        }.font(.system(size: 12, weight: .medium)).frame(minHeight: 36)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 22).padding(.vertical, 4)
            }
        }
        .background(LauncherMaterial())
        .background(Color(red: 0.07, green: 0.08, blue: 0.085).opacity(0.94))
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .preferredColorScheme(.dark)
        .onChange(of: model.category) { _, _ in focusInput() }
    }

    private func submit(_ paste: Bool) {
        guard model.selectedNoolEvent == nil else { return }
        if let result = model.selectedResult { activate(result, paste) }
    }

    private func cancel() {
        if model.selectedNoolEvent != nil { model.selectedNoolEvent = nil }
        else { close() }
    }

    private func clipboardData(for result: LauncherResult) -> Data? {
        guard case .clipboard(let id) = result.payload else { return nil }
        return model.clipboard.items.first { $0.id == id }?.imageData
    }

    private func primaryTitle(_ result: LauncherResult) -> String {
        switch result.payload {
        case .application, .file, .nool: "Открыть"
        case .clipboard, .calculation: "Скопировать"
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: model.category == .clipboard ? "clipboard" : "magnifyingglass")
                .font(.system(size: 32, weight: .ultraLight)).foregroundStyle(.white.opacity(0.3))
            Text(emptyTitle).font(.system(size: 15, weight: .medium))
            Text(emptyDetail).font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 400)
            if model.category == .clipboard && !model.settings.clipboardEnabled {
                Button("Настроить историю буфера", action: openSettings)
                    .buttonStyle(.bordered).tint(Color.signalMint)
            }
        }.padding(24)
    }

    private var emptyTitle: String {
        if model.category == .clipboard && !model.settings.clipboardEnabled { return "История буфера выключена" }
        if model.isSearching { return "Ищем…" }
        if model.query.isEmpty { return model.category == .files ? "Найдите файл или папку" : "Здесь пока пусто" }
        return "Ничего не найдено"
    }

    private var emptyDetail: String {
        if model.category == .clipboard { return "Текст и изображения сохраняются локально, когда история включена." }
        if model.category == .files { return "Введите имя. Папки для поиска можно выбрать в настройках Launcher." }
        return "Начните вводить название приложения, имя файла или выражение, например 24 * 7."
    }
}

private struct LauncherResultRow: View {
    let result: LauncherResult
    let selected: Bool
    let icons: LauncherIcons
    let clipboardData: Data?
    @State private var icon: NSImage?

    var body: some View {
        HStack(spacing: 13) {
            Group {
                if let icon {
                    Image(nsImage: icon).resizable().scaledToFit().padding(3)
                } else {
                    Image(systemName: symbol).font(.system(size: 21, weight: .regular))
                        .foregroundStyle(selected ? Color.signalMint : .white.opacity(0.7))
                }
            }
            .frame(width: 38, height: 38)
            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(result.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                Text(result.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(kind).font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.3))
            if selected { Image(systemName: "return").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)) }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(selected ? Color.white.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 12))
        .task(id: result.id) { icon = await icons.image(for: result, clipboardData: clipboardData) }
    }

    private var symbol: String {
        switch result.payload {
        case .application: "app.dashed"
        case .file: "doc"
        case .clipboard: "clipboard"
        case .calculation: "equal.square"
        case .nool(_, let kind): kind.symbol
        }
    }
    private var kind: String {
        switch result.payload {
        case .application: "Приложение"
        case .file: "Файл"
        case .clipboard: "Буфер"
        case .calculation: "Калькулятор"
        case .nool(_, let kind): kind.title
        }
    }
}

private struct LauncherMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

private struct LauncherSearchField: NSViewRepresentable {
    @Binding var text: String
    let move: (Int) -> Void
    let submit: (Bool) -> Void
    let cancel: () -> Void
    let cycle: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 23, weight: .regular)
        field.textColor = .white
        field.placeholderString = "Поиск в Nool…"
        field.setAccessibilityLabel("Поиск в Nool Launcher")
        field.identifier = NSUserInterfaceItemIdentifier("nool.launcher.search")
        field.delegate = context.coordinator
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: LauncherSearchField
        init(_ parent: LauncherSearchField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if textView.hasMarkedText() { return false }
            switch NSStringFromSelector(selector) {
            case "moveUp:": parent.move(-1)
            case "moveDown:": parent.move(1)
            case "insertNewline:": parent.submit(NSApp.currentEvent?.modifierFlags.contains(.command) == true)
            case "cancelOperation:": parent.cancel()
            case "insertTab:": parent.cycle(false)
            case "insertBacktab:": parent.cycle(true)
            default: return false
            }
            return true
        }
    }
}

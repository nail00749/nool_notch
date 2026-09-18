import AppKit
import SwiftUI

struct TextRecognitionView: View {
    @ObservedObject var store: TextRecognitionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            header

            switch store.phase {
            case .idle, .running:
                loadingView
            case .failed(let message):
                errorView(message)
            case .ready:
                resultView
            }

            if let actionMessage = store.actionMessage {
                Text(actionMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(NotchPalette.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(22)
        .frame(minWidth: 580, minHeight: 470)
        .background(NotchPalette.surface)
        .foregroundStyle(NotchPalette.text)
        .tint(NotchPalette.accent)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: "text.viewfinder")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(NotchPalette.accent)
                .frame(width: 42, height: 42)
                .background(NotchPalette.accent.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text("Распознавание текста")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                Text(fileSummary)
                    .font(.system(size: 11))
                    .foregroundStyle(NotchPalette.secondary)
                    .lineLimit(2)
                    .help(store.urls.map(\.lastPathComponent).joined(separator: ", "))
            }
            Spacer(minLength: 0)
            Button { store.close() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Закрыть распознанный текст")
        }
    }

    private var fileSummary: String {
        store.urls.count == 1
            ? store.urls[0].lastPathComponent
            : "\(store.urls.count) файлов: " + store.urls.map(\.lastPathComponent).joined(separator: ", ")
    }

    private var loadingView: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.regular).tint(NotchPalette.accent)
            Text("Распознаём текст локально…")
                .font(.system(size: 13, weight: .medium))
            Text("Изображения и PDF обрабатываются на этом Mac.")
                .font(.system(size: 11))
                .foregroundStyle(NotchPalette.secondary)
            Button("Отмена") { store.close() }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NotchPalette.raised.opacity(0.55),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 13) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 26))
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Повторить") { store.start() }
                .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NotchPalette.raised.opacity(0.55),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var resultView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(NotchPalette.secondary)
                TextField("Найти в тексте", text: $store.searchQuery)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Поиск в распознанном тексте")
                if !store.searchQuery.isEmpty {
                    Text(store.matches.isEmpty
                         ? "Нет совпадений"
                         : "\(store.selectedMatchIndex + 1) из \(store.matches.count)")
                        .font(.system(size: 10))
                        .foregroundStyle(NotchPalette.secondary)
                        .monospacedDigit()
                    Button(action: store.previousMatch) {
                        Image(systemName: "chevron.up")
                    }
                    .accessibilityLabel("Предыдущее совпадение")
                    .disabled(store.matches.isEmpty)
                    Button(action: store.nextMatch) {
                        Image(systemName: "chevron.down")
                    }
                    .accessibilityLabel("Следующее совпадение")
                    .disabled(store.matches.isEmpty)
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .padding(.horizontal, 11)
            .frame(height: 36)
            .background(NotchPalette.raised,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            TextRecognitionEditor(
                text: $store.text,
                selectedRange: store.selectedMatchRange,
                selectionRevision: store.selectionRevision
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(NotchPalette.raised.opacity(0.65),
                        in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(NotchPalette.separator, lineWidth: 1)
            }
            .accessibilityLabel("Распознанный текст, можно исправить")

            HStack(spacing: 10) {
                Text("Текст можно исправить перед копированием или передачей в AI.")
                    .font(.system(size: 10))
                    .foregroundStyle(NotchPalette.secondary)
                Spacer(minLength: 8)
                Text("\(store.text.count) символов")
                    .font(.system(size: 10))
                    .foregroundStyle(NotchPalette.secondary)
                    .monospacedDigit()
            }

            HStack(spacing: 9) {
                Spacer()
                Button("Скопировать", action: store.copyText)
                    .buttonStyle(.bordered)
                    .disabled(store.text.isEmpty)
                Button("В AI-черновик", action: store.prepareAIDraft)
                    .buttonStyle(.borderedProminent)
                    .disabled(store.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityHint("Откроет текст в AI без отправки сообщения")
            }
        }
    }
}

private struct TextRecognitionEditor: NSViewRepresentable {
    @Binding var text: String
    let selectedRange: NSRange?
    let selectionRevision: Int

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView(frame: .zero)
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let editor = NSTextView(frame: scrollView.contentView.bounds)
        editor.isEditable = true
        editor.isSelectable = true
        editor.isRichText = false
        editor.drawsBackground = false
        editor.textColor = NSColor(NotchPalette.text)
        editor.insertionPointColor = NSColor(NotchPalette.accent)
        editor.font = .systemFont(ofSize: 12)
        editor.textContainerInset = NSSize(width: 12, height: 12)
        editor.textContainer?.lineFragmentPadding = 0
        editor.minSize = NSSize(width: 0, height: 0)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                height: CGFloat.greatestFiniteMagnitude)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.allowsUndo = true
        editor.delegate = context.coordinator
        editor.string = text
        scrollView.documentView = editor
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let editor = scrollView.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        if editor.string != text {
            editor.string = text
        }
        if context.coordinator.appliedSelectionRevision != selectionRevision {
            context.coordinator.appliedSelectionRevision = selectionRevision
            if let selectedRange, NSMaxRange(selectedRange) <= (editor.string as NSString).length {
                editor.setSelectedRange(selectedRange)
                editor.scrollRangeToVisible(selectedRange)
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TextRecognitionEditor
        var appliedSelectionRevision = -1

        init(parent: TextRecognitionEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
        }
    }
}

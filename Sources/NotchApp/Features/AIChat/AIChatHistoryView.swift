import SwiftUI

/// A compact, local-only transcript picker. The containing view decides how to
/// present and dismiss it after a conversation is restored.
struct AIChatHistoryView: View {
    @ObservedObject var store: AIChatStore
    let onSelect: (UUID) -> Void

    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var conversations: [AIChatHistoryConversation] {
        store.history.filter { $0.matches(query) }
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(NotchPalette.secondary)
                TextField("Поиск по чатам", text: $query)
                    .textFieldStyle(.plain).font(.system(size: 13))
                    .foregroundStyle(NotchPalette.text.opacity(0.9))
                    .focused($searchFocused)
            }
            .padding(.horizontal, 13).frame(height: 40)
            .background(NotchPalette.text.opacity(0.055), in: RoundedRectangle(cornerRadius: 11))

            if let historyError = store.historyError {
                Text(historyError)
                    .font(.caption)
                    .foregroundStyle(NotchPalette.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if conversations.isEmpty {
                ContentUnavailableView(
                    "Нет сохранённых чатов",
                    systemImage: "clock",
                    description: Text(query.isEmpty ? "История появится после первого сообщения." : "Измените запрос поиска.")
                )
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                LazyVStack(spacing: 5) {
                ForEach(conversations) { conversation in
                    HStack(spacing: 8) {
                        Button {
                            store.openConversation(conversation.id)
                            onSelect(conversation.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(conversation.title)
                                    .font(.system(size: 13, weight: .medium)).lineLimit(1)
                                    .foregroundStyle(NotchPalette.text.opacity(0.9))
                                Text("\(conversation.provider.title) · \(conversation.modelID)")
                                    .font(.caption)
                                    .foregroundStyle(NotchPalette.secondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)

                        Button {
                            store.togglePinConversation(conversation.id)
                        } label: {
                            Image(systemName: conversation.isPinned ? "pin.fill" : "pin")
                                .foregroundStyle(conversation.isPinned ? NotchPalette.accent : NotchPalette.secondary)
                                .frame(width: 36, height: 40).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(conversation.isPinned ? "Открепить чат" : "Закрепить чат")

                        Button(role: .destructive) {
                            store.deleteConversation(conversation.id)
                        } label: {
                            Image(systemName: "trash").foregroundStyle(NotchPalette.secondary)
                                .frame(width: 36, height: 40).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Удалить чат")
                    }
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(NotchPalette.raised.opacity(store.activeConversationID == conversation.id ? 1 : 0.4),
                                in: RoundedRectangle(cornerRadius: 11))
                }
                }
                }
            }
        }
        .padding()
        .frame(minWidth: 360, minHeight: 300)
        .onAppear { searchFocused = true }
    }
}

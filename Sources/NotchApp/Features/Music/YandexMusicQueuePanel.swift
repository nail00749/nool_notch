import SwiftUI

struct YandexMusicQueuePanel: View {
    @ObservedObject var store: YandexMusicQueueStore
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Далее в очереди").font(.system(size: 14, weight: .semibold))
                    Text("Яндекс Музыка").font(.system(size: 10)).foregroundStyle(NotchPalette.secondary)
                }
                Spacer(minLength: 4)
                Button { store.refresh() } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 40, height: 40)
                }
                .buttonStyle(NotchButtonStyle())
                .disabled(store.pendingItemID != nil)
                .accessibilityLabel("Обновить очередь Яндекс Музыки")
                Button { store.openQueue() } label: {
                    Image(systemName: "arrow.up.right.square").frame(width: 40, height: 40)
                }
                .buttonStyle(NotchButtonStyle())
                .disabled(store.pendingItemID != nil)
                .help("Открыть очередь в Яндекс Музыке")
                .accessibilityLabel("Открыть очередь в Яндекс Музыке")
            }
            if let message = store.playbackMessage {
                Text(message).font(.system(size: 11)).foregroundStyle(NotchPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            switch store.state {
            case .idle, .loading:
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .permissionRequired:
                placeholder("Нужен Универсальный доступ", detail: "Разрешите NooL App читать очередь открытого плеера.",
                            action: "Открыть настройки", onAction: onOpenSettings)
            case .notRunning:
                placeholder("Яндекс Музыка не запущена", detail: "Откройте приложение Яндекс Музыки и его очередь воспроизведения.",
                            action: "Открыть Яндекс Музыку", onAction: store.openQueue)
            case .closed:
                placeholder("Откройте очередь в Яндексе", detail: "Здесь появятся следующие треки из открытой очереди. На экране «Моя волна» сначала перейдите в «Коллекцию».",
                            action: "Открыть очередь", onAction: store.openQueue)
            case .failed(let message):
                placeholder("Очередь недоступна", detail: message, action: "Обновить", onAction: store.refresh)
            case .loaded(let items, let partial):
                if items.isEmpty {
                    placeholder("Следующих треков нет", detail: "Добавьте песни в очередь Яндекс Музыки.", action: nil, onAction: {})
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                Button { store.play(item) } label: {
                                HStack(spacing: 10) {
                                    Text("\(index + 1)")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(NotchPalette.secondary)
                                        .frame(width: 22)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                        Text(item.artist).font(.system(size: 10)).foregroundStyle(NotchPalette.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                    if store.pendingItemID == item.id {
                                        ProgressView().controlSize(.mini).frame(width: 22)
                                    } else {
                                        Image(systemName: "play.fill")
                                            .font(.system(size: 10))
                                            .foregroundStyle(NotchPalette.secondary)
                                            .frame(width: 22)
                                    }
                                }
                                .foregroundStyle(NotchPalette.text)
                                .frame(minHeight: 42)
                                .padding(.horizontal, 8)
                                .background(index == 0 ? NotchPalette.text.opacity(0.06) : .clear,
                                            in: RoundedRectangle(cornerRadius: 10))
                                .contentShape(Rectangle())
                                }
                                .buttonStyle(NotchButtonStyle())
                                .disabled(store.pendingItemID != nil)
                                .accessibilityLabel("Воспроизвести \(item.title), \(item.artist)")
                                .accessibilityHint("Сначала проверит актуальность очереди Яндекс Музыки")
                            }
                        }
                    }
                }
                Text(partial ? "Показана доступная часть очереди · до 40 треков" : "Очередь обновляется, пока открыта в Яндекс Музыке")
                    .font(.system(size: 10)).foregroundStyle(NotchPalette.secondary)
            }
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func placeholder(_ title: String, detail: String, action: String?,
                             onAction: @escaping () -> Void) -> some View {
        VStack(spacing: 10) {
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(detail).font(.system(size: 11)).foregroundStyle(NotchPalette.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 330)
            if let action {
                Button(action, action: onAction).buttonStyle(NotchButtonStyle()).frame(minHeight: 40)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

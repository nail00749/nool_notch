import SwiftUI

struct MusicLyricsPanel: View {
    @ObservedObject var store: MusicLyricsStore
    let snapshot: NowPlayingSnapshot
    let isActive: Bool
    let onSeek: (TimeInterval) -> Void
    let onTogglePlayPause: () -> Void
    @State private var followsPlayback = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(snapshot.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(snapshot.artist).font(.system(size: 11)).foregroundStyle(NotchPalette.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Button(action: onTogglePlayPause) {
                    Image(systemName: snapshot.playbackState.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(NotchButtonStyle())
                .accessibilityLabel(snapshot.playbackState.isPlaying ? "Пауза" : "Воспроизвести")
            }
            switch store.state {
            case .idle:
                message("Текст текущей песни", detail: "Название, исполнитель и альбом будут отправлены в LRCLIB для поиска текста.", action: "Найти текст")
            case .loading:
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Ищем текст в LRCLIB…").font(.caption).foregroundStyle(NotchPalette.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            case .notFound:
                message("Текст не найден", detail: "В LRCLIB пока нет совпадения для этого трека.", action: "Повторить поиск")
            case .instrumental:
                message("Без слов", detail: "В LRCLIB трек отмечен как инструментальный.", action: nil)
            case .failed(let failure):
                message("Не удалось загрузить текст", detail: failure.message, action: "Повторить")
            case .loaded(let document):
                if document.timedLines.isEmpty {
                    ScrollView {
                        Text(document.plainText)
                            .font(.system(size: 14, weight: .medium))
                            .lineSpacing(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                    }
                    sourceFooter(synced: false)
                } else {
                    TimelineView(.periodic(from: .now, by: isActive ? 0.5 : 3_600)) { context in
                        let active = document.activeLineIndex(at: snapshot.elapsedTime(at: context.date))
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 4) {
                                    ForEach(Array(document.timedLines.enumerated()), id: \.offset) { index, line in
                                        Button {
                                            let time = snapshot.duration > 0
                                                ? min(line.time, snapshot.duration) : line.time
                                            onSeek(max(0, time))
                                        } label: {
                                            Text(line.text.isEmpty ? "♪" : line.text)
                                                .font(.system(size: 15, weight: active == index ? .semibold : .medium))
                                                .foregroundStyle(active == index ? NotchPalette.text : NotchPalette.secondary)
                                                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                                                .padding(.horizontal, 10)
                                                .background(active == index ? NotchPalette.text.opacity(0.08) : .clear,
                                                            in: RoundedRectangle(cornerRadius: 10))
                                        }
                                        .buttonStyle(.plain)
                                        .id(index)
                                        .accessibilityHint("Перемотать к этой строке")
                                    }
                                }
                            }
                            .onAppear { if let active { proxy.scrollTo(active, anchor: .center) } }
                            .onChange(of: active) { _, index in
                                guard followsPlayback, let index else { return }
                                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                                    proxy.scrollTo(index, anchor: .center)
                                }
                            }
                            .onChange(of: followsPlayback) { _, follows in
                                if follows, let active { proxy.scrollTo(active, anchor: .center) }
                            }
                        }
                    }
                    sourceFooter(synced: true)
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: store.track) { _, _ in followsPlayback = true }
    }

    private func message(_ title: String, detail: String, action: String?) -> some View {
        VStack(spacing: 10) {
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(detail).font(.system(size: 11)).foregroundStyle(NotchPalette.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 330)
            if let action {
                Button(action) { store.lookup() }
                    .buttonStyle(NotchButtonStyle()).frame(minHeight: 40)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sourceFooter(synced: Bool) -> some View {
        HStack {
            Link("LRCLIB", destination: URL(string: "https://lrclib.net")!)
                .font(.system(size: 10)).foregroundStyle(NotchPalette.secondary)
            Text(synced ? "Синхронизированный текст" : "Без синхронизации")
                .font(.system(size: 10)).foregroundStyle(NotchPalette.secondary)
            Spacer(minLength: 4)
            if synced {
                Button { followsPlayback.toggle() } label: {
                    Image(systemName: followsPlayback ? "arrow.down.to.line.compact" : "arrow.down")
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(NotchButtonStyle())
                .accessibilityLabel(followsPlayback ? "Выключить автопрокрутку текста" : "Следовать за песней")
                .help(followsPlayback ? "Выключить автопрокрутку" : "Следовать за песней")
            }
        }
    }
}

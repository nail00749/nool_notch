import AppKit
import SwiftUI

struct MusicPanel: View {
    @ObservedObject var model: NotchViewModel

    var body: some View {
        Group {
            if let snapshot = model.nowPlayingSnapshot {
                NowPlayingCard(
                    snapshot: snapshot,
                    isActive: model.selectedPanel == .music,
                    onPrevious: model.nowPlayingPreviousTrack,
                    onTogglePlayPause: model.nowPlayingTogglePlayPause,
                    onNext: model.nowPlayingNextTrack,
                    onSeek: model.nowPlayingSeek,
                    onOpenPlayer: model.openNowPlayingApplication
                )
            } else {
                MusicEmptyState(
                    requiresAccessibilityAccess: model.nowPlayingRequiresAccessibilityAccess,
                    onRefresh: model.refreshNowPlaying,
                    onOpenSettings: model.openAccessibilitySettings
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if model.selectedPanel == .music {
                model.refreshNowPlaying()
            }
        }
        .onChange(of: model.selectedPanel) { _, panel in
            if panel == .music {
                model.refreshNowPlaying()
            }
        }
    }
}

private struct NowPlayingCard: View {
    let snapshot: NowPlayingSnapshot
    let isActive: Bool
    let onPrevious: () -> Void
    let onTogglePlayPause: () -> Void
    let onNext: () -> Void
    let onSeek: (TimeInterval) -> Void
    let onOpenPlayer: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draggedProgress: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: isActive ? 1 : 3_600)) { context in
            let liveElapsed = snapshot.elapsedTime(at: context.date)
            let liveProgress = snapshot.progress(at: context.date)
            let progress = draggedProgress ?? liveProgress
            let elapsed = draggedProgress.map { $0 * snapshot.duration } ?? liveElapsed

            VStack(spacing: 16) {
                HStack(spacing: 16) {
                    NowPlayingArtwork(data: snapshot.artworkData)

                    Button(action: onOpenPlayer) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Сейчас играет")
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.signalMint)
                                .textCase(.uppercase)

                            Text(snapshot.title)
                                .font(.system(size: 17, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white)
                                .lineLimit(2)

                            Text(snapshot.artist)
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.58))
                                .lineLimit(1)

                            if let album = snapshot.album, album.isEmpty == false {
                                Text(album)
                                    .font(.system(size: 10, weight: .medium, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.36))
                                    .lineLimit(1)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .accessibilityLabel("Открыть приложение-плеер")

                    Spacer(minLength: 0)
                }

                VStack(spacing: 5) {
                    if snapshot.duration > 0 {
                        Slider(
                            value: Binding(
                                get: { draggedProgress ?? liveProgress },
                                set: { draggedProgress = min(max($0, 0), 1) }
                            ),
                            in: 0...1,
                            onEditingChanged: { isEditing in
                                guard isEditing == false,
                                      let draggedProgress else {
                                    return
                                }
                                self.draggedProgress = nil
                                onSeek(draggedProgress * snapshot.duration)
                            }
                        )
                        .tint(Color.signalMint)
                        .controlSize(.small)
                        .accessibilityLabel("Позиция трека")
                    } else {
                        ProgressView(value: progress)
                            .tint(Color.signalMint)
                            .scaleEffect(y: 0.75)
                    }

                    HStack {
                        Text(formatTime(elapsed))
                        Spacer()
                        Text(snapshot.duration > 0 ? formatTime(snapshot.duration) : "--:--")
                    }
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.38))
                    .monospacedDigit()
                }

                HStack(spacing: 8) {
                    NowPlayingControlButton(
                        icon: "backward.fill",
                        label: "Предыдущий трек",
                        action: onPrevious
                    )

                    NowPlayingControlButton(
                        icon: snapshot.playbackState.isPlaying ? "pause.fill" : "play.fill",
                        label: snapshot.playbackState.isPlaying ? "Пауза" : "Воспроизвести",
                        action: onTogglePlayPause,
                        isPrimary: true
                    )

                    NowPlayingControlButton(
                        icon: "forward.fill",
                        label: "Следующий трек",
                        action: onNext
                    )
                }
                .frame(maxWidth: .infinity)

                if let appName = snapshot.appName, appName.isEmpty == false {
                    Text(appName)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.32))
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .background(
                Color.white.opacity(0.055),
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
            .padding(.horizontal, 16)
            .animation(
                reduceMotion ? .linear(duration: 0.01) : .easeOut(duration: 0.18),
                value: snapshot.id
            )
        }
    }

    private func formatTime(_ time: TimeInterval) -> String {
        guard time.isFinite, time >= 0 else { return "0:00" }
        let totalSeconds = Int(time.rounded(.down))
        return "\(totalSeconds / 60):\(String(format: "%02d", totalSeconds % 60))"
    }
}

private struct NowPlayingArtwork: View {
    let data: Data?

    var body: some View {
        Group {
            if let data, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Color.signalMint)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 92, height: 92)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .stroke(.white.opacity(0.1), lineWidth: 1)
        }
    }
}

private struct NowPlayingControlButton: View {
    let icon: String
    let label: String
    let action: () -> Void
    var isPrimary = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: isPrimary ? 15 : 12, weight: .semibold))
                .padding(.leading, isPrimary && icon == "play.fill" ? 2 : 0)
                .frame(width: 40, height: 40)
                .foregroundStyle(isPrimary ? .black : .white.opacity(0.78))
                .background(
                    isPrimary ? Color.signalMint : Color.white.opacity(0.1),
                    in: Circle()
                )
        }
        .buttonStyle(NotchButtonStyle())
        .accessibilityLabel(label)
    }
}

private struct MusicEmptyState: View {
    let requiresAccessibilityAccess: Bool
    let onRefresh: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 11) {
            Image(systemName: "waveform")
                .font(.system(size: 29, weight: .light))
                .foregroundStyle(Color.signalMint)

            Text("Ничего не играет")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)

            Text(requiresAccessibilityAccess
                 ? "Разрешите NotchApp доступ в Настройки → Конфиденциальность и безопасность → Универсальный доступ."
                 : "Включите музыку — текущий трек появится здесь.")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.42))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 280)

            HStack(spacing: 8) {
                Button(action: onRefresh) {
                    Label("Обновить", systemImage: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .frame(minWidth: 40, minHeight: 40)
                }
                .buttonStyle(NotchButtonStyle())
                .foregroundStyle(.white.opacity(0.8))
                .accessibilityLabel("Обновить текущий трек")

                if requiresAccessibilityAccess {
                    Button(action: onOpenSettings) {
                        Label("Открыть настройки", systemImage: "gearshape")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .frame(minWidth: 40, minHeight: 40)
                    }
                    .buttonStyle(NotchButtonStyle())
                    .foregroundStyle(Color.signalMint)
                    .accessibilityLabel("Открыть настройки универсального доступа")
                }
            }
        }
        .padding(20)
    }
}

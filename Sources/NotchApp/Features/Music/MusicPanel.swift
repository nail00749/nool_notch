import AppKit
import SwiftUI

struct MusicPanel: View {
    @ObservedObject var model: NotchViewModel
    private enum Section { case player, lyrics, queue }
    @State private var section: Section = .player

    private var isVisible: Bool {
        model.isExpanded && model.selectedPanel == .music && model.activeUtility == nil
            && !model.isShowingSettings && model.modules.isEnabled(.music)
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                musicTab("Плеер", icon: "play.circle", selected: section == .player) {
                    section = .player
                    model.musicLyrics.deactivate()
                }
                musicTab("Текст", icon: "text.quote", selected: section == .lyrics) {
                    section = .lyrics
                }
                .disabled(model.nowPlayingSnapshot == nil)
                musicTab("Очередь", icon: "list.bullet", selected: section == .queue) {
                    section = .queue
                    model.musicLyrics.deactivate()
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            if section == .queue {
                YandexMusicQueuePanel(store: model.musicQueue,
                                      onOpenSettings: model.openAccessibilitySettings)
            } else if let snapshot = model.nowPlayingSnapshot {
                if section == .lyrics {
                    MusicLyricsPanel(store: model.musicLyrics, snapshot: snapshot,
                                     isActive: isVisible,
                                     onSeek: model.nowPlayingSeek,
                                     onTogglePlayPause: model.nowPlayingTogglePlayPause)
                } else {
                    NowPlayingCard(
                        snapshot: snapshot,
                        isActive: isVisible,
                        gesturesEnabled: model.modules.isEnabled(.gestures),
                        onPrevious: model.nowPlayingPreviousTrack,
                        onTogglePlayPause: model.nowPlayingTogglePlayPause,
                        onNext: model.nowPlayingNextTrack,
                        onSeek: model.nowPlayingSeek,
                        onOpenPlayer: model.openNowPlayingApplication
                    )
                }
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
            updateQueueActivity()
            if model.selectedPanel == .music {
                model.refreshNowPlaying()
            }
        }
        .onChange(of: section) { _, _ in updateQueueActivity() }
        .onChange(of: isVisible) { _, _ in updateQueueActivity() }
        .onChange(of: model.selectedPanel) { _, panel in
            if panel == .music {
                model.refreshNowPlaying()
            }
        }
        .onDisappear {
            model.musicLyrics.deactivate()
            model.musicQueue.setActive(false)
        }
    }

    private func updateQueueActivity() {
        model.musicQueue.setActive(isVisible && section == .queue)
    }

    private func musicTab(_ title: String, icon: String, selected: Bool,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 12)
                .frame(minHeight: 40)
                .foregroundStyle(selected ? NotchPalette.text : NotchPalette.secondary)
                .background(selected ? NotchPalette.text.opacity(0.09) : .clear,
                            in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(NotchButtonStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct NowPlayingCard: View {
    let snapshot: NowPlayingSnapshot
    let isActive: Bool
    let gesturesEnabled: Bool
    let onPrevious: () -> Void
    let onTogglePlayPause: () -> Void
    let onNext: () -> Void
    let onSeek: (TimeInterval) -> Void
    let onOpenPlayer: () -> Void

    @ObservedObject private var gestureSettings = NotchGestureSettings.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draggedProgress: Double?
    @State private var volumeFeedback: NotchVolumeAdjustmentResult?
    @State private var volumeFeedbackTask: Task<Void, Never>?

    var body: some View {
        TimelineView(.periodic(from: .now, by: isActive ? 1 : 3_600)) { context in
            let liveElapsed = snapshot.elapsedTime(at: context.date)
            let liveProgress = snapshot.progress(at: context.date)
            let progress = draggedProgress ?? liveProgress
            let elapsed = draggedProgress.map { $0 * snapshot.duration } ?? liveElapsed

            HStack(spacing: 18) {
                NowPlayingArtwork(data: snapshot.artworkData)
                    .background {
                        if isActive && gesturesEnabled {
                            NotchGestureSurface(
                                preferences: gestureSettings.preferences,
                                isCompact: false,
                                onSingleClick: {},
                                onDoubleClick: performGestureAction,
                                onVolume: showVolumeFeedback
                            )
                            .allowsHitTesting(false)
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if let volumeFeedback {
                            Text(volumeFeedback.compactFeedback)
                                .font(.system(size: 9, weight: .semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                                .padding(.horizontal, 5)
                                .frame(maxWidth: 88, minHeight: 18)
                                .background(.regularMaterial, in: Capsule())
                                .allowsHitTesting(false)
                                .accessibilityLabel(volumeFeedback.feedback)
                        }
                    }

                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("СЕЙЧАС ИГРАЕТ")
                            .font(.system(size: 9, weight: .bold, design: .default))
                            .tracking(0.8)
                            .foregroundStyle(NotchPalette.accent)

                        Button(action: onOpenPlayer) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(snapshot.title)
                                    .font(.system(size: 17, weight: .semibold, design: .default))
                                    .foregroundStyle(NotchPalette.text)
                                    .lineLimit(2)

                                Text(snapshot.artist)
                                    .font(.system(size: 12, weight: .medium, design: .default))
                                    .foregroundStyle(NotchPalette.text.opacity(0.6))
                                    .lineLimit(1)

                                if let album = snapshot.album, album.isEmpty == false {
                                    Text(album)
                                        .font(.system(size: 10, weight: .medium, design: .default))
                                        .foregroundStyle(NotchPalette.text.opacity(0.38))
                                        .lineLimit(1)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Открыть приложение-плеер")
                    }

                    VStack(spacing: 3) {
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
                            .tint(NotchPalette.accent)
                            .controlSize(.small)
                            .accessibilityLabel("Позиция трека")
                        } else {
                            ProgressView(value: progress)
                                .tint(NotchPalette.accent)
                                .scaleEffect(y: 0.75)
                        }

                        HStack {
                            Text(formatTime(elapsed))
                            Spacer(minLength: 0)
                            Text(snapshot.duration > 0 ? formatTime(snapshot.duration) : "--:--")
                        }
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(NotchPalette.text.opacity(0.42))
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

                        Spacer(minLength: 4)

                        if let appName = snapshot.appName, appName.isEmpty == false {
                            Text(appName)
                                .font(.system(size: 9, weight: .medium, design: .default))
                                .foregroundStyle(NotchPalette.text.opacity(0.36))
                                .lineLimit(1)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
            .padding(17)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(NotchPalette.text.opacity(0.055))
                    .overlay {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .strokeBorder(NotchPalette.text.opacity(0.09), lineWidth: 0.75)
                    }
            }
            .padding(.horizontal, 16)
            .animation(
                reduceMotion ? .linear(duration: 0.01) : .easeOut(duration: 0.18),
                value: snapshot.id
            )
        }
        .onDisappear {
            volumeFeedbackTask?.cancel()
            volumeFeedbackTask = nil
        }
    }

    private func performGestureAction(_ action: NotchDoubleClickAction) {
        switch action {
        case .disabled: break
        case .playPause: onTogglePlayPause()
        case .nextTrack: onNext()
        case .previousTrack: onPrevious()
        }
    }

    private func showVolumeFeedback(_ result: NotchVolumeAdjustmentResult) {
        volumeFeedback = result
        volumeFeedbackTask?.cancel()
        volumeFeedbackTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
            volumeFeedback = nil
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
                    .foregroundStyle(NotchPalette.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 112, height: 112)
        .background(NotchPalette.text.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .stroke(NotchPalette.text.opacity(0.1), lineWidth: 1)
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
                .foregroundStyle(isPrimary ? Color.white : NotchPalette.text.opacity(0.78))
                .background(
                    isPrimary ? NotchPalette.accent : NotchPalette.text.opacity(0.1),
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
                .foregroundStyle(NotchPalette.accent)

            Text("Ничего не играет")
                .font(.system(size: 17, weight: .semibold, design: .default))
                .foregroundStyle(NotchPalette.text)

            Text(requiresAccessibilityAccess
                 ? "Разрешите NooL App доступ в Настройки → Конфиденциальность и безопасность → Универсальный доступ."
                 : "Включите музыку — текущий трек появится здесь.")
                .font(.system(size: 11, weight: .medium, design: .default))
                .foregroundStyle(NotchPalette.text.opacity(0.42))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 280)

            HStack(spacing: 8) {
                Button(action: onRefresh) {
                    Label("Обновить", systemImage: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold, design: .default))
                        .frame(minWidth: 40, minHeight: 40)
                }
                .buttonStyle(NotchButtonStyle())
                .foregroundStyle(NotchPalette.text.opacity(0.8))
                .accessibilityLabel("Обновить текущий трек")

                if requiresAccessibilityAccess {
                    Button(action: onOpenSettings) {
                        Label("Открыть настройки", systemImage: "gearshape")
                            .font(.system(size: 11, weight: .semibold, design: .default))
                            .frame(minWidth: 40, minHeight: 40)
                    }
                    .buttonStyle(NotchButtonStyle())
                    .foregroundStyle(NotchPalette.accent)
                    .accessibilityLabel("Открыть настройки универсального доступа")
                }
            }
        }
        .padding(20)
    }
}

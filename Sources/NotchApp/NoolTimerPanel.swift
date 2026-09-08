import Foundation
import SwiftUI

/// A single-purpose timer surface for the Live panel. The source owns all
/// scheduling and publishes the current snapshot; this view only renders it.
struct NoolTimerPanel: View {
    @ObservedObject var source: NoolTimerSource
    var onCompact: (() -> Void)?

    @State private var hours = 0
    @State private var minutes = 5
    @State private var seconds = 0

    private let clockOrange = Color(red: 1.0, green: 0.47, blue: 0.16)

    var body: some View {
        Group {
            if let snapshot = source.snapshot {
                runningCard(snapshot: snapshot)
            } else {
                setupCard
            }
        }
        .padding(.top, 2)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .topTrailing) {
            if source.snapshot != nil, let onCompact {
                Button(action: onCompact) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .padding(8)
                .accessibilityLabel("Показать компактный отсчёт")
            }
        }
    }

    private var setupCard: some View {
        HStack(spacing: 8) {
            Image(systemName: "timer")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(clockOrange)
                .accessibilityLabel("Таймер")
            HStack(spacing: 4) {
                timePicker(title: "Часы", unit: "ч", selection: $hours, values: 0...23)
                timePicker(title: "Минуты", unit: "м", selection: $minutes, values: 0...59)
                timePicker(title: "Секунды", unit: "с", selection: $seconds, values: 0...59)
            }
            Spacer(minLength: 8)

            Button(action: startTimer) {
                Image(systemName: "play.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.black.opacity(0.78))
                    .frame(width: 32, height: 32)
                    .background(Color.signalMint, in: Circle())
            }
            .buttonStyle(NotchButtonStyle())
            .disabled(selectedDuration == 0)
            .opacity(selectedDuration == 0 ? 0.38 : 1)
            .accessibilityLabel("Запустить таймер")
        }
        .padding(8)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(clockOrange.opacity(0.18), lineWidth: 0.75)
        }
    }

    private func runningCard(snapshot: NoolTimerSnapshot) -> some View {
        let isCompleted = snapshot.state == .completed
        let progress = timerProgress(remaining: snapshot.remaining, duration: snapshot.duration)

        return HStack(spacing: 12) {
            timerRing(
                progress: isCompleted ? 0 : progress,
                countdown: isCompleted ? "00:00" : snapshot.countdownText,
                isCompleted: isCompleted
            )

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(isCompleted ? "Готово" : snapshot.title)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)

                    Text(statusText(for: snapshot.state))
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(isCompleted ? clockOrange.opacity(0.82) : .white.opacity(0.46))
                }

                Spacer(minLength: 0)

                HStack(spacing: 8) {
                    if isCompleted {
                        Button {
                            source.create(duration: snapshot.duration)
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.black.opacity(0.8))
                                .frame(width: 34, height: 34)
                                .background(clockOrange, in: Circle())
                        }
                        .buttonStyle(NotchButtonStyle())
                        .accessibilityLabel("Запустить таймер заново")
                    } else {
                        Button {
                            source.toggle()
                        } label: {
                            Image(systemName: snapshot.state == .paused ? "play.fill" : "pause.fill")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.black.opacity(0.8))
                                .frame(width: 34, height: 34)
                                .background(clockOrange, in: Circle())
                        }
                        .buttonStyle(NotchButtonStyle())
                        .accessibilityLabel(snapshot.state == .paused ? "Продолжить таймер" : "Поставить таймер на паузу")
                    }

                    Button(action: source.cancel) {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white.opacity(0.74))
                            .frame(width: 34, height: 34)
                            .background(Color.white.opacity(0.12), in: Circle())
                    }
                    .buttonStyle(NotchButtonStyle())
                    .accessibilityLabel("Отменить таймер")
                }
            }

            Color.clear.frame(width: 28, height: 1)
        }
        .padding(8)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(clockOrange.opacity(0.18), lineWidth: 0.75)
        }
    }

    private func timePicker(title: String, unit: String, selection: Binding<Int>, values: ClosedRange<Int>) -> some View {
        JiraDurationWheel(title: title, unit: unit, values: Array(values), selection: selection,
                          rowHeight: 16, accentColor: clockOrange, valueFontSize: 12)
            .frame(width: 52)
    }

    private func timerRing(progress: Double, countdown: String, isCompleted: Bool) -> some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.1), lineWidth: 3)

            Circle()
                .trim(from: 0, to: min(1, max(0.015, progress)))
                .stroke(
                    clockOrange,
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))

            if isCompleted {
                Image(systemName: "checkmark")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(clockOrange)
            } else {
                VStack(spacing: 4) {
                    Text(countdown)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                        .frame(width: 46)
                        .foregroundStyle(.white.opacity(0.94))
                }
            }
        }
        .frame(width: 56, height: 56)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isCompleted ? "Таймер завершён" : "Осталось \(countdown)")
    }

    private var selectedDuration: TimeInterval {
        TimeInterval(hours * 3_600 + minutes * 60 + seconds)
    }

    private func startTimer() {
        guard selectedDuration > 0 else { return }
        source.create(duration: selectedDuration)
    }

    private func timerProgress(remaining: TimeInterval, duration: TimeInterval) -> Double {
        guard duration > 0 else { return 0 }
        return remaining / duration
    }

    private func statusText(for state: LiveActivityState) -> String {
        switch state {
        case .active: "идёт"
        case .paused: "на паузе"
        case .completed: ""
        case .notification: "готово"
        }
    }
}

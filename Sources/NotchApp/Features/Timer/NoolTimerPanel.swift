import Foundation
import SwiftUI

struct NoolTimerPanel: View {
    @ObservedObject var source: NoolTimerSource
    var onCompact: (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var mode: NoolTimerMode = .timer
    @State private var hours = 0
    @State private var minutes = 5
    @State private var seconds = 0
    @State private var focusMinutes = 25
    @State private var breakMinutes = 5
    @State private var longBreakMinutes = 15
    @State private var rounds = 4
    @State private var showsExactDuration = false
    @State private var showsExactEditor = false

    private let accent = Color.signalMint

    var body: some View {
        VStack(spacing: 0) {
            if let snapshot = source.snapshot {
                runningCard(snapshot)
            } else {
                setupCard
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(NotchPalette.text.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 18))
        .onAppear {
            if let snapshot = source.snapshot { mode = snapshot.mode }
        }
    }

    private var setupCard: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                modeMenu

                if mode == .stopwatch {
                    Image(systemName: "stopwatch")
                        .font(.system(size: 18, weight: .light))
                        .foregroundStyle(accent)
                        .frame(minWidth: 80, maxWidth: .infinity, minHeight: 40)
                        .accessibilityHidden(true)
                } else if mode == .timer && showsExactDuration {
                    Text("Точное")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(NotchPalette.secondary)
                        .frame(minWidth: 80, maxWidth: .infinity, minHeight: 40)
                } else {
                    TimerDurationRuler(minutes: rulerMinutes)
                        .frame(minWidth: 80, maxWidth: .infinity)
                }

                Text(setupClock)
                    .font(.system(size: 23, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(accent)
                    .fixedSize()
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: setupClock)

                if mode == .timer {
                    Button(action: selectExactDuration) {
                        Image(systemName: showsExactDuration ? "ruler" : "clock")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(showsExactDuration ? accent : NotchPalette.secondary)
                            .frame(width: 40, height: 40)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(NotchButtonStyle())
                    .accessibilityLabel("Точная длительность: часы, минуты и секунды")
                    .help("Точная длительность")
                }

                Button(action: start) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(accent)
                        .frame(width: 40, height: 40)
                        .background(accent.opacity(0.13), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(NotchButtonStyle())
                .disabled(mode == .timer && selectedDuration == 0)
                .accessibilityLabel("Запустить \(title(mode).lowercased())")
                .accessibilityHint(mode == .pomodoro ? "Следующий этап запускается вручную по кнопке." : "")
                .help(mode == .pomodoro ? "Следующий этап запускается вручную по кнопке" : "Запустить \(title(mode).lowercased())")
            }

            if mode == .timer && showsExactEditor {
                exactDurationEditor
            }

            if mode == .pomodoro {
                HStack(spacing: 8) {
                    setting("Перерыв", selection: $breakMinutes, values: [1, 3, 5, 10, 15], suffix: "м")
                    setting("Длинный", selection: $longBreakMinutes, values: [5, 10, 15, 20, 30], suffix: "м")
                    setting("Через", selection: $rounds, values: [2, 3, 4, 5, 6], suffix: "фокуса")
                }
            }
        }
    }

    private var modeMenu: some View {
        Menu {
            ForEach([NoolTimerMode.timer, .pomodoro, .stopwatch], id: \.self) { candidate in
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { mode = candidate }
                } label: {
                    if mode == candidate {
                        Label(title(candidate), systemImage: "checkmark")
                    } else {
                        Text(title(candidate))
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(title(mode))
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(NotchPalette.text)
            .padding(.horizontal, 8)
            .frame(height: 40)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: true, vertical: false)
        .buttonStyle(NotchButtonStyle())
        .accessibilityLabel("Режим таймера: \(title(mode))")
        .accessibilityHint("Выбрать режим")
    }

    private var exactDurationEditor: some View {
        VStack(spacing: 8) {
            Text("Точная длительность")
                .font(.system(size: 12, weight: .semibold))
            HStack(spacing: 4) {
                timePicker("Часы", unit: "ч", selection: $hours, values: 0...23)
                timePicker("Минуты", unit: "м", selection: $minutes, values: 0...59)
                timePicker("Секунды", unit: "с", selection: $seconds, values: 0...59)
            }
            HStack {
                Button("Линейка минут") {
                    let totalMinutes = Int(selectedDuration / 60)
                    hours = 0
                    minutes = min(120, max(1, totalMinutes))
                    seconds = 0
                    showsExactDuration = false
                    showsExactEditor = false
                }
                .buttonStyle(NotchButtonStyle())
                Spacer()
                Button("Готово") { showsExactEditor = false }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(NotchButtonStyle())
            }
            .font(.system(size: 11, weight: .medium))
        }
        .padding(12)
        .frame(width: 230)
    }

    private func selectExactDuration() {
        if !showsExactDuration {
            hours = minutes / 60
            minutes %= 60
            seconds = 0
            showsExactDuration = true
        }
        showsExactEditor = true
    }

    private func runningCard(_ snapshot: NoolTimerSnapshot) -> some View {
        let completed = snapshot.state == .completed
        let stopwatch = snapshot.mode == .stopwatch
        let progress = stopwatch
            ? snapshot.elapsed.truncatingRemainder(dividingBy: 60) / 60
            : (snapshot.duration > 0 ? snapshot.remaining / snapshot.duration : 0)

        return HStack(spacing: 8) {
            ZStack {
                Circle().stroke(NotchPalette.track, lineWidth: 4)
                Circle()
                    .trim(from: 0, to: min(1, max(0, progress)))
                    .stroke(accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(reduceMotion || stopwatch ? nil : .linear(duration: 0.8), value: progress)
                Image(systemName: completed ? "checkmark" : snapshot.state == .paused ? "pause.fill" : stopwatch ? "stopwatch" : "timer")
                    .font(.system(size: 16, weight: .light))
                    .foregroundStyle(accent)
            }
            .frame(width: 32, height: 32)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(completed ? "\(snapshot.title): готово" : snapshot.title)
                        .font(.system(size: 10, weight: .semibold))
                        .lineLimit(1)
                    if snapshot.mode == .pomodoro {
                        Text("· Фокус №\(snapshot.pomodoroRound)")
                            .font(.system(size: 9))
                            .foregroundStyle(NotchPalette.secondary)
                            .lineLimit(1)
                    }
                }
                Text(snapshot.countdownText)
                    .font(.system(size: 23, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: !stopwatch))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: snapshot.countdownText)
            }
            Spacer(minLength: 0)
            if let onCompact, !completed {
                action("chevron.up", label: "Показать компактный отсчёт", perform: onCompact)
            }
            if completed && snapshot.mode == .pomodoro {
                Button(snapshot.pomodoroPhase == .focus ? "Начать перерыв" : "Начать фокус") {
                    source.advancePomodoro()
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(accent)
                .padding(.horizontal, 8)
                .frame(height: 40)
                .background(accent.opacity(0.13), in: Capsule())
                .buttonStyle(NotchButtonStyle())
            } else if !completed {
                action(snapshot.state == .paused ? "play.fill" : "pause.fill",
                       label: snapshot.state == .paused ? "Продолжить" : "Пауза",
                       prominent: true, perform: source.toggle)
            }
            action("arrow.counterclockwise", label: "Начать заново", perform: source.restart)
            action("xmark", label: "Завершить и выбрать режим", perform: source.cancel)
        }
    }

    private func action(_ icon: String, label: String, prominent: Bool = false, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(prominent ? accent : NotchPalette.secondary)
                .frame(width: 40, height: 40)
                .background((prominent ? accent : NotchPalette.text).opacity(0.09), in: Circle())
        }
        .buttonStyle(NotchButtonStyle())
        .accessibilityLabel(label)
        .help(label)
    }

    private func setting(_ name: String, selection: Binding<Int>, values: [Int], suffix: String) -> some View {
        HStack(spacing: 4) {
            Text(name).font(.system(size: 9)).foregroundStyle(NotchPalette.secondary).lineLimit(1)
            Picker(name, selection: selection) {
                ForEach(values, id: \.self) { Text("\($0) \(suffix)").tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .font(.system(size: 10))
            .frame(minHeight: 40)
        }
        .frame(maxWidth: .infinity)
    }

    private func timePicker(_ name: String, unit: String, selection: Binding<Int>, values: ClosedRange<Int>) -> some View {
        JiraDurationWheel(title: name, unit: unit, values: Array(values), selection: selection,
                          rowHeight: 16, accentColor: accent, valueFontSize: 12)
            .frame(width: 46)
    }

    private var rulerMinutes: Binding<Int> {
        Binding(
            get: { mode == .pomodoro ? focusMinutes : minutes },
            set: { value in
                if mode == .pomodoro { focusMinutes = value }
                else { hours = 0; minutes = value; seconds = 0 }
            }
        )
    }

    private var selectedDuration: TimeInterval { TimeInterval(hours * 3600 + minutes * 60 + seconds) }
    private var setupClock: String {
        let duration = mode == .stopwatch ? 0 : mode == .pomodoro ? focusMinutes * 60 : Int(selectedDuration)
        return duration >= 3600
            ? String(format: "%d:%02d:%02d", duration / 3600, duration / 60 % 60, duration % 60)
            : String(format: "%02d:%02d", duration / 60, duration % 60)
    }

    private func title(_ mode: NoolTimerMode) -> String {
        switch mode {
        case .timer: "Таймер"
        case .pomodoro: "Pomodoro"
        case .stopwatch: "Секундомер"
        }
    }

    private func start() {
        switch mode {
        case .timer: source.create(duration: selectedDuration)
        case .pomodoro:
            source.startPomodoro(focusDuration: TimeInterval(focusMinutes * 60),
                                 shortBreakDuration: TimeInterval(breakMinutes * 60),
                                 longBreakDuration: TimeInterval(longBreakMinutes * 60),
                                 sessionsBeforeLongBreak: rounds)
        case .stopwatch: source.startStopwatch()
        }
    }
}

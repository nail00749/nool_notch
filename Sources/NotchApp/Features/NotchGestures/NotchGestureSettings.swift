import Combine
import SwiftUI

enum NotchDoubleClickAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case disabled
    case playPause
    case nextTrack
    case previousTrack

    var id: Self { self }

    var title: String {
        switch self {
        case .disabled: "Выключено"
        case .playPause: "Пауза или воспроизведение"
        case .nextTrack: "Следующий трек"
        case .previousTrack: "Предыдущий трек"
        }
    }
}

struct NotchGesturePreferences: Codable, Equatable, Sendable {
    var scrollVolumeEnabled = false
    var doubleClickAction: NotchDoubleClickAction = .disabled
    var volumeStep = 0.04

    var sanitized: Self {
        var result = self
        result.volumeStep = volumeStep.isFinite ? min(max(volumeStep, 0.01), 0.10) : 0.04
        return result
    }
}

@MainActor
final class NotchGestureSettings: ObservableObject {
    static let shared = NotchGestureSettings()
    static let preferencesKey = "nool.notchGestures.preferences.v1"

    @Published private(set) var preferences: NotchGesturePreferences
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        preferences = defaults.data(forKey: Self.preferencesKey).flatMap {
            try? JSONDecoder().decode(NotchGesturePreferences.self, from: $0)
        }?.sanitized ?? NotchGesturePreferences()
    }

    func setPreferences(_ value: NotchGesturePreferences) {
        let value = value.sanitized
        guard value != preferences else { return }
        preferences = value
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: Self.preferencesKey)
        }
    }
}

@MainActor
final class NotchGestureInteraction: ObservableObject {
    static let shared = NotchGestureInteraction()
    @Published private(set) var isResolvingCompactClick = false

    func setResolvingCompactClick(_ value: Bool) {
        isResolvingCompactClick = value
    }
}

struct NotchGestureSettingsView: View {
    @ObservedObject var settings: NotchGestureSettings

    var body: some View {
        VStack(spacing: 12) {
            SettingsCard(title: "Жесты на чёлке", icon: "hand.point.up.left") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Прокрутка меняет громкость", isOn: preference(\.scrollVolumeEnabled))
                        .frame(minHeight: 40)
                    Text("Прокручивайте вверх или вниз по компактной чёлке. В разделе «Музыка» жест работает только на обложке альбома.")
                        .settingsHintStyle()
                    Picker("Шаг громкости", selection: preference(\.volumeStep)) {
                        Text("2 %").tag(0.02)
                        Text("4 %").tag(0.04)
                        Text("6 %").tag(0.06)
                        Text("10 %").tag(0.10)
                    }
                    .disabled(!settings.preferences.scrollVolumeEnabled)
                }
            }

            SettingsCard(title: "Двойной щелчок", icon: "hand.tap") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Действие", selection: preference(\.doubleClickAction)) {
                        ForEach(NotchDoubleClickAction.allCases) { action in
                            Text(action.title).tag(action)
                        }
                    }
                    Text("Один щелчок по компактной чёлке открывает NooL App. Когда двойной щелчок включён, первый щелчок ждёт системный интервал, чтобы отличить его от второго.")
                        .settingsHintStyle()
                }
            }

            Text("Оба жеста выключены по умолчанию. Громкость меняется через системное аудиоустройство; некоторые HDMI и цифровые выходы не поддерживают её регулировку.")
                .settingsHintStyle()
        }
        .font(.system(size: 12))
    }

    private func preference<T>(_ keyPath: WritableKeyPath<NotchGesturePreferences, T>) -> Binding<T> {
        Binding(get: { settings.preferences[keyPath: keyPath] }, set: { newValue in
            var value = settings.preferences
            value[keyPath: keyPath] = newValue
            settings.setPreferences(value)
        })
    }
}

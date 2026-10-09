import SwiftUI

/// The built-in feature catalog. Turning a module off keeps its own preferences intact.
struct AppModulesSettingsView: View {
    @ObservedObject var modules: AppModuleStore
    let openSettings: (NotchSettingsSection) -> Void

    @State private var searchText = ""
    @State private var showsPresets = false

    private var matchingModules: [AppModuleID] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return AppModuleID.allCases }
        return AppModuleID.allCases.filter { module in
            ([module.title, module.subtitle, module.permissionSummary ?? ""] + module.surfaces)
                .contains { $0.localizedStandardContains(query) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsCard(title: "Соберите свой NooL", icon: "square.grid.2x2") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("\(modules.enabledModules.count) из \(AppModuleID.allCases.count) включено")
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()

                    Text("Launcher, основные настройки и обновления доступны всегда. При выключении модуля его настройки и данные сохраняются.")
                        .settingsHintStyle()

                    DisclosureGroup("Готовые наборы", isExpanded: $showsPresets) {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(AppModulePreset.allCases) { preset in
                                HStack(alignment: .top, spacing: 8) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("\(preset.title) · \(preset.modules.count) мод.")
                                            .font(.system(size: 11, weight: .semibold))
                                        Text(preset.subtitle)
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(NotchPalette.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer(minLength: 0)
                                    Button("Применить") { modules.applyPreset(preset) }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                        .accessibilityLabel("Применить набор \(preset.title)")
                                }
                            }
                        }
                        .padding(.top, 8)
                    }
                    .font(.system(size: 11, weight: .medium))
                }
            }

            TextField("Найти модуль", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Поиск модулей")

            if matchingModules.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .frame(maxWidth: .infinity)
            } else {
                ForEach(matchingModules) { module in
                    moduleCard(module)
                }
            }
        }
    }

    private func moduleCard(_ module: AppModuleID) -> some View {
        SettingsCard(title: module.title, icon: module.iconName) {
            VStack(alignment: .leading, spacing: 9) {
                Text(module.subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(NotchPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !module.surfaces.isEmpty {
                    Text(module.surfaces.joined(separator: " · "))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(NotchPalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let permission = module.permissionSummary {
                    Label(permission, systemImage: "hand.raised")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(NotchPalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Toggle(module.title, isOn: Binding(
                        get: { modules.isEnabled(module) },
                        set: { modules.setEnabled(module, enabled: $0) }
                    ))
                    .labelsHidden()
                    .accessibilityLabel("\(modules.isEnabled(module) ? "Выключить" : "Включить") \(module.title)")

                    Text(modules.isEnabled(module) ? "Включён" : "Выключен")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(modules.isEnabled(module) ? NotchPalette.accent : NotchPalette.secondary)

                    Spacer(minLength: 8)

                    if modules.isEnabled(module),
                       let section = NotchSettingsSection.settingsSection(for: module) {
                        Button("Настроить") { openSettings(section) }
                            .buttonStyle(.borderless)
                            .font(.system(size: 11, weight: .medium))
                            .accessibilityLabel("Настроить \(module.title)")
                    }
                }
                .frame(minHeight: 30)
            }
        }
    }
}

import AppKit
import Darwin
import SwiftUI

/// A compact utility window for applying and saving common window arrangements.
/// Placement and Accessibility work remain in `WindowLayoutManager`.
struct WindowLayoutsView: View {
    @ObservedObject var manager: WindowLayoutManager
    let targetPID: pid_t?

    @State private var isBusy = false
    @State private var message: String?
    @State private var layoutName = ""

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                if manager.hasAccessibilityAccess {
                    actionGrid.disabled(manager.isBusy)
                    saveSection.disabled(manager.isBusy)
                    savedLayoutsSection.disabled(manager.isBusy)
                } else {
                    accessRequired
                }

                if let message {
                    statusMessage(message)
                }
            }
            .padding(22)
        }
        .frame(minWidth: 580, minHeight: 480)
        .background(NotchPalette.surface)
        .foregroundStyle(NotchPalette.text)
        .tint(NotchPalette.accent)
        .preferredColorScheme(.dark)
        .onAppear(perform: manager.refreshAccessibilityAccess)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            manager.refreshAccessibilityAccess()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "rectangle.split.2x1")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(NotchPalette.accent)
                .frame(width: 42, height: 42)
                .background(NotchPalette.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 13, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text("Раскладки окон")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                Text(targetPID == nil
                     ? "Расположите активное окно на экране."
                     : "Расположите окно выбранного приложения.")
                    .font(.system(size: 12))
                    .foregroundStyle(NotchPalette.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var accessRequired: some View {
        VStack(alignment: .leading, spacing: 13) {
            Label("Нужен доступ в разделе «Универсальный доступ»", systemImage: "hand.raised.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(NotchPalette.text)

            Text("Для этой функции Nool нужен доступ к положению и размеру окон. Разрешите приложение в разделе «Универсальный доступ» настроек macOS.")
                .font(.system(size: 12))
                .foregroundStyle(NotchPalette.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Открыть настройки доступа") {
                manager.requestAccess()
            }
            .buttonStyle(.borderedProminent)
            .tint(NotchPalette.accent)
            .disabled(isBusy)
            .accessibilityHint("Открывает настройки Универсального доступа macOS")
        }
        .padding(16)
        .background(NotchPalette.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var actionGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Быстрая раскладка")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(NotchPalette.text)

            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(WindowLayoutAction.allCases, id: \.self) { action in
                    Button {
                        perform(action)
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: action.systemImage)
                                .font(.system(size: 13, weight: .semibold))
                                .frame(width: 20)
                            Text(action.title)
                                .font(.system(size: 12, weight: .semibold))
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(isBusy ? NotchPalette.secondary : NotchPalette.text)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(NotchPalette.raised.opacity(isBusy ? 0.45 : 0.9), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(isBusy)
                    .accessibilityLabel(action.title)
                }
            }
        }
    }

    private var saveSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Сохранить текущую раскладку")
                .font(.system(size: 13, weight: .semibold))

            HStack(spacing: 9) {
                TextField("Например, Разработка", text: $layoutName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 11)
                    .frame(height: 34)
                    .background(NotchPalette.surface.opacity(0.65), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(NotchPalette.separator, lineWidth: 1)
                    }
                    .accessibilityLabel("Название раскладки")

                Button("Сохранить", action: saveLayout)
                    .buttonStyle(.borderedProminent)
                    .tint(NotchPalette.accent)
                    .disabled(isBusy || layoutName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
        .background(NotchPalette.raised.opacity(0.72), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var savedLayoutsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Сохранённые")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(manager.layouts.count)")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(NotchPalette.secondary)
            }

            if manager.layouts.isEmpty {
                Text("Сохраните расположение окон, чтобы быстро восстановить его позже.")
                    .font(.system(size: 12))
                    .foregroundStyle(NotchPalette.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 7) {
                    ForEach(manager.layouts, id: \.id) { layout in
                        HStack(spacing: 10) {
                            Image(systemName: "rectangle.3.group")
                                .foregroundStyle(NotchPalette.accent)
                                .frame(width: 22, height: 22)
                                .background(NotchPalette.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                            VStack(alignment: .leading, spacing: 2) {
                                Text(layout.name)
                                    .font(.system(size: 12, weight: .semibold))
                                    .lineLimit(1)
                                Text("\(layout.windows.count) \(windowCountText(layout.windows.count))")
                                    .font(.system(size: 10))
                                    .foregroundStyle(NotchPalette.secondary)
                            }
                            Spacer(minLength: 0)

                            Button("Восстановить") {
                                restore(layout.id)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(isBusy)

                            Button(role: .destructive) {
                                manager.removeLayout(id: layout.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .disabled(isBusy)
                            .accessibilityLabel("Удалить раскладку \(layout.name)")
                        }
                        .padding(10)
                        .background(NotchPalette.surface.opacity(0.62), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                }
            }
        }
    }

    private func statusMessage(_ text: String) -> some View {
        Label(text, systemImage: "info.circle.fill")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(NotchPalette.text.opacity(0.84))
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(NotchPalette.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private func perform(_ action: WindowLayoutAction) {
        guard !isBusy else { return }
        isBusy = true
        message = nil
        Task { @MainActor in
            message = await manager.perform(action, targetPID: targetPID)
            isBusy = false
        }
    }

    private func saveLayout() {
        let name = layoutName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isBusy, !name.isEmpty else { return }
        isBusy = true
        message = nil
        Task { @MainActor in
            message = await manager.saveLayout(name: name)
            layoutName = ""
            isBusy = false
        }
    }

    private func restore(_ id: UUID) {
        guard !isBusy else { return }
        isBusy = true
        message = nil
        Task { @MainActor in
            message = await manager.restoreLayout(id: id)
            isBusy = false
        }
    }

    private func windowCountText(_ count: Int) -> String {
        let remainder = count % 100
        if (11...14).contains(remainder) { return "окон" }
        switch count % 10 {
        case 1: return "окно"
        case 2...4: return "окна"
        default: return "окон"
        }
    }
}

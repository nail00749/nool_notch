import AppKit
import ApplicationServices
import SwiftUI

struct FinderConversionRadialView: View {
    @ObservedObject var model: FinderConversionModel
    let close: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false
    @State private var hoveredFormat: FileConversionFormat?

    var body: some View {
        ZStack {
            Circle()
                .fill(.black.opacity(reduceTransparency ? 1 : 0.86))
                .background {
                    if !reduceTransparency { NativePanelBackground(material: .popover).clipShape(Circle()) }
                }
                .overlay { Circle().strokeBorder(.white.opacity(0.14), lineWidth: 1) }
                .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
                .padding(12)

            VStack(spacing: 7) {
                if model.isRunning || model.isPreparing {
                    ProgressView().controlSize(.small)
                    Text(model.isRunning ? model.progressMessage : "Читаю форматы…")
                } else if !model.outputs.isEmpty {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 28)).foregroundStyle(.green)
                    Text("Готово: \(model.outputs.count)")
                    Button("Показать в Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(model.outputs)
                        close()
                    }.buttonStyle(.plain).foregroundStyle(.white)
                } else if let error = model.error {
                    Image(systemName: "exclamationmark.circle").font(.system(size: 24)).foregroundStyle(.orange)
                    Text(error).font(.system(size: 11)).lineLimit(5)
                } else {
                    Image(systemName: "doc").font(.system(size: 29, weight: .light))
                    Text(model.title).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                    Text("Выберите формат").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                }
                Button(model.isRunning ? "Отменить" : "Закрыть", action: close)
                    .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
            }
            .font(.system(size: 12, weight: .medium))
            .multilineTextAlignment(.center)
            .frame(width: 146)

            if !model.isRunning, !model.isPreparing, model.outputs.isEmpty, model.error == nil {
                ForEach(Array(model.formats.enumerated()), id: \.element.id) { index, format in
                    ConversionPetalButton(title: format.title, index: index, count: model.formats.count,
                                          highlighted: hoveredFormat == format) { model.convert(to: format) }
                }
            }
        }
        .frame(width: 344, height: 344)
        .onContinuousHover { phase in
            switch phase {
            case .active(let point):
                hoveredFormat = model.formats.enumerated().first { index, _ in
                    ConversionPetal(index: index, count: model.formats.count)
                        .path(in: CGRect(x: 0, y: 0, width: 344, height: 344)).contains(point)
                }?.element
            case .ended: hoveredFormat = nil
            }
        }
        .scaleEffect(revealed || reduceMotion ? 1 : 0.025, anchor: .center)
        .opacity(revealed ? 1 : 0)
        .allowsHitTesting(revealed)
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .task {
            // Let AppKit place the fixed-size panel before animating its contents.
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? .easeOut(duration: 0.14) : .spring(response: 0.34, dampingFraction: 0.86)) {
                revealed = true
            }
        }
        .onExitCommand(perform: close)
    }
}

/// The visible petal and its hit area use the same annular path, keeping the
/// centre and the narrow gaps available to the controls underneath.
struct ConversionPetal: Shape {
    let index: Int
    let count: Int

    var centerAngle: Double { Double(index) * 2 * .pi / Double(max(1, count)) - .pi / 2 }

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let scale = min(rect.width, rect.height) / 344
        let outer = 156 * scale
        let inner = 91 * scale
        let half = .pi / Double(max(1, count)) - 0.018
        let start = centerAngle - half
        let end = centerAngle + half
        var path = Path()
        path.addArc(center: center, radius: outer, startAngle: .radians(start), endAngle: .radians(end), clockwise: false)
        path.addLine(to: CGPoint(x: center.x + cos(end) * inner, y: center.y + sin(end) * inner))
        path.addArc(center: center, radius: inner, startAngle: .radians(end), endAngle: .radians(start), clockwise: true)
        path.closeSubpath()
        return path
    }
}

private struct ConversionPetalButton: View {
    let title: String
    let index: Int
    let count: Int
    let highlighted: Bool
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var petal: ConversionPetal { ConversionPetal(index: index, count: count) }

    var body: some View {
        Button(action: action) {
            ZStack {
                petal.fill(highlighted ? Color.white : Color.white.opacity(0.09))
                petal.stroke(.white.opacity(highlighted ? 0.7 : 0.13), style: StrokeStyle(lineWidth: 0.7, lineJoin: .round))
                Text(title).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(highlighted ? .black : .white)
                    .offset(x: cos(petal.centerAngle) * 125, y: sin(petal.centerAngle) * 125)
            }
            .frame(width: 344, height: 344)
            .contentShape(petal)
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: highlighted)
        .accessibilityLabel("Конвертировать в \(title)")
    }
}

struct FinderConversionSettingsView: View {
    @ObservedObject private var preferences = FinderConversionPreferences.shared
    @State private var trusted = AXIsProcessTrusted()
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Toggle("Конвертация в Finder", isOn: $preferences.enabled)
                .toggleStyle(.switch)
            Text("Выделите файлы в Finder и удерживайте клавишу над одним из них. Отпустите её и выберите формат в радиальном меню.")
                .font(.callout).foregroundStyle(.secondary)
            Picker("Клавиша вызова", selection: $preferences.modifier) {
                ForEach(FinderConversionModifier.allCases) { modifier in
                    Text(modifier.title).tag(modifier)
                }
            }.pickerStyle(.segmented)
            Text("Результаты сохраняются рядом с исходниками под новыми именами. Исходные файлы остаются на месте.")
                .font(.callout).foregroundStyle(.secondary)
            Divider()
            Label(trusted ? "Универсальный доступ разрешён" : "Нужен универсальный доступ",
                  systemImage: trusted ? "checkmark.shield" : "lock.shield")
            if !trusted {
                Text("Он нужен, чтобы определить выделенные файлы и файл под указателем в Finder.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Разрешить универсальный доступ") {
                    trusted = AXIsProcessTrustedWithOptions(
                        ["AXTrustedCheckOptionPrompt": true] as CFDictionary)
                }
            }
            Text("Изображения · PDF и Word · Markdown · аудио и видео")
                .font(.callout.weight(.medium))
            Text("Меню показывает общие форматы для всех выделенных файлов. Некоторые кодеки и защищённые файлы не поддерживаются.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Документы сохраняют базовое текстовое оформление. Сложная вёрстка Word может измениться. PDF-сканы распознаются автоматически на устройстве, до 40 страниц со сканами в одном файле.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            trusted = AXIsProcessTrusted()
        }
    }
}

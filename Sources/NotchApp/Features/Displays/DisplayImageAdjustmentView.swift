import SwiftUI

struct DisplayImageAdjustmentView: View {
    @ObservedObject var model: DisplayFeatureModel
    let display: DisplayInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button { model.adjustingDisplayUUID = nil } label: {
                    Image(systemName: "chevron.left").frame(width: 26, height: 28)
                }
                .buttonStyle(.plain).accessibilityLabel("Назад к дисплеям")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Коррекция изображения").font(.system(size: 12, weight: .semibold))
                    Text(display.name).font(.system(size: 10))
                        .foregroundStyle(DisplayControlTheme.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Button("Сбросить") { model.setImageAdjustment(.neutral, for: display) }
                    .buttonStyle(DisplayActionStyle())
                    .disabled(model.imageAdjustment(for: display).isNeutral)
            }
            VStack(spacing: 8) {
                adjustmentRow("Гамма", symbol: "circle.lefthalf.filled", keyPath: \.gamma, range: 0.5...2)
                adjustmentRow("Контраст", symbol: "circle.righthalf.filled", keyPath: \.contrast, range: 0.5...1.5)
                adjustmentRow("Температура", symbol: "thermometer.medium", keyPath: \.temperature, range: -1...1,
                              lowerLabel: "Холоднее", upperLabel: "Теплее")
            }
            .padding(10)
            .background(DisplayControlTheme.field.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))

            VStack(spacing: 8) {
                adjustmentRow("Красный", symbol: "r.circle", keyPath: \.red, range: 0...1)
                adjustmentRow("Зелёный", symbol: "g.circle", keyPath: \.green, range: 0...1)
                adjustmentRow("Синий", symbol: "b.circle", keyPath: \.blue, range: 0...1)
            }
            .padding(10)
            .background(DisplayControlTheme.field.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
            Text("Изменения видны сразу. «Сбросить» возвращает нейтральные значения.")
                .font(.system(size: 9)).foregroundStyle(DisplayControlTheme.secondary)
                .lineLimit(2)
        }
        .padding(12)
        .background(DisplayControlTheme.card, in: RoundedRectangle(cornerRadius: 18))
        .disabled(!display.isEnabled || model.isPending || model.isApplyingPreset)
    }

    private func adjustmentRow(_ title: String, symbol: String,
                               keyPath: WritableKeyPath<DisplayImageAdjustment, Double>, range: ClosedRange<Double>,
                               lowerLabel: String? = nil, upperLabel: String? = nil) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 11)).frame(width: 15)
                    .foregroundStyle(DisplayControlTheme.secondary)
                Text(title).font(.system(size: 10, weight: .medium)).frame(width: 76, alignment: .leading)
                Slider(value: binding(keyPath), in: range)
                    .tint(.white).controlSize(.small)
                    .accessibilityLabel("\(title): \(display.name)")
                Text(model.imageAdjustment(for: display)[keyPath: keyPath], format: .number.precision(.fractionLength(2)))
                    .font(.system(size: 10, weight: .medium)).monospacedDigit()
                    .foregroundStyle(DisplayControlTheme.secondary).frame(width: 34, alignment: .trailing)
            }
            .frame(minHeight: 24)
            if let lowerLabel, let upperLabel {
                HStack {
                    Text(lowerLabel)
                    Spacer()
                    Text(upperLabel)
                }
                .font(.system(size: 8)).foregroundStyle(DisplayControlTheme.secondary)
                .padding(.leading, 107).padding(.trailing, 42)
            }
        }
    }

    private func binding(_ keyPath: WritableKeyPath<DisplayImageAdjustment, Double>) -> Binding<Double> {
        Binding(get: { model.imageAdjustment(for: display)[keyPath: keyPath] }, set: { value in
            var adjustment = model.imageAdjustment(for: display)
            adjustment[keyPath: keyPath] = value
            model.setImageAdjustment(adjustment, for: display)
        })
    }
}

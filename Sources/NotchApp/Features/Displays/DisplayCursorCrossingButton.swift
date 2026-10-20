import AppKit
import SwiftUI

struct DisplayCursorCrossingButton: View {
    @ObservedObject var model: DisplayCursorCrossingModel
    var isDisabled = false

    private var symbol: String {
        NSImage(systemSymbolName: "cursorarrow.motionlines", accessibilityDescription: nil) == nil
            ? "cursorarrow" : "cursorarrow.motionlines"
    }

    var body: some View {
        Button { model.setEnabled(!model.isEnabled) } label: {
            HStack(spacing: 5) {
                Label("Переход курсора", systemImage: symbol)
                    .lineLimit(1).minimumScaleFactor(0.9)
                if model.errorMessage != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                }
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(model.isEnabled ? Color.black : Color.white)
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 38)
            .background(model.isEnabled ? Color.white : DisplayControlTheme.card,
                        in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .frame(minWidth: 0, maxWidth: .infinity)
        .disabled(isDisabled)
        .help("Переход курсора через несовпадающие края дисплеев. \(model.statusDescription)")
        .accessibilityLabel("Переход курсора через несовпадающие края дисплеев")
        .accessibilityValue(model.isEnabled ? "Включено" : "Выключено")
        .accessibilityHint(model.statusDescription)
    }
}

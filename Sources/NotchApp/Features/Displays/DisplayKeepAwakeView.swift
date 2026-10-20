import SwiftUI

struct DisplayKeepAwakeView: View {
    @ObservedObject var model: DisplayKeepAwakeModel
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Menu {
                Text(model.isActive ? "Продлить режим бодрствования" : "Не давать Mac уснуть")
                ForEach([15, 30, 60, 120], id: \.self) { minutes in
                    Button("На \(minutes) мин") { model.start(minutes: minutes) }
                }
                Button("До выключения вручную") { model.start(minutes: nil) }
                Divider()
                Toggle("Не выключать экраны", isOn: Binding(
                    get: { model.keepsDisplaysAwake },
                    set: { model.setKeepsDisplaysAwake($0) }
                ))
                if model.isActive {
                    Divider()
                    Button("Выключить режим", action: model.stop)
                }
            } label: {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    HStack(spacing: compact ? 6 : 9) {
                        Image(systemName: "cup.and.saucer.fill")
                            .font(.system(size: 13)).foregroundStyle(model.isActive ? .white : DisplayControlTheme.secondary)
                        if compact {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Не спать").font(.system(size: 9, weight: .semibold))
                                Text(model.isActive ? remaining(at: context.date) : "Выкл")
                                    .font(.system(size: 8)).monospacedDigit()
                                    .foregroundStyle(DisplayControlTheme.secondary)
                            }
                            .lineLimit(1)
                            Spacer(minLength: 0)
                        } else {
                            Text(model.isActive ? "Mac не уснёт" : "Не давать Mac уснуть")
                                .font(.system(size: 11, weight: .medium))
                            Spacer(minLength: 8)
                        }
                        if model.isActive && !compact {
                            Text(remaining(at: context.date)).font(.system(size: 10)).monospacedDigit()
                                .foregroundStyle(DisplayControlTheme.secondary)
                            Circle().fill(.white).frame(width: 5, height: 5)
                        }
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(DisplayControlTheme.secondary)
                    }
                    .padding(.horizontal, compact ? 8 : 12).frame(height: 38)
                    .background(DisplayControlTheme.card, in: RoundedRectangle(cornerRadius: 12))
                    .contentShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .displayMenuStyle()
            .accessibilityLabel(model.isActive ? "Mac не уснёт. Настроить или выключить" : "Не давать Mac уснуть")
            if let error = model.errorMessage {
                Text(error).font(.system(size: 9)).foregroundStyle(.orange).lineLimit(2)
                    .padding(.horizontal, 4)
            }
        }
    }

    private func remaining(at date: Date) -> String {
        guard let expiresAt = model.expiresAt else { return "Вручную" }
        let minutes = max(0, Int(ceil(expiresAt.timeIntervalSince(date) / 60)))
        return minutes > 0 ? "\(minutes) мин" : "Завершение…"
    }
}

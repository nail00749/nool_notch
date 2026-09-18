import SwiftUI

struct AIPanel: View {
    @ObservedObject var model: NotchViewModel

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                sectionPicker
                    .frame(maxWidth: .infinity)
                HStack {
                    inboxStatusCounts
                    Spacer()
                }
            }
            .padding(.horizontal, 22)

            Group {
                switch model.selectedAISection {
                case .limits:
                    LimitsPanel(model: model)
                case .sessions:
                    AISessionsPanel(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var inboxStatusCounts: some View {
        HStack(spacing: 3) {
            AIStatusCount(
                count: model.aiSessions.filter(\.status.needsAttention).count,
                color: .signalAmber,
                label: "Нужно внимание"
            )
            AIStatusCount(
                count: model.aiSessions.filter { $0.status == .running }.count,
                color: .signalMint,
                label: "Работают"
            )
            AIStatusCount(
                count: model.aiSessions.filter { $0.status.isActive == false }.count,
                color: .signalCyan,
                label: "Недавние"
            )
        }
    }

    private var sectionPicker: some View {
        HStack(spacing: 4) {
            ForEach(AISection.allCases) { section in
                Button {
                    model.selectAISection(section)
                } label: {
                    Text(section.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(
                            model.selectedAISection == section
                                ? NotchPalette.surface
                                : NotchPalette.secondary
                        )
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(
                            model.selectedAISection == section
                                ? NotchPalette.accent
                                : Color.clear,
                            in: Capsule()
                        )
                        .frame(height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(NotchButtonStyle())
                .accessibilityLabel(section.title)
                .accessibilityAddTraits(
                    model.selectedAISection == section ? .isSelected : []
                )
            }
        }
        .padding(.horizontal, 4)
        .background {
            Capsule()
                .fill(NotchPalette.raised)
                .frame(height: 36)
        }
    }
}

private struct AIStatusCount: View {
    let count: Int
    let color: Color
    let label: String

    var body: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
            Text("\(count)")
                .monospacedDigit()
        }
        .font(.system(size: 8, weight: .bold, design: .rounded))
        .foregroundStyle(.white.opacity(0.72))
        .frame(width: 30, height: 15)
        .background(.white.opacity(0.045), in: Capsule())
        .help("\(label): \(count)")
        .accessibilityLabel("\(label): \(count)")
    }
}

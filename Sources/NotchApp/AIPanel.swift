import SwiftUI

struct AIPanel: View {
    @ObservedObject var model: NotchViewModel

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                inboxStatusCounts
                sectionPicker
            }
            .padding(.horizontal, 14)

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
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(
                            model.selectedAISection == section
                                ? Color.black
                                : Color.white.opacity(0.62)
                        )
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background(
                            model.selectedAISection == section
                                ? Color.signalMint
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
                .fill(.white.opacity(0.06))
                .frame(height: 32)
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

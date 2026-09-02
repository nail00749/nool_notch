import SwiftUI

struct AIPanel: View {
    @ObservedObject var model: NotchViewModel

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(AISection.allCases) { section in
                    Button {
                        model.selectAISection(section)
                    } label: {
                        Text(section.title)
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(
                                model.selectedAISection == section
                                    ? Color.black
                                    : Color.white.opacity(0.62)
                            )
                            .frame(maxWidth: .infinity)
                            .frame(height: 28)
                            .background(
                                model.selectedAISection == section
                                    ? Color.signalMint
                                    : Color.clear,
                                in: Capsule()
                            )
                    }
                    .buttonStyle(NotchButtonStyle())
                    .accessibilityLabel(section.title)
                    .accessibilityAddTraits(
                        model.selectedAISection == section ? .isSelected : []
                    )
                }
            }
            .padding(3)
            .background(.white.opacity(0.06), in: Capsule())
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
}

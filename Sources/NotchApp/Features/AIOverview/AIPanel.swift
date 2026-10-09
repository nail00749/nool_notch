import SwiftUI

struct AIPanel: View {
    @ObservedObject var model: NotchViewModel

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                if model.modules.isEnabled(.quotas) {
                    LimitsPanel(model: model)
                }
                if model.modules.isEnabled(.agentInbox) {
                    AISessionsPanel(model: model, embedded: true)
                    AIUsagePanel(store: model.aiUsage, isActive: model.isExpanded
                                 && model.selectedPanel == .ai && model.activeUtility == nil
                                 && !model.isShowingSettings)
                }
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 12)
        }
    }
}

import Foundation

extension NoolDockItem {
    @MainActor
    func isAvailable(in modules: AppModuleStore) -> Bool {
        switch kind {
        case .music: modules.isEnabled(.music)
        case .calendar: modules.isEnabled(.calendar)
        case .timer: modules.isEnabled(.liveActivities)
        case .app, .note: true
        }
    }
}

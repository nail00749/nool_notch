import Foundation

@MainActor
protocol CalendarProviding: AnyObject {
    var canLoadWithoutPrompt: Bool { get }
    func loadUpcomingEvents() async -> CalendarLoadState
    func loadEvents(for month: Date) async -> [CalendarEvent]
}

extension CalendarProviding {
    var canLoadWithoutPrompt: Bool { false }
}

import Foundation

enum WindowLayoutAction: String, CaseIterable, Identifiable, Hashable, Sendable {
    case left
    case right
    case maximize
    case center
    case nextDisplay

    var id: Self { self }

    var title: String {
        switch self {
        case .left: "Слева"
        case .right: "Справа"
        case .maximize: "На весь экран"
        case .center: "По центру"
        case .nextDisplay: "На следующий дисплей"
        }
    }

    var systemImage: String {
        switch self {
        case .left: "rectangle.lefthalf.filled"
        case .right: "rectangle.righthalf.filled"
        case .maximize: "rectangle.expand.vertical"
        case .center: "rectangle.center.inset.filled"
        case .nextDisplay: "display.2"
        }
    }
}

struct WindowLayoutRect: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    var maxX: Double { x + width }
    var maxY: Double { y + height }
    var centerX: Double { x + width / 2 }
    var centerY: Double { y + height / 2 }
    var isUsable: Bool {
        x.isFinite && y.isFinite && width.isFinite && height.isFinite
            && width > 0 && height > 0
    }
}

struct WindowLayoutScreen: Equatable, Sendable {
    let id: String
    let frame: WindowLayoutRect
    let visibleFrame: WindowLayoutRect
}

struct SavedWindowPlacement: Codable, Equatable, Sendable {
    let bundleIdentifier: String
    let windowTitle: String
    let ordinal: Int
    let displayID: String
    let normalizedFrame: WindowLayoutRect
}

struct SavedWindowLayout: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let windows: [SavedWindowPlacement]
}

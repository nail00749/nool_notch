import Foundation

enum WindowLayoutAction: String, CaseIterable, Identifiable, Hashable, Sendable {
    case left
    case right
    case maximize
    case restore
    case center
    case nextDisplay
    case previousDisplay
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
    case leftThird
    case centerThird
    case rightThird
    case leftTwoThirds
    case rightTwoThirds

    var id: Self { self }

    var title: String {
        switch self {
        case .left: "Слева"
        case .right: "Справа"
        case .maximize: "На весь экран"
        case .restore: "Вернуть размер и положение"
        case .center: "По центру"
        case .nextDisplay: "На следующий дисплей"
        case .previousDisplay: "На предыдущий дисплей"
        case .topLeft: "Верхняя левая четверть"
        case .topRight: "Верхняя правая четверть"
        case .bottomLeft: "Нижняя левая четверть"
        case .bottomRight: "Нижняя правая четверть"
        case .leftThird: "Левая треть"
        case .centerThird: "Центральная треть"
        case .rightThird: "Правая треть"
        case .leftTwoThirds: "Левые две трети"
        case .rightTwoThirds: "Правые две трети"
        }
    }

    var systemImage: String {
        switch self {
        case .left: "rectangle.lefthalf.filled"
        case .right: "rectangle.righthalf.filled"
        case .maximize: "rectangle.expand.vertical"
        case .restore: "arrow.uturn.backward"
        case .center: "rectangle.center.inset.filled"
        case .nextDisplay, .previousDisplay: "display.2"
        case .topLeft: "rectangle.inset.topleft.filled"
        case .topRight: "rectangle.inset.topright.filled"
        case .bottomLeft: "rectangle.inset.bottomleft.filled"
        case .bottomRight: "rectangle.inset.bottomright.filled"
        case .leftThird, .centerThird, .rightThird: "rectangle.split.3x1"
        case .leftTwoThirds, .rightTwoThirds: "rectangle.split.3x1.fill"
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

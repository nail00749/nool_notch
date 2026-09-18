import AppKit
import CoreGraphics
import Foundation

enum NotchDisplayMode: String, CaseIterable, Identifiable {
    case automatic
    case followPointer
    case fixed

    var id: Self { self }

    var title: String {
        switch self {
        case .automatic: "Встроенный дисплей"
        case .followPointer: "Следовать за указателем"
        case .fixed: "Выбранный дисплей"
        }
    }
}

struct NotchDisplayDescriptor: Identifiable, Equatable {
    let id: String
    let name: String
    let frame: CGRect
    let isBuiltIn: Bool
    let isMain: Bool
    var physicalNotchSize: CGSize = .zero

    var selectionTitle: String {
        let width = Int(frame.width.rounded())
        let height = Int(frame.height.rounded())
        let x = Int(frame.minX.rounded())
        let y = Int(frame.minY.rounded())
        return "\(name) · \(width)×\(height) · \(x), \(y)"
    }
}

enum NotchDisplaySelectionPolicy {
    static func selectedDisplayID(
        mode: NotchDisplayMode,
        fixedDisplayID: String?,
        displays: [NotchDisplayDescriptor],
        pointerLocation: CGPoint,
        activeDisplayID: String? = nil,
        isExpanded: Bool = false
    ) -> String? {
        guard displays.isEmpty == false else { return nil }

        let builtIn = displays.first(where: \.isBuiltIn)
        let main = displays.first(where: \.isMain)
        let underPointer = displays.first { $0.frame.contains(pointerLocation) }

        switch mode {
        case .automatic:
            return (builtIn ?? underPointer ?? main ?? displays[0]).id
        case .followPointer:
            if isExpanded,
               let activeDisplayID,
               displays.contains(where: { $0.id == activeDisplayID }) {
                return activeDisplayID
            }
            return (underPointer ?? main ?? builtIn ?? displays[0]).id
        case .fixed:
            if let fixedDisplayID,
               let fixed = displays.first(where: { $0.id == fixedDisplayID }) {
                return fixed.id
            }
            return (builtIn ?? main ?? underPointer ?? displays[0]).id
        }
    }
}

@MainActor
final class NotchDisplaySettings: ObservableObject {
    private enum Key {
        static let mode = "notch.display.mode"
        static let fixedDisplayID = "notch.display.fixedDisplayID"
        static let usesPerDisplayCompactHeight = "notch.display.usesPerDisplayCompactHeight"
        static let compactHeights = "notch.display.compactHeights"
    }

    private let defaults: UserDefaults

    @Published var mode: NotchDisplayMode {
        didSet {
            guard mode != oldValue else { return }
            defaults.set(mode.rawValue, forKey: Key.mode)
            onConfigurationChange?()
        }
    }

    @Published var fixedDisplayID: String? {
        didSet {
            guard fixedDisplayID != oldValue else { return }
            if let fixedDisplayID {
                defaults.set(fixedDisplayID, forKey: Key.fixedDisplayID)
            } else {
                defaults.removeObject(forKey: Key.fixedDisplayID)
            }
            onConfigurationChange?()
        }
    }

    @Published var usesPerDisplayCompactHeight: Bool {
        didSet {
            guard usesPerDisplayCompactHeight != oldValue else { return }
            defaults.set(usesPerDisplayCompactHeight, forKey: Key.usesPerDisplayCompactHeight)
            onConfigurationChange?()
        }
    }

    @Published private(set) var connectedDisplays: [NotchDisplayDescriptor] = []
    @Published private(set) var activeDisplayID: String?
    @Published private var compactHeights: [String: Double]

    var onConfigurationChange: (() -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = NotchDisplayMode(rawValue: defaults.string(forKey: Key.mode) ?? "") ?? .automatic
        fixedDisplayID = defaults.string(forKey: Key.fixedDisplayID)
        usesPerDisplayCompactHeight = defaults.object(
            forKey: Key.usesPerDisplayCompactHeight
        ) as? Bool ?? false
        compactHeights = (defaults.dictionary(forKey: Key.compactHeights) ?? [:])
            .compactMapValues { value in
                if let number = value as? NSNumber { return number.doubleValue }
                return value as? Double
            }
    }

    func refreshConnectedDisplays() {
        connectedDisplays = NSScreen.screens.map(Self.descriptor(for:))
    }

    func selectedScreen(
        pointerLocation: CGPoint = NSEvent.mouseLocation,
        preserveActiveDisplay: Bool = false
    ) -> NSScreen? {
        let screens = NSScreen.screens
        let descriptors = screens.map(Self.descriptor(for:))
        guard let selectedID = NotchDisplaySelectionPolicy.selectedDisplayID(
            mode: mode,
            fixedDisplayID: fixedDisplayID,
            displays: descriptors,
            pointerLocation: pointerLocation,
            activeDisplayID: activeDisplayID,
            isExpanded: preserveActiveDisplay
        ) else { return nil }

        return zip(screens, descriptors).first(where: { $0.1.id == selectedID })?.0
    }

    func setActiveDisplayID(_ displayID: String?) {
        guard activeDisplayID != displayID else { return }
        activeDisplayID = displayID
    }

    func setActiveScreen(_ screen: NSScreen?) {
        setActiveDisplayID(screen.map { Self.descriptor(for: $0).id })
    }

    func compactHeight(for displayID: String, fallback: CGFloat) -> CGFloat {
        guard let stored = compactHeights[displayID] else { return fallback }
        return Self.clampedHeight(CGFloat(stored))
    }

    func setCompactHeight(_ height: CGFloat, for displayID: String) {
        let clamped = Double(Self.clampedHeight(height))
        guard compactHeights[displayID] != clamped else { return }
        compactHeights[displayID] = clamped
        defaults.set(compactHeights, forKey: Key.compactHeights)
        onConfigurationChange?()
    }

    func effectiveCompactHeight(fallback: CGFloat) -> CGFloat {
        guard usesPerDisplayCompactHeight, let activeDisplayID else { return fallback }
        return compactHeight(for: activeDisplayID, fallback: fallback)
    }

    var activeDisplay: NotchDisplayDescriptor? {
        guard let activeDisplayID else { return nil }
        return connectedDisplays.first(where: { $0.id == activeDisplayID })
    }

    var activeMetrics: NotchLayoutMetrics {
        NotchLayoutMetrics(physicalNotchSize: activeDisplay?.physicalNotchSize ?? .zero)
    }

    var activeScreenFrame: CGRect? { activeDisplay?.frame }

    var activeScreen: NSScreen? {
        guard let activeDisplayID else { return nil }
        return NSScreen.screens.first { Self.descriptor(for: $0).id == activeDisplayID }
    }

    private static func clampedHeight(_ height: CGFloat) -> CGFloat {
        min(NotchLayout.compactHeightRange.upperBound,
            max(NotchLayout.compactHeightRange.lowerBound, height))
    }

    private static func descriptor(for screen: NSScreen) -> NotchDisplayDescriptor {
        let displayID = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? CGDirectDisplayID
        let identifier: String
        if let displayID,
           let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() {
            identifier = CFUUIDCreateString(nil, uuid) as String
        } else if let displayID {
            identifier = "display-\(displayID)"
        } else {
            identifier = "frame-\(screen.frame.origin.x)-\(screen.frame.origin.y)-\(screen.frame.width)x\(screen.frame.height)"
        }

        return NotchDisplayDescriptor(
            id: identifier,
            name: screen.localizedName,
            frame: screen.frame,
            isBuiltIn: displayID.map { CGDisplayIsBuiltin($0) != 0 } ?? false,
            isMain: screen === NSScreen.main,
            physicalNotchSize: NotchLayout.metrics(
                safeAreaTop: screen.safeAreaInsets.top,
                leftAuxiliaryArea: screen.auxiliaryTopLeftArea,
                rightAuxiliaryArea: screen.auxiliaryTopRightArea
            ).physicalNotchSize
        )
    }
}

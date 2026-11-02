import AppKit

/// The screen state that can change window placement. Keep screen order because
/// NSScreen.screens.first identifies the menu-bar display, independently of main.
struct ScreenParametersSignature: Equatable {
    struct Insets: Equatable {
        let top: CGFloat
        let left: CGFloat
        let bottom: CGFloat
        let right: CGFloat
    }

    struct Screen: Equatable {
        let displayID: CGDirectDisplayID?
        let uuid: String?
        let name: String
        let isBuiltIn: Bool
        let frame: CGRect
        let visibleFrame: CGRect
        let scale: CGFloat
        let safeArea: Insets
        let auxiliaryTopLeft: CGRect?
        let auxiliaryTopRight: CGRect?
    }

    let screens: [Screen]
    let mainDisplayID: CGDirectDisplayID?

    @MainActor
    static func capture() -> Self {
        // NSScreen.main queries WindowServer: read it once, outside the map.
        let mainDisplayID = displayID(of: NSScreen.main)
        return Self(
            screens: NSScreen.screens.map { screen in
                let insets = screen.safeAreaInsets
                let id = displayID(of: screen)
                let uuid = id.flatMap { CGDisplayCreateUUIDFromDisplayID($0)?.takeRetainedValue() }
                return Screen(
                    displayID: id,
                    uuid: uuid.map { CFUUIDCreateString(nil, $0) as String },
                    name: screen.localizedName,
                    isBuiltIn: id.map { CGDisplayIsBuiltin($0) != 0 } ?? false,
                    frame: screen.frame,
                    visibleFrame: screen.visibleFrame,
                    scale: screen.backingScaleFactor,
                    safeArea: Insets(top: insets.top, left: insets.left,
                                     bottom: insets.bottom, right: insets.right),
                    auxiliaryTopLeft: screen.auxiliaryTopLeftArea,
                    auxiliaryTopRight: screen.auxiliaryTopRightArea
                )
            },
            mainDisplayID: mainDisplayID
        )
    }

    @MainActor
    private static func displayID(of screen: NSScreen?) -> CGDirectDisplayID? {
        (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

/// Coalesces notification bursts and filters notifications that repeat identical
/// state. Preference and pointer-driven repositioning do not go through this gate.
@MainActor
final class ScreenParametersChangeObserver {
    typealias Schedule = (@escaping @MainActor () -> Void) -> Void

    private let capture: @MainActor () -> ScreenParametersSignature
    private let schedule: Schedule
    private let onChange: () -> Void
    private var lastSignature: ScreenParametersSignature
    private var isScheduled = false

    init(
        capture: @escaping @MainActor () -> ScreenParametersSignature = ScreenParametersSignature.capture,
        schedule: @escaping Schedule = { work in DispatchQueue.main.async(execute: work) },
        onChange: @escaping () -> Void
    ) {
        self.capture = capture
        self.schedule = schedule
        self.onChange = onChange
        // The owner creates this immediately after its initial window placement.
        lastSignature = capture()
    }

    func parametersDidChange() {
        guard !isScheduled else { return }
        isScheduled = true
        schedule { [weak self] in
            guard let self else { return }
            self.isScheduled = false
            // Capture at delivery, so a burst uses its final screen arrangement.
            let signature = self.capture()
            guard signature != self.lastSignature else { return }
            self.lastSignature = signature
            self.onChange()
        }
    }
}

import AppKit

extension NSScreen {
    static var preferredNotchScreen: NSScreen? {
        if let builtInScreen = screens.first(where: { screen in
            guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                return false
            }
            return CGDisplayIsBuiltin(displayID) != 0
        }) {
            return builtInScreen
        }

        if let screenUnderPointer = screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) {
            return screenUnderPointer
        }

        return main ?? screens.first
    }
}

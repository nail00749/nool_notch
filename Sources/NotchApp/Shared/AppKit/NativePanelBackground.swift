import AppKit
import SwiftUI

/// Native window vibrancy, with an opaque system surface for Reduce Transparency.
/// The caller owns clipping and window geometry.
struct NativePanelBackground: View {
    var material: NSVisualEffectView.Material = .popover
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Group {
            if reduceTransparency {
                NotchPalette.surface
            } else {
                VisualEffect(material: material)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private struct VisualEffect: NSViewRepresentable {
        let material: NSVisualEffectView.Material

        func makeNSView(context: Context) -> NSVisualEffectView {
            let view = NSVisualEffectView()
            view.blendingMode = .behindWindow
            view.state = .active
            view.material = material
            return view
        }

        func updateNSView(_ view: NSVisualEffectView, context: Context) {
            view.material = material
        }
    }
}

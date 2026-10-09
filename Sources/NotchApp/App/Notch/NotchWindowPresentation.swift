import SwiftUI

/// AppKit allocates the canvas; SwiftUI alone animates the visible viewport.
@MainActor
final class NotchWindowPresentation: ObservableObject {
    @Published var size: CGSize
    @Published var mountsExpandedContent = false

    init(size: CGSize) { self.size = size }
}

enum NotchWindowEnvelope {
    static func frame(containing current: CGRect, target: CGRect) -> CGRect {
        let size = CGSize(width: max(current.width, target.width),
                          height: max(current.height, target.height))
        return CGRect(x: target.midX - size.width / 2,
                      y: target.maxY - size.height,
                      width: size.width, height: size.height)
    }
}

struct NotchVisualViewport<Content: View>: View {
    let size: CGSize
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { canvas in
            content
                .frame(width: size.width, height: size.height, alignment: .top)
                .frame(width: canvas.size.width, height: canvas.size.height, alignment: .top)
        }
    }
}

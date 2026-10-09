import AppKit
import CoreGraphics

struct ScreenTextCaptureRequest: Sendable, Equatable {
    let displayID: CGDirectDisplayID
    let displaySize: CGSize
    /// Display-local logical points, with the origin at the top left as ScreenCaptureKit expects.
    let sourceRect: CGRect
    let pixelWidth: Int
    let pixelHeight: Int
}

enum ScreenTextCaptureGeometry {
    static let maximumPixelDimension = 4_096
    static let maximumPixels = 60_000_000
    static let minimumSelectionPoints: CGFloat = 8

    static func selection(from start: CGPoint, to end: CGPoint, in bounds: CGRect) -> CGRect {
        let first = CGPoint(x: min(max(start.x, bounds.minX), bounds.maxX),
                            y: min(max(start.y, bounds.minY), bounds.maxY))
        let last = CGPoint(x: min(max(end.x, bounds.minX), bounds.maxX),
                           y: min(max(end.y, bounds.minY), bounds.maxY))
        return CGRect(x: min(first.x, last.x), y: min(first.y, last.y),
                      width: abs(last.x - first.x), height: abs(last.y - first.y))
    }

    static func request(displayID: CGDirectDisplayID, screenFrame: CGRect,
                        selectedScreenRect: CGRect, backingScale: CGFloat) -> ScreenTextCaptureRequest? {
        guard screenFrame.width > 0, screenFrame.height > 0,
              backingScale.isFinite, backingScale > 0 else { return nil }
        let clipped = selectedScreenRect.intersection(screenFrame)
        guard !clipped.isNull, clipped.width >= minimumSelectionPoints,
              clipped.height >= minimumSelectionPoints else { return nil }

        let source = CGRect(x: clipped.minX - screenFrame.minX,
                            y: screenFrame.maxY - clipped.maxY,
                            width: clipped.width, height: clipped.height)
        guard [source.minX, source.minY, source.width, source.height].allSatisfy(\.isFinite),
              source.minX >= 0, source.minY >= 0,
              source.maxX <= screenFrame.width + 0.5,
              source.maxY <= screenFrame.height + 0.5 else { return nil }

        let scale = min(backingScale,
                        CGFloat(maximumPixelDimension) / source.width,
                        CGFloat(maximumPixelDimension) / source.height,
                        sqrt(CGFloat(maximumPixels) / (source.width * source.height)))
        let width = min(maximumPixelDimension, max(1, Int((source.width * scale).rounded())))
        let height = min(maximumPixelDimension, max(1, Int((source.height * scale).rounded())))
        guard width <= 20_000, height <= 20_000, width * height <= maximumPixels else { return nil }
        return ScreenTextCaptureRequest(displayID: displayID, displaySize: screenFrame.size,
                                        sourceRect: source, pixelWidth: width, pixelHeight: height)
    }
}

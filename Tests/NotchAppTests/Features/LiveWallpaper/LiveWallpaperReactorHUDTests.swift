import AppKit
import XCTest
@testable import NotchApp

final class LiveWallpaperReactorHUDTests: XCTestCase {
    @MainActor
    func testMemoryTextKeepsHeightWhenFormatterAddsDecimalDigits() throws {
        _ = NSApplication.shared
        let gib: UInt64 = 1_073_741_824
        for size in [CGSize(width: 800, height: 600), CGSize(width: 1600, height: 1000),
                     CGSize(width: 2560, height: 720)] {
            let whole = try memoryTextHeight(used: 16 * gib, total: 32 * gib, size: size)
            let fractional = try memoryTextHeight(used: 16 * gib + gib / 4, total: 32 * gib, size: size)
            XCTAssertGreaterThan(whole, 0)
            XCTAssertEqual(whole, fractional, "Memory glyphs must keep the same height at \(size)")
        }
    }

    @MainActor
    private func memoryTextHeight(used: UInt64, total: UInt64, size: CGSize) throws -> Int {
        let bounds = CGRect(origin: .zero, size: size)
        let hud = LiveWallpaperReactorHUD(frame: bounds)
        hud.update(.init(sampledAt: Date(), cpuFraction: 0.1,
                         memory: .init(usedBytes: used, totalBytes: total), disk: nil, network: nil))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        // Match the flipped coordinate system used by the desktop HUD.
        context.cgContext.translateBy(x: 0, y: size.height)
        context.cgContext.scaleBy(x: 1, y: -1)
        hud.draw(bounds)
        NSGraphicsContext.restoreGraphicsState()

        let compact = size.width < 900
        let scale = min(1.12, max(0.72, size.width / 1800))
        let margin = (compact ? 18.0 : 52.0) * scale
        let width = compact ? min(196 * scale, max(148 * scale, size.width * 0.235))
            : min(440 * scale, max(290 * scale, size.width * 0.19))
        let top = 64 * scale, bottom = 120 * scale
        let center = min(size.height - bottom - 100 * scale, max(top + 170 * scale, size.height / 2))
        let gap = (compact ? 24.0 : 42.0) * scale
        let block = (compact ? 84.0 : 104.0) * scale
        let group = block * 2 + gap
        let first = min(size.height - bottom - group, max(top + 92 * scale, center - group / 2))
        let valueY = first + block + gap + 21 * scale
        var litRows: [Int] = []
        for y in Int(valueY)..<Int(valueY + 25 * scale) {
            for x in Int(margin + 10 * scale)..<Int(margin + width) {
                if let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0.1 {
                    litRows.append(y)
                    break
                }
            }
        }
        guard let first = litRows.first, let last = litRows.last else { return 0 }
        return last - first + 1
    }
}

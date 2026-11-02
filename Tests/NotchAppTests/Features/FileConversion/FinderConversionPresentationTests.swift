import AppKit
import SwiftUI
import XCTest
@testable import NotchApp

final class FinderConversionPresentationTests: XCTestCase {
    func testPetalHitAreasExcludeCentreAndNeverOverlap() {
        let bounds = CGRect(x: 0, y: 0, width: 344, height: 344)
        for count in 1...6 {
            let petals = (0..<count).map { ConversionPetal(index: $0, count: count) }
            for (index, petal) in petals.enumerated() {
                let label = CGPoint(x: 172 + cos(petal.centerAngle) * 125,
                                    y: 172 + sin(petal.centerAngle) * 125)
                XCTAssertTrue(petal.path(in: bounds).contains(label))
                XCTAssertFalse(petal.path(in: bounds).contains(CGPoint(x: 172, y: 172)))
                for other in petals.indices where other != index {
                    XCTAssertFalse(petals[other].path(in: bounds).contains(label))
                }
            }
            for angle in stride(from: 0.0, to: 2 * .pi, by: 0.02) {
                let point = CGPoint(x: 172 + cos(angle) * 125, y: 172 + sin(angle) * 125)
                XCTAssertLessThanOrEqual(petals.filter { $0.path(in: bounds).contains(point) }.count, 1)
            }
        }
    }

    @MainActor
    func testOversizedBatchExplainsLimitBeforeInspectingFiles() {
        let model = FinderConversionModel()
        model.prepare((0..<21).map { URL(fileURLWithPath: "/tmp/example-\($0).txt") })
        XCTAssertFalse(model.isPreparing)
        XCTAssertTrue(model.formats.isEmpty)
        XCTAssertEqual(model.error, "За один раз можно конвертировать не более 20 файлов.")
    }

    @MainActor
    func testPanelStaysOnSelectedScreenIncludingNegativeOrigin() {
        let bounds = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
        for point in [CGPoint(x: -1919, y: -199), CGPoint(x: -1, y: 879), CGPoint(x: -900, y: 300)] {
            let frame = FinderConversionCoordinator.frame(at: point, within: bounds)
            XCTAssertTrue(bounds.contains(frame))
            XCTAssertEqual(frame.size, CGSize(width: 344, height: 344))
        }
    }

    @MainActor
    func testPreferencesRoundTrip() throws {
        let suite = "ConversionPreferences.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = FinderConversionPreferences(defaults: defaults)
        XCTAssertTrue(preferences.enabled)
        XCTAssertEqual(preferences.modifier, .command)
        preferences.enabled = false
        preferences.modifier = .option
        let restored = FinderConversionPreferences(defaults: defaults)
        XCTAssertFalse(restored.enabled)
        XCTAssertEqual(restored.modifier, .option)
    }

    @MainActor
    func testModelPreparesConvertsAndCanRenderRadialMenu() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RadialFixture-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Заметка.txt")
        try Data("Пример текста".utf8).write(to: source)
        let model = FinderConversionModel()
        model.prepare([source])
        await model.waitForCompletion()
        XCTAssertEqual(Set(model.formats), Set([.md, .rtf, .html, .pdf, .docx]))
        XCTAssertFalse(model.isPreparing)
        if ProcessInfo.processInfo.environment["NOOL_CONVERSION_RENDER"] == "1" {
            let host = NSHostingView(rootView: FinderConversionRadialView(model: model, close: {}))
            host.sizingOptions = []
            let window = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 344, height: 344),
                                 styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            let initialFrame = window.frame
            window.orderFrontRegardless()
            try await Task.sleep(for: .milliseconds(450))
            XCTAssertEqual(window.frame, initialFrame, "Animation must not resize or move the hosting panel")
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: "/tmp/nool-conversion-radial.png"))
        }
        model.convert(to: .rtf)
        await model.waitForCompletion()
        XCTAssertFalse(model.isRunning)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.outputs.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }
}

import AppKit
import XCTest
@testable import NotchApp

final class LiveWallpaperPolicyTests: XCTestCase {
    func testStateRequiresEnabledVideoAndRespectsPauseReasons() {
        var preferences = LiveWallpaperPreferences()
        let environment = LiveWallpaperEnvironment()
        XCTAssertEqual(LiveWallpaperPolicy.state(preferences: preferences, hasContent: true, environment: environment), .hidden)
        preferences.enabled = true
        XCTAssertEqual(LiveWallpaperPolicy.state(preferences: preferences, hasContent: false, environment: environment), .hidden)
        XCTAssertEqual(LiveWallpaperPolicy.state(preferences: preferences, hasContent: true, environment: environment), .playing)

        XCTAssertEqual(state(preferences, LiveWallpaperEnvironment(isAsleep: true, isCovered: true)), .paused(.asleep))
        XCTAssertEqual(state(preferences, LiveWallpaperEnvironment(isOnBattery: true)), .paused(.power))
        XCTAssertEqual(state(preferences, LiveWallpaperEnvironment(isLowPowerMode: true)), .paused(.power))
        XCTAssertEqual(state(preferences, LiveWallpaperEnvironment(isCovered: true)), .paused(.covered))

        preferences.pausesOnBattery = false
        preferences.pausesWhenCovered = false
        XCTAssertEqual(state(preferences, LiveWallpaperEnvironment(isOnBattery: true, isCovered: true)), .playing)
        XCTAssertEqual(state(preferences, LiveWallpaperEnvironment(isAsleep: true)), .paused(.asleep))
    }

    func testConfigurationIsNilWithoutScreensAndCarriesSanitizedValues() {
        var preferences = LiveWallpaperPreferences()
        preferences.enabled = true
        preferences.selectedFileName = "a.mp4"
        preferences.volume = 4
        preferences.playbackRate = .nan
        let display = LiveWallpaperDisplay(key: "A", displayID: 1, name: "A", frame: CGRect(x: 0, y: 0, width: 100, height: 50))
        XCTAssertNil(LiveWallpaperPolicy.configuration(displays: [], preferences: preferences,
                                                       environment: LiveWallpaperEnvironment(), resolve: Self.resolve))
        let configuration = LiveWallpaperPolicy.configuration(
            displays: [display], preferences: preferences,
            environment: LiveWallpaperEnvironment(isCovered: true), resolve: Self.resolve)
        XCTAssertEqual(configuration?.volume, 1)
        XCTAssertEqual(configuration?.playbackRate, 1)
        XCTAssertEqual(configuration?.isPlaying, false)
    }

    func testEachDisplayUsesItsOwnVideoOrFallsBackToSharedOne() {
        let displays = ["A", "B", "C"].enumerated().map { index, key in
            LiveWallpaperDisplay(key: key, displayID: CGDirectDisplayID(index + 1), name: key,
                                 frame: CGRect(x: CGFloat(index) * 100, y: 0, width: 100, height: 100))
        }
        var preferences = LiveWallpaperPreferences()
        preferences.enabled = true
        preferences.displayFileNames = ["B": "b.mov", "C": "missing.mp4"]
        var configuration = LiveWallpaperPolicy.configuration(
            displays: displays, preferences: preferences, environment: LiveWallpaperEnvironment(), resolve: Self.resolve)
        XCTAssertEqual(configuration?.screens.map(\.displayID), [2], "Only displays with an existing video render")
        XCTAssertEqual(configuration?.screens.first?.content.fileName, "b.mov")

        preferences.selectedFileName = "a.mp4"
        configuration = LiveWallpaperPolicy.configuration(
            displays: displays, preferences: preferences, environment: LiveWallpaperEnvironment(), resolve: Self.resolve)
        XCTAssertEqual(configuration?.screens.map(\.content.fileName), ["a.mp4", "b.mov"])

        preferences.forget(fileName: "b.mov")
        XCTAssertNil(preferences.displayFileNames["B"])
        XCTAssertEqual(preferences.fileName(forDisplay: "B"), "a.mp4")
    }

    private static func resolve(_ name: String) -> LiveWallpaperContent? {
        name == "missing.mp4" ? nil : .video(URL(fileURLWithPath: "/tmp/\(name)"))
    }

    func testScenePresetsAreAcceptableKeysAndSceneSettingsSanitize() throws {
        XCTAssertEqual(LiveWallpaperScenePreset(key: "nool-scene-plexus"), .plexus)
        XCTAssertNil(LiveWallpaperScenePreset(key: "nool-scene-unknown"))
        XCTAssertTrue(LiveWallpaperItem.isAcceptableKey("nool-scene-snow"))
        XCTAssertTrue(LiveWallpaperItem.isAcceptableKey("photo.HEIC"))
        XCTAssertEqual(LiveWallpaperItem.presets.count, LiveWallpaperScenePreset.allCases.count)

        var scene = LiveWallpaperSceneSettings()
        scene.density = 9
        scene.cursorStrength = .nan
        scene.parallax = -1
        scene.framesPerSecond = 120
        let sanitized = scene.sanitized
        XCTAssertEqual(sanitized.density, 2)
        XCTAssertEqual(sanitized.cursorStrength, 0.6)
        XCTAssertEqual(sanitized.parallax, 0)
        XCTAssertEqual(sanitized.framesPerSecond, 60)

        let decoded = try JSONDecoder().decode(LiveWallpaperPreferences.self,
                                               from: Data(#"{"scene":{"cursorMode":"attract"}}"#.utf8))
        XCTAssertEqual(decoded.scene.cursorMode, .attract)
        XCTAssertEqual(decoded.scene.framesPerSecond, 30)
    }

    func testPreferencesDecodeMissingKeysAndRejectUnsafeFileNames() throws {
        let decoded = try JSONDecoder().decode(LiveWallpaperPreferences.self, from: Data(#"{"enabled":true}"#.utf8))
        XCTAssertTrue(decoded.enabled)
        XCTAssertTrue(decoded.pausesOnBattery)
        XCTAssertEqual(decoded.scaleMode, .fill)
        XCTAssertEqual(decoded.displayFileNames, [:])

        var preferences = LiveWallpaperPreferences()
        for name in ["../secret.mp4", ".hidden.mp4", "a/b.mov", "clip.txt"] {
            preferences.selectedFileName = name
            XCTAssertNil(preferences.sanitized.selectedFileName, name)
        }
        preferences.selectedFileName = "Ocean 2.MOV"
        XCTAssertEqual(preferences.sanitized.selectedFileName, "Ocean 2.MOV")
        preferences.displayFileNames = ["A": "../x.mp4", "": "a.mp4", "B": "b.mp4"]
        XCTAssertEqual(preferences.sanitized.displayFileNames, ["B": "b.mp4"])
    }

    private func state(_ preferences: LiveWallpaperPreferences,
                       _ environment: LiveWallpaperEnvironment) -> LiveWallpaperPlaybackState {
        LiveWallpaperPolicy.state(preferences: preferences, hasContent: true, environment: environment)
    }
}

final class LiveWallpaperMotionTests: XCTestCase {
    func testCursorPushesWithinRadiusOnlyAndRespectsMode() {
        let cursor = CGPoint(x: 100, y: 100)
        let near = CGPoint(x: 150, y: 100)
        let repel = LiveWallpaperMotion.cursorAcceleration(particle: near, cursor: cursor, mode: .repel, strength: 1)
        let attract = LiveWallpaperMotion.cursorAcceleration(particle: near, cursor: cursor, mode: .attract, strength: 1)
        XCTAssertGreaterThan(repel.dx, 0)
        XCTAssertEqual(repel.dy, 0, accuracy: 0.001)
        XCTAssertEqual(attract.dx, -repel.dx, accuracy: 0.001)

        let closer = LiveWallpaperMotion.cursorAcceleration(particle: CGPoint(x: 120, y: 100), cursor: cursor,
                                                            mode: .repel, strength: 1)
        XCTAssertGreaterThan(closer.dx, repel.dx, "Force falls off with distance")
        for (point, mode, strength, cursor) in [
            (CGPoint(x: 1_000, y: 100), LiveWallpaperCursorMode.repel, 1.0, Optional(cursor)),
            (near, .off, 1, cursor), (near, .repel, 0, cursor), (near, .repel, 1, nil)
        ] {
            XCTAssertEqual(LiveWallpaperMotion.cursorAcceleration(particle: point, cursor: cursor, mode: mode,
                                                                  strength: strength), .zero)
        }
    }

    func testParallaxMovesAgainstCursorAndParticleCountScalesWithArea() {
        let size = CGSize(width: 1000, height: 500)
        XCTAssertEqual(LiveWallpaperMotion.parallaxOffset(cursor: CGPoint(x: 500, y: 250), size: size, amount: 1), .zero)
        let right = LiveWallpaperMotion.parallaxOffset(cursor: CGPoint(x: 1000, y: 250), size: size, amount: 1)
        XCTAssertEqual(right.dx, -LiveWallpaperMotion.maxParallaxShift, accuracy: 0.001)
        XCTAssertEqual(LiveWallpaperMotion.parallaxOffset(cursor: nil, size: size, amount: 1), .zero)

        let laptop = LiveWallpaperMotion.particleCount(style: .snow, size: CGSize(width: 1800, height: 1169), density: 1)
        let ultrawide = LiveWallpaperMotion.particleCount(style: .snow, size: CGSize(width: 5120, height: 1440), density: 1)
        XCTAssertGreaterThan(ultrawide, laptop)
        XCTAssertLessThanOrEqual(LiveWallpaperMotion.particleCount(style: .plexus, size: CGSize(width: 8000, height: 4000),
                                                                   density: 2), 160)
        XCTAssertEqual(LiveWallpaperMotion.particleCount(style: .none, size: size, density: 1), 0)
    }
}

final class LiveWallpaperLibraryTests: XCTestCase {
    func testItemsListOnlyVideosAndImportUsesUniqueNames() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LiveWallpaperLibrary(directory: root.appendingPathComponent("Wallpapers"))
        try library.ensureDirectory()
        for name in ["b.mov", "a.mp4", "notes.txt", ".x.partial", ".hidden.mp4", "c.png"] {
            try Data().write(to: library.directory.appendingPathComponent(name))
        }
        try FileManager.default.createDirectory(at: library.directory.appendingPathComponent("folder.mp4"),
                                                withIntermediateDirectories: true)
        XCTAssertEqual(library.items().map(\.fileName), ["a.mp4", "b.mov", "c.png"])
        XCTAssertEqual(library.items().last?.content, .image(library.directory.appendingPathComponent("c.png")))

        let source = root.appendingPathComponent("a.MP4")
        try Data([1, 2, 3]).write(to: source)
        let imported = try library.importFile(from: source)
        XCTAssertEqual(imported.fileName, "a 2.mp4")
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(imported.url)), Data([1, 2, 3]))
        XCTAssertFalse(library.items().map(\.fileName).contains { $0.hasSuffix(".partial") })

        let text = root.appendingPathComponent("clip.txt")
        try Data().write(to: text)
        XCTAssertThrowsError(try library.importFile(from: text))
        XCTAssertNil(library.url(for: "../a.mp4"))
    }
}

@MainActor
final class LiveWallpaperControllerTests: XCTestCase {
    func testStartRendersSelectedVideoPausesOnPowerAndModulePauseRemovesWindows() async throws {
        let fixture = try Fixture(files: ["ocean.mp4"])
        defer { fixture.cleanUp() }
        var preferences = LiveWallpaperPreferences()
        preferences.enabled = true
        preferences.selectedFileName = "ocean.mp4"
        fixture.controller.setPreferences(preferences)
        XCTAssertTrue(fixture.renderer.configurations.isEmpty, "Nothing renders before the module starts")

        fixture.controller.start()
        try await waitUntil { fixture.renderer.configurations.last??.isPlaying == true }
        XCTAssertEqual(fixture.renderer.configurations.last??.screens.first?.content.fileName, "ocean.mp4")
        XCTAssertTrue(fixture.power.started)

        fixture.power.isOnBattery = true
        fixture.power.onChange?()
        XCTAssertEqual(fixture.renderer.configurations.last??.isPlaying, false)
        XCTAssertEqual(fixture.controller.playbackState, .paused(.power))

        fixture.renderer.onCoverageChange?(true)
        XCTAssertTrue(fixture.controller.environment.isCovered)

        fixture.controller.pause()
        XCTAssertNil(fixture.renderer.configurations.last ?? nil)
        XCTAssertFalse(fixture.power.started)
        let count = fixture.renderer.configurations.count
        fixture.power.onChange?()
        fixture.renderer.onCoverageChange?(false)
        XCTAssertEqual(fixture.renderer.configurations.count, count, "Late callbacks are ignored after pause")
        XCTAssertEqual(fixture.controller.preferences.selectedFileName, "ocean.mp4")
    }

    func testAssigningToDisplayOverridesOnlyThatDisplay() async throws {
        let fixture = try Fixture(files: ["ocean.mp4", "city.mov"])
        defer { fixture.cleanUp() }
        fixture.controller.start()
        try await waitUntil { fixture.controller.fileItems.count == 2 && !fixture.controller.displays.isEmpty }
        let display = try XCTUnwrap(fixture.controller.displays.first)
        let ocean = try XCTUnwrap(fixture.controller.item(named: "ocean.mp4"))
        let city = try XCTUnwrap(fixture.controller.item(named: "city.mov"))

        fixture.controller.assign(ocean, to: .allDisplays)
        fixture.controller.assign(city, to: .display(display.key))
        XCTAssertEqual(fixture.controller.preferences.selectedFileName, "ocean.mp4")
        XCTAssertEqual(fixture.controller.fileName(for: .display(display.key)), "city.mov")
        XCTAssertEqual(fixture.renderer.configurations.last??.screens.first?.content.fileName, "city.mov")

        fixture.controller.resetDisplay(display.key)
        XCTAssertFalse(fixture.controller.hasOverride(display))
        XCTAssertEqual(fixture.renderer.configurations.last??.screens.first?.content.fileName, "ocean.mp4")
    }

    func testBuiltInScenesAreAlwaysInLibraryAndCanBeAssigned() async throws {
        let fixture = try Fixture(files: [])
        defer { fixture.cleanUp() }
        fixture.controller.start()
        try await waitUntil { !fixture.controller.displays.isEmpty }
        let fireflies = try XCTUnwrap(fixture.controller.item(named: "nool-scene-fireflies"))
        fixture.controller.select(fireflies)
        XCTAssertEqual(fixture.renderer.configurations.last??.screens.first?.content, .scene(.fireflies))
        XCTAssertTrue(fixture.controller.usesScenes)
        fixture.controller.remove(fireflies)
        XCTAssertNotNil(fixture.controller.item(named: "nool-scene-fireflies"), "Built-in scenes cannot be removed")
    }

    func testMissingSelectedFileHidesWallpaper() async throws {
        let fixture = try Fixture(files: [])
        defer { fixture.cleanUp() }
        var preferences = LiveWallpaperPreferences()
        preferences.enabled = true
        preferences.selectedFileName = "gone.mp4"
        fixture.controller.setPreferences(preferences)
        fixture.controller.start()
        try await waitUntil { fixture.controller.message != nil }
        XCTAssertNil(fixture.renderer.configurations.last ?? nil)
        XCTAssertEqual(fixture.controller.playbackState, .hidden)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }

    @MainActor
    private struct Fixture {
        let root: URL
        let defaults: UserDefaults
        let suiteName: String
        let renderer = FakeRenderer()
        let power = FakePower()
        let controller: LiveWallpaperController

        init(files: [String]) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let library = LiveWallpaperLibrary(directory: root)
            try library.ensureDirectory()
            for name in files { try Data().write(to: root.appendingPathComponent(name)) }
            suiteName = "LiveWallpaperTests.\(UUID().uuidString)"
            defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            let screen = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first)
            controller = LiveWallpaperController(defaults: defaults, library: library, renderer: renderer,
                                                 power: power, desktopImage: FakeDesktopImage(),
                                                 screensProvider: { [screen] })
        }

        func cleanUp() {
            controller.stop()
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
    }

    @MainActor
    private final class FakeRenderer: LiveWallpaperRendering {
        var onCoverageChange: ((Bool) -> Void)?
        var configurations: [LiveWallpaperRenderConfiguration?] = []
        func apply(_ configuration: LiveWallpaperRenderConfiguration?) { configurations.append(configuration) }
        func sceneSnapshot(forDisplay displayID: CGDirectDisplayID) -> CGImage? { nil }
    }

    @MainActor
    private final class FakePower: LiveWallpaperPowerMonitoring {
        var onChange: (() -> Void)?
        var isOnBattery = false
        var isLowPowerMode = false
        var started = false
        func start() { started = true }
        func stop() { started = false }
    }

    @MainActor
    private struct FakeDesktopImage: LiveWallpaperDesktopImageSetting {
        func setDesktopImage(_ url: URL, for screen: NSScreen) throws {}
    }
}

private extension LiveWallpaperContent {
    var fileName: String? {
        switch self {
        case .video(let url), .image(let url): url.lastPathComponent
        case .scene(let preset): preset.key
        }
    }
}

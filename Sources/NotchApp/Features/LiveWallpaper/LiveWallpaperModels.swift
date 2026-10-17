import CoreGraphics
import Foundation

enum LiveWallpaperScaleMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case fill, fit, stretch

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fill: "Заполнить"
        case .fit: "Вписать"
        case .stretch: "Растянуть"
        }
    }
}

/// Built-in interactive scenes; they need no files and are keyed as `nool-scene-<name>`.
enum LiveWallpaperScenePreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case starfield, fireflies, plexus, snow, embers

    static let keyPrefix = "nool-scene-"

    var id: String { rawValue }
    var key: String { Self.keyPrefix + rawValue }

    init?(key: String) {
        guard key.hasPrefix(Self.keyPrefix) else { return nil }
        self.init(rawValue: String(key.dropFirst(Self.keyPrefix.count)))
    }

    var title: String {
        switch self {
        case .starfield: "Звёздное небо"
        case .fireflies: "Светлячки"
        case .plexus: "Нейросеть"
        case .snow: "Снегопад"
        case .embers: "Искры"
        }
    }

    var symbolName: String {
        switch self {
        case .starfield: "sparkles"
        case .fireflies: "light.min"
        case .plexus: "point.3.connected.trianglepath.dotted"
        case .snow: "snowflake"
        case .embers: "flame"
        }
    }

    /// Top and bottom background colors as RGB components.
    var gradient: (top: SIMD3<Double>, bottom: SIMD3<Double>) {
        switch self {
        case .starfield: (SIMD3(0.02, 0.03, 0.09), SIMD3(0.07, 0.05, 0.18))
        case .fireflies: (SIMD3(0.01, 0.06, 0.05), SIMD3(0.04, 0.13, 0.08))
        case .plexus: (SIMD3(0.03, 0.04, 0.10), SIMD3(0.01, 0.13, 0.20))
        case .snow: (SIMD3(0.10, 0.14, 0.22), SIMD3(0.26, 0.31, 0.40))
        case .embers: (SIMD3(0.06, 0.02, 0.02), SIMD3(0.20, 0.06, 0.02))
        }
    }

    /// Particles drawn by the preset.
    var particles: LiveWallpaperParticleStyle {
        switch self {
        case .starfield: .stars
        case .fireflies: .fireflies
        case .plexus: .plexus
        case .snow: .snow
        case .embers: .embers
        }
    }
}

enum LiveWallpaperParticleStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case none, stars, fireflies, plexus, snow, embers

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "Без частиц"
        case .stars: "Звёзды"
        case .fireflies: "Светлячки"
        case .plexus: "Сеть"
        case .snow: "Снег"
        case .embers: "Искры"
        }
    }
}

enum LiveWallpaperCursorMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case repel, attract, off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .repel: "Отталкивать"
        case .attract: "Притягивать"
        case .off: "Не реагировать"
        }
    }
}

/// Shared settings of scene wallpapers: built-in presets and pictures with particles.
struct LiveWallpaperSceneSettings: Codable, Equatable, Sendable {
    var density: Double = 1
    var cursorMode: LiveWallpaperCursorMode = .repel
    var cursorStrength: Double = 0.6
    var parallax: Double = 0.5
    var imageParticles: LiveWallpaperParticleStyle = .fireflies
    var framesPerSecond = 30

    init() {}

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self()
        density = (try? container.decodeIfPresent(Double.self, forKey: .density)) ?? defaults.density
        cursorMode = (try? container.decodeIfPresent(LiveWallpaperCursorMode.self, forKey: .cursorMode)) ?? defaults.cursorMode
        cursorStrength = (try? container.decodeIfPresent(Double.self, forKey: .cursorStrength)) ?? defaults.cursorStrength
        parallax = (try? container.decodeIfPresent(Double.self, forKey: .parallax)) ?? defaults.parallax
        imageParticles = (try? container.decodeIfPresent(LiveWallpaperParticleStyle.self, forKey: .imageParticles))
            ?? defaults.imageParticles
        framesPerSecond = (try? container.decodeIfPresent(Int.self, forKey: .framesPerSecond)) ?? defaults.framesPerSecond
    }

    var sanitized: Self {
        var copy = self
        copy.density = density.isFinite ? min(2, max(0.25, density)) : 1
        copy.cursorStrength = cursorStrength.isFinite ? min(1, max(0, cursorStrength)) : 0.6
        copy.parallax = parallax.isFinite ? min(1, max(0, parallax)) : 0.5
        copy.framesPerSecond = framesPerSecond >= 45 ? 60 : 30
        return copy
    }
}

struct LiveWallpaperPreferences: Codable, Equatable, Sendable {
    var enabled = false
    /// Video for every display without its own choice.
    var selectedFileName: String?
    /// Per-display overrides keyed by `LiveWallpaperDisplay.key`.
    var displayFileNames: [String: String] = [:]
    var scaleMode: LiveWallpaperScaleMode = .fill
    var volume: Double = 0
    var playbackRate: Double = 1
    var pausesOnBattery = true
    var pausesWhenCovered = true
    var syncsSystemWallpaper = false
    var scene = LiveWallpaperSceneSettings()

    init() {}

    /// Missing keys keep defaults, so preferences survive fields added in later versions.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self()
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        selectedFileName = try container.decodeIfPresent(String.self, forKey: .selectedFileName)
        displayFileNames = (try? container.decodeIfPresent([String: String].self, forKey: .displayFileNames)) ?? [:]
        scaleMode = (try? container.decodeIfPresent(LiveWallpaperScaleMode.self, forKey: .scaleMode)) ?? defaults.scaleMode
        volume = try container.decodeIfPresent(Double.self, forKey: .volume) ?? defaults.volume
        playbackRate = try container.decodeIfPresent(Double.self, forKey: .playbackRate) ?? defaults.playbackRate
        pausesOnBattery = try container.decodeIfPresent(Bool.self, forKey: .pausesOnBattery) ?? defaults.pausesOnBattery
        pausesWhenCovered = try container.decodeIfPresent(Bool.self, forKey: .pausesWhenCovered) ?? defaults.pausesWhenCovered
        syncsSystemWallpaper = try container.decodeIfPresent(Bool.self, forKey: .syncsSystemWallpaper)
            ?? defaults.syncsSystemWallpaper
        scene = (try? container.decodeIfPresent(LiveWallpaperSceneSettings.self, forKey: .scene)) ?? defaults.scene
    }

    var sanitized: Self {
        var copy = self
        copy.volume = volume.isFinite ? min(1, max(0, volume)) : 0
        copy.playbackRate = playbackRate.isFinite ? min(2, max(0.25, playbackRate)) : 1
        if let name = selectedFileName, !LiveWallpaperItem.isAcceptableKey(name) {
            copy.selectedFileName = nil
        }
        copy.displayFileNames = displayFileNames.filter { !$0.key.isEmpty && LiveWallpaperItem.isAcceptableKey($0.value) }
        copy.scene = scene.sanitized
        return copy
    }

    func fileName(forDisplay key: String) -> String? { displayFileNames[key] ?? selectedFileName }

    /// Every file a display may show, used to detect removed videos.
    var referencedFileNames: Set<String> { Set(displayFileNames.values).union(selectedFileName.map { [$0] } ?? []) }

    mutating func forget(fileName: String) {
        if selectedFileName == fileName { selectedFileName = nil }
        displayFileNames = displayFileNames.filter { $0.value != fileName }
    }
}

enum LiveWallpaperContent: Equatable, Sendable {
    case video(URL)
    case image(URL)
    case scene(LiveWallpaperScenePreset)

    var isScene: Bool { if case .video = self { false } else { true } }
}

/// A library entry. `fileName` is its stored key: a file in the library folder or a built-in scene key.
struct LiveWallpaperItem: Identifiable, Equatable, Sendable {
    let fileName: String
    let content: LiveWallpaperContent

    init(fileName: String, url: URL) {
        self.fileName = fileName
        content = LiveWallpaperLibrary.isImageFileName(fileName) ? .image(url) : .video(url)
    }

    init(preset: LiveWallpaperScenePreset) {
        fileName = preset.key
        content = .scene(preset)
    }

    static let presets = LiveWallpaperScenePreset.allCases.map(LiveWallpaperItem.init(preset:))

    static func isAcceptableKey(_ key: String) -> Bool {
        LiveWallpaperScenePreset(key: key) != nil || LiveWallpaperLibrary.isAcceptableFileName(key)
    }

    var id: String { fileName }

    var url: URL? {
        switch content {
        case .video(let url), .image(let url): url
        case .scene: nil
        }
    }

    var preset: LiveWallpaperScenePreset? { if case .scene(let preset) = content { preset } else { nil } }

    var title: String { preset?.title ?? url?.deletingPathExtension().lastPathComponent ?? fileName }

    var kindTitle: String {
        switch content {
        case .video: "Видео"
        case .image: "Картинка"
        case .scene: "Сцена"
        }
    }
}

struct LiveWallpaperEnvironment: Equatable, Sendable {
    var isAsleep = false
    var isOnBattery = false
    var isLowPowerMode = false
    var isCovered = false
}

enum LiveWallpaperPauseReason: Equatable, Sendable {
    case asleep, power, covered

    var title: String {
        switch self {
        case .asleep: "Пауза: экран спит или заблокирован"
        case .power: "Пауза: питание от батареи или режим энергосбережения"
        case .covered: "Пауза: рабочий стол закрыт окнами"
        }
    }
}

enum LiveWallpaperPlaybackState: Equatable, Sendable {
    case hidden
    case paused(LiveWallpaperPauseReason)
    case playing
}

/// A connected display. `key` is the display UUID, stable across reconnects and restarts.
struct LiveWallpaperDisplay: Identifiable, Equatable, Sendable {
    let key: String
    let displayID: CGDirectDisplayID
    let name: String
    let frame: CGRect

    var id: String { key }
}

enum LiveWallpaperTarget: Hashable, Sendable {
    case allDisplays
    case display(String)
}

struct LiveWallpaperScreen: Equatable, Sendable {
    let displayID: CGDirectDisplayID
    let frame: CGRect
    let content: LiveWallpaperContent
}

struct LiveWallpaperRenderConfiguration: Equatable, Sendable {
    let screens: [LiveWallpaperScreen]
    let scaleMode: LiveWallpaperScaleMode
    let volume: Float
    let playbackRate: Float
    let isPlaying: Bool
    /// Stops each display whose wallpaper window is fully covered, even while another display shows it.
    let pausesHiddenScreens: Bool
    let scene: LiveWallpaperSceneSettings
}

enum LiveWallpaperPolicy {
    static func state(preferences: LiveWallpaperPreferences, hasContent: Bool,
                      environment: LiveWallpaperEnvironment) -> LiveWallpaperPlaybackState {
        guard preferences.enabled, hasContent else { return .hidden }
        if environment.isAsleep { return .paused(.asleep) }
        if preferences.pausesOnBattery, environment.isOnBattery || environment.isLowPowerMode {
            return .paused(.power)
        }
        if preferences.pausesWhenCovered, environment.isCovered { return .paused(.covered) }
        return .playing
    }

    /// Displays whose wallpaper cannot be resolved stay with the system wallpaper.
    static func configuration(displays: [LiveWallpaperDisplay], preferences: LiveWallpaperPreferences,
                              environment: LiveWallpaperEnvironment,
                              resolve: (String) -> LiveWallpaperContent?) -> LiveWallpaperRenderConfiguration? {
        let screens = displays.compactMap { display -> LiveWallpaperScreen? in
            guard let content = preferences.fileName(forDisplay: display.key).flatMap(resolve) else { return nil }
            return LiveWallpaperScreen(displayID: display.displayID, frame: display.frame, content: content)
        }
        let state = state(preferences: preferences, hasContent: !screens.isEmpty, environment: environment)
        guard state != .hidden else { return nil }
        let sanitized = preferences.sanitized
        return LiveWallpaperRenderConfiguration(
            screens: screens,
            scaleMode: sanitized.scaleMode,
            volume: Float(sanitized.volume),
            playbackRate: Float(sanitized.playbackRate),
            isPlaying: state == .playing,
            pausesHiddenScreens: sanitized.pausesWhenCovered,
            scene: sanitized.scene
        )
    }
}

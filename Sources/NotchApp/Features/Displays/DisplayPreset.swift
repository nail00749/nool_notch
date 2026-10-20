import CoreGraphics
import Foundation

struct DisplayPreset: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var displays: [DisplayPresetEntry]

    init(id: UUID = UUID(), name: String, displays: [DisplayPresetEntry]) {
        self.id = id
        self.name = name
        self.displays = displays
    }
}

struct DisplayPresetEntry: Codable, Equatable {
    let stableUUID: String
    let enabled: Bool
    let mode: SavedDisplayMode?
    let origin: CGPoint
    let isMain: Bool
    let mirrorMasterUUID: String?
    let brightness: Double
    let useSoftwareBrightness: Bool
    let colorProfileID: String?
    let imageAdjustment: DisplayImageAdjustment?

    init(stableUUID: String, enabled: Bool = true, mode: SavedDisplayMode? = nil,
         origin: CGPoint = .zero, isMain: Bool = false, mirrorMasterUUID: String? = nil,
         brightness: Double = 1, useSoftwareBrightness: Bool = false, colorProfileID: String? = nil,
         imageAdjustment: DisplayImageAdjustment? = nil) {
        self.stableUUID = stableUUID
        self.enabled = enabled
        self.mode = mode
        self.origin = origin
        self.isMain = isMain
        self.mirrorMasterUUID = mirrorMasterUUID
        self.brightness = brightness
        self.useSoftwareBrightness = useSoftwareBrightness
        self.colorProfileID = colorProfileID
        self.imageAdjustment = imageAdjustment
    }
}

enum DisplayPresetError: LocalizedError, Equatable {
    case unavailable
    case displaySetMismatch
    case invalidPreset
    case modeUnavailable(displayUUID: String)
    case powerUnavailable(displayUUID: String)
    case displayChanged

    var errorDescription: String? {
        switch self {
        case .unavailable: "Применение пресетов дисплеев недоступно."
        case .displaySetMismatch: "Подключите тот же набор дисплеев, который сохранён в пресете."
        case .invalidPreset: "В пресете некорректные настройки дисплеев."
        case .modeUnavailable: "Сохранённый режим одного из дисплеев больше недоступен."
        case .powerUnavailable: "Нельзя безопасно изменить включение одного из дисплеев этого пресета."
        case .displayChanged: "Набор дисплеев изменился во время применения пресета."
        }
    }
}

/// A read-only plan: callers can reject invalid input before a single driver mutation.
struct DisplayPresetConfigurationPlan {
    struct Entry {
        let saved: DisplayPresetEntry
        let display: DisplayInfo
        let resolvedMode: DisplayModeOption?
        let targetSize: CGSize
    }

    let entries: [Entry]
    let temporaryPlacements: [DisplayPlacement]

    static func make(_ preset: DisplayPreset, displays: [DisplayInfo],
                     supportsDisplayPower: Bool, powerChangeableUUIDs: Set<String>) throws -> Self {
        let savedIDs = preset.displays.map(\.stableUUID)
        let liveIDs = displays.map(\.id)
        guard !savedIDs.isEmpty, Set(savedIDs).count == savedIDs.count,
              Set(liveIDs).count == liveIDs.count else { throw DisplayPresetError.invalidPreset }
        guard Set(savedIDs) == Set(liveIDs) else { throw DisplayPresetError.displaySetMismatch }
        let savedByUUID = Dictionary(uniqueKeysWithValues: preset.displays.map { ($0.stableUUID, $0) })
        let liveByUUID = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0) })
        let enabled = preset.displays.filter(\.enabled)
        guard !enabled.isEmpty,
              enabled.filter(\.isMain).count == 1,
              let main = enabled.first(where: \.isMain), main.origin == .zero, main.mirrorMasterUUID == nil else {
            throw DisplayPresetError.invalidPreset
        }

        let entries = try preset.displays.map { saved -> Entry in
            guard !saved.stableUUID.isEmpty, DisplayArrangementPolicy.validOrigin(saved.origin),
                  saved.brightness.isFinite, (0...1).contains(saved.brightness),
                  saved.enabled || (!saved.isMain && saved.mirrorMasterUUID == nil),
                  let display = liveByUUID[saved.stableUUID] else { throw DisplayPresetError.invalidPreset }
            if let masterUUID = saved.mirrorMasterUUID {
                guard masterUUID != saved.stableUUID, let master = savedByUUID[masterUUID],
                      master.enabled, master.mirrorMasterUUID == nil, saved.origin == master.origin else {
                    throw DisplayPresetError.invalidPreset
                }
            }
            if saved.enabled != display.isEnabled {
                guard supportsDisplayPower, powerChangeableUUIDs.contains(saved.stableUUID) else {
                    throw DisplayPresetError.powerUnavailable(displayUUID: saved.stableUUID)
                }
            }
            var resolved: DisplayModeOption?
            if let mode = saved.mode {
                guard mode.width > 0, mode.height > 0, mode.pixelWidth > 0, mode.pixelHeight > 0,
                      mode.refreshRate.isFinite, mode.refreshRate >= 0 else { throw DisplayPresetError.invalidPreset }
                if saved.enabled {
                    let candidates = display.modes + (display.currentMode.map { [$0] } ?? [])
                    resolved = candidates.first(where: mode.matches)
                    // Disabled displays may expose no driver catalog until enabled. All modes
                    // already visible must be checked now; a hidden catalog is resolved later.
                    if resolved == nil, display.isEnabled || !display.modes.isEmpty {
                        throw DisplayPresetError.modeUnavailable(displayUUID: saved.stableUUID)
                    }
                }
            }
            let size = targetSize(saved: saved, display: display)
            if saved.enabled || display.isEnabled {
                guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
                    throw DisplayPresetError.invalidPreset
                }
            }
            return Entry(saved: saved, display: display, resolvedMode: resolved, targetSize: size)
        }

        let targetDisplays = entries.map { entry in
            DisplayInfo(id: entry.display.id, displayID: entry.display.displayID, name: entry.display.name,
                        isBuiltin: entry.display.isBuiltin, isMain: entry.saved.isMain,
                        mirrorMasterID: entry.saved.mirrorMasterUUID.flatMap { liveByUUID[$0]?.displayID },
                        modes: entry.display.modes, currentMode: entry.resolvedMode ?? entry.display.currentMode,
                        frame: CGRect(origin: entry.saved.origin, size: entry.targetSize), isEnabled: entry.saved.enabled)
        }
        do {
            try DisplayArrangementPolicy.validate(enabled.filter { $0.mirrorMasterUUID == nil }.map {
                DisplayPlacement(uuid: $0.stableUUID, origin: $0.origin)
            }, displays: targetDisplays)
        } catch { throw DisplayPresetError.invalidPreset }

        // Until extras are disabled, park them beside the desired topology. Otherwise CG
        // can move desired origins to make room for a screen that is about to disappear.
        let roots = entries.filter { $0.saved.enabled && $0.saved.mirrorMasterUUID == nil }
        guard let rightmost = roots.max(by: { $0.saved.origin.x + $0.targetSize.width < $1.saved.origin.x + $1.targetSize.width }) else {
            throw DisplayPresetError.invalidPreset
        }
        var nextX = rightmost.saved.origin.x + rightmost.targetSize.width
        let temporary = try entries.filter { !$0.saved.enabled && $0.display.isEnabled }.map { entry in
            let origin = CGPoint(x: nextX, y: rightmost.saved.origin.y)
            guard DisplayArrangementPolicy.validOrigin(origin) else { throw DisplayPresetError.invalidPreset }
            nextX += entry.display.frame.width
            guard nextX.isFinite, nextX <= CGFloat(Int32.max) else { throw DisplayPresetError.invalidPreset }
            return DisplayPlacement(uuid: entry.saved.stableUUID, origin: origin)
        }
        return Self(entries: entries, temporaryPlacements: temporary)
    }

    private static func targetSize(saved: DisplayPresetEntry, display: DisplayInfo) -> CGSize {
        guard let mode = saved.mode, saved.enabled else { return display.frame.size }
        let swapsAxes = display.currentMode.map {
            $0.width != $0.height && display.frame.width == CGFloat($0.height) && display.frame.height == CGFloat($0.width)
        } ?? false
        return CGSize(width: swapsAxes ? mode.height : mode.width, height: swapsAxes ? mode.width : mode.height)
    }
}

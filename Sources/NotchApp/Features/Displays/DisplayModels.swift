import CoreGraphics
import Foundation

struct DisplayInfo: Identifiable, Equatable {
    let id: String
    let displayID: UInt32
    let name: String
    let isBuiltin: Bool
    let isMain: Bool
    let mirrorMasterID: UInt32?
    let modes: [DisplayModeOption]
    let currentMode: DisplayModeOption?
    let frame: CGRect
    let isEnabled: Bool
    let physicalSize: CGSize?

    var aspectRatio: CGFloat {
        if let size = physicalSize, size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 {
            return size.width / size.height
        }
        return frame.height > 0 ? frame.width / frame.height : 1
    }

    init(id: String, displayID: UInt32, name: String, isBuiltin: Bool, isMain: Bool,
         mirrorMasterID: UInt32?, modes: [DisplayModeOption], currentMode: DisplayModeOption?,
         frame: CGRect = .zero, isEnabled: Bool = true, physicalSize: CGSize? = nil) {
        self.id = id
        self.displayID = displayID
        self.name = name
        self.isBuiltin = isBuiltin
        self.isMain = isMain
        self.mirrorMasterID = mirrorMasterID
        self.modes = modes
        self.currentMode = currentMode
        self.frame = frame
        self.isEnabled = isEnabled
        self.physicalSize = physicalSize
    }
}

struct DisplayPlacement: Equatable {
    let uuid: String
    let origin: CGPoint
}

struct DisplayModeOption: Identifiable, Hashable, Codable {
    let id: UInt32
    let width: Int
    let height: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let refreshRate: Double

    var isHiDPI: Bool { pixelWidth > width }

    var label: String {
        let rate = refreshRate > 0 ? " · \(refreshRate.formatted(.number.precision(.fractionLength(0...2)))) Гц" : ""
        return "\(width) × \(height)\(isHiDPI ? " · HiDPI" : "")\(rate)"
    }

    init(id: UInt32, width: Int, height: Int, pixelWidth: Int, pixelHeight: Int, refreshRate: Double) {
        self.id = id
        self.width = width
        self.height = height
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.refreshRate = refreshRate
    }

    init(_ mode: CGDisplayMode) {
        self.init(id: UInt32(bitPattern: mode.ioDisplayModeID), width: mode.width, height: mode.height,
                  pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight, refreshRate: mode.refreshRate)
    }

    /// Prefer the actual current mode when duplicate driver modes describe the same choice.
    static func deduplicated(_ modes: [DisplayModeOption], currentModeID: UInt32?) -> [DisplayModeOption] {
        struct Key: Hashable {
            let width: Int
            let height: Int
            let refreshRate: Double
            let isHiDPI: Bool
        }
        var unique: [Key: DisplayModeOption] = [:]
        for mode in modes {
            let key = Key(width: mode.width, height: mode.height, refreshRate: mode.refreshRate, isHiDPI: mode.isHiDPI)
            if unique[key] == nil || mode.id == currentModeID { unique[key] = mode }
        }
        return unique.values.sorted {
            if $0.width != $1.width { return $0.width > $1.width }
            if $0.height != $1.height { return $0.height > $1.height }
            if $0.isHiDPI != $1.isHiDPI { return $0.isHiDPI }
            if $0.refreshRate != $1.refreshRate { return $0.refreshRate > $1.refreshRate }
            return $0.id < $1.id
        }
    }
}

enum DisplayChange: Equatable {
    case mode(displayID: UInt32, modeID: UInt32)
    case main(displayID: UInt32)
    case mirror(displayID: UInt32, masterID: UInt32?)
    case enabled(displayID: UInt32, enabled: Bool)
    case arrangement([DisplayPlacement])
}

/// Retains the real driver mode rather than reconstructing a potentially lossy mode choice.
struct DisplayConfigurationSnapshot {
    struct Entry {
        let displayID: UInt32
        let uuid: String
        let mode: CGDisplayMode?
        let origin: CGPoint
        let mirrorMasterID: UInt32?
        let mirrorMasterUUID: String?
        let isEnabled: Bool
        let wasManagedDisabled: Bool

        init(displayID: UInt32, uuid: String, mode: CGDisplayMode?, origin: CGPoint,
             mirrorMasterID: UInt32?, mirrorMasterUUID: String?, isEnabled: Bool = true,
             wasManagedDisabled: Bool = false) {
            self.displayID = displayID
            self.uuid = uuid
            self.mode = mode
            self.origin = origin
            self.mirrorMasterID = mirrorMasterID
            self.mirrorMasterUUID = mirrorMasterUUID
            self.isEnabled = isEnabled
            self.wasManagedDisabled = wasManagedDisabled
        }
    }

    let entries: [Entry]

    init(entries: [Entry] = []) { self.entries = entries }
}

enum DisplayServiceError: LocalizedError {
    case coreGraphics(operation: String, code: Int32)
    case disconnected
    case unavailableMode
    case unavailableGamma
    case invalidOrigin
    case mirroredDisplayCannotBeMain
    case displayPowerUnavailable
    case lastEnabledDisplay
    case invalidArrangement
    case displayIdentityUnavailable

    var errorDescription: String? {
        switch self {
        case .coreGraphics(let operation, let code): "Не удалось \(operation) (CoreGraphics: \(code))."
        case .disconnected: "Дисплей отключён."
        case .unavailableMode: "Этот режим дисплея больше недоступен."
        case .unavailableGamma: "Программное затемнение недоступно для этого дисплея."
        case .invalidOrigin: "Не удалось определить расположение дисплея."
        case .mirroredDisplayCannotBeMain: "Сначала отключите зеркалирование этого дисплея."
        case .displayPowerUnavailable: "Включение и отключение дисплеев недоступно в этой версии macOS."
        case .lastEnabledDisplay: "Нельзя отключить последний активный дисплей."
        case .invalidArrangement: "Расположите все включённые дисплеи рядом без перекрытий; главный дисплей должен оставаться в точке 0, 0."
        case .displayIdentityUnavailable: "Не удалось безопасно определить дисплей для последующего включения."
        }
    }
}

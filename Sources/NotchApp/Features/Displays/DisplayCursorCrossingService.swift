import AppKit
import Carbon
import CoreGraphics

@MainActor
protocol DisplayCursorCrossingServing: AnyObject {
    var isRunning: Bool { get }
    var onFailure: (@MainActor (String) -> Void)? { get set }
    func start(displays: [DisplayInfo]) throws
    func stop()
}

enum DisplayCursorCrossingError: LocalizedError {
    case unavailable
    case monitorInstallation
    case topologyChanged
    case warp(CGError)

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Переход между краями дисплеев недоступен."
        case .monitorInstallation: return "Не удалось включить наблюдение за движением курсора."
        case .topologyChanged: return "Расположение дисплеев изменилось. Переход курсора приостановлен."
        case .warp(let error): return "Не удалось переместить курсор (\(error.rawValue)). Выключите и снова включите переход между краями."
        }
    }
}

@MainActor
final class UnavailableDisplayCursorCrossingService: DisplayCursorCrossingServing {
    var isRunning: Bool { false }
    var onFailure: (@MainActor (String) -> Void)?
    func start(displays: [DisplayInfo]) throws { throw DisplayCursorCrossingError.unavailable }
    func stop() {}
}

enum DisplayCursorCrossingEligibility {
    static func screens(from displays: [DisplayInfo]) -> [DisplayCursorCrossingScreen] {
        // A mirrored master is excluded as well: its apparent desktop edge is
        // shared by the whole group, rather than an independent destination.
        let masters = Set(displays.compactMap(\.mirrorMasterID))
        let ids = Dictionary(grouping: displays, by: \.displayID)
        let uuids = Dictionary(grouping: displays, by: { normalizedUUID($0.id) })
        return displays.compactMap { display in
            let uuid = normalizedUUID(display.id)
            guard display.isEnabled, display.mirrorMasterID == nil, !masters.contains(display.displayID),
                  display.displayID != 0, !uuid.isEmpty, ids[display.displayID]?.count == 1,
                  uuids[uuid]?.count == 1, valid(display.frame) else { return nil }
            return DisplayCursorCrossingScreen(uuid: uuid, displayID: display.displayID, frame: display.frame)
        }.sorted { $0.uuid == $1.uuid ? $0.displayID < $1.displayID : $0.uuid < $1.uuid }
    }

    static func normalizedUUID(_ uuid: String) -> String {
        uuid.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func valid(_ frame: CGRect) -> Bool {
        frame.origin.x.isFinite && frame.origin.y.isFinite && frame.width.isFinite && frame.height.isFinite
            && frame.maxX.isFinite && frame.maxY.isFinite && frame.width >= 8 && frame.height >= 8
    }
}

struct DisplayCursorCrossingSample {
    let location: CGPoint
    let delta: CGVector
    let timestamp: TimeInterval
    let pressedMouseButtons: Int
}

@MainActor
protocol DisplayCursorCrossingRuntime: AnyObject {
    var now: TimeInterval { get }
    var pressedMouseButtons: Int { get }
    var isSecureInputEnabled: Bool { get }
    func installGlobal(_ handler: @escaping @MainActor (DisplayCursorCrossingSample) -> Void) -> Any?
    func installLocal(_ handler: @escaping @MainActor (DisplayCursorCrossingSample) -> Void) -> Any?
    func removeMonitor(_ token: Any)
    func currentPointerLocation() -> CGPoint?
    func liveScreens() -> [DisplayCursorCrossingScreen]?
    func warp(to point: CGPoint) -> CGError
}

/// Mouse-only AppKit observers require neither Accessibility nor an event tap.
/// No listener runs while all shared edges already have native cursor coverage.
@MainActor
final class PublicDisplayCursorCrossingService: DisplayCursorCrossingServing {
    private(set) var isRunning = false
    var onFailure: (@MainActor (String) -> Void)?
    private let runtime: any DisplayCursorCrossingRuntime
    private var screens: [DisplayCursorCrossingScreen] = []
    private var monitors: [Any] = []
    private var generation: UInt64 = 0
    private var lastWarpAt: TimeInterval?

    init(runtime: any DisplayCursorCrossingRuntime = AppKitDisplayCursorCrossingRuntime()) {
        self.runtime = runtime
    }

    func start(displays: [DisplayInfo]) throws {
        let next = DisplayCursorCrossingEligibility.screens(from: displays)
        guard next != screens || !isRunning else { return }
        stop()
        screens = next
        guard DisplayCursorCrossingGeometry.hasUnalignedEdges(in: next) else { return }
        let installedGeneration = generation
        let handler: @MainActor (DisplayCursorCrossingSample) -> Void = { [weak self] sample in
            self?.receive(sample, generation: installedGeneration)
        }
        guard let global = runtime.installGlobal(handler) else {
            throw DisplayCursorCrossingError.monitorInstallation
        }
        guard let local = runtime.installLocal(handler) else {
            runtime.removeMonitor(global)
            generation &+= 1
            throw DisplayCursorCrossingError.monitorInstallation
        }
        monitors = [global, local]
        isRunning = true
    }

    func stop() {
        generation &+= 1
        isRunning = false
        let previous = monitors
        monitors.removeAll()
        screens = []
        lastWarpAt = nil
        for token in previous { runtime.removeMonitor(token) }
    }

    private func receive(_ sample: DisplayCursorCrossingSample, generation: UInt64) {
        guard isRunning, generation == self.generation else { return }
        let now = runtime.now, age = now - sample.timestamp
        guard age.isFinite, age >= 0, age <= 0.1,
              sample.pressedMouseButtons == 0, runtime.pressedMouseButtons == 0,
              !runtime.isSecureInputEnabled,
              lastWarpAt.map({ now - $0 >= 0.15 }) ?? true,
              let destination = DisplayCursorCrossingGeometry.destination(location: sample.location,
                  delta: sample.delta, displays: screens),
              let current = runtime.currentPointerLocation(),
              current.x.isFinite, current.y.isFinite,
              current.x >= destination.source.frame.minX, current.x < destination.source.frame.maxX,
              current.y >= destination.source.frame.minY, current.y < destination.source.frame.maxY,
              hypot(current.x - sample.location.x, current.y - sample.location.y) <= 2 else { return }
        // Query immediately before the only side effect. Numeric IDs alone are
        // insufficient: WindowServer can reuse them after a disconnection.
        guard let live = runtime.liveScreens(), live == screens else {
            fail(.topologyChanged)
            return
        }
        let result = runtime.warp(to: destination.point)
        guard result == .success else {
            fail(.warp(result))
            return
        }
        lastWarpAt = now
    }

    private func fail(_ error: DisplayCursorCrossingError) {
        stop()
        onFailure?(error.localizedDescription)
    }
}

/// The interval is restored even when a warp fails. Keep this change scoped to
/// the synchronous warp instead of altering the session's permanent policy.
enum DisplayCursorCrossingWarp {
    static func perform(to point: CGPoint, previousInterval: TimeInterval?,
                        setInterval: (TimeInterval) -> Void, warp: (CGPoint) -> CGError) -> CGError {
        guard let previousInterval, previousInterval.isFinite, previousInterval >= 0 else { return .cannotComplete }
        setInterval(0)
        defer { setInterval(previousInterval) }
        return warp(point)
    }
}

@MainActor
final class AppKitDisplayCursorCrossingRuntime: DisplayCursorCrossingRuntime {
    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    var pressedMouseButtons: Int { NSEvent.pressedMouseButtons }
    var isSecureInputEnabled: Bool { IsSecureEventInputEnabled() }

    func installGlobal(_ handler: @escaping @MainActor (DisplayCursorCrossingSample) -> Void) -> Any? {
        NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { event in
            // AppKit documents both monitor callbacks as main-thread callbacks.
            MainActor.assumeIsolated {
                if let sample = Self.sample(event) { handler(sample) }
            }
        }
    }

    func installLocal(_ handler: @escaping @MainActor (DisplayCursorCrossingSample) -> Void) -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { event in
            MainActor.assumeIsolated {
                if let sample = Self.sample(event) { handler(sample) }
            }
            return event
        }
    }

    func removeMonitor(_ token: Any) { NSEvent.removeMonitor(token) }

    func currentPointerLocation() -> CGPoint? {
        let location = NSEvent.mouseLocation
        let main = CGDisplayBounds(CGMainDisplayID())
        guard main.height.isFinite, main.height > 0 else { return nil }
        return CGPoint(x: location.x, y: main.height - location.y)
    }

    func liveScreens() -> [DisplayCursorCrossingScreen]? {
        let limit: UInt32 = 128
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(limit)), count: UInt32 = 0
        guard CGGetActiveDisplayList(limit, &ids, &count) == .success, count < limit else { return nil }
        var result: [DisplayCursorCrossingScreen] = []
        for id in ids.prefix(Int(count)) {
            guard CGDisplayIsActive(id) != 0, CGDisplayIsOnline(id) != 0,
                  CGDisplayIsAsleep(id) == 0, CGDisplayIsInMirrorSet(id) == 0 else { continue }
            guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
                  let string = CFUUIDCreateString(nil, uuid) else { return nil }
            let frame = CGDisplayBounds(id)
            guard DisplayCursorCrossingEligibility.valid(frame) else { return nil }
            result.append(DisplayCursorCrossingScreen(uuid: DisplayCursorCrossingEligibility.normalizedUUID(string as String),
                                                      displayID: id, frame: frame))
        }
        guard Set(result.map(\.uuid)).count == result.count,
              Set(result.map(\.displayID)).count == result.count else { return nil }
        return result.sorted { $0.uuid == $1.uuid ? $0.displayID < $1.displayID : $0.uuid < $1.uuid }
    }

    func warp(to point: CGPoint) -> CGError {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return .cannotComplete }
        return DisplayCursorCrossingWarp.perform(to: point, previousInterval: source.localEventsSuppressionInterval,
            setInterval: { source.localEventsSuppressionInterval = $0 }, warp: CGWarpMouseCursorPosition)
    }

    private static func sample(_ event: NSEvent) -> DisplayCursorCrossingSample? {
        guard let cgEvent = event.cgEvent else { return nil }
        return DisplayCursorCrossingSample(location: cgEvent.location,
            delta: CGVector(dx: cgEvent.getDoubleValueField(.mouseEventDeltaX),
                            dy: cgEvent.getDoubleValueField(.mouseEventDeltaY)),
            timestamp: event.timestamp, pressedMouseButtons: NSEvent.pressedMouseButtons)
    }
}

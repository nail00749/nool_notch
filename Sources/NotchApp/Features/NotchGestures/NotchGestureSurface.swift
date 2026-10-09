import AppKit
import SwiftUI

enum NotchClickDecision: Equatable {
    case scheduleSingle
    case performDouble
    case ignore
}

struct NotchDoubleClickPolicy {
    static var systemInterval: TimeInterval {
        let interval = NSEvent.doubleClickInterval
        return interval.isFinite && interval > 0 ? interval : 0.5
    }

    private(set) var firstClick: (time: TimeInterval, point: CGPoint)?
    private var pressed: (decision: NotchClickDecision, point: CGPoint)?

    mutating func mouseDown(at time: TimeInterval, point: CGPoint,
                            clickCount: Int, interval: TimeInterval) -> NotchClickDecision {
        if clickCount > 2 {
            firstClick = nil
            pressed = nil
            return .ignore
        }
        if clickCount == 2, let firstClick,
           time - firstClick.time >= 0, time - firstClick.time <= interval,
           hypot(point.x - firstClick.point.x, point.y - firstClick.point.y) <= 8 {
            self.firstClick = nil
            pressed = (.performDouble, point)
            return .performDouble
        }
        firstClick = (time, point)
        pressed = (.scheduleSingle, point)
        return .scheduleSingle
    }

    mutating func dragged(to point: CGPoint) -> Bool {
        guard let pressed,
              hypot(point.x - pressed.point.x, point.y - pressed.point.y) > 8 else { return false }
        cancel()
        return true
    }

    mutating func mouseUp(at point: CGPoint) -> NotchClickDecision {
        guard let pressed else { return .ignore }
        self.pressed = nil
        guard hypot(point.x - pressed.point.x, point.y - pressed.point.y) <= 8 else {
            cancel()
            return .ignore
        }
        return pressed.decision
    }

    mutating func resolveSingle() -> Bool {
        guard firstClick != nil else { return false }
        firstClick = nil
        return true
    }

    mutating func cancel() {
        firstClick = nil
        pressed = nil
    }
}

enum NotchScrollDecision: Equatable {
    case pass
    case consume(step: Int?)
}

struct NotchScrollVolumePolicy {
    private enum Axis { case undecided, horizontal, vertical }
    private var axis = Axis.undecided
    private var horizontalDistance = 0.0
    private var verticalDistance = 0.0
    private var lastEventAt = -Double.infinity
    private(set) var accumulated = 0.0
    private(set) var lastStepAt = -Double.infinity

    mutating func process(vertical: Double, horizontal: Double,
                          precise: Bool, momentum: Bool, modified: Bool,
                          began: Bool, ended: Bool,
                          time: TimeInterval) -> NotchScrollDecision {
        if began || precise && time - lastEventAt > 0.25 { reset() }
        lastEventAt = time
        guard !momentum, !modified, vertical.isFinite, horizontal.isFinite else {
            if ended { reset() }
            return .pass
        }
        if precise {
            horizontalDistance += horizontal
            verticalDistance += vertical
            if axis == .undecided, max(abs(horizontalDistance), abs(verticalDistance)) >= 8 {
                if abs(horizontalDistance) > abs(verticalDistance) * 1.2 {
                    axis = .horizontal
                } else if abs(verticalDistance) > abs(horizontalDistance) * 1.2 {
                    axis = .vertical
                }
            }
        } else {
            axis = abs(vertical) > abs(horizontal) * 1.2 && vertical != 0 ? .vertical : .horizontal
        }
        guard axis == .vertical else {
            if ended || !precise { reset() }
            return .pass
        }

        let threshold = precise ? 24.0 : 1.0
        if accumulated.sign != vertical.sign && accumulated != 0 && vertical != 0 { accumulated = 0 }
        accumulated = min(max(accumulated + vertical, -threshold * 2), threshold * 2)
        var step: Int?
        if abs(accumulated) >= threshold, time - lastStepAt >= 0.085 {
            step = accumulated > 0 ? 1 : -1
            accumulated -= Double(step!) * threshold
            lastStepAt = time
        }
        if ended || !precise { reset() }
        return .consume(step: step)
    }

    mutating func reset() {
        axis = .undecided
        horizontalDistance = 0
        verticalDistance = 0
        lastEventAt = -Double.infinity
        accumulated = 0
    }
}

/// A passive view: mouse hit testing remains with the existing SwiftUI controls.
/// The local monitor handles only events inside this view in its own window.
struct NotchGestureSurface: NSViewRepresentable {
    let preferences: NotchGesturePreferences
    let isCompact: Bool
    let onSingleClick: () -> Void
    let onDoubleClick: (NotchDoubleClickAction) -> Void
    let onVolume: (NotchVolumeAdjustmentResult) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PassiveView {
        let view = PassiveView()
        context.coordinator.trackedView = view
        context.coordinator.configure(from: self)
        context.coordinator.startMonitoring()
        return view
    }

    func updateNSView(_ view: PassiveView, context: Context) {
        context.coordinator.trackedView = view
        context.coordinator.configure(from: self)
    }

    static func dismantleNSView(_ view: PassiveView, coordinator: Coordinator) {
        coordinator.stopMonitoring()
    }

    final class PassiveView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    @MainActor
    final class Coordinator {
        weak var trackedView: NSView?
        private var preferences = NotchGesturePreferences()
        private var isCompact = false
        private var onSingleClick: () -> Void = {}
        private var onDoubleClick: (NotchDoubleClickAction) -> Void = { _ in }
        private var onVolume: (NotchVolumeAdjustmentResult) -> Void = { _ in }
        private var eventMonitor: Any?
        private var pendingSingleTask: Task<Void, Never>?
        private var clickPolicy = NotchDoubleClickPolicy()
        private var scrollPolicy = NotchScrollVolumePolicy()
        private var consumeNextMouseUp = false
        private let volume = NotchGestureVolumeHandler(controller: CoreAudioVolumeController())

        func configure(from surface: NotchGestureSurface) {
            if preferences.doubleClickAction != surface.preferences.doubleClickAction ||
                (isCompact && !surface.isCompact) {
                cancelPendingClick()
            }
            if preferences.scrollVolumeEnabled != surface.preferences.scrollVolumeEnabled {
                scrollPolicy.reset()
            }
            preferences = surface.preferences
            isCompact = surface.isCompact
            onSingleClick = surface.onSingleClick
            onDoubleClick = surface.onDoubleClick
            onVolume = surface.onVolume
        }

        func startMonitoring() {
            guard eventMonitor == nil else { return }
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [
                .scrollWheel, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
                .rightMouseDown, .otherMouseDown
            ]) { [weak self] event in
                guard let self else { return event }
                return self.handle(event)
            }
        }

        func stopMonitoring() {
            if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
            eventMonitor = nil
            cancelPendingClick()
            scrollPolicy.reset()
            trackedView = nil
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let trackedView, let window = trackedView.window else { return event }
            guard event.window === window else {
                if event.type == .leftMouseDown || event.type == .leftMouseUp ||
                    event.type == .rightMouseDown || event.type == .otherMouseDown {
                    cancelPendingClick()
                }
                return event
            }
            let point = trackedView.convert(event.locationInWindow, from: nil)
            let isInside = trackedView.bounds.contains(point)

            switch event.type {
            case .scrollWheel:
                return handleScroll(event, isInside: isInside)
            case .leftMouseDown:
                guard isInside, preferences.doubleClickAction != .disabled else {
                    cancelPendingClick()
                    return event
                }
                guard event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else {
                    cancelPendingClick()
                    return event
                }
                consumeNextMouseUp = true
                switch clickPolicy.mouseDown(at: event.timestamp, point: point,
                                             clickCount: event.clickCount,
                                             interval: NotchDoubleClickPolicy.systemInterval) {
                case .scheduleSingle:
                    pendingSingleTask?.cancel()
                    pendingSingleTask = nil
                    if isCompact { NotchGestureInteraction.shared.setResolvingCompactClick(true) }
                case .performDouble:
                    pendingSingleTask?.cancel()
                    pendingSingleTask = nil
                case .ignore:
                    cancelPendingClick(keepingMouseUp: true)
                }
                return nil
            case .leftMouseUp:
                guard consumeNextMouseUp else { return event }
                consumeNextMouseUp = false
                guard isInside else {
                    cancelPendingClick()
                    return nil
                }
                switch clickPolicy.mouseUp(at: point) {
                case .scheduleSingle: scheduleSingleClick()
                case .performDouble:
                    if isCompact { NotchGestureInteraction.shared.setResolvingCompactClick(false) }
                    onDoubleClick(preferences.doubleClickAction)
                case .ignore:
                    if isCompact { NotchGestureInteraction.shared.setResolvingCompactClick(false) }
                }
                return nil
            case .leftMouseDragged:
                if clickPolicy.dragged(to: point) {
                    cancelPendingClick(keepingMouseUp: true)
                }
                return event
            case .rightMouseDown, .otherMouseDown:
                cancelPendingClick()
                return event
            default:
                return event
            }
        }

        private func handleScroll(_ event: NSEvent, isInside: Bool) -> NSEvent? {
            guard isInside, preferences.scrollVolumeEnabled else {
                scrollPolicy.reset()
                return event
            }
            let modified = !event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
            let vertical = Double(event.scrollingDeltaY)
            let horizontal = Double(event.scrollingDeltaX)
            let decision = scrollPolicy.process(
                vertical: vertical, horizontal: horizontal,
                precise: event.hasPreciseScrollingDeltas,
                momentum: !event.momentumPhase.isEmpty, modified: modified,
                began: event.phase.contains(.began) || event.phase.contains(.mayBegin),
                ended: event.phase.contains(.ended) || event.phase.contains(.cancelled),
                time: event.timestamp
            )
            guard case .consume(let direction) = decision else { return event }
            if let direction,
               let result = volume.adjust(direction: direction, step: preferences.volumeStep) {
                onVolume(result)
            }
            return nil
        }

        private func scheduleSingleClick() {
            pendingSingleTask?.cancel()
            pendingSingleTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(NotchDoubleClickPolicy.systemInterval)) }
                catch { return }
                guard let self, self.clickPolicy.resolveSingle() else { return }
                self.pendingSingleTask = nil
                if self.isCompact { NotchGestureInteraction.shared.setResolvingCompactClick(false) }
                self.onSingleClick()
            }
        }

        private func cancelPendingClick(keepingMouseUp: Bool = false) {
            pendingSingleTask?.cancel()
            pendingSingleTask = nil
            clickPolicy.cancel()
            if !keepingMouseUp { consumeNextMouseUp = false }
            if isCompact, !keepingMouseUp || !consumeNextMouseUp {
                NotchGestureInteraction.shared.setResolvingCompactClick(false)
            }
        }
    }
}

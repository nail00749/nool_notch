import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

enum DockWindowAction: String, CaseIterable, Hashable, Sendable, Identifiable {
    case activate, close, minimize, zoom, leftHalf, rightHalf, nextDisplay
    var id: Self { self }
    var title: String {
        switch self {
        case .activate: "Открыть окно"
        case .close: "Закрыть"
        case .minimize: "Свернуть"
        case .zoom: "Развернуть"
        case .leftHalf: "Левая половина"
        case .rightHalf: "Правая половина"
        case .nextDisplay: "На следующий дисплей"
        }
    }
    var systemImage: String {
        switch self {
        case .activate: "macwindow"
        case .close: "xmark"
        case .minimize: "minus"
        case .zoom: "arrow.up.left.and.arrow.down.right"
        case .leftHalf: "rectangle.lefthalf.filled"
        case .rightHalf: "rectangle.righthalf.filled"
        case .nextDisplay: "display.2"
        }
    }
}

enum DockWindowMatching {
    /// Intentionally strict: title alone, an ordinal, or the focused window never establishes identity.
    static func matches(title: String, frame: CGRect, candidateTitle: String, candidateFrame: CGRect) -> Bool {
        title == candidateTitle && framesMatch(frame, candidateFrame)
    }

    static func framesMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        let values = [lhs.minX, lhs.minY, lhs.width, lhs.height, rhs.minX, rhs.minY, rhs.width, rhs.height]
        return values.allSatisfy(\.isFinite) && lhs.width > 0 && lhs.height > 0 && rhs.width > 0 && rhs.height > 0
            && abs(lhs.minX - rhs.minX) <= 1 && abs(lhs.minY - rhs.minY) <= 1
            && abs(lhs.width - rhs.width) <= 1 && abs(lhs.height - rhs.height) <= 1
    }

    static func uniqueIndex(title: String, frame: CGRect, candidates: [(String, CGRect)]) -> Int? {
        let indices = candidates.indices.filter {
            matches(title: title, frame: frame, candidateTitle: candidates[$0].0, candidateFrame: candidates[$0].1)
        }
        return indices.count == 1 ? indices[0] : nil
    }
}

struct DockWindowServerDescriptor: Sendable {
    let id: UInt32
    let pid: Int32
    let title: String
    let frame: CGRect
    let isOnScreen: Bool
    var layer: Int = 0
    var alpha: Double = 1
}

enum DockWindowServerMetadata {
    static func windows(for pid: Int32) -> [DockWindowServerDescriptor] {
        let rows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (row[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let id = (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let bounds = row[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.width > 1, frame.height > 1 else { return nil }
            return .init(id: id, pid: pid, title: row[kCGWindowName as String] as? String ?? "", frame: frame,
                         isOnScreen: row[kCGWindowIsOnscreen as String] as? Bool ?? false,
                         alpha: (row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1)
        }
    }

    static func isCurrent(_ record: DockWindowRecord) -> Bool {
        windows(for: record.application.pid).contains {
            $0.id == record.id && DockWindowMatching.matches(title: record.title, frame: record.frame,
                                                             candidateTitle: $0.title, candidateFrame: $0.frame)
        }
    }
}

struct DockAccessibilityWindow: Sendable {
    let token: UUID
    let title: String
    let frame: CGRect
    let isMinimized: Bool
    let actions: Set<DockWindowAction>
}

/// WindowServer includes application's invisible implementation windows. AX standard-window
/// evidence preserves real minimized/other-Space windows without exposing those backing surfaces.
enum DockWindowRecordBuilder {
    static func records(application: DockWindowApplicationIdentity,
                        descriptors: [DockWindowServerDescriptor], accessibility: [DockAccessibilityWindow],
                        captureWindowIDs: Set<UInt32>) -> [DockWindowRecord] {
        var seenIDs = Set<UInt32>()
        let eligible = descriptors.filter { descriptor in
            guard descriptor.pid == application.pid, descriptor.layer == 0, descriptor.alpha > 0,
                  DockWindowMatching.framesMatch(descriptor.frame, descriptor.frame),
                  seenIDs.insert(descriptor.id).inserted else { return false }
            if descriptor.isOnScreen { return true }
            if accessibility.contains(where: { matches(descriptor, $0) }) { return true }
            // Without an AX list, a named nonvisible window can belong to another Space. Hidden
            // unnamed surfaces have no evidence that they are actual user-facing windows.
            return accessibility.isEmpty && !descriptor.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.sorted { $0.isOnScreen && !$1.isOnScreen }

        var usedTokens = Set<UUID>()
        var result: [DockWindowRecord] = []
        for descriptor in eligible.prefix(24) {
            let candidates = accessibility.filter { matches(descriptor, $0) }
            let unique = candidates.count == 1 && eligible.filter { matches($0, candidates[0]) }.count == 1
                ? candidates[0] : nil
            // Deduplication establishes representation only. A title/geometry race must never
            // grant an exact-window action through a geometry-only guess.
            candidates.forEach { usedTokens.insert($0.token) }
            if candidates.isEmpty {
                let sameFrame = accessibility.filter {
                    !$0.isMinimized && DockWindowMatching.framesMatch(descriptor.frame, $0.frame)
                }
                if sameFrame.count == 1 && eligible.filter({
                    DockWindowMatching.framesMatch($0.frame, descriptor.frame)
                }).count == 1 {
                    let window = sameFrame[0]
                    usedTokens.insert(window.token)
                    if descriptor.title.isEmpty,
                       let index = accessibility.firstIndex(where: { $0.token == window.token }) {
                        // A redacted CG title cannot prove the capture/AX association. Preserve
                        // the directly retained AX window and its name/actions, without a guessed ID.
                        result.append(.init(id: UInt32.max - UInt32(index), application: application,
                                            title: window.title, frame: window.frame, isMinimized: window.isMinimized,
                                            captureWindowID: nil, accessibilityToken: window.token,
                                            availableActions: window.actions))
                        continue
                    }
                }
            }
            result.append(.init(id: descriptor.id, application: application, title: unique?.title ?? descriptor.title,
                                frame: descriptor.frame, isMinimized: unique?.isMinimized ?? false,
                                captureWindowID: captureWindowIDs.contains(descriptor.id) ? descriptor.id : nil,
                                accessibilityToken: unique?.token, availableActions: unique?.actions ?? []))
        }
        for (index, window) in accessibility.enumerated() where !usedTokens.contains(window.token) && result.count < 24 {
            let synthetic = UInt32.max - UInt32(index)
            guard !result.contains(where: { $0.id == synthetic }) else { continue }
            result.append(.init(id: synthetic, application: application, title: window.title, frame: window.frame,
                                isMinimized: window.isMinimized, captureWindowID: nil,
                                accessibilityToken: window.token, availableActions: window.actions))
        }
        return result
    }

    private static func matches(_ descriptor: DockWindowServerDescriptor, _ window: DockAccessibilityWindow) -> Bool {
        (!descriptor.isOnScreen || !window.isMinimized)
            && DockWindowMatching.matches(title: descriptor.title, frame: descriptor.frame,
                                          candidateTitle: window.title, candidateFrame: window.frame)
    }
}

/// Only this serial worker holds AX references. It never acts on a focused-window or ordinal fallback.
actor DockWindowActions {
    private struct RetainedWindow {
        let application: DockWindowApplicationIdentity
        let element: AXUIElement
    }
    private var retained: [UUID: RetainedWindow] = [:]
    private static let messagingTimeout: Float = 0.15

    nonisolated static func isCurrent(_ identity: DockWindowApplicationIdentity) -> Bool {
        guard let application = NSRunningApplication(processIdentifier: identity.pid), !application.isTerminated,
              let launchDate = application.launchDate, let url = application.bundleURL else { return false }
        return identity.launchDate == launchDate
            && identity.applicationPath == url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    func snapshot(_ identity: DockWindowApplicationIdentity) -> [DockAccessibilityWindow] {
        // Replace only this application's references: an action in another, still open
        // preview keeps its exact window. Terminated applications are pruned.
        retained = retained.filter { $0.value.application != identity && Self.isCurrent($0.value.application) }
        if retained.count > 256 { retained = [:] }
        guard AXIsProcessTrusted(), Self.isCurrent(identity) else { return [] }
        let application = AXUIElementCreateApplication(identity.pid)
        AXUIElementSetMessagingTimeout(application, Self.messagingTimeout)
        let deadline = Date().addingTimeInterval(3)
        var result: [DockAccessibilityWindow] = []
        for window in Self.windows(application).prefix(32) {
            if Task.isCancelled || Date() > deadline { break }
            AXUIElementSetMessagingTimeout(window, Self.messagingTimeout)
            guard Self.isStandardWindow(window), let frame = Self.frame(window) else { continue }
            let token = UUID()
            let minimized = Self.bool(window, kAXMinimizedAttribute) ?? false
            retained[token] = .init(application: identity, element: window)
            result.append(.init(token: token, title: Self.string(window, kAXTitleAttribute) ?? "", frame: frame,
                                isMinimized: minimized, actions: Self.availableActions(window, minimized: minimized)))
        }
        return result
    }

    func perform(_ action: DockWindowAction, on record: DockWindowRecord,
                 screens: [WindowLayoutScreen]) async throws {
        try Task.checkCancellation()
        guard AXIsProcessTrusted() else { throw DockWindowPreviewError.permission }
        guard Self.isCurrent(record.application), let token = record.accessibilityToken,
              let saved = retained[token], saved.application == record.application else {
            throw DockWindowPreviewError.unavailable
        }
        if record.captureWindowID != nil && !DockWindowServerMetadata.isCurrent(record) {
            throw DockWindowPreviewError.unavailable
        }
        let application = AXUIElementCreateApplication(record.application.pid)
        AXUIElementSetMessagingTimeout(application, Self.messagingTimeout)
        let deadline = Date().addingTimeInterval(3)
        var live: [AXUIElement] = []
        for candidate in Self.windows(application).prefix(32) {
            try Task.checkCancellation()
            guard Date() <= deadline else { throw DockWindowPreviewError.timeout }
            AXUIElementSetMessagingTimeout(candidate, Self.messagingTimeout)
            guard Self.isStandardWindow(candidate), let frame = Self.frame(candidate) else { continue }
            if DockWindowMatching.matches(title: record.title, frame: record.frame,
                                           candidateTitle: Self.string(candidate, kAXTitleAttribute) ?? "",
                                           candidateFrame: frame) { live.append(candidate) }
        }
        guard Date() <= deadline else { throw DockWindowPreviewError.timeout }
        guard live.count == 1 else { throw DockWindowPreviewError.ambiguous }
        let window = live[0]
        guard CFEqual(saved.element, window), Self.isCurrent(record.application),
              Self.pid(window) == record.application.pid else { throw DockWindowPreviewError.unavailable }
        let minimized = Self.bool(window, kAXMinimizedAttribute) ?? false
        guard Self.availableActions(window, minimized: minimized).contains(action) else {
            throw DockWindowPreviewError.unsupported
        }
        try Task.checkCancellation()
        switch action {
        case .activate:
            if minimized {
                guard AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse) == .success else {
                    throw DockWindowPreviewError.failed
                }
            }
            guard AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success else {
                throw DockWindowPreviewError.failed
            }
            _ = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            if Self.settable(window, kAXFocusedAttribute) {
                _ = AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            }
            guard Self.isCurrent(record.application),
                  let app = NSRunningApplication(processIdentifier: record.application.pid),
                  app.activate(options: []) else { throw DockWindowPreviewError.failed }
            // Activating an application is insufficient evidence that this exact window was selected.
            var selected = false
            for _ in 0..<4 {
                try Task.checkCancellation()
                guard Self.isCurrent(record.application) else { throw DockWindowPreviewError.unavailable }
                if let focused = Self.element(application, kAXFocusedWindowAttribute), CFEqual(focused, window) {
                    selected = true
                    break
                }
                try await Task.sleep(for: .milliseconds(75))
            }
            guard selected else { throw DockWindowPreviewError.unsupported }
        case .close:
            try Self.pressButton(window, kAXCloseButtonAttribute)
            // A save dialog belongs to the target application. Never dismiss it automatically.
            if Self.isCurrent(record.application) {
                _ = NSRunningApplication(processIdentifier: record.application.pid)?.activate(options: [])
            }
        case .minimize:
            guard AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue) == .success else {
                throw DockWindowPreviewError.failed
            }
        case .zoom:
            try Self.pressButton(window, kAXZoomButtonAttribute)
        case .leftHalf, .rightHalf, .nextDisplay:
            guard let frame = Self.frame(window) else { throw DockWindowPreviewError.unavailable }
            let current = WindowLayoutRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height)
            let placement: WindowLayoutAction = action == .leftHalf ? .left : action == .rightHalf ? .right : .nextDisplay
            guard let target = WindowLayoutGeometry.target(for: placement, current: current, screens: screens) else {
                throw DockWindowPreviewError.unsupported
            }
            try Self.move(window, from: current, to: target)
        }
    }

    private static func move(_ window: AXUIElement, from original: WindowLayoutRect,
                             to target: WindowLayoutRect) throws {
        guard target.isUsable else { throw DockWindowPreviewError.unsupported }
        var size = CGSize(width: target.width, height: target.height)
        var point = CGPoint(x: target.x, y: target.y)
        guard let sizeValue = AXValueCreate(.cgSize, &size),
              let positionValue = AXValueCreate(.cgPoint, &point),
              AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue) == .success else {
            throw DockWindowPreviewError.failed
        }
        guard AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue) == .success else {
            var previous = CGSize(width: original.width, height: original.height)
            if let value = AXValueCreate(.cgSize, &previous) {
                _ = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
            }
            throw DockWindowPreviewError.failed
        }
        guard let result = frame(window),
              DockWindowMatching.framesMatch(result, CGRect(x: target.x, y: target.y,
                                                            width: target.width, height: target.height)) else {
            throw DockWindowPreviewError.unsupported
        }
    }

    private static func availableActions(_ window: AXUIElement, minimized: Bool) -> Set<DockWindowAction> {
        var result = Set<DockWindowAction>()
        if supports(window, kAXRaiseAction), !minimized || settable(window, kAXMinimizedAttribute) { result.insert(.activate) }
        if let close = element(window, kAXCloseButtonAttribute), supports(close, kAXPressAction), bool(close, kAXEnabledAttribute) != false {
            result.insert(.close)
        }
        if !minimized, settable(window, kAXMinimizedAttribute) { result.insert(.minimize) }
        if !minimized, bool(window, "AXFullScreen") != true {
            if let zoom = element(window, kAXZoomButtonAttribute), supports(zoom, kAXPressAction), bool(zoom, kAXEnabledAttribute) != false {
                result.insert(.zoom)
            }
            if settable(window, kAXPositionAttribute), settable(window, kAXSizeAttribute) {
                result.formUnion([.leftHalf, .rightHalf, .nextDisplay])
            }
        }
        return result
    }

    private static func pressButton(_ window: AXUIElement, _ attribute: String) throws {
        guard let button = element(window, attribute), supports(button, kAXPressAction),
              bool(button, kAXEnabledAttribute) != false,
              AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else {
            throw DockWindowPreviewError.failed
        }
    }

    private static func windows(_ application: AXUIElement) -> [AXUIElement] {
        guard let raw = attribute(application, kAXWindowsAttribute), CFGetTypeID(raw) == CFArrayGetTypeID() else { return [] }
        let array = unsafeDowncast(raw, to: CFArray.self)
        return (0..<min(CFArrayGetCount(array), 32)).compactMap { index in
            let rawElement = unsafeBitCast(CFArrayGetValueAtIndex(array, index), to: CFTypeRef.self)
            guard CFGetTypeID(rawElement) == AXUIElementGetTypeID() else { return nil }
            return unsafeDowncast(rawElement, to: AXUIElement.self)
        }
    }
    private static func pid(_ element: AXUIElement) -> Int32? {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }
    private static func isStandardWindow(_ window: AXUIElement) -> Bool {
        guard string(window, kAXRoleAttribute) == kAXWindowRole as String else { return false }
        return string(window, kAXSubroleAttribute).map { $0 == kAXStandardWindowSubrole as String } ?? true
    }
    private static func supports(_ element: AXUIElement, _ action: String) -> Bool {
        var names: CFArray?
        return AXUIElementCopyActionNames(element, &names) == .success && (names as? [String])?.contains(action) == true
    }
    private static func settable(_ element: AXUIElement, _ key: String) -> Bool {
        var flag = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, key as CFString, &flag) == .success && flag.boolValue
    }
    private static func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute), let size = attribute(element, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeDowncast(size, to: AXValue.self), .cgSize, &dimensions) else { return nil }
        let result = CGRect(origin: point, size: dimensions)
        return DockWindowMatching.framesMatch(result, result) ? result : nil
    }
    private static func element(_ source: AXUIElement, _ key: String) -> AXUIElement? {
        guard let value = attribute(source, key), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeDowncast(value, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return element
    }
    private static func bool(_ element: AXUIElement, _ key: String) -> Bool? { attribute(element, key) as? Bool }
    private static func string(_ element: AXUIElement, _ key: String) -> String? { attribute(element, key) as? String }
    private static func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value
    }
}

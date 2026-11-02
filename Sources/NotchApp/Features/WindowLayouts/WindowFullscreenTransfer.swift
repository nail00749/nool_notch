import Foundation
import OSLog

struct WindowFullscreenState: Sendable {
    let isFullscreen: Bool
    let frame: WindowLayoutRect
    let canMoveAndResize: Bool
}

/// The backend owns one retained window identity throughout the transition.
protocol WindowFullscreenTransferBackend: Sendable {
    func read() async -> WindowFullscreenState?
    func setFullscreen(_ enabled: Bool) async -> Bool
    func move(to frame: WindowLayoutRect) async -> Bool
    func pause() async throws
}

struct WindowFullscreenTransferResult: Sendable {
    let message: String
    let didMove: Bool
    let normalOriginal: WindowLayoutOriginalPlacement?
}

enum WindowFullscreenTransfer {
    static func trace(_ message: @autoclosure () -> String) {
        #if DEBUG
        let rendered = message()
        Logger(subsystem: "com.nool.window-management", category: "fullscreen-transfer")
            .notice("\(rendered, privacy: .public)")
        #endif
    }
    private enum Failure: Error {
        case disappeared, exitRefused, exitTimeout, moveRefused, moveTimeout, enterRefused, enterTimeout

        var message: String {
            switch self {
            case .disappeared: "Окно стало недоступно во время переноса."
            case .exitRefused: "Приложение не разрешило выйти из полноэкранного режима."
            case .exitTimeout: "Приложение не завершило выход из полноэкранного режима."
            case .moveRefused: "Приложение не разрешило перенести окно на другой дисплей."
            case .moveTimeout: "Не удалось подтвердить перенос окна на другой дисплей."
            case .enterRefused: "Приложение не разрешило вернуть полноэкранный режим."
            case .enterTimeout: "Не удалось подтвердить полноэкранный режим на нужном дисплее."
            }
        }
    }

    private enum Wait {
        case normal(WindowLayoutRect)
        case moved(String)
        case fullscreen(WindowLayoutScreen)
    }

    static func run<B: WindowFullscreenTransferBackend>(action: WindowLayoutAction,
        initial: WindowFullscreenState, screens: [WindowLayoutScreen], backend: B) async -> WindowFullscreenTransferResult {
        guard action == .nextDisplay || action == .previousDisplay,
              let source = WindowLayoutGeometry.screen(for: initial.frame, in: screens),
              let target = WindowLayoutGeometry.target(for: action, current: initial.frame, screens: screens),
              let destination = WindowLayoutGeometry.screen(for: target, in: screens), destination.id != source.id else {
            return .init(message: "Подключён только один доступный дисплей.", didMove: false, normalOriginal: nil)
        }
        var normalOriginal: WindowLayoutOriginalPlacement?
        trace("Start fullscreen transfer: x=\(initial.frame.x), y=\(initial.frame.y), w=\(initial.frame.width), h=\(initial.frame.height)")
        var didMove = false
        var exitRequested = false
        do {
            try Task.checkCancellation()
            exitRequested = true
            guard await backend.setFullscreen(false) else { throw Failure.exitRefused }
            let normal = try await wait(.normal(initial.frame), screens: screens, backend: backend, failure: .exitTimeout)
            guard let restoredScreen = WindowLayoutGeometry.screen(for: normal.frame, in: screens) else { throw Failure.disappeared }
            normalOriginal = .init(frame: normal.frame, displayID: restoredScreen.id)
            let placement = WindowLayoutGeometry.restore(
                WindowLayoutGeometry.normalize(normal.frame, in: restoredScreen.visibleFrame), to: destination.visibleFrame)
            try Task.checkCancellation()
            guard await backend.move(to: placement) else { throw Failure.moveRefused }
            _ = try await wait(.moved(destination.id), screens: screens, backend: backend, failure: .moveTimeout)
            didMove = true
            try Task.checkCancellation()
            guard await backend.setFullscreen(true) else { throw Failure.enterRefused }
            _ = try await wait(.fullscreen(destination), screens: screens, backend: backend, failure: .enterTimeout)
            return .init(message: "Окно перенесено на другой дисплей в полноэкранном режиме.",
                         didMove: true, normalOriginal: normalOriginal)
        } catch {
            let reason = error is CancellationError ? "Перенос отменён." : (error as? Failure)?.message ?? "Не удалось перенести окно."
            trace("Transfer failed: \(reason)")
            guard exitRequested else { return .init(message: reason, didMove: false, normalOriginal: nil) }
            // A refusal or cancellation may arrive after the app has already moved the window.
            if let state = await backend.read() {
                didMove = WindowLayoutGeometry.screen(for: state.frame, in: screens)?.id == destination.id
            }
            let recoveryScreen = didMove ? destination : source
            let recovery = await Task.detached {
                await recover(on: recoveryScreen, screens: screens, backend: backend)
            }.value
            let location = didMove ? "целевом" : "исходном"
            let suffix = recovery
                ? "Полноэкранный режим восстановлен на \(location) дисплее."
                : "Не удалось восстановить полноэкранный режим. Проверьте окно и включите его вручную."
            return .init(message: "\(reason) \(suffix)", didMove: didMove, normalOriginal: normalOriginal)
        }
    }

    private static func recover<B: WindowFullscreenTransferBackend>(on screen: WindowLayoutScreen,
        screens: [WindowLayoutScreen], backend: B) async -> Bool {
        guard let state = await backend.read() else { return false }
        do {
            if state.isFullscreen {
                // An earlier exit request may still be pending even though AX reports the
                // old full-screen state. Reassert the desired state before confirming it.
                guard await backend.setFullscreen(true) else { return false }
                _ = try await wait(.fullscreen(screen), screens: screens, backend: backend, failure: .enterTimeout)
                return true
            }
            if WindowLayoutGeometry.screen(for: state.frame, in: screens)?.id != screen.id {
                guard let currentScreen = WindowLayoutGeometry.screen(for: state.frame, in: screens) else { return false }
                let frame = WindowLayoutGeometry.restore(
                    WindowLayoutGeometry.normalize(state.frame, in: currentScreen.visibleFrame), to: screen.visibleFrame)
                guard await backend.move(to: frame) else { return false }
                _ = try await wait(.moved(screen.id), screens: screens, backend: backend, failure: .moveTimeout)
            }
            guard await backend.setFullscreen(true) else { return false }
            _ = try await wait(.fullscreen(screen), screens: screens, backend: backend, failure: .enterTimeout)
            return true
        } catch { return false }
    }

    private static func wait<B: WindowFullscreenTransferBackend>(_ phase: Wait,
        screens: [WindowLayoutScreen], backend: B, failure: Failure) async throws -> WindowFullscreenState {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        var previous: WindowLayoutRect?
        var stable = 0
        var entryRetries = 0
        var normalFrame: WindowLayoutRect?
        var normalSamples = 0
        for attempt in 0..<50 {
            try Task.checkCancellation()
            guard clock.now < deadline else { break }
            guard let state = await backend.read() else { throw Failure.disappeared }
            let ready: Bool
            switch phase {
            case .normal(let fullscreenFrame):
                // Some apps publish AXFullScreen=false before restoring their frame. An unchanged
                // frame can also be legitimate; allow it after at least one second of settling.
                ready = !state.isFullscreen && (!near(state.frame, fullscreenFrame)
                    || (attempt >= 10 && state.canMoveAndResize))
            case .moved(let id):
                ready = !state.isFullscreen && WindowLayoutGeometry.screen(for: state.frame, in: screens)?.id == id
            case .fullscreen(let screen):
                ready = state.isFullscreen && WindowLayoutGeometry.screen(for: state.frame, in: screens)?.id == screen.id
                    && state.frame.width >= screen.frame.width * 0.9 && state.frame.height >= screen.frame.height * 0.9
                // An app can acknowledge AXFullScreen=true while a previous Spaces transition
                // is still finishing, then ignore it. Retry only an unchanged, movable normal
                // window on the destination; never interrupt an observable fullscreen transition.
                if !state.isFullscreen, state.canMoveAndResize,
                   WindowLayoutGeometry.screen(for: state.frame, in: screens)?.id == screen.id {
                    normalSamples = normalFrame.map { near($0, state.frame) } == true ? normalSamples + 1 : 1
                    normalFrame = state.frame
                    if normalSamples >= 8, entryRetries < 2 {
                        try Task.checkCancellation()
                        guard await backend.setFullscreen(true) else { throw Failure.enterRefused }
                        entryRetries += 1
                        normalSamples = 0
                        normalFrame = nil
                        trace("Retry ignored fullscreen entry, attempt=\(entryRetries)")
                    }
                } else {
                    normalSamples = 0
                    normalFrame = nil
                }
            }
            stable = ready && previous.map { near($0, state.frame) } == true ? stable + 1 : (ready ? 1 : 0)
            if stable >= 3 {
                trace("Settled: full=\(state.isFullscreen), x=\(state.frame.x), y=\(state.frame.y), w=\(state.frame.width), h=\(state.frame.height)")
                return state
            }
            previous = ready ? state.frame : nil
            try await backend.pause()
        }
        throw failure
    }

    private static func near(_ lhs: WindowLayoutRect, _ rhs: WindowLayoutRect) -> Bool {
        abs(lhs.x - rhs.x) <= 2 && abs(lhs.y - rhs.y) <= 2
            && abs(lhs.width - rhs.width) <= 2 && abs(lhs.height - rhs.height) <= 2
    }
}

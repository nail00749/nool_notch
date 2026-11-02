import Foundation

protocol WindowFrameApplicationBackend: Sendable {
    func readFrame() async -> WindowLayoutRect?
    func setPosition(x: Double, y: Double) async -> Bool
    func setSize(width: Double, height: Double) async -> Bool
    func pause() async throws
}

/// AX setters acknowledge a request before some applications finish constraining their
/// window. Apply position first, then verify the observed frame rather than the ACKs.
enum WindowFrameApplication {
    struct Result: Sendable {
        let didApply: Bool
        let needsRestore: Bool
    }

    private enum Failure: Error { case rejected, unavailable }

    static func run(target: WindowLayoutRect, original: WindowLayoutRect, changeSize: Bool,
                    backend: any WindowFrameApplicationBackend) async -> Result {
        guard target.isUsable, original.isUsable else { return .init(didApply: false, needsRestore: false) }
        do {
            for _ in 0..<3 {
                try Task.checkCancellation()
                guard let before = await backend.readFrame() else { throw Failure.unavailable }
                if !positionMatches(before, target) {
                    guard await backend.setPosition(x: target.x, y: target.y) else { throw Failure.rejected }
                    try await backend.pause()
                }
                try Task.checkCancellation()
                // Position can restore an application's preferred size. Read again even if
                // the size matched before moving, then reassert only when it is missing.
                guard let positioned = await backend.readFrame() else { throw Failure.unavailable }
                if changeSize, !sizeMatches(positioned, target) {
                    guard await backend.setSize(width: target.width, height: target.height) else { throw Failure.rejected }
                    try await backend.pause()
                }
                if try await settles(at: target, backend: backend) {
                    try Task.checkCancellation()
                    return .init(didApply: true, needsRestore: false)
                }
            }
        } catch {
            // Rejected requests and cancellation both need the same bounded cleanup.
        }
        let restored = await Task.detached {
            await rollback(original: original, changeSize: changeSize, backend: backend)
        }.value
        return .init(didApply: false, needsRestore: !restored)
    }

    private static func rollback(original: WindowLayoutRect, changeSize: Bool,
                                 backend: any WindowFrameApplicationBackend) async -> Bool {
        do {
            guard let current = await backend.readFrame() else { return false }
            if matches(current, original) { return true }
            // Continue after a rejected intermediate request: restoring the size can make
            // the final position acceptable again. Only the final observed frame decides.
            _ = await backend.setPosition(x: original.x, y: original.y)
            try await backend.pause()
            guard let positioned = await backend.readFrame() else { return false }
            if changeSize, !sizeMatches(positioned, original) {
                _ = await backend.setSize(width: original.width, height: original.height)
                try await backend.pause()
            }
            _ = await backend.setPosition(x: original.x, y: original.y)
            try await backend.pause()
            return try await settles(at: original, backend: backend)
        } catch { return false }
    }

    private static func settles(at target: WindowLayoutRect,
                                backend: any WindowFrameApplicationBackend) async throws -> Bool {
        var matchingReads = 0
        for attempt in 0..<6 {
            try Task.checkCancellation()
            guard let frame = await backend.readFrame() else { return false }
            matchingReads = matches(frame, target) ? matchingReads + 1 : 0
            if matchingReads >= 2 { return true }
            if attempt < 5 { try await backend.pause() }
        }
        return false
    }

    private static func matches(_ lhs: WindowLayoutRect, _ rhs: WindowLayoutRect) -> Bool {
        positionMatches(lhs, rhs) && sizeMatches(lhs, rhs)
    }
    private static func positionMatches(_ lhs: WindowLayoutRect, _ rhs: WindowLayoutRect) -> Bool {
        abs(lhs.x - rhs.x) <= 2 && abs(lhs.y - rhs.y) <= 2
    }
    private static func sizeMatches(_ lhs: WindowLayoutRect, _ rhs: WindowLayoutRect) -> Bool {
        abs(lhs.width - rhs.width) <= 2 && abs(lhs.height - rhs.height) <= 2
    }
}

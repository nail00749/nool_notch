import AppKit
import XCTest
@testable import NotchApp

@MainActor
final class ScreenParametersChangeObserverTests: XCTestCase {
    func testStartupCapturesPlacedStateWithoutRepositioning() {
        var reads = 0
        var changes = 0
        let signature = snapshot()
        let observer = ScreenParametersChangeObserver(
            capture: { reads += 1; return signature },
            onChange: { changes += 1 }
        )

        XCTAssertEqual(reads, 1)
        XCTAssertEqual(changes, 0)
        withExtendedLifetime(observer) {}
    }

    func testRepeatedUnchangedNotificationsReadOncePerCoalescedBurstWithoutRepositioning() {
        var pending: [@MainActor () -> Void] = []
        var reads = 0
        var changes = 0
        let signature = snapshot()
        let observer = ScreenParametersChangeObserver(
            capture: { reads += 1; return signature },
            schedule: { pending.append($0) },
            onChange: { changes += 1 }
        )

        for _ in 0..<3 {
            for _ in 0..<20 { observer.parametersDidChange() }
            XCTAssertEqual(pending.count, 1)
            pending.removeFirst()()
        }

        XCTAssertEqual(reads, 4)
        XCTAssertEqual(changes, 0)
    }

    func testCoalescingUsesNewestStateAndRemembersItBeforeCallback() {
        let initial = snapshot()
        let intermediate = snapshot(mainDisplayID: 2)
        let newest = snapshot(screens: [screen(), screen(displayID: 2)], mainDisplayID: 2)
        var current = initial
        var pending: [@MainActor () -> Void] = []
        var delivered: [ScreenParametersSignature] = []
        let observer = ScreenParametersChangeObserver(
            capture: { current },
            schedule: { pending.append($0) },
            onChange: { delivered.append(current) }
        )

        current = intermediate
        observer.parametersDidChange()
        current = newest
        observer.parametersDidChange()
        XCTAssertTrue(delivered.isEmpty)
        XCTAssertEqual(pending.count, 1)
        pending.removeFirst()()
        XCTAssertEqual(delivered, [newest])

        observer.parametersDidChange()
        pending.removeFirst()()
        XCTAssertEqual(delivered, [newest])

        current = initial
        observer.parametersDidChange()
        pending.removeFirst()()
        XCTAssertEqual(delivered, [newest, initial])
    }

    func testEveryPlacementAndIdentityChangeTriggersReposition() {
        let second = screen(displayID: 2)
        let variants = [
            snapshot(mainDisplayID: 2),
            snapshot(screens: []),
            snapshot(screens: [screen(), second]),
            snapshot(screens: [screen(displayID: 3)]),
            snapshot(screens: [screen(uuid: "replacement")]),
            snapshot(screens: [screen(name: "Renamed Display")]),
            snapshot(screens: [screen(isBuiltIn: true)]),
            snapshot(screens: [screen(frame: CGRect(x: 1, y: 0, width: 1920, height: 1080))]),
            snapshot(screens: [screen(visibleFrame: CGRect(x: 0, y: 30, width: 1920, height: 1050))]),
            snapshot(screens: [screen(scale: 2)]),
            snapshot(screens: [screen(safeArea: .init(top: 30, left: 0, bottom: 0, right: 0))]),
            snapshot(screens: [screen(auxiliaryTopLeft: CGRect(x: 0, y: 1050, width: 900, height: 30))]),
            snapshot(screens: [screen(auxiliaryTopRight: CGRect(x: 1000, y: 1050, width: 920, height: 30))])
        ]

        for variant in variants {
            var current = snapshot()
            var changes = 0
            let observer = ScreenParametersChangeObserver(
                capture: { current }, schedule: { $0() }, onChange: { changes += 1 }
            )
            current = variant
            observer.parametersDidChange()
            observer.parametersDidChange()
            XCTAssertEqual(changes, 1, "Changed signature: \(variant)")
        }
    }

    func testScreenOrderChangeTriggersRepositionWithoutMainChange() {
        var current = snapshot(screens: [screen(), screen(displayID: 2)])
        var changes = 0
        let observer = ScreenParametersChangeObserver(
            capture: { current }, schedule: { $0() }, onChange: { changes += 1 }
        )
        current = snapshot(screens: Array(current.screens.reversed()))
        observer.parametersDidChange()
        XCTAssertEqual(changes, 1)
    }

    func testTransientStateReturningToInitialBeforeDeliveryDoesNotReposition() {
        let initial = snapshot()
        var current = initial
        var pending: [@MainActor () -> Void] = []
        var changes = 0
        let observer = ScreenParametersChangeObserver(
            capture: { current }, schedule: { pending.append($0) }, onChange: { changes += 1 }
        )
        current = snapshot(mainDisplayID: 2)
        observer.parametersDidChange()
        current = initial
        pending.removeFirst()()
        XCTAssertEqual(changes, 0)
    }

    private func snapshot(
        screens: [ScreenParametersSignature.Screen]? = nil,
        mainDisplayID: CGDirectDisplayID? = 1
    ) -> ScreenParametersSignature {
        .init(screens: screens ?? [screen()], mainDisplayID: mainDisplayID)
    }

    private func screen(
        displayID: CGDirectDisplayID = 1,
        uuid: String = "display-1",
        name: String = "Display",
        isBuiltIn: Bool = false,
        frame: CGRect = CGRect(x: 0, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect = CGRect(x: 0, y: 0, width: 1920, height: 1080),
        scale: CGFloat = 1,
        safeArea: ScreenParametersSignature.Insets = .init(top: 0, left: 0, bottom: 0, right: 0),
        auxiliaryTopLeft: CGRect? = nil,
        auxiliaryTopRight: CGRect? = nil
    ) -> ScreenParametersSignature.Screen {
        .init(displayID: displayID, uuid: uuid, name: name, isBuiltIn: isBuiltIn,
              frame: frame, visibleFrame: visibleFrame, scale: scale, safeArea: safeArea,
              auxiliaryTopLeft: auxiliaryTopLeft, auxiliaryTopRight: auxiliaryTopRight)
    }
}

import XCTest
@testable import NotchApp

final class DockHandoffTests: XCTestCase {
    func testReadsDeviceModelFromIdentifier() {
        XCTAssertEqual(DockHandoffItem.deviceName(from: "com.apple.iphone-15-pro-max-1"), "iPhone 15 Pro Max")
        XCTAssertEqual(DockHandoffItem.deviceName(from: "com.apple.ipad-pro-11-1"), "iPad Pro 11")
        XCTAssertEqual(DockHandoffItem.deviceName(from: "com.apple.macbook-pro-14"), "MacBook Pro 14")
        XCTAssertNil(DockHandoffItem.deviceName(from: ""))
    }
}

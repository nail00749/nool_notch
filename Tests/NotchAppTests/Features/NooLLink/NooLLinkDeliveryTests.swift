import Foundation
import Network
import XCTest
@testable import NotchApp

final class NooLLinkDeliveryTests: XCTestCase {
    func testReceivedFilesAreRenamedFinderStyleInsteadOfOverwritten() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nool-delivery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try NooLLinkService.writeUnique(Data("one".utf8), named: "Report.pdf", in: directory)
        let second = try NooLLinkService.writeUnique(Data("two".utf8), named: "Report.pdf", in: directory)
        let bare = try NooLLinkService.writeUnique(Data("a".utf8), named: "README", in: directory)
        let bareSecond = try NooLLinkService.writeUnique(Data("b".utf8), named: "README", in: directory)

        XCTAssertEqual(first.lastPathComponent, "Report.pdf")
        XCTAssertEqual(second.lastPathComponent, "Report 2.pdf")
        XCTAssertEqual(bare.lastPathComponent, "README")
        XCTAssertEqual(bareSecond.lastPathComponent, "README 2")
        XCTAssertEqual(try Data(contentsOf: first), Data("one".utf8))
        XCTAssertEqual(try Data(contentsOf: second), Data("two".utf8))
    }

    func testOnlyThisMacsOwnAddressesSkipAirDropConsent() {
        XCTAssertTrue(AirDropReceiver.isThisMac(.hostPort(host: .ipv4(.loopback), port: 8770)))
        XCTAssertTrue(AirDropReceiver.isThisMac(.hostPort(host: .ipv6(.loopback), port: 8770)))
        // Documentation range (RFC 5737), never assigned to a local interface.
        XCTAssertFalse(AirDropReceiver.isThisMac(.hostPort(host: .ipv4(IPv4Address("192.0.2.44")!), port: 8770)))
        XCTAssertFalse(AirDropReceiver.isThisMac(.hostPort(host: .ipv6(IPv6Address("fe80::1234:5678:9abc:def0")!), port: 8770)))
    }
}

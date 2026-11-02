import Foundation
import Network
import XCTest
@testable import NotchApp

final class NooLLinkProtocolTests: XCTestCase {
    func testRejectsTraversalAndWindowsSpecialNames() {
        for name in ["", ".", "..", "../secret", "folder/file", "folder\\file", "C:secret", "CON", "nul.txt", "LPT1.csv", "tail.", "tail ", "bad\u{0}name"] {
            XCTAssertFalse(NooLLinkEnvelope.safeFilename(name), name)
        }
        for name in ["Фото.png", "report 2026.pdf", "COM10.txt", ".gitignore"] {
            XCTAssertTrue(NooLLinkEnvelope.safeFilename(name), name)
        }
    }

    func testRejectsExpiredPayloadAndMalformedIdentity() throws {
        let now = Date()
        let valid = envelope(at: now, text: "hello")
        XCTAssertNoThrow(try valid.validated(now: now))
        XCTAssertThrowsError(try valid.validated(now: now.addingTimeInterval(301)))
        let invalid = NooLLinkEnvelope(id: "not-an-id", originDeviceID: UUID().uuidString,
                                      createdAt: valid.createdAt, kind: "text", text: "hello")
        XCTAssertThrowsError(try invalid.validated(now: now))
    }

    func testRejectsMixedFormatsAndOversizedText() {
        var item = envelope(at: Date(), text: "hello")
        item.imageBase64 = Data([1, 2, 3]).base64EncodedString()
        XCTAssertThrowsError(try item.validated())
        XCTAssertThrowsError(try envelope(at: Date(), text: String(repeating: "x", count: 1024 * 1024 + 1)).validated())
    }

    func testRejectsDuplicateFileNamesAndEncodedTraversal() {
        let data = Data("sample".utf8).base64EncodedString()
        let now = ISO8601DateFormatter().string(from: Date())
        for files in [[NooLLinkFile(name: "a.txt", dataBase64: data), NooLLinkFile(name: "A.txt", dataBase64: data)],
                      [NooLLinkFile(name: "../a", dataBase64: data)], [NooLLinkFile(name: "a", dataBase64: "invalid")]] {
            let item = NooLLinkEnvelope(id: UUID().uuidString, originDeviceID: UUID().uuidString,
                                       createdAt: now, kind: "files", files: files)
            XCTAssertThrowsError(try item.validated())
        }
    }

    func testTokenComparisonAndEntropy() throws {
        let token = try NooLLinkKeychain.randomToken()
        XCTAssertEqual(token.count, 43)
        XCTAssertTrue(NooLLinkKeychain.equal(token, token))
        XCTAssertFalse(NooLLinkKeychain.equal(token, try NooLLinkKeychain.randomToken()))
        XCTAssertFalse(NooLLinkKeychain.equal(token, token + "x"))
    }

    func testOnlyPrivateOrLinkLocalPeersAreAccepted() {
        for address in ["192.168.1.7", "10.1.2.3", "172.16.0.1", "169.254.1.1", "127.0.0.1"] {
            XCTAssertTrue(NooLLinkHTTPServer.isLocal(.hostPort(host: .ipv4(IPv4Address(address)!), port: 443)))
        }
        for address in ["8.8.8.8", "185.1.2.3", "172.32.0.1", "100.64.0.1"] {
            XCTAssertFalse(NooLLinkHTTPServer.isLocal(.hostPort(host: .ipv4(IPv4Address(address)!), port: 443)))
        }
    }

    private func envelope(at date: Date, text: String) -> NooLLinkEnvelope {
        NooLLinkEnvelope(id: UUID().uuidString, originDeviceID: UUID().uuidString,
                         createdAt: ISO8601DateFormatter().string(from: date), kind: "text", text: text)
    }
}

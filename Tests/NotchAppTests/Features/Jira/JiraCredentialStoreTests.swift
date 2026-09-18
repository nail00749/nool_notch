import Foundation
import XCTest
@testable import NotchApp

@MainActor
final class JiraCredentialStoreTests: XCTestCase {
    func testTokenLifecyclePersistsReplacesAndDeletesKeychainItem() throws {
        let service = "com.nailuyltyev.NotchApp.tests.\(UUID().uuidString)"
        let store = KeychainJiraCredentialStore(service: service, account: "test-token")
        defer { try? store.deleteToken() }

        XCTAssertNil(try store.loadToken())

        try store.saveToken("first-secret")
        XCTAssertEqual(try store.loadToken(), "first-secret")

        try store.saveToken("replacement-secret")
        XCTAssertEqual(try store.loadToken(), "replacement-secret")

        try store.deleteToken()
        XCTAssertNil(try store.loadToken())
    }
}

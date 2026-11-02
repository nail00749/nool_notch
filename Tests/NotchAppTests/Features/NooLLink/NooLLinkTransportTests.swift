import CryptoKit
import Foundation
import Network
import Security
import XCTest
@testable import NotchApp

final class NooLLinkTransportTests: XCTestCase {
    func testEphemeralIdentityCanBeImportedWithoutUserKeychain() throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("Memory-only PKCS12 import requires macOS 15") }
        let identity = try NooLLinkIdentity.ephemeral()
        XCTAssertEqual(identity.fingerprint.count, 64)
        XCTAssertNotNil(sec_identity_create(identity.identity))
    }

    func testPinnedLoopbackTLSRejectsUnauthorizedHTTP() async throws {
        guard ProcessInfo.processInfo.environment["NOOL_LINK_NETWORK_TESTS"] == "1" else {
            throw XCTSkip("Set NOOL_LINK_NETWORK_TESTS=1 to exercise a loopback TLS listener")
        }
        guard #available(macOS 15.0, *) else { throw XCTSkip("Memory-only PKCS12 import requires macOS 15") }
        let identity = try NooLLinkIdentity.ephemeral()
        let server = NooLLinkHTTPServer(port: .any)
        defer { server.stop() }
        let ready = expectation(description: "TLS listener ready")
        let port = LockedPort()
        try server.start(identity: identity, authorize: { request in
            request.headers["authorization"] == "Bearer test-token"
        }, handle: { _ in
            .init(status: 200, body: Data("{\"ok\":true}".utf8))
        }, ready: { value in
            if port.setOnce(value) { ready.fulfill() }
        }, failure: { message in
            port.setError(message)
        })
        await fulfillment(of: [ready], timeout: 10)
        let value = try XCTUnwrap(port.value, port.error ?? "Listener did not open a port")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 10
        let delegate = PinnedTestDelegate(fingerprint: identity.fingerprint)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let url = try XCTUnwrap(URL(string: "https://127.0.0.1:\(value)/v1/clipboard"))
        let (_, unauthorized) = try await session.data(from: url)
        XCTAssertEqual((unauthorized as? HTTPURLResponse)?.statusCode, 401)
        var request = URLRequest(url: url)
        request.setValue("Bearer test-token", forHTTPHeaderField: "Authorization")
        let (data, authorized) = try await session.data(for: request)
        XCTAssertEqual((authorized as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), "{\"ok\":true}")
    }
}

private final class LockedPort: @unchecked Sendable {
    private let lock = NSLock()
    private var received = false
    private var stored: UInt16?
    private var storedError: String?
    var value: UInt16? { lock.lock(); defer { lock.unlock() }; return stored }
    var error: String? { lock.lock(); defer { lock.unlock() }; return storedError }
    func setError(_ message: String) { lock.lock(); defer { lock.unlock() }; storedError = message }
    func setOnce(_ value: UInt16?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !received else { return false }
        received = true; stored = value
        return true
    }
}

private final class PinnedTestDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    let fingerprint: String
    init(fingerprint: String) { self.fingerprint = fingerprint }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let certificate = chain.first else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        let actual = SHA256.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02x", $0) }.joined()
        if NooLLinkKeychain.equal(actual, fingerprint) { completionHandler(.useCredential, URLCredential(trust: trust)) }
        else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }
}

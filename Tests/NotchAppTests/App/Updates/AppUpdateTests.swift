import Foundation
import XCTest
@testable import NotchApp

final class AppUpdateTests: XCTestCase {
    func testSemanticVersionComparisonUsesNumericComponents() throws {
        let current = try XCTUnwrap(AppVersion("1.9.9"))
        let latest = try XCTUnwrap(AppVersion("v1.10.0"))

        XCTAssertLessThan(current, latest)
        XCTAssertEqual(AppVersion("0.3.0"), AppVersion("v0.3.0"))
        XCTAssertNil(AppVersion("release-next"))
    }

    func testPrereleaseIsOlderThanStableAndUsesNumericIdentifierOrdering() throws {
        let beta2 = try XCTUnwrap(AppVersion("0.4.0-beta.2"))
        let beta10 = try XCTUnwrap(AppVersion("0.4.0-beta.10"))
        let stable = try XCTUnwrap(AppVersion("0.4.0"))

        XCTAssertLessThan(beta2, beta10)
        XCTAssertLessThan(beta10, stable)
        XCTAssertEqual(beta2.description, "0.4.0-beta.2")
    }

    func testLatestReleaseRequestAndResponsePreservePublishedMetadata() async throws {
        let transport = RecordingAppUpdateTransport(
            data: Data(
                #"{"tag_name":"v0.4.0","name":"Nool Notch 0.4.0","body":"Added\n- Display profiles","html_url":"https://github.com/nail00749/nool_notch/releases/tag/v0.4.0","published_at":"2026-09-09T10:00:00Z"}"#.utf8
            )
        )
        let client = GitHubReleaseClient(transport: transport)

        let release = try await client.latestRelease()

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://api.github.com/repos/nail00749/nool_notch/releases/latest"
        )
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
        XCTAssertNotNil(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"))
        XCTAssertEqual(release.version, AppVersion("0.4.0"))
        XCTAssertEqual(release.title, "Nool Notch 0.4.0")
        XCTAssertEqual(release.notes, "Added\n- Display profiles")
        XCTAssertEqual(release.pageURL.absoluteString, "https://github.com/nail00749/nool_notch/releases/tag/v0.4.0")
        XCTAssertNotNil(release.publishedAt)
    }

    func testLatestReleaseRejectsUnsuccessfulHTTPResponse() async {
        let transport = RecordingAppUpdateTransport(data: Data(), statusCode: 503)
        let client = GitHubReleaseClient(transport: transport)

        do {
            _ = try await client.latestRelease()
            XCTFail("Expected an HTTP status error")
        } catch {
            XCTAssertEqual(error as? AppUpdateError, .httpStatus(503))
        }
    }

    func testAvailabilityDistinguishesNewerEqualAndOlderRelease() throws {
        let installed = try XCTUnwrap(AppVersion("0.4.0"))

        XCTAssertEqual(
            AppUpdateAvailability(installed: installed, latest: try XCTUnwrap(AppVersion("0.5.0"))),
            .updateAvailable
        )
        XCTAssertEqual(
            AppUpdateAvailability(installed: installed, latest: try XCTUnwrap(AppVersion("0.4.0"))),
            .upToDate
        )
        XCTAssertEqual(
            AppUpdateAvailability(installed: installed, latest: try XCTUnwrap(AppVersion("0.3.0"))),
            .developmentBuild
        )
    }
}

private final class RecordingAppUpdateTransport: AppUpdateHTTPTransport, @unchecked Sendable {
    private let data: Data
    private let statusCode: Int
    private(set) var requests: [URLRequest] = []

    init(data: Data, statusCode: Int = 200) {
        self.data = data
        self.statusCode = statusCode
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return (
            data,
            HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
        )
    }
}

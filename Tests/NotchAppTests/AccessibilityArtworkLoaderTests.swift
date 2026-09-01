import Foundation
import XCTest
@testable import NotchApp

final class AccessibilityArtworkLoaderTests: XCTestCase {
    private let secureURL = URL(string: "https://example.com/artwork.png")!
    private let tinyPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    )!

    func testArtworkRejectsInsecureURLWithoutFetching() async {
        do {
            _ = try await AccessibilityArtworkLoader.load(
                url: URL(string: "http://example.com/artwork.png")!
            ) { _ in
                XCTFail("Fetch must not run for an insecure URL")
                throw AccessibilityArtworkError.invalidResponse
            }
            XCTFail("Expected insecure URL rejection")
        } catch {
            XCTAssertEqual(error as? AccessibilityArtworkError, .insecureURL)
        }
    }

    func testArtworkAcceptsBoundedImageResponse() async throws {
        let image = tinyPNG
        let result = try await AccessibilityArtworkLoader.load(url: secureURL) { request in
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "image/png"]
                )
            )
            return (image, response)
        }

        XCTAssertEqual(result, tinyPNG)
    }

    func testArtworkRejectsOversizedAndNonImageResponses() async {
        await assertArtworkError(.responseTooLarge) { request in
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "Content-Type": "image/png",
                        "Content-Length": "6000000"
                    ]
                )
            )
            return (Data(), response)
        }

        await assertArtworkError(.unsupportedContentType) { request in
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "text/html"]
                )
            )
            return (Data("not an image".utf8), response)
        }
    }

    private func assertArtworkError(
        _ expected: AccessibilityArtworkError,
        fetch: @escaping AccessibilityArtworkLoader.Fetch
    ) async {
        do {
            _ = try await AccessibilityArtworkLoader.load(url: secureURL, fetch: fetch)
            XCTFail("Expected \(expected)")
        } catch {
            XCTAssertEqual(error as? AccessibilityArtworkError, expected)
        }
    }
}

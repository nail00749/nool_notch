import AppKit
import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import NotchApp

@MainActor
final class TextRecognitionServiceTests: XCTestCase {
    func testReadingOrderGroupsRowsWithoutNontransitiveComparison() {
        // Adjacent y distances are within the row tolerance, but the endpoints are not.
        let boxes = [
            CGRect(x: 0.8, y: 0.89, width: 0.1, height: 0.02),
            CGRect(x: 0.1, y: 0.875, width: 0.1, height: 0.02),
            CGRect(x: 0.0, y: 0.86, width: 0.1, height: 0.02)
        ]

        let order = TextRecognitionService.readingOrder(for: boxes)

        XCTAssertEqual(order, [1, 0, 2])
        XCTAssertEqual(Set(order), Set(boxes.indices))
    }

    func testRejectsUnsupportedAndCorruptInputWithoutTruncatingSelection() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let unsupported = directory.appendingPathComponent("notes.txt")
        let corruptImage = directory.appendingPathComponent("broken.png")
        try Data("hello".utf8).write(to: unsupported)
        try Data("not an image".utf8).write(to: corruptImage)

        XCTAssertFalse(TextRecognitionService.supports(url: unsupported))
        XCTAssertTrue(TextRecognitionService.supports(url: corruptImage))
        let unsupportedError = await failure(for: [unsupported]) as? TextRecognitionError
        let corruptError = await failure(for: [corruptImage]) as? TextRecognitionError
        let tooManyError = await failure(for: Array(repeating: corruptImage, count: 11))
            as? TextRecognitionError
        XCTAssertEqual(unsupportedError, .unsupportedFormat("notes.txt"))
        XCTAssertEqual(corruptError, .invalidImage("broken.png"))
        XCTAssertEqual(tooManyError, .tooManyFiles)
    }

    func testCancellationBeforeRecognitionStopsTheWorker() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appendingPathComponent("scan.png")
        try makeImageData().write(to: image)
        let cancellation = TextRecognitionCancellation()
        cancellation.cancel()

        do {
            _ = try await TextRecognitionService.recognize(urls: [image], cancellation: cancellation)
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected before any Vision request is made.
        }
    }

    func testRecognizesTextInGeneratedImageAndScannedPDF() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageURL = directory.appendingPathComponent("scan.png")
        let pdfURL = directory.appendingPathComponent("scanned.pdf")
        let imageData = try makeImageData()
        try imageData.write(to: imageURL)
        try makeScannedPDF(from: imageData, at: pdfURL)

        let imageText = try await TextRecognitionService.recognize(urls: [imageURL])
        let pdfText = try await TextRecognitionService.recognize(urls: [pdfURL])

        XCTAssertTrue(imageText.localizedCaseInsensitiveContains("HELLO"), imageText)
        XCTAssertTrue(pdfText.localizedCaseInsensitiveContains("HELLO"), pdfText)
    }

    private func failure(for urls: [URL]) async -> Error? {
        do {
            _ = try await TextRecognitionService.recognize(urls: urls)
            return nil
        } catch {
            return error
        }
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nool-ocr-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeImageData() throws -> Data {
        let image = NSImage(size: NSSize(width: 1_000, height: 300))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 1_000, height: 300).fill()
        ("HELLO NOOL" as NSString).draw(
            at: NSPoint(x: 38, y: 85),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 105, weight: .bold),
                .foregroundColor: NSColor.black
            ]
        )
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return png
    }

    private func makeScannedPDF(from imageData: Data, at url: URL) throws {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var box = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        context.beginPDFPage(nil)
        context.draw(image, in: box)
        context.endPDFPage()
        context.closePDF()
    }
}

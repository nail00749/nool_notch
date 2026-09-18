import CoreText
import Foundation
import ImageIO
import XCTest
@testable import NotchApp

final class AIChatAttachmentLoaderTests: XCTestCase {
    func testLoadsUTF8SourceText() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let file = fixture.directory.appendingPathComponent("sample.swift")
        try Data("let value = 42\n".utf8).write(to: file)

        let attachment = try AIChatAttachmentLoader.load(url: file)
        XCTAssertEqual(attachment.name, "sample.swift")
        XCTAssertEqual(attachment.kind, .text)
        XCTAssertEqual(attachment.text, "let value = 42\n")
        XCTAssertEqual(attachment.mimeType, "text/plain")
    }

    func testRejectsOversizeAndSymbolicLinkFiles() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let oversized = fixture.directory.appendingPathComponent("large.txt")
        try Data(repeating: 0, count: 10 * 1024 * 1024 + 1).write(to: oversized)
        XCTAssertEqual(try loaderError(for: oversized), .fileTooLarge)

        let target = fixture.directory.appendingPathComponent("target.txt")
        let symlink = fixture.directory.appendingPathComponent("link.txt")
        try Data("secret".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
        XCTAssertEqual(try loaderError(for: symlink), .regularFileRequired)
    }

    func testRejectsOversizeOrBinaryTextBeforeAttachmentCreation() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let longText = fixture.directory.appendingPathComponent("long.txt")
        try Data(String(repeating: "a", count: 12_001).utf8).write(to: longText)
        XCTAssertEqual(try loaderError(for: longText), .textTooLarge)

        let binaryText = fixture.directory.appendingPathComponent("binary.txt")
        try Data([0x61, 0x00, 0x62]).write(to: binaryText)
        XCTAssertEqual(try loaderError(for: binaryText), .binaryText)
    }

    func testExtractsBoundedTextFromPDF() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let file = fixture.directory.appendingPathComponent("notes.pdf")
        try makePDF(text: "План релиза").write(to: file)

        let attachment = try AIChatAttachmentLoader.load(url: file)
        XCTAssertEqual(attachment.kind, .text)
        XCTAssertEqual(attachment.mimeType, "application/pdf")
        XCTAssertTrue(attachment.text.contains("План релиза"))
    }

    func testRejectsPDFWithoutExtractableText() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let file = fixture.directory.appendingPathComponent("scan.pdf")
        try makePDF(text: nil).write(to: file)

        XCTAssertEqual(try loaderError(for: file), .pdfWithoutText)
    }

    func testPDFMarksPagesWithoutExtractableTextInsteadOfOmittingThem() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let file = fixture.directory.appendingPathComponent("mixed.pdf")
        try makePDF(pages: ["Текст на первой странице", nil]).write(to: file)

        let attachment = try AIChatAttachmentLoader.load(url: file)
        XCTAssertTrue(attachment.text.contains("Текст на первой странице"))
        XCTAssertTrue(attachment.text.contains("Страница 2: нет извлекаемого текста"))
    }

    func testNormalizesSupportedImageAndStripsOriginalContainer() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let file = fixture.directory.appendingPathComponent("photo.png")
        try makePNG().write(to: file)

        let attachment = try AIChatAttachmentLoader.load(url: file)
        let imageData = try XCTUnwrap(attachment.imageData)
        XCTAssertEqual(attachment.kind, .image)
        XCTAssertEqual(attachment.mimeType, "image/png")
        XCTAssertLessThanOrEqual(imageData.count, 2 * 1024 * 1024)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(imageData as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertLessThanOrEqual((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? .max, 1_536)
        XCTAssertLessThanOrEqual((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? .max, 1_536)
    }

    func testAllowedExtensionsExposePickerWhitelist() {
        XCTAssertTrue(AIChatAttachmentLoader.allowedExtensions.contains("pdf"))
        XCTAssertTrue(AIChatAttachmentLoader.allowedExtensions.contains("swift"))
        XCTAssertTrue(AIChatAttachmentLoader.allowedExtensions.contains("heic"))
    }

    private func loaderError(for url: URL) throws -> AIChatAttachmentLoaderError {
        do {
            _ = try AIChatAttachmentLoader.load(url: url)
            XCTFail("Expected attachment loading to fail")
            throw NSError(domain: "AIChatAttachmentLoaderTests", code: 1)
        } catch let error as AIChatAttachmentLoaderError {
            return error
        }
    }

    private func makePNG() throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 8,
            height: 8,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 0.5)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func makePDF(text: String?) -> Data {
        makePDF(pages: [text])
    }

    private func makePDF(pages: [String?]) -> Data {
        let data = NSMutableData()
        let consumer = CGDataConsumer(data: data)!
        var mediaBox = CGRect(x: 0, y: 0, width: 300, height: 200)
        let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)!
        for text in pages {
            context.beginPDFPage(nil)
            if let text {
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: CTFontCreateWithName("Helvetica" as CFString, 16, nil)
                ]
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
                context.textPosition = CGPoint(x: 24, y: 120)
                CTLineDraw(line, context)
            }
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    private struct Fixture {
        let directory: URL

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("ai-chat-attachment-test-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}

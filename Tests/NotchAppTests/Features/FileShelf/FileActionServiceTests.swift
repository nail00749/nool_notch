import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import XCTest
@testable import NotchApp

final class FileActionServiceTests: XCTestCase {
    func testCompressAndResizeCreateBoundedImagesWithoutChangingOriginal() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = fixture.directory.appendingPathComponent("source.png")
        let original = try makeImage(width: 80, height: 40, alpha: true, type: "public.png")
        try original.write(to: source)

        let compressed = try FileActionService.execute(
            kind: .compressImage,
            urls: [source],
            options: .init(maxDimension: 30, jpegQuality: 0.5),
            outputDirectory: fixture.directory
        )
        let resized = try FileActionService.execute(
            kind: .resizeImage,
            urls: [source],
            options: .init(maxDimension: 20),
            outputDirectory: fixture.directory
        )

        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(compressed.count, 1)
        XCTAssertEqual(compressed[0].pathExtension, "jpg")
        XCTAssertEqual(resized[0].pathExtension, "png")
        XCTAssertLessThanOrEqual(try imageSize(at: compressed[0]).width, 30)
        XCTAssertLessThanOrEqual(try imageSize(at: resized[0]).width, 20)
    }

    func testConversionsUseRequestedFormatsAndNeverOverwriteExistingOutput() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = fixture.directory.appendingPathComponent("image.png")
        try makeImage(width: 16, height: 12, alpha: true, type: "public.png").write(to: source)
        let existing = fixture.directory.appendingPathComponent("image-сжато.jpg")
        try Data("keep".utf8).write(to: existing)

        let compressed = try FileActionService.execute(kind: .compressImage, urls: [source], options: .init(), outputDirectory: fixture.directory)
        let jpeg = try FileActionService.execute(kind: .convertJPEG, urls: [source], options: .init(), outputDirectory: fixture.directory)
        let png = try FileActionService.execute(kind: .convertPNG, urls: [jpeg[0]], options: .init(), outputDirectory: fixture.directory)

        XCTAssertEqual(compressed[0].lastPathComponent, "image-сжато-2.jpg")
        XCTAssertEqual(try Data(contentsOf: existing), Data("keep".utf8))
        XCTAssertEqual(try imageType(at: jpeg[0]), "public.jpeg")
        XCTAssertEqual(try imageType(at: png[0]), "public.png")
    }

    func testImagesToPDFKeepsOnePagePerInputInOrder() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let first = fixture.directory.appendingPathComponent("first.png")
        let second = fixture.directory.appendingPathComponent("second.png")
        try makeImage(width: 30, height: 10, alpha: false, type: "public.png").write(to: first)
        try makeImage(width: 10, height: 30, alpha: false, type: "public.png").write(to: second)

        let outputs = try FileActionService.execute(
            kind: .imagesToPDF,
            urls: [first, second],
            options: .init(maxDimension: 100),
            outputDirectory: fixture.directory
        )

        let document = try XCTUnwrap(PDFDocument(url: outputs[0]))
        XCTAssertEqual(outputs.count, 1)
        XCTAssertEqual(document.pageCount, 2)
        XCTAssertEqual(Int(document.page(at: 0)?.bounds(for: .mediaBox).width ?? 0), 30)
        XCTAssertEqual(Int(document.page(at: 0)?.bounds(for: .mediaBox).height ?? 0), 10)
        XCTAssertEqual(Int(document.page(at: 1)?.bounds(for: .mediaBox).width ?? 0), 10)
        XCTAssertEqual(Int(document.page(at: 1)?.bounds(for: .mediaBox).height ?? 0), 30)
    }

    func testImageOutputsDefaultToEachOriginalsDirectory() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let firstDirectory = fixture.directory.appendingPathComponent("one", isDirectory: true)
        let secondDirectory = fixture.directory.appendingPathComponent("two", isDirectory: true)
        try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
        let first = firstDirectory.appendingPathComponent("first.png")
        let second = secondDirectory.appendingPathComponent("second.png")
        try makeImage(width: 12, height: 12, alpha: false, type: "public.png").write(to: first)
        try makeImage(width: 12, height: 12, alpha: false, type: "public.png").write(to: second)

        let outputs = try FileActionService.execute(kind: .resizeImage, urls: [first, second], options: .init(maxDimension: 8))

        XCTAssertEqual(outputs.map { $0.deletingLastPathComponent() }, [firstDirectory, secondDirectory])
    }

    func testRenamePreviewRejectsUnsafePrefixAndProtectsCollision() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = fixture.directory.appendingPathComponent("old.txt")
        try Data("original".utf8).write(to: source)

        XCTAssertThrowsError(try FileActionService.renamePreview(urls: [source], options: .init(renamePrefix: "../bad"))) { error in
            XCTAssertEqual(error as? FileActionError, .invalidRenamePrefix)
        }

        let entries = try FileActionService.renamePreview(urls: [source], options: .init(renamePrefix: "Новый"))
        try Data("occupied".utf8).write(to: entries[0].destination)

        XCTAssertThrowsError(try FileActionService.applyRename(entries)) { error in
            XCTAssertEqual(error as? FileActionError, .renameCollision)
        }
        XCTAssertEqual(try Data(contentsOf: source), Data("original".utf8))
    }

    func testRenamePreviewDetectsStaleSourceAndSuccessfulRenamePreservesExtension() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let stale = fixture.directory.appendingPathComponent("stale.txt")
        try Data("before".utf8).write(to: stale)
        let staleEntry = try FileActionService.renamePreview(urls: [stale], options: .init(renamePrefix: "Архив"))
        try FileManager.default.removeItem(at: stale)
        try Data("after".utf8).write(to: stale)

        XCTAssertThrowsError(try FileActionService.applyRename(staleEntry)) { error in
            XCTAssertEqual(error as? FileActionError, .staleRenameSource)
        }

        let source = fixture.directory.appendingPathComponent("photo.png")
        try Data("content".utf8).write(to: source)
        let entries = try FileActionService.renamePreview(urls: [source], options: .init(renamePrefix: "Снимок", startNumber: 7))
        let outputs = try FileActionService.applyRename(entries)
        XCTAssertEqual(outputs[0].lastPathComponent, "Снимок 007.png")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: outputs[0]), Data("content".utf8))
    }

    func testRejectsDirectoriesAndSymbolicLinks() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let target = fixture.directory.appendingPathComponent("target.png")
        let link = fixture.directory.appendingPathComponent("link.png")
        try makeImage(width: 4, height: 4, alpha: false, type: "public.png").write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertThrowsError(try FileActionService.execute(kind: .resizeImage, urls: [fixture.directory], options: .init()))
        XCTAssertThrowsError(try FileActionService.execute(kind: .resizeImage, urls: [link], options: .init()))
    }

    private func imageSize(at url: URL) throws -> (width: Int, height: Int) {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return (
            try XCTUnwrap((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue),
            try XCTUnwrap((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue)
        )
    }

    private func imageType(at url: URL) throws -> String {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceGetType(source) as String?)
    }

    private func makeImage(width: Int, height: Int, alpha: Bool, type: String) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast).rawValue
        ))
        context.setFillColor(red: 0.1, green: 0.4, blue: 0.8, alpha: alpha ? 0.4 : 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private struct Fixture {
        let directory: URL

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("file-action-test-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}

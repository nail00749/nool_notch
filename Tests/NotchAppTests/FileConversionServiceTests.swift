import AppKit
@preconcurrency import AVFoundation
import Foundation
import ImageIO
import PDFKit
import CoreText
import UniformTypeIdentifiers
import XCTest
@testable import NotchApp

final class FileConversionServiceTests: XCTestCase {
    func testFormatsIntersectAndRejectLinksDirectoriesAndUnknownTypes() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = directory.appendingPathComponent("a.png")
        let jpeg = directory.appendingPathComponent("b.jpg")
        let text = directory.appendingPathComponent("c.txt")
        let link = directory.appendingPathComponent("linked.png")
        for file in [png, jpeg, text] { try Data().write(to: file) }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: png)
        let common = FileConversionService.formats(for: [png, jpeg])
        XCTAssertTrue(common.contains(.tiff))
        XCTAssertFalse(common.contains(.png))
        XCTAssertFalse(common.contains(.jpeg))
        XCTAssertEqual(FileConversionService.formats(for: [png, text]), [.pdf])
        XCTAssertTrue(FileConversionService.formats(for: [directory]).isEmpty)
        XCTAssertTrue(FileConversionService.formats(for: [link]).isEmpty)
        XCTAssertTrue(FileConversionService.formats(for: []).isEmpty)
        XCTAssertTrue(FileConversionService.formats(for: Array(repeating: png, count: 21)).isEmpty)
    }

    func testJPEGPreservesDimensionsOrientationAndCompositesTransparencyWhite() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("transparent.png")
        try makeImage(at: input, type: .png, orientation: 6)
        let original = try Data(contentsOf: input)
        let outputs = try await FileConversionService.convert(urls: [input], to: .jpeg)
        XCTAssertEqual(outputs.count, 1)
        XCTAssertEqual(try Data(contentsOf: input), original)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(outputs[0] as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 4)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 2)
        XCTAssertEqual(properties[kCGImagePropertyOrientation] as? Int, 6)
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let context = try XCTUnwrap(CGContext(data: nil, width: 4, height: 2, bitsPerComponent: 8, bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 4, height: 2))
        let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        XCTAssertGreaterThan(pixels[0], 245)
        XCTAssertGreaterThan(pixels[1], 245)
        XCTAssertGreaterThan(pixels[2], 245)
    }

    func testCollisionNeverOverwritesAndRollbackKeepsExistingFiles() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("photo.png")
        try makeImage(at: input, type: .png)
        let occupied = directory.appendingPathComponent("photo.jpeg")
        let sentinel = Data("existing".utf8)
        try sentinel.write(to: occupied)
        let outputs = try await FileConversionService.convert(urls: [input], to: .jpeg)
        XCTAssertEqual(outputs.first?.lastPathComponent, "photo 2.jpeg")
        XCTAssertEqual(try Data(contentsOf: occupied), sentinel)
        let corrupt = directory.appendingPathComponent("broken.png")
        try Data("invalid image".utf8).write(to: corrupt)
        do {
            _ = try await FileConversionService.convert(urls: [input, corrupt], to: .jpeg)
            XCTFail("A corrupt second input must fail the batch")
        } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("photo 3.jpeg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputs[0].path))
        XCTAssertEqual(try Data(contentsOf: occupied), sentinel)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".nool-convert-") })
    }

    func testMultipageImagesAreRejectedWithoutFlattening() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("pages.tiff")
        try makeImage(at: input, type: .tiff, count: 2)
        do {
            _ = try await FileConversionService.convert(urls: [input], to: .png)
            XCTFail("Must preserve the source's multiple pages by refusing conversion")
        } catch FileConversionError.multipleFrames { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("pages.png").path))
    }

    func testHEICToJPEGUsesActualImageCodec() async throws {
        let writable = CGImageDestinationCopyTypeIdentifiers() as! [String]
        guard writable.contains(UTType.heic.identifier) else { throw XCTSkip("HEIC encoder is unavailable on this system") }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("photo.heic")
        try makeImage(at: input, type: .heic)
        let original = try Data(contentsOf: input)
        let outputs = try await FileConversionService.convert(urls: [input], to: .jpeg)
        let image = try XCTUnwrap(CGImageSourceCreateWithURL(outputs[0] as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(image) as String?, UTType.jpeg.identifier)
        XCTAssertEqual(try Data(contentsOf: input), original)
    }

    func testConcurrentConversionsReserveDifferentOutputNames() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("photo.png")
        try makeImage(at: input, type: .png)
        async let first = FileConversionService.convert(urls: [input], to: .jpeg)
        async let second = FileConversionService.convert(urls: [input], to: .jpeg)
        let outputs = try await (first, second)
        XCTAssertNotEqual(outputs.0[0], outputs.1[0])
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputs.0[0].path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputs.1[0].path))
    }

    func testTextRTFRoundTripAndHTMLEscapesLiteralContent() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("note.txt")
        let original = "Привет & <script>alert(\"x\")</script>\n**Markdown stays literal**"
        try Data(original.utf8).write(to: input)
        let rtf = try await FileConversionService.convert(urls: [input], to: .rtf)
        let text = try await FileConversionService.convert(urls: rtf, to: .txt)
        XCTAssertEqual(try String(contentsOf: text[0], encoding: .utf8), original)
        let html = try await FileConversionService.convert(urls: [input], to: .html)
        let rendered = try String(contentsOf: html[0], encoding: .utf8)
        XCTAssertTrue(rendered.contains("&lt;script&gt;"))
        XCTAssertTrue(rendered.contains("&amp;"))
        XCTAssertFalse(rendered.contains("<script>"))
        XCTAssertTrue(FileConversionService.formats(for: html).isEmpty)
    }

    func testOversizedAndInvalidUTF8TextRefuseWithoutOutput() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("binary.txt")
        try Data([0xff, 0xfe, 0x81]).write(to: input)
        do {
            _ = try await FileConversionService.convert(urls: [input], to: .rtf)
            XCTFail("Non-UTF8 text must not be silently replaced")
        } catch FileConversionError.invalidText { }
        let large = directory.appendingPathComponent("large.md")
        FileManager.default.createFile(atPath: large.path, contents: nil)
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: 8 * 1_024 * 1_024 + 1)
        try handle.close()
        do {
            _ = try await FileConversionService.convert(urls: [large], to: .txt)
            XCTFail("Size limit must be applied before reading")
        } catch FileConversionError.tooLarge { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("large.txt").path))
    }

    func testDocumentFormatsIntersectAndNormalizeMarkdownExtension() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let markdown = directory.appendingPathComponent("notes.markdown")
        let word = directory.appendingPathComponent("notes.docx")
        try Data().write(to: markdown)
        try Data().write(to: word)
        XCTAssertEqual(Set(FileConversionService.formats(for: [markdown])), [.txt, .rtf, .html, .pdf, .docx])
        XCTAssertEqual(Set(FileConversionService.formats(for: [markdown, word])), [.txt, .rtf, .html, .pdf])
        let text = directory.appendingPathComponent("notes.txt")
        try Data().write(to: text)
        XCTAssertTrue(FileConversionService.formats(for: [text]).contains(.md))
    }

    func testNativeDOCXRoundTripPreservesUnicodeBasicStylesAndInertHyperlinks() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("document.md")
        try Data("# Привет Word\n\nЭто **жирный** и *курсивный* текст.\n[Без загрузки сайта](https://example.invalid)\n".utf8).write(to: source)
        let outputs = try await FileConversionService.convert(urls: [source], to: .docx)
        let data = try Data(contentsOf: outputs[0])
        XCTAssertEqual(Array(data.prefix(4)), [0x50, 0x4b, 3, 4])
        let native = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil)
        XCTAssertTrue(native.string.contains("Привет Word"))
        let bold = (native.string as NSString).range(of: "жирный")
        let font = native.attribute(.font, at: bold.location, effectiveRange: nil) as? NSFont
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        let text = try await FileConversionService.convert(urls: outputs, to: .txt)
        let plain = try String(contentsOf: text[0], encoding: .utf8)
        XCTAssertTrue(plain.contains("Это жирный и курсивный текст."))
        XCTAssertTrue(plain.contains("Без загрузки сайта"))
        let markdown = try await FileConversionService.convert(urls: outputs, to: .md)
        let serialized = try String(contentsOf: markdown[0], encoding: .utf8)
        XCTAssertTrue(serialized.contains("**жирный**"))
        XCTAssertTrue(serialized.contains("# "))
        let again = try await FileConversionService.convert(urls: markdown, to: .txt)
        XCTAssertTrue(try String(contentsOf: again[0], encoding: .utf8).contains("Привет Word"))
    }

    func testPlainTextMarkdownRoundTripAndDocumentCollisionAreSafe() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("notes.txt")
        let original = "# Literal heading\n- item\n**literal stars** & Привет\n"
        try Data(original.utf8).write(to: source)
        let occupied = directory.appendingPathComponent("notes.md")
        try Data("existing".utf8).write(to: occupied)
        let markdown = try await FileConversionService.convert(urls: [source], to: .md)
        XCTAssertEqual(markdown[0].lastPathComponent, "notes 2.md")
        XCTAssertEqual(try String(contentsOf: occupied, encoding: .utf8), "existing")
        let roundtrip = try await FileConversionService.convert(urls: markdown, to: .txt)
        XCTAssertEqual(try String(contentsOf: roundtrip[0], encoding: .utf8), original)
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), original)
    }

    func testUnicodeMultiPagePDFContainsSelectableTextThroughLastLine() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("long.txt")
        let lines = (0..<350).map { "Строка \($0): Привет мир Ω café — конец" }
        try Data(lines.joined(separator: "\n").utf8).write(to: source)
        let pdf = try await FileConversionService.convert(urls: [source], to: .pdf)
        let document = try XCTUnwrap(PDFDocument(url: pdf[0]))
        XCTAssertGreaterThan(document.pageCount, 1)
        XCTAssertLessThan(document.pageCount, 100)
        let text = try await FileConversionService.convert(urls: pdf, to: .txt)
        let extracted = try String(contentsOf: text[0], encoding: .utf8)
        for line in lines { XCTAssertTrue(extracted.contains(line), "Missing: \(line)") }
    }

    func testImagePDFPreservesAspectAndBlankPageFailsWithNumberAfterOCR() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for (orientation, ratio) in [(1, 2.0), (6, 0.5)] {
            let image = directory.appendingPathComponent("image-\(orientation).png")
            try makeImage(at: image, type: .png, orientation: orientation)
            let result = try await FileConversionService.convert(urls: [image], to: .pdf)
            let document = try XCTUnwrap(PDFDocument(url: result[0]))
            XCTAssertEqual(document.pageCount, 1)
            let box = try XCTUnwrap(document.page(at: 0)).bounds(for: .mediaBox)
            XCTAssertEqual(box.width / box.height, ratio, accuracy: 0.001)
            do {
                _ = try await FileConversionService.convert(urls: result, to: .txt)
                XCTFail("Image-only PDF must explicitly require OCR")
            } catch FileConversionError.pdfNoText(let page) { XCTAssertEqual(page, 1) }
        }
    }

    func testMalformedAndPasswordProtectedPDFsFailExplicitly() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let malformed = directory.appendingPathComponent("malformed.pdf")
        try Data("not a PDF".utf8).write(to: malformed)
        do {
            _ = try await FileConversionService.convert(urls: [malformed], to: .txt)
            XCTFail("Invalid PDF must fail")
        } catch FileConversionError.document { }
        let source = directory.appendingPathComponent("private.txt")
        try Data("Private Unicode Привет".utf8).write(to: source)
        let pdf = try await FileConversionService.convert(urls: [source], to: .pdf)
        let document = try XCTUnwrap(PDFDocument(url: pdf[0]))
        let locked = directory.appendingPathComponent("locked.pdf")
        XCTAssertTrue(document.write(to: locked, withOptions: [.userPasswordOption: "secret", .ownerPasswordOption: "owner"]))
        XCTAssertTrue(try XCTUnwrap(PDFDocument(url: locked)).isLocked)
        do {
            _ = try await FileConversionService.convert(urls: [locked], to: .txt)
            XCTFail("Locked PDF must explicitly refuse")
        } catch FileConversionError.lockedPDF { }
    }

    func testMixedPDFDoesNotSilentlyDropNonTextPageWithoutXObjects() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.txt")
        try Data("Selectable first page".utf8).write(to: source)
        let exported = try await FileConversionService.convert(urls: [source], to: .pdf)
        let mixed = try XCTUnwrap(PDFDocument(url: exported[0]))
        var box = CGRect(x: 0, y: 0, width: 100, height: 100)
        let graphics = directory.appendingPathComponent("graphics.pdf")
        let context = try XCTUnwrap(CGContext(graphics as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(box)
        context.endPDFPage()
        context.closePDF()
        let nonText = try XCTUnwrap(PDFDocument(url: graphics)?.page(at: 0))
        mixed.insert(nonText, at: 1)
        let input = directory.appendingPathComponent("mixed.pdf")
        XCTAssertTrue(mixed.write(to: input))
        do {
            _ = try await FileConversionService.convert(urls: [input], to: .txt)
            XCTFail("A non-text page must not disappear from a partly selectable PDF")
        } catch FileConversionError.pdfNoText(let page) { XCTAssertEqual(page, 2) }
    }

    func testScannedPDFConvertsToMarkdownAndDOCXWithNativeOCR() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("scan.pdf")
        try makeScannedPDF(at: source, text: "HELLO SCANNED DOCUMENT")
        XCTAssertTrue((PDFDocument(url: source)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let progress = ConversionProgressRecorder()
        let markdown = try await FileConversionService.convert(urls: [source], to: .md, onProgress: progress.record)
        let recognized = try String(contentsOf: markdown[0], encoding: .utf8)
        XCTAssertTrue(recognized.localizedCaseInsensitiveContains("HELLO SCANNED DOCUMENT"), recognized)
        XCTAssertEqual(progress.values, [.recognizingPDF(page: 1, total: 1)])
        let word = try await FileConversionService.convert(urls: [source], to: .docx)
        let text = try await FileConversionService.convert(urls: word, to: .txt)
        let wordText = try String(contentsOf: text[0], encoding: .utf8)
        XCTAssertTrue(wordText.localizedCaseInsensitiveContains("HELLO SCANNED DOCUMENT"), wordText)
    }

    func testMixedPDFPreservesPageOrderAndOnlyRecognizesMissingText() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.txt")
        let last = directory.appendingPathComponent("last.txt")
        try Data("NATIVE FIRST".utf8).write(to: first)
        try Data("NATIVE LAST".utf8).write(to: last)
        let native = try await FileConversionService.convert(urls: [first, last], to: .pdf)
        let scanned = directory.appendingPathComponent("middle.pdf")
        try makeScannedPDF(at: scanned, text: "SCANNED MIDDLE")
        let document = PDFDocument()
        for (index, source) in [native[0], scanned, native[1]].enumerated() {
            document.insert(try XCTUnwrap(PDFDocument(url: source)?.page(at: 0)), at: index)
        }
        let data = try XCTUnwrap(document.dataRepresentation())
        var calls = 0
        let extracted = try FileConversionDocument.extractPDF(data, recognizePage: { _, _ in
            calls += 1
            return "SCANNED MIDDLE"
        }).string
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(extracted.components(separatedBy: "NATIVE FIRST").count, 2)
        XCTAssertEqual(extracted.components(separatedBy: "SCANNED MIDDLE").count, 2)
        XCTAssertEqual(extracted.components(separatedBy: "NATIVE LAST").count, 2)
        let rangeFirst = try XCTUnwrap(extracted.range(of: "NATIVE FIRST"))
        let rangeMiddle = try XCTUnwrap(extracted.range(of: "SCANNED MIDDLE"))
        let rangeLast = try XCTUnwrap(extracted.range(of: "NATIVE LAST"))
        XCTAssertLessThan(rangeFirst.lowerBound, rangeMiddle.lowerBound)
        XCTAssertLessThan(rangeMiddle.lowerBound, rangeLast.lowerBound)
        let input = directory.appendingPathComponent("mixed-readable.pdf")
        try data.write(to: input)
        let progress = ConversionProgressRecorder()
        let converted = try await FileConversionService.convert(urls: [input], to: .txt, onProgress: progress.record)
        let actual = try String(contentsOf: converted[0], encoding: .utf8)
        XCTAssertTrue(actual.localizedCaseInsensitiveContains("SCANNED MIDDLE"), actual)
        XCTAssertEqual(progress.values, [.recognizingPDF(page: 2, total: 3)])
    }

    func testPDFNativeTextBypassesOCRAndScanCapChecksBeforeRecognition() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("native.txt")
        try Data("NATIVE TEXT ONLY".utf8).write(to: input)
        let outputs = try await FileConversionService.convert(urls: [input], to: .pdf)
        let page = try XCTUnwrap(PDFDocument(url: outputs[0])?.page(at: 0))
        let longNative = PDFDocument()
        for index in 0..<41 { longNative.insert(try XCTUnwrap(page.copy() as? PDFPage), at: index) }
        var calls = 0
        let result = try FileConversionDocument.extractPDF(try XCTUnwrap(longNative.dataRepresentation()), recognizePage: { _, _ in
            calls += 1
            XCTFail("Selectable text must not be recognized again")
            return ""
        })
        XCTAssertTrue(result.string.contains("NATIVE TEXT ONLY"))
        XCTAssertEqual(calls, 0)
        let scan = directory.appendingPathComponent("blank.pdf")
        try makeScannedPDF(at: scan, text: "")
        let emptyPage = try XCTUnwrap(PDFDocument(url: scan)?.page(at: 0))
        let tooMany = PDFDocument()
        for index in 0..<41 { tooMany.insert(try XCTUnwrap(emptyPage.copy() as? PDFPage), at: index) }
        do {
            _ = try FileConversionDocument.extractPDF(try XCTUnwrap(tooMany.dataRepresentation()), recognizePage: { _, _ in
                calls += 1
                return "fake"
            })
            XCTFail("More than 40 scan pages must fail before Vision starts")
        } catch FileConversionError.tooManyScannedPages { }
        XCTAssertEqual(calls, 0)
    }

    func testUnrecognizedPDFRollsBackEarlierBatchOutputs() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let text = directory.appendingPathComponent("first.txt")
        let empty = directory.appendingPathComponent("blank.pdf")
        try Data("First document".utf8).write(to: text)
        try makeScannedPDF(at: empty, text: "")
        do {
            _ = try await FileConversionService.convert(urls: [text, empty], to: .md)
            XCTFail("Blank OCR output must fail the entire batch")
        } catch FileConversionError.pdfNoText(let page) { XCTAssertEqual(page, 1) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("first.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("blank.md").path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".nool-convert-") })
    }

    func testCancellingConversionAtOCRBoundaryRollsBackWithoutOutput() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let text = directory.appendingPathComponent("first.txt")
        let scan = directory.appendingPathComponent("scan.pdf")
        try Data("First document".utf8).write(to: text)
        try makeScannedPDF(at: scan, text: "HELLO CANCELLED DOCUMENT")
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let task = Task {
            try await FileConversionService.convert(urls: [text, scan], to: .md, onProgress: { _ in
                started.signal()
                _ = release.wait(timeout: .now() + 5)
            })
        }
        let waitResult = await Task.detached { Self.waitForSignal(started) }.value
        XCTAssertEqual(waitResult, .success)
        task.cancel()
        release.signal()
        do {
            _ = try await task.value
            XCTFail("Cancelled OCR must fail without publishing the batch")
        } catch is CancellationError { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("first.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("scan.md").path))
    }

    func testDOCXArchivePreflightRejectsExternalContentAndDifferentialNames() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let xml = Data("<document/>".utf8)
        let relationships = Data("<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"r1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"https://example.invalid/image.png\"/></Relationships>".utf8)
        let fixtures = [
            storedZIP([("word/document.xml", xml), ("word/_rels/document.xml.rels", relationships)]),
            storedZIP([("word/document.xml", xml)], mismatchedLocalName: true),
            storedZIP([("word/document.xml", Data("<!DOCTYPE document [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><document>&x;</document>".utf8))]),
            storedZIP([("word/document.xml", xml)], declaredExpansion: 17 * 1_024 * 1_024)
        ]
        for (index, fixture) in fixtures.enumerated() {
            let source = directory.appendingPathComponent("unsafe-\(index).docx")
            try fixture.write(to: source)
            do {
                _ = try await FileConversionService.convert(urls: [source], to: .txt)
                XCTFail("Unsafe package must be rejected before native import")
            } catch FileConversionError.document { }
        }
    }

    func testPreCancelledConversionWritesNothing() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("note.md")
        try Data("hello".utf8).write(to: input)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await FileConversionService.convert(urls: [input], to: .txt)
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled work must not write output")
        } catch is CancellationError { }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["note.md"])
    }

    func testNativeAudioAIFFAndM4AExport() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("tone.wav")
        try makeAudio(at: input)
        let aiff = try await FileConversionService.convert(urls: [input], to: .aiff)
        let decoded = try AVAudioFile(forReading: aiff[0])
        XCTAssertEqual(decoded.length, 2_205)
        XCTAssertEqual(decoded.processingFormat.sampleRate, 22_050)
        let wav = try await FileConversionService.convert(urls: aiff, to: .wav)
        XCTAssertEqual(try AVAudioFile(forReading: wav[0]).length, 2_205)
        let m4a = try await FileConversionService.convert(urls: [input], to: .m4a)
        let asset = AVURLAsset(url: m4a[0])
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(tracks.count, 1)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 0.1, accuracy: 0.03)
    }

    func testNativeVideoExportPreservesAspectAndRotation() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("clip.mov")
        try await makeVideo(at: input)
        let outputs = try await FileConversionService.convert(urls: [input], to: .mp4)
        let asset = AVURLAsset(url: outputs[0])
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let displayed = CGRect(origin: .zero, size: size).applying(transform)
        XCTAssertEqual(abs(displayed.width) / abs(displayed.height), 0.5, accuracy: 0.01)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 0.2, accuracy: 0.04)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nool-conversion-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func makeScannedPDF(at url: URL, text: String) throws {
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: 1_200, height: 320, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let box = CGRect(x: 0, y: 0, width: 1_200, height: 320)
        bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
        bitmap.fill(box)
        bitmap.textPosition = CGPoint(x: 35, y: 120)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 66, weight: .bold), .foregroundColor: NSColor.black]))
        CTLineDraw(line, bitmap)
        let image = try XCTUnwrap(bitmap.makeImage())
        var pageBox = box
        let pdf = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &pageBox, nil))
        pdf.beginPDFPage(nil)
        pdf.draw(image, in: box)
        pdf.endPDFPage()
        pdf.closePDF()
    }

    private final class ConversionProgressRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var records: [FileConversionProgress] = []
        var values: [FileConversionProgress] { lock.withLock { records } }
        func record(_ progress: FileConversionProgress) { lock.withLock { records.append(progress) } }
    }

    private static func waitForSignal(_ semaphore: DispatchSemaphore) -> DispatchTimeoutResult {
        semaphore.wait(timeout: .now() + 5)
    }

    private func storedZIP(_ entries: [(String, Data)], mismatchedLocalName: Bool = false, declaredExpansion: Int? = nil) -> Data {
        func word(_ value: Int, bytes: Int) -> Data { Data((0..<bytes).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
        var result = Data(), central = Data()
        for (name, content) in entries {
            let filename = Data(name.utf8)
            let localName = Data((mismatchedLocalName ? name.replacingOccurrences(of: "word/", with: "evil/") : name).utf8)
            let offset = result.count, size = declaredExpansion ?? content.count
            result += word(0x04034b50, bytes: 4) + word(20, bytes: 2) + word(0, bytes: 2) + word(0, bytes: 2)
            result += Data(repeating: 0, count: 8) + word(content.count, bytes: 4) + word(size, bytes: 4)
            result += word(localName.count, bytes: 2) + word(0, bytes: 2) + localName + content
            central += word(0x02014b50, bytes: 4) + word(20, bytes: 2) + word(20, bytes: 2) + word(0, bytes: 2) + word(0, bytes: 2)
            central += Data(repeating: 0, count: 8) + word(content.count, bytes: 4) + word(size, bytes: 4)
            central += word(filename.count, bytes: 2) + Data(repeating: 0, count: 12) + word(offset, bytes: 4) + filename
        }
        let offset = result.count
        result += central
        result += word(0x06054b50, bytes: 4) + Data(repeating: 0, count: 4) + word(entries.count, bytes: 2) + word(entries.count, bytes: 2)
        result += word(central.count, bytes: 4) + word(offset, bytes: 4) + word(0, bytes: 2)
        return result
    }

    private func makeImage(at url: URL, type: UTType, orientation: Int = 1, count: Int = 1) throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 4, height: 2, bitsPerComponent: 8, bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.clear(CGRect(x: 0, y: 0, width: 4, height: 2))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, count, nil))
        for _ in 0..<count {
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func makeAudio(at url: URL) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2_205))
        buffer.frameLength = 2_205
        let samples = try XCTUnwrap(buffer.floatChannelData)[0]
        for index in 0..<2_205 { samples[index] = Float(sin(Double(index) * 2 * .pi * 440 / 22_050) * 0.1) }
        try file.write(from: buffer)
    }

    private func makeVideo(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 32])
        input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 32, ty: 0)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 32])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for index in 0..<2 {
            for _ in 0..<100 {
                if input.isReadyForMoreMediaData { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(input.isReadyForMoreMediaData)
            var buffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 32, kCVPixelFormatType_32ARGB, nil, &buffer), kCVReturnSuccess)
            let pixels = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            if let address = CVPixelBufferGetBaseAddress(pixels) { memset(address, 0, CVPixelBufferGetDataSize(pixels)) }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            XCTAssertTrue(adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(index), timescale: 10)))
        }
        writer.endSession(atSourceTime: CMTime(value: 2, timescale: 10))
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
    }
}

import AppKit
import Compression
import CoreText
import Foundation
import PDFKit

/// Basic text document interchange, not a page-layout or embedded-object converter.
enum FileConversionDocument {
    private static let maximumTextLength = 2_000_000
    private static let maximumPages = 1_000

    static func convert(
        data: Data, sourceExtension ext: String, to format: FileConversionFormat, output: URL,
        cancellation: TextRecognitionCancellation = TextRecognitionCancellation(),
        onProgress: (@Sendable (FileConversionProgress) -> Void)? = nil
    ) throws {
        let text: NSAttributedString
        switch ext {
        case "pdf": text = try extractPDF(data, cancellation: cancellation, onProgress: onProgress)
        case "docx":
            try validateOfficeArchive(data)
            text = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil)
        case "rtf":
            guard let parsed = NSAttributedString(rtf: data, documentAttributes: nil) else { throw FileConversionError.invalidText }
            text = parsed
        default:
            guard let string = String(data: data, encoding: .utf8) else { throw FileConversionError.invalidText }
            text = ext == "md" || ext == "markdown" ? try parseMarkdown(string) : NSAttributedString(string: string)
        }
        guard text.length <= maximumTextLength else { throw FileConversionError.tooLarge }
        try Task.checkCancellation()
        if format == .pdf {
            try writeTextPDF(text, to: output)
            return
        }
        let range = NSRange(location: 0, length: text.length)
        let result: Data
        switch format {
        case .txt: result = Data(text.string.utf8)
        case .md: result = Data(markdown(from: text).utf8)
        case .rtf: result = try text.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        case .docx:
            result = try text.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
            // Do not publish a different format under a DOCX extension if a native writer fails.
            try validateOfficeArchive(result)
        case .html: result = Data(html(from: text).utf8)
        default: throw FileConversionError.unsupported
        }
        try Task.checkCancellation()
        try result.write(to: output, options: .withoutOverwriting)
    }

    static func extractPDF(
        _ data: Data,
        cancellation: TextRecognitionCancellation = TextRecognitionCancellation(),
        onProgress: (@Sendable (FileConversionProgress) -> Void)? = nil,
        recognizePage: (CGPDFPage, TextRecognitionCancellation) throws -> String = {
            try TextRecognitionService.recognizePDFPage($0, cancellation: $1)
        }
    ) throws -> NSAttributedString {
        guard let document = PDFDocument(data: data) else { throw FileConversionError.document("Некорректный PDF.") }
        guard !document.isLocked, document.allowsCopying else { throw FileConversionError.lockedPDF }
        guard document.pageCount > 0, document.pageCount <= maximumPages else { throw FileConversionError.tooLarge }
        var selectable: [String?] = []
        var scannedPages = 0
        var length = 0
        for index in 0..<document.pageCount {
            try cancellation.check()
            guard let page = document.page(at: index) else { throw FileConversionError.document("Не удалось прочитать страницу PDF.") }
            let string = page.string ?? ""
            if string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                scannedPages += 1
                guard scannedPages <= TextRecognitionService.maximumPDFPages else { throw FileConversionError.tooManyScannedPages }
                selectable.append(nil)
            } else {
                selectable.append(string)
                length += string.utf16.count + 2
                guard length <= maximumTextLength else { throw FileConversionError.tooLarge }
            }
        }
        var pages: [String] = []
        var recognizedLength = 0
        for (index, selectableText) in selectable.enumerated() {
            try cancellation.check()
            if let selectableText {
                pages.append(selectableText)
                continue
            }
            guard let page = document.page(at: index)?.pageRef else { throw FileConversionError.document("Не удалось прочитать страницу PDF.") }
            onProgress?(.recognizingPDF(page: index + 1, total: document.pageCount))
            try cancellation.check()
            let recognized = try recognizePage(page, cancellation)
            try cancellation.check()
            guard !recognized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw FileConversionError.pdfNoText(page: index + 1) }
            recognizedLength += recognized.count
            guard recognizedLength <= TextRecognitionService.maximumCharacters else { throw TextRecognitionError.textTooLong }
            length += recognized.utf16.count + 2
            guard length <= maximumTextLength else { throw FileConversionError.tooLarge }
            pages.append(recognized)
        }
        try cancellation.check()
        return NSAttributedString(string: pages.joined(separator: "\n\n"))
    }

    private static func writeTextPDF(_ original: NSAttributedString, to output: URL) throws {
        guard original.length > 0 else { throw FileConversionError.document("Документ пуст.") }
        let text = NSMutableAttributedString(attributedString: original)
        let full = NSRange(location: 0, length: text.length)
        text.addAttribute(.foregroundColor, value: NSColor.black, range: full)
        original.enumerateAttribute(.font, in: full) { value, range, _ in
            if value == nil { text.addAttribute(.font, value: NSFont.systemFont(ofSize: 12), range: range) }
        }
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        var pageBox = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let context = CGContext(output as CFURL, mediaBox: &pageBox, nil) else { throw FileConversionError.cannotWrite }
        defer { context.closePDF() }
        let path = CGPath(rect: pageBox.insetBy(dx: 48, dy: 48), transform: nil)
        var position = 0
        var pages = 0
        while position < text.length {
            try Task.checkCancellation()
            guard pages < maximumPages else { throw FileConversionError.tooLarge }
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: position, length: 0), path, nil)
            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length > 0, visible.location == position else {
                throw FileConversionError.document("Размер текста не позволяет разместить его на странице.")
            }
            context.beginPDFPage(nil)
            context.textMatrix = .identity
            CTFrameDraw(frame, context)
            context.endPDFPage()
            position += visible.length
            pages += 1
        }
    }

    static func writeImagePDF(_ image: CGImage, orientation: Int, to output: URL) throws {
        try Task.checkCancellation()
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let rotated = (5...8).contains(orientation)
        let size = rotated ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        let scale = min(1, 842 / max(size.width, size.height))
        var box = CGRect(origin: .zero, size: CGSize(width: size.width * scale, height: size.height * scale))
        guard let context = CGContext(output as CFURL, mediaBox: &box, nil) else { throw FileConversionError.cannotWrite }
        defer { context.closePDF() }
        context.beginPDFPage(nil)
        context.scaleBy(x: scale, y: scale)
        let transform: CGAffineTransform = switch orientation {
        case 2: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: width, ty: 0)
        case 3: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: width, ty: height)
        case 4: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: height)
        case 5: CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: height, ty: width)
        case 6: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: width)
        case 7: CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case 8: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: height, ty: 0)
        default: .identity
        }
        context.concatenate(transform)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.endPDFPage()
        try Task.checkCancellation()
    }

    private static func parseMarkdown(_ source: String) throws -> NSAttributedString {
        guard source.utf16.count <= maximumTextLength else { throw FileConversionError.tooLarge }
        let result = NSMutableAttributedString(string: "")
        var codeBlock = false
        let lines = source.components(separatedBy: "\n")
        for (index, original) in lines.enumerated() {
            try Task.checkCancellation()
            if original.hasPrefix("```") { codeBlock.toggle(); continue }
            var line = original
            let heading = codeBlock ? 0 : min(6, line.prefix { $0 == "#" }.count)
            let isHeading = heading > 0 && line.dropFirst(heading).first == " "
            if isHeading { line = String(line.dropFirst(heading + 1)) }
            if !codeBlock, line.hasPrefix("- ") || line.hasPrefix("* ") { line = "• " + line.dropFirst(2) }
            let size: CGFloat = isHeading ? [24, 22, 20, 18, 16, 14][heading - 1] : 12
            if codeBlock {
                result.append(NSAttributedString(string: line, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)]))
            } else {
                let parsed = try AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
                for run in parsed.runs {
                    let intent = run.inlinePresentationIntent ?? []
                    var traits: NSFontDescriptor.SymbolicTraits = []
                    if isHeading || intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
                    if intent.contains(.emphasized) { traits.insert(.italic) }
                    let base = intent.contains(.code) ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular) : NSFont.systemFont(ofSize: size)
                    let font = NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(traits), size: size) ?? base
                    var attributes: [NSAttributedString.Key: Any] = [.font: font]
                    if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                    if let link = run.link { attributes[.link] = link }
                    result.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
                }
            }
            if index < lines.count - 1 { result.append(NSAttributedString(string: "\n")) }
        }
        return result
    }

    private static func markdown(from text: NSAttributedString) -> String {
        var output = ""
        let string = text.string as NSString
        var position = 0
        while position < text.length {
            let paragraph = string.paragraphRange(for: NSRange(location: position, length: 0))
            let range = NSIntersectionRange(paragraph, NSRange(location: position, length: text.length - position))
            let font = text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
            let size = font?.pointSize ?? 12
            if font?.fontDescriptor.symbolicTraits.contains(.bold) == true, size >= 14 {
                let level = [CGFloat(24), 22, 20, 18, 16, 14].firstIndex(where: { size >= $0 }) ?? 5
                output += String(repeating: "#", count: level + 1) + " "
            }
            text.enumerateAttributes(in: range) { attributes, part, _ in
                let raw = string.substring(with: part)
                let font = attributes[.font] as? NSFont
                let traits = font?.fontDescriptor.symbolicTraits ?? []
                output += raw.components(separatedBy: "\n").map { line in
                    guard !line.isEmpty else { return "" }
                    var escaped = escapeMarkdown(line)
                    if traits.contains(.bold) { escaped = "**\(escaped)**" }
                    if traits.contains(.italic) { escaped = "*\(escaped)*" }
                    if attributes[.strikethroughStyle] != nil { escaped = "~~\(escaped)~~" }
                    return escaped
                }.joined(separator: "\n")
            }
            position = NSMaxRange(range)
        }
        return output
    }

    private static func escapeMarkdown(_ string: String) -> String {
        var result = ""
        for character in string {
            if "\\`*_{}[]<>#+-.".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }

    private static func html(from text: NSAttributedString) -> String {
        var body = ""
        let string = text.string as NSString
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            var escaped = string.substring(with: range).replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
            let traits = (attributes[.font] as? NSFont)?.fontDescriptor.symbolicTraits ?? []
            if traits.contains(.bold) { escaped = "<strong>\(escaped)</strong>" }
            if traits.contains(.italic) { escaped = "<em>\(escaped)</em>" }
            body += escaped
        }
        return "<!doctype html><html><head><meta charset=\"utf-8\"></head><body><pre>\(body)</pre></body></html>"
    }

    /// Validate ZIP bounds before handing a DOCX to the native rich-text importer.
    /// No extraction to disk and no external embedded resources or XML entities.
    private static func validateOfficeArchive(_ data: Data) throws {
        func invalid() -> FileConversionError { .document("Повреждённый DOCX или неподдерживаемое внешнее содержимое.") }
        func u16(_ offset: Int) throws -> Int {
            guard offset >= 0, offset + 2 <= data.count else { throw invalid() }
            return Int(data[offset]) | Int(data[offset + 1]) << 8
        }
        func u32(_ offset: Int) throws -> Int { try u16(offset) | u16(offset + 2) << 16 }
        guard data.count >= 22 else { throw invalid() }
        let lower = max(0, data.count - 65_557)
        guard let end = stride(from: data.count - 22, through: lower, by: -1).first(where: { (try? u32($0)) == 0x06054b50 }) else { throw invalid() }
        let count = try u16(end + 10), centralSize = try u32(end + 12), central = try u32(end + 16)
        guard try u16(end + 4) == 0, try u16(end + 6) == 0, try u16(end + 8) == count,
              count > 0, count <= 2_048, central >= 0, central + centralSize <= end else { throw invalid() }
        var cursor = central, totalSize = 0
        var names = Set<String>()
        var hasDocument = false
        for _ in 0..<count {
            try Task.checkCancellation()
            guard try u32(cursor) == 0x02014b50 else { throw invalid() }
            let flags = try u16(cursor + 8), method = try u16(cursor + 10)
            let compressed = try u32(cursor + 20), expanded = try u32(cursor + 24)
            let nameLength = try u16(cursor + 28), extra = try u16(cursor + 30), comment = try u16(cursor + 32), local = try u32(cursor + 42)
            let next = cursor + 46 + nameLength + extra + comment
            guard next <= central + centralSize, flags & 1 == 0, method == 0 || method == 8,
                  expanded <= 16 * 1_024 * 1_024, compressed <= data.count else { throw invalid() }
            totalSize += expanded
            guard totalSize <= 64 * 1_024 * 1_024 else { throw FileConversionError.tooLarge }
            guard let name = String(data: data[(cursor + 46)..<(cursor + 46 + nameLength)], encoding: .utf8),
                  !name.hasPrefix("/"), !name.contains("\\"), !name.contains("\0"), !name.split(separator: "/").contains(".."),
                  names.insert(name.lowercased()).inserted else { throw invalid() }
            guard try u32(local) == 0x04034b50, try u16(local + 8) == method, try u16(local + 6) & 1 == 0 else { throw invalid() }
            let localFlags = try u16(local + 6), localCompressed = try u32(local + 18), localExpanded = try u32(local + 22)
            guard localFlags & 8 == flags & 8 else { throw invalid() }
            if flags & 8 == 0 {
                guard localCompressed == compressed, localExpanded == expanded else { throw invalid() }
            } else {
                guard (localCompressed == 0 || localCompressed == compressed), (localExpanded == 0 || localExpanded == expanded) else { throw invalid() }
            }
            let localNameLength = try u16(local + 26)
            guard localNameLength == nameLength, local + 30 + localNameLength <= data.count,
                  data[(local + 30)..<(local + 30 + localNameLength)] == data[(cursor + 46)..<(cursor + 46 + nameLength)] else { throw invalid() }
            let payload = try local + 30 + localNameLength + u16(local + 28)
            guard payload >= 0, payload + compressed <= central else { throw invalid() }
            let packed = Data(data[payload..<(payload + compressed)])
            let unpacked: Data
            if method == 0 {
                guard compressed == expanded else { throw invalid() }
                unpacked = packed
            } else {
                var bytes = [UInt8](repeating: 0, count: expanded + 1)
                let actual = bytes.withUnsafeMutableBufferPointer { destination in
                    packed.withUnsafeBytes { source in
                        guard let sourceAddress = source.baseAddress?.assumingMemoryBound(to: UInt8.self), let destinationAddress = destination.baseAddress else { return 0 }
                        return compression_decode_buffer(destinationAddress, destination.count, sourceAddress, source.count, nil, COMPRESSION_ZLIB)
                    }
                }
                guard actual == expanded else { throw invalid() }
                unpacked = Data(bytes.prefix(actual))
            }
            if name == "word/document.xml" { hasDocument = true }
            if name.hasSuffix(".xml") || name.hasSuffix(".rels") {
                guard let xml = String(data: unpacked, encoding: .utf8), !xml.localizedCaseInsensitiveContains("<!DOCTYPE"), !xml.localizedCaseInsensitiveContains("<!ENTITY") else { throw invalid() }
                if name.hasSuffix(".rels") {
                    let delegate = OfficeRelationshipValidator()
                    let parser = XMLParser(data: unpacked)
                    parser.shouldResolveExternalEntities = false
                    parser.delegate = delegate
                    guard parser.parse(), !delegate.hasExternalContent else { throw invalid() }
                }
            }
            cursor = next
        }
        guard hasDocument else { throw invalid() }
    }

    private final class OfficeRelationshipValidator: NSObject, XMLParserDelegate {
        var hasExternalContent = false
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
            let target = attributes["Target"]?.removingPercentEncoding ?? attributes["Target"] ?? ""
            let external = attributes["TargetMode"]?.lowercased() == "external"
                || target.hasPrefix("/") || target.hasPrefix("\\") || URLComponents(string: target)?.scheme != nil
            if external, attributes["Type"]?.hasSuffix("/hyperlink") != true {
                hasExternalContent = true
                parser.abortParsing()
            }
        }
    }
}

import Darwin
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Reads one explicitly selected local file into a bounded chat attachment.
/// Callers run this synchronous API off the main actor.
enum AIChatAttachmentLoader {
    static let allowedExtensions = [
        "txt", "md", "markdown", "json", "csv", "log", "xml", "yaml", "yml",
        "swift", "py", "js", "mjs", "cjs", "ts", "tsx", "jsx", "html", "htm",
        "css", "sh", "zsh", "bash", "rb", "go", "rs", "java", "kt", "kts",
        "c", "h", "cc", "cpp", "hpp", "cs", "sql", "toml", "ini", "conf",
        "properties", "graphql", "gql", "php", "lua", "pl", "scala", "dart",
        "vue", "svelte", "pdf", "png", "jpg", "jpeg", "heic", "tif", "tiff"
    ]

    private static let maximumInputBytes = 10 * 1024 * 1024
    private static let maximumPDFPages = 40
    private static let maximumPDFCharacters = 12_000
    private static let maximumTextUTF8Bytes = 48_000
    private static let maximumTextCharacters = 12_000
    private static let maximumImageDimension = 16_384
    private static let maximumImagePixels = 40_000_000
    private static let thumbnailMaximumPixelSize = 1_536
    private static let maximumImageBytes = 2 * 1024 * 1024

    static func load(url: URL) throws -> AIChatAttachment {
        guard url.isFileURL else { throw AIChatAttachmentLoaderError.localFilesOnly }
        let name = url.lastPathComponent
        guard name.isEmpty == false else { throw AIChatAttachmentLoaderError.unsupportedFormat }
        let ext = url.pathExtension.lowercased()
        guard allowedExtensions.contains(ext) else { throw AIChatAttachmentLoaderError.unsupportedFormat }

        let accessedSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if accessedSecurityScope { url.stopAccessingSecurityScopedResource() }
        }

        let data = try readRegularFile(url)
        switch ext {
        case "pdf":
            return try loadPDF(data: data, name: name)
        case "png", "jpg", "jpeg", "heic", "tif", "tiff":
            return try loadImage(data: data, name: name)
        default:
            return try loadText(data: data, name: name)
        }
    }

    private static func readRegularFile(_ url: URL) throws -> Data {
        var pathStatus = stat()
        guard lstat(url.path, &pathStatus) == 0,
              (pathStatus.st_mode & S_IFMT) == S_IFREG else {
            throw AIChatAttachmentLoaderError.regularFileRequired
        }
        guard pathStatus.st_size >= 0, pathStatus.st_size <= off_t(maximumInputBytes) else {
            throw AIChatAttachmentLoaderError.fileTooLarge
        }

        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw AIChatAttachmentLoaderError.unreadable }
        defer { close(descriptor) }

        var openedStatus = stat()
        guard fstat(descriptor, &openedStatus) == 0,
              (openedStatus.st_mode & S_IFMT) == S_IFREG,
              openedStatus.st_size >= 0,
              openedStatus.st_size <= off_t(maximumInputBytes),
              openedStatus.st_dev == pathStatus.st_dev,
              openedStatus.st_ino == pathStatus.st_ino else {
            throw AIChatAttachmentLoaderError.regularFileRequired
        }

        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else { throw AIChatAttachmentLoaderError.unreadable }
            guard result.count + count <= maximumInputBytes else {
                throw AIChatAttachmentLoaderError.fileTooLarge
            }
            result.append(buffer, count: count)
        }

        var finalStatus = stat()
        guard fstat(descriptor, &finalStatus) == 0,
              (finalStatus.st_mode & S_IFMT) == S_IFREG,
              finalStatus.st_dev == openedStatus.st_dev,
              finalStatus.st_ino == openedStatus.st_ino,
              finalStatus.st_size == openedStatus.st_size,
              finalStatus.st_size <= off_t(maximumInputBytes) else {
            throw AIChatAttachmentLoaderError.changedDuringRead
        }
        return result
    }

    private static func loadText(data: Data, name: String) throws -> AIChatAttachment {
        guard data.count <= maximumTextUTF8Bytes else { throw AIChatAttachmentLoaderError.textTooLarge }
        guard let text = String(data: data, encoding: .utf8) else {
            throw AIChatAttachmentLoaderError.textEncoding
        }
        guard text.utf8.contains(0) == false else { throw AIChatAttachmentLoaderError.binaryText }
        guard text.count <= maximumTextCharacters else { throw AIChatAttachmentLoaderError.textTooLarge }
        return AIChatAttachment(name: name, kind: .text, text: text, mimeType: "text/plain")
    }

    private static func loadPDF(data: Data, name: String) throws -> AIChatAttachment {
        guard let document = PDFDocument(data: data), document.pageCount > 0 else {
            throw AIChatAttachmentLoaderError.invalidPDF
        }
        guard document.pageCount <= maximumPDFPages else { throw AIChatAttachmentLoaderError.pdfTooLarge }

        var pages = [String]()
        var count = 0
        var hasExtractableText = false
        for index in 0..<document.pageCount {
            let extracted = document.page(at: index)?.string?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let pageText: String
            if let extracted, extracted.isEmpty == false {
                pageText = extracted
                hasExtractableText = true
            } else {
                pageText = "[Страница \(index + 1): нет извлекаемого текста]"
            }
            count += pageText.count + (pages.isEmpty ? 0 : 2)
            guard count <= maximumPDFCharacters else { throw AIChatAttachmentLoaderError.pdfTooLarge }
            pages.append(pageText)
        }
        guard hasExtractableText else { throw AIChatAttachmentLoaderError.pdfWithoutText }
        return AIChatAttachment(name: name, kind: .text, text: pages.joined(separator: "\n\n"), mimeType: "application/pdf")
    }

    private static func loadImage(data: Data, name: String) throws -> AIChatAttachment {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let sourceType = CGImageSourceGetType(source),
              imageMimeType(for: sourceType) != nil,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            throw AIChatAttachmentLoaderError.invalidImage
        }
        let widthValue = width.intValue
        let heightValue = height.intValue
        guard widthValue > 0, heightValue > 0,
              widthValue <= maximumImageDimension, heightValue <= maximumImageDimension,
              Int64(widthValue) * Int64(heightValue) <= Int64(maximumImagePixels) else {
            throw AIChatAttachmentLoaderError.imageTooLarge
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailMaximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw AIChatAttachmentLoaderError.invalidImage
        }
        let outputIsPNG = hasAlpha(image)
        let outputType: CFString = outputIsPNG ? UTType.png.identifier as CFString : UTType.jpeg.identifier as CFString
        let output = try reencode(image: image, type: outputType)
        guard output.count <= maximumImageBytes else { throw AIChatAttachmentLoaderError.imageTooLarge }
        return AIChatAttachment(
            name: name,
            kind: .image,
            imageData: output,
            mimeType: outputIsPNG ? "image/png" : "image/jpeg"
        )
    }

    private static func reencode(image: CGImage, type: CFString) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type, 1, nil) else {
            throw AIChatAttachmentLoaderError.invalidImage
        }
        let options: [CFString: Any] = (type as String) == UTType.jpeg.identifier
            ? [kCGImageDestinationLossyCompressionQuality: 0.78]
            : [:]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw AIChatAttachmentLoaderError.invalidImage }
        return output as Data
    }

    private static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast: true
        default: false
        }
    }

    private static func imageMimeType(for type: CFString) -> String? {
        switch type as String {
        case UTType.png.identifier: "image/png"
        case UTType.jpeg.identifier: "image/jpeg"
        case UTType.heic.identifier: "image/heic"
        case UTType.tiff.identifier: "image/tiff"
        default: nil
        }
    }
}

enum AIChatAttachmentLoaderError: LocalizedError, Equatable {
    case localFilesOnly
    case unsupportedFormat
    case regularFileRequired
    case fileTooLarge
    case unreadable
    case changedDuringRead
    case textEncoding
    case textTooLarge
    case binaryText
    case invalidPDF
    case pdfTooLarge
    case pdfWithoutText
    case invalidImage
    case imageTooLarge

    var errorDescription: String? {
        switch self {
        case .localFilesOnly: "Можно прикреплять только локальные файлы."
        case .unsupportedFormat: "Этот формат файла не поддерживается."
        case .regularFileRequired: "Можно прикреплять только обычные файлы."
        case .fileTooLarge: "Файл больше 10 МБ."
        case .unreadable, .changedDuringRead: "Не удалось безопасно прочитать файл."
        case .textEncoding: "Текстовый файл должен быть в UTF-8."
        case .textTooLarge: "Текст вложения превышает лимит 12 000 символов."
        case .binaryText: "Текстовый файл содержит двоичные данные."
        case .invalidPDF: "Не удалось прочитать PDF."
        case .pdfTooLarge: "PDF превышает лимит вложения."
        case .pdfWithoutText: "В PDF нет извлекаемого текста."
        case .invalidImage: "Не удалось прочитать изображение."
        case .imageTooLarge: "Изображение превышает лимит вложения."
        }
    }
}

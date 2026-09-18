import AppKit
import Darwin
import Foundation
import ImageIO
import Vision

enum TextRecognitionError: LocalizedError, Equatable {
    case noFiles
    case tooManyFiles
    case unsupportedFormat(String)
    case regularFileRequired(String)
    case unreadable(String)
    case fileTooLarge(String)
    case changedDuringRead(String)
    case invalidImage(String)
    case imageTooLarge(String)
    case invalidPDF(String)
    case tooManyPages(String)
    case noText(String)
    case textTooLong

    var errorDescription: String? {
        switch self {
        case .noFiles: "Выберите изображение или PDF."
        case .tooManyFiles: "Выберите не более 10 файлов за один раз."
        case .unsupportedFormat(let name): "Формат файла «\(name)» не поддерживается. Выберите PNG, JPEG, HEIC, TIFF или PDF."
        case .regularFileRequired(let name): "«\(name)» должен быть обычным локальным файлом."
        case .unreadable(let name): "Не удалось прочитать «\(name)». Проверьте доступ к файлу."
        case .fileTooLarge(let name): "«\(name)» больше 20 МБ. Выберите файл меньшего размера."
        case .changedDuringRead(let name): "«\(name)» изменился во время чтения. Повторите попытку."
        case .invalidImage(let name): "Не удалось открыть изображение «\(name)». Возможно, файл повреждён."
        case .imageTooLarge(let name): "Изображение «\(name)» слишком большое для распознавания."
        case .invalidPDF(let name): "Не удалось открыть PDF «\(name)». Возможно, файл повреждён или защищён паролем."
        case .tooManyPages(let name): "В PDF «\(name)» больше 40 страниц. Выберите меньший документ."
        case .noText(let name): "В «\(name)» не найден текст для распознавания."
        case .textTooLong: "Распознанный текст длиннее 100 000 символов. Выберите меньше файлов или страниц."
        }
    }
}

/// Cancellation can interrupt a synchronous Vision request on its worker thread.
final class TextRecognitionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var activeRequest: VNRequest?

    func cancel() {
        lock.lock()
        cancelled = true
        let request = activeRequest
        lock.unlock()
        request?.cancel()
    }

    func check() throws {
        lock.lock()
        let isCancelled = cancelled
        lock.unlock()
        if isCancelled || Task<Never, Never>.isCancelled { throw CancellationError() }
    }

    func activate(_ request: VNRequest) throws {
        lock.lock()
        let isCancelled = cancelled
        if !isCancelled { activeRequest = request }
        lock.unlock()
        if isCancelled {
            request.cancel()
            throw CancellationError()
        }
    }

    func deactivate(_ request: VNRequest) {
        lock.lock()
        if activeRequest === request { activeRequest = nil }
        lock.unlock()
    }
}

enum TextRecognitionService {
    static let maximumInputs = 10
    static let maximumFileBytes = 20 * 1024 * 1024
    static let maximumPDFPages = 40
    static let maximumCharacters = 100_000
    static let maximumImageDimension = 20_000
    static let maximumImagePixels = 60_000_000
    static let maximumRecognitionPixels = 2_048

    nonisolated static func supports(url: URL) -> Bool {
        guard url.isFileURL else { return false }
        return ["png", "jpg", "jpeg", "heic", "tif", "tiff", "pdf"]
            .contains(url.pathExtension.lowercased())
    }

    static func recognize(
        urls: [URL],
        cancellation: TextRecognitionCancellation = TextRecognitionCancellation()
    ) async throws -> String {
        guard !urls.isEmpty else { throw TextRecognitionError.noFiles }
        guard urls.count <= maximumInputs else { throw TextRecognitionError.tooManyFiles }
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try recognizeSynchronously(urls: urls, cancellation: cancellation)
            }.value
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func recognizeSynchronously(
        urls: [URL], cancellation: TextRecognitionCancellation
    ) throws -> String {
        var sections: [String] = []
        var characterCount = 0
        for url in urls {
            try cancellation.check()
            let name = url.lastPathComponent
            guard supports(url: url) else { throw TextRecognitionError.unsupportedFormat(name) }
            let resource = SecurityScopedResource(url: url)
            defer { resource.endAccess() }
            let data = try readFile(url, name: name, cancellation: cancellation)
            let recognized = try url.pathExtension.lowercased() == "pdf"
                ? recognizePDF(data, name: name, cancellation: cancellation)
                : recognizeImage(data, name: name, cancellation: cancellation)
            let section = urls.count == 1 ? recognized : "[\(name)]\n\(recognized)"
            characterCount += section.count + (sections.isEmpty ? 0 : 2)
            guard characterCount <= maximumCharacters else { throw TextRecognitionError.textTooLong }
            sections.append(section)
        }
        try cancellation.check()
        return sections.joined(separator: "\n\n")
    }

    private static func readFile(
        _ url: URL, name: String, cancellation: TextRecognitionCancellation
    ) throws -> Data {
        var status = stat()
        guard lstat(url.path, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG else {
            throw TextRecognitionError.regularFileRequired(name)
        }
        guard status.st_size >= 0, status.st_size <= off_t(maximumFileBytes) else {
            throw TextRecognitionError.fileTooLarge(name)
        }
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw TextRecognitionError.unreadable(name) }
        defer { close(descriptor) }

        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              opened.st_mode & S_IFMT == S_IFREG,
              opened.st_size >= 0, opened.st_size <= off_t(maximumFileBytes),
              opened.st_dev == status.st_dev, opened.st_ino == status.st_ino else {
            throw TextRecognitionError.changedDuringRead(name)
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try cancellation.check()
            let count = read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else { throw TextRecognitionError.unreadable(name) }
            guard data.count + count <= maximumFileBytes else {
                throw TextRecognitionError.fileTooLarge(name)
            }
            data.append(buffer, count: count)
        }
        var final = stat()
        guard fstat(descriptor, &final) == 0,
              final.st_mode & S_IFMT == S_IFREG,
              final.st_dev == opened.st_dev, final.st_ino == opened.st_ino,
              final.st_size == opened.st_size else {
            throw TextRecognitionError.changedDuringRead(name)
        }
        return data
    }

    private static func recognizeImage(
        _ data: Data, name: String, cancellation: TextRecognitionCancellation
    ) throws -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let type = CGImageSourceGetType(source) as String?,
              ["public.png", "public.jpeg", "public.heic", "public.tiff"].contains(type),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else {
            throw TextRecognitionError.invalidImage(name)
        }
        guard width > 0, height > 0,
              width <= maximumImageDimension, height <= maximumImageDimension,
              Int64(width) * Int64(height) <= maximumImagePixels else {
            throw TextRecognitionError.imageTooLarge(name)
        }
        try cancellation.check()
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumRecognitionPixels,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw TextRecognitionError.invalidImage(name)
        }
        let lines = try recognize(image, cancellation: cancellation)
        guard !lines.isEmpty else { throw TextRecognitionError.noText(name) }
        return lines.joined(separator: "\n")
    }

    private static func recognizePDF(
        _ data: Data, name: String, cancellation: TextRecognitionCancellation
    ) throws -> String {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider), document.numberOfPages > 0,
              !document.isEncrypted || document.isUnlocked else {
            throw TextRecognitionError.invalidPDF(name)
        }
        guard document.numberOfPages <= maximumPDFPages else {
            throw TextRecognitionError.tooManyPages(name)
        }
        var pages: [String] = []
        var characterCount = 0
        var foundText = false
        for index in 1...document.numberOfPages {
            try cancellation.check()
            guard let page = document.page(at: index),
                  let image = render(page: page) else {
                throw TextRecognitionError.invalidPDF(name)
            }
            let lines = try recognize(image, cancellation: cancellation)
            foundText = foundText || !lines.isEmpty
            let content = lines.isEmpty ? "[Текст не найден]" : lines.joined(separator: "\n")
            let section = document.numberOfPages == 1
                ? content : "[Страница \(index)]\n\(content)"
            characterCount += section.count + (pages.isEmpty ? 0 : 2)
            guard characterCount <= maximumCharacters else { throw TextRecognitionError.textTooLong }
            pages.append(section)
        }
        guard foundText else { throw TextRecognitionError.noText(name) }
        return pages.joined(separator: "\n\n")
    }

    private static func render(page: CGPDFPage) -> CGImage? {
        let box = page.getBoxRect(.cropBox)
        guard box.width.isFinite, box.height.isFinite,
              box.width > 0, box.height > 0 else { return nil }
        let scale = min(2, CGFloat(maximumRecognitionPixels) / max(box.width, box.height))
        let width = max(1, Int(ceil(box.width * scale)))
        let height = max(1, Int(ceil(box.height * scale)))
        guard width <= maximumRecognitionPixels, height <= maximumRecognitionPixels,
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.concatenate(page.getDrawingTransform(
            .cropBox, rect: CGRect(x: 0, y: 0, width: width, height: height),
            rotate: 0, preserveAspectRatio: true
        ))
        context.drawPDFPage(page)
        return context.makeImage()
    }

    private static func recognize(
        _ image: CGImage, cancellation: TextRecognitionCancellation
    ) throws -> [String] {
        try cancellation.check()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        let preferred = ["ru-RU", "en-US"].filter(supported.contains)
        if !preferred.isEmpty { request.recognitionLanguages = preferred }
        try cancellation.activate(request)
        defer { cancellation.deactivate(request) }
        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
        } catch {
            try cancellation.check()
            throw error
        }
        try cancellation.check()
        let results = request.results ?? []
        let order = readingOrder(for: results.map(\.boundingBox))
        let observations = order.map { results[$0] }
        return observations.compactMap { $0.topCandidates(1).first?.string }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Anchor each row to its highest observation so nearby rows cannot create a sort cycle.
    static func readingOrder(for boxes: [CGRect]) -> [Int] {
        let verticalOrder = boxes.indices.sorted { left, right in
            let lhs = boxes[left]
            let rhs = boxes[right]
            if lhs.midY != rhs.midY { return lhs.midY > rhs.midY }
            if lhs.minX != rhs.minX { return lhs.minX < rhs.minX }
            return left < right
        }
        var rows: [[Int]] = []
        for index in verticalOrder {
            if let first = rows.last?.first,
               boxes[first].midY - boxes[index].midY <= 0.02 {
                rows[rows.count - 1].append(index)
            } else {
                rows.append([index])
            }
        }
        return rows.flatMap { row in
            row.sorted { left, right in
                let lhs = boxes[left]
                let rhs = boxes[right]
                if lhs.minX != rhs.minX { return lhs.minX < rhs.minX }
                if lhs.midY != rhs.midY { return lhs.midY > rhs.midY }
                return left < right
            }
        }
    }
}

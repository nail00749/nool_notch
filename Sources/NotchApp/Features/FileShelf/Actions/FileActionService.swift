import CoreGraphics
import Darwin
import Foundation
import ImageIO

enum FileActionKind: String, CaseIterable, Identifiable, Sendable {
    case compressImage
    case resizeImage
    case convertPNG
    case convertJPEG
    case imagesToPDF
    case rename

    var id: Self { self }

    var title: String {
        switch self {
        case .compressImage: "Сжать изображение"
        case .resizeImage: "Изменить размер"
        case .convertPNG: "Конвертировать в PNG"
        case .convertJPEG: "Конвертировать в JPEG"
        case .imagesToPDF: "Изображения в PDF"
        case .rename: "Переименовать"
        }
    }
}

struct FileActionOptions: Sendable {
    var maxDimension: Int = 1_920
    var jpegQuality: Double = 0.75
    var renamePrefix: String = "Файл"
    var startNumber: Int = 1
}

struct FileRenameEntry: Identifiable, Sendable {
    let source: URL
    let destination: URL
    fileprivate let sourceIdentity: FileIdentity?

    var id: String { source.path }

    init(source: URL, destination: URL) {
        self.source = source
        self.destination = destination
        sourceIdentity = nil
    }

    fileprivate init(source: URL, destination: URL, sourceIdentity: FileIdentity) {
        self.source = source
        self.destination = destination
        self.sourceIdentity = sourceIdentity
    }
}

enum FileActionError: LocalizedError, Sendable, Equatable {
    case noFiles
    case tooManyFiles
    case localRegularFileRequired
    case unsupportedImage
    case imageTooLarge
    case invalidOptions(String)
    case invalidOutputDirectory
    case cannotCreateOutput
    case invalidRenamePrefix
    case renameCollision
    case staleRenameSource
    case renameRollbackFailed([URL])

    var errorDescription: String? {
        switch self {
        case .noFiles: return "Выберите хотя бы один файл."
        case .tooManyFiles: return "За один раз можно обработать не более 20 файлов."
        case .localRegularFileRequired: return "Нужен локальный обычный файл; папки и символические ссылки не поддерживаются."
        case .unsupportedImage: return "Не удалось прочитать изображение."
        case .imageTooLarge: return "Изображение слишком большое для безопасной обработки."
        case let .invalidOptions(reason): return reason
        case .invalidOutputDirectory: return "Папка для результата недоступна."
        case .cannotCreateOutput: return "Не удалось безопасно создать файл результата."
        case .invalidRenamePrefix: return "Префикс имени не должен быть пустым и не может содержать «/» или «..»."
        case .renameCollision: return "Новое имя уже занято или конфликтует с другим файлом."
        case .staleRenameSource: return "Файл изменился после предпросмотра. Обновите список имён."
        case let .renameRollbackFailed(destinations):
            let names = destinations.map(\.lastPathComponent).joined(separator: ", ")
            return "Переименование остановлено; не удалось вернуть: \(names)."
        }
    }
}

private struct FileIdentity: Sendable, Equatable {
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
}

private struct PreparedImage {
    let image: CGImage
    let prefersPNG: Bool
}

enum FileActionService {
    private static let maximumInputs = 20
    private static let maximumOutputDimension = 4_096
    private static let maximumSourceDimension = 16_384
    private static let maximumSourcePixels: Int64 = 64_000_000

    nonisolated static func execute(
        kind: FileActionKind,
        urls: [URL],
        options: FileActionOptions,
        outputDirectory: URL? = nil
    ) throws -> [URL] {
        guard kind != .rename else {
            throw FileActionError.invalidOptions("Для переименования сначала создайте предпросмотр имён.")
        }
        try validateInputURLs(urls)
        try validateImageOptions(options)
        try Task.checkCancellation()

        var outputs: [URL] = []
        do {
            switch kind {
            case .imagesToPDF:
                let destinationDirectory = try resolvedOutputDirectory(outputDirectory, fallback: urls[0])
                let output = try createPDF(from: urls, options: options, in: destinationDirectory)
                outputs.append(output)
            case .compressImage, .resizeImage, .convertPNG, .convertJPEG:
                for url in urls {
                    try Task.checkCancellation()
                    let destinationDirectory = try resolvedOutputDirectory(outputDirectory, fallback: url)
                    let prepared = try preparedImage(from: url, maxDimension: options.maxDimension)
                    let format = outputFormat(for: kind, prepared: prepared)
                    let output = try writeImage(
                        prepared.image,
                        format: format,
                        quality: kind == .compressImage || format == .jpeg ? options.jpegQuality : nil,
                        source: url,
                        kind: kind,
                        in: destinationDirectory
                    )
                    outputs.append(output)
                }
            case .rename:
                break
            }
            try Task.checkCancellation()
            return outputs
        } catch {
            for output in outputs {
                try? FileManager.default.removeItem(at: output)
            }
            throw error
        }
    }

    nonisolated static func renamePreview(
        urls: [URL],
        options: FileActionOptions
    ) throws -> [FileRenameEntry] {
        try validateInputURLs(urls)
        let prefix = try validatedRenamePrefix(options.renamePrefix)
        guard options.startNumber > 0, options.startNumber <= 999_999 else {
            throw FileActionError.invalidOptions("Начальный номер должен быть от 1 до 999999.")
        }

        var entries: [FileRenameEntry] = []
        for (index, source) in urls.enumerated() {
            try Task.checkCancellation()
            let sourceURL = source.standardizedFileURL
            let extensionSuffix = sourceURL.pathExtension.isEmpty ? "" : ".\(sourceURL.pathExtension)"
            let destinationName = "\(prefix) \(String(format: "%03d", options.startNumber + index))\(extensionSuffix)"
            let destination = sourceURL.deletingLastPathComponent().appendingPathComponent(destinationName)
            let identity = try fileIdentity(for: sourceURL)
            entries.append(FileRenameEntry(source: sourceURL, destination: destination, sourceIdentity: identity))
        }
        try validateRenamePlan(entries, requireSavedIdentities: true)
        return entries
    }

    nonisolated static func applyRename(_ entries: [FileRenameEntry]) throws -> [URL] {
        guard entries.count <= maximumInputs else { throw FileActionError.tooManyFiles }
        guard entries.isEmpty == false else { return [] }
        try validateRenamePlan(entries, requireSavedIdentities: false)
        for entry in entries {
            try Task.checkCancellation()
            if let expected = entry.sourceIdentity,
               try fileIdentity(for: entry.source.standardizedFileURL) != expected {
                throw FileActionError.staleRenameSource
            }
        }

        var completed: [FileRenameEntry] = []
        do {
            for entry in entries {
                try Task.checkCancellation()
                if let expected = entry.sourceIdentity,
                   try fileIdentity(for: entry.source.standardizedFileURL) != expected {
                    throw FileActionError.staleRenameSource
                }
                try FileManager.default.moveItem(at: entry.source, to: entry.destination)
                completed.append(entry)
            }
            return completed.map(\.destination)
        } catch {
            var rollbackFailures: [URL] = []
            for entry in completed.reversed() {
                do {
                    try FileManager.default.moveItem(at: entry.destination, to: entry.source)
                } catch {
                    rollbackFailures.append(entry.destination)
                }
            }
            if rollbackFailures.isEmpty == false {
                throw FileActionError.renameRollbackFailed(rollbackFailures)
            }
            throw error
        }
    }

    private static func validateInputURLs(_ urls: [URL]) throws {
        guard urls.isEmpty == false else { throw FileActionError.noFiles }
        guard urls.count <= maximumInputs else { throw FileActionError.tooManyFiles }
        var identities = Set<String>()
        for url in urls {
            try Task.checkCancellation()
            let normalized = url.standardizedFileURL
            guard identities.insert(normalized.path.lowercased()).inserted else {
                throw FileActionError.localRegularFileRequired
            }
            _ = try fileIdentity(for: normalized)
        }
    }

    private static func validateImageOptions(_ options: FileActionOptions) throws {
        guard (1...maximumOutputDimension).contains(options.maxDimension) else {
            throw FileActionError.invalidOptions("Максимальный размер должен быть от 1 до \(maximumOutputDimension) пикселей.")
        }
        guard (0.05...1.0).contains(options.jpegQuality) else {
            throw FileActionError.invalidOptions("Качество JPEG должно быть от 0.05 до 1.0.")
        }
    }

    private static func resolvedOutputDirectory(_ requested: URL?, fallback source: URL) throws -> URL {
        let directory = (requested ?? source.deletingLastPathComponent()).standardizedFileURL
        var status = stat()
        guard directory.isFileURL,
              lstat(directory.path, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR
        else { throw FileActionError.invalidOutputDirectory }
        return directory
    }

    private static func fileIdentity(for url: URL) throws -> FileIdentity {
        guard url.isFileURL else { throw FileActionError.localRegularFileRequired }
        var status = stat()
        guard lstat(url.path, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG
        else { throw FileActionError.localRegularFileRequired }
        return FileIdentity(
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino),
            size: Int64(status.st_size),
            modificationSeconds: Int64(status.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(status.st_mtimespec.tv_nsec)
        )
    }

    private static func preparedImage(from url: URL, maxDimension: Int) throws -> PreparedImage {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let type = CGImageSourceGetType(source),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0,
              height > 0
        else { throw FileActionError.unsupportedImage }

        guard width <= maximumSourceDimension,
              height <= maximumSourceDimension,
              Int64(width) * Int64(height) <= maximumSourcePixels
        else { throw FileActionError.imageTooLarge }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            throw FileActionError.unsupportedImage
        }
        return PreparedImage(image: image, prefersPNG: (type as String) == "public.png")
    }

    private enum ImageFormat {
        case png
        case jpeg

        var fileExtension: String { self == .png ? "png" : "jpg" }
        var type: CFString { self == .png ? "public.png" as CFString : "public.jpeg" as CFString }
    }

    private static func outputFormat(for kind: FileActionKind, prepared: PreparedImage) -> ImageFormat {
        switch kind {
        case .resizeImage: prepared.prefersPNG ? .png : .jpeg
        case .convertPNG: .png
        case .compressImage, .convertJPEG: .jpeg
        case .imagesToPDF, .rename: .jpeg
        }
    }

    private static func writeImage(
        _ image: CGImage,
        format: ImageFormat,
        quality: Double?,
        source: URL,
        kind: FileActionKind,
        in directory: URL
    ) throws -> URL {
        let suffix: String
        switch kind {
        case .compressImage: suffix = "сжато"
        case .resizeImage: suffix = "размер"
        case .convertPNG: suffix = "png"
        case .convertJPEG: suffix = "jpeg"
        case .imagesToPDF, .rename: suffix = "результат"
        }
        let staging = temporaryURL(in: directory, pathExtension: format.fileExtension)
        defer { try? FileManager.default.removeItem(at: staging) }

        let rendered = format == .jpeg ? flattenedForJPEG(image) : image
        guard let destination = CGImageDestinationCreateWithURL(staging as CFURL, format.type, 1, nil) else {
            throw FileActionError.cannotCreateOutput
        }
        let metadata: [CFString: Any] = format == .jpeg
            ? [kCGImageDestinationLossyCompressionQuality: quality ?? 0.75]
            : [:]
        CGImageDestinationAddImage(destination, rendered, metadata as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw FileActionError.cannotCreateOutput }
        try Task.checkCancellation()
        return try moveStagingFile(
            staging,
            toUniqueOutputNamed: source.deletingPathExtension().lastPathComponent + "-\(suffix)",
            pathExtension: format.fileExtension,
            in: directory
        )
    }

    private static func flattenedForJPEG(_ image: CGImage) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return image }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage() ?? image
    }

    private static func createPDF(from urls: [URL], options: FileActionOptions, in directory: URL) throws -> URL {
        try Task.checkCancellation()
        let first = try preparedImage(from: urls[0], maxDimension: options.maxDimension)
        let staging = temporaryURL(in: directory, pathExtension: "pdf")
        defer { try? FileManager.default.removeItem(at: staging) }

        var firstBox = CGRect(x: 0, y: 0, width: first.image.width, height: first.image.height)
        guard let context = CGContext(staging as CFURL, mediaBox: &firstBox, nil) else {
            throw FileActionError.cannotCreateOutput
        }
        var closed = false
        defer {
            if closed == false {
                context.closePDF()
            }
        }

        for (index, url) in urls.enumerated() {
            try Task.checkCancellation()
            let prepared = index == 0 ? first : try preparedImage(from: url, maxDimension: options.maxDimension)
            let pageBox = CGRect(x: 0, y: 0, width: prepared.image.width, height: prepared.image.height)
            var pageBoxValue = pageBox
            let pageBoxData = Data(bytes: &pageBoxValue, count: MemoryLayout<CGRect>.size)
            let pageProperties: [CFString: Any] = [kCGPDFContextMediaBox: pageBoxData as CFData]
            context.beginPDFPage(pageProperties as CFDictionary)
            context.draw(prepared.image, in: pageBox)
            context.endPDFPage()
        }
        context.closePDF()
        closed = true
        try Task.checkCancellation()
        return try moveStagingFile(
            staging,
            toUniqueOutputNamed: urls[0].deletingPathExtension().lastPathComponent + "-изображения",
            pathExtension: "pdf",
            in: directory
        )
    }

    private static func temporaryURL(in directory: URL, pathExtension: String) -> URL {
        directory.appendingPathComponent(".nool-file-action-\(UUID().uuidString).\(pathExtension)")
    }

    private static func moveStagingFile(
        _ staging: URL,
        toUniqueOutputNamed baseName: String,
        pathExtension: String,
        in directory: URL
    ) throws -> URL {
        let manager = FileManager.default
        for number in 1...1_000 {
            let suffix = number == 1 ? "" : "-\(number)"
            let destination = directory.appendingPathComponent("\(baseName)\(suffix).\(pathExtension)")
            guard manager.fileExists(atPath: destination.path) == false else { continue }
            do {
                try manager.moveItem(at: staging, to: destination)
                return destination
            } catch {
                if manager.fileExists(atPath: staging.path) { continue }
                throw FileActionError.cannotCreateOutput
            }
        }
        throw FileActionError.cannotCreateOutput
    }

    private static func validatedRenamePrefix(_ value: String) throws -> String {
        let prefix = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard prefix.isEmpty == false,
              prefix.contains("/") == false,
              prefix.contains("..") == false,
              prefix.contains("\\") == false
        else { throw FileActionError.invalidRenamePrefix }
        return prefix
    }

    private static func validateRenamePlan(
        _ entries: [FileRenameEntry],
        requireSavedIdentities: Bool
    ) throws {
        guard entries.isEmpty == false else { throw FileActionError.noFiles }
        guard entries.count <= maximumInputs else { throw FileActionError.tooManyFiles }

        var sourcePaths = Set<String>()
        var destinationPaths = Set<String>()
        var occupiedNamesByParent: [String: Set<String>] = [:]

        for entry in entries {
            try Task.checkCancellation()
            let source = entry.source.standardizedFileURL
            let destination = entry.destination.standardizedFileURL
            _ = try fileIdentity(for: source)
            guard source.deletingLastPathComponent().path == destination.deletingLastPathComponent().path,
                  destination.isFileURL,
                  destination.lastPathComponent.isEmpty == false,
                  sourcePaths.insert(source.path.lowercased()).inserted,
                  destinationPaths.insert(destination.path.lowercased()).inserted,
                  source.path.lowercased() != destination.path.lowercased()
            else { throw FileActionError.renameCollision }
            if requireSavedIdentities, entry.sourceIdentity == nil {
                throw FileActionError.staleRenameSource
            }

            let parent = destination.deletingLastPathComponent()
            let parentPath = parent.path.lowercased()
            if occupiedNamesByParent[parentPath] == nil {
                let existing = try FileManager.default.contentsOfDirectory(
                    at: parent,
                    includingPropertiesForKeys: nil,
                    options: []
                ).map { $0.lastPathComponent.lowercased() }
                occupiedNamesByParent[parentPath] = Set(existing)
            }
            guard occupiedNamesByParent[parentPath]?.contains(destination.lastPathComponent.lowercased()) == false else {
                throw FileActionError.renameCollision
            }
        }
    }
}

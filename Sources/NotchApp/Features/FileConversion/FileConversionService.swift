import AppKit
@preconcurrency import AVFoundation
import Darwin
import Foundation
import ImageIO
import CoreText
import UniformTypeIdentifiers

enum FileConversionFormat: String, CaseIterable, Identifiable, Sendable {
    case jpeg, png, tiff, heic, txt, md, rtf, html, pdf, docx, mp4, mov, m4a, wav, aiff

    var id: Self { self }
    var title: String { rawValue.uppercased() }
    var fileExtension: String { rawValue }

    fileprivate var imageType: UTType? {
        switch self {
        case .jpeg: .jpeg
        case .png: .png
        case .tiff: .tiff
        case .heic: .heic
        default: nil
        }
    }
}

enum FileConversionProgress: Sendable, Equatable {
    case recognizingPDF(page: Int, total: Int)
}

enum FileConversionError: LocalizedError, Sendable {
    case invalidSelection
    case unsupported
    case tooLarge
    case multipleFrames
    case invalidText
    case cannotWrite
    case media(String)
    case document(String)
    case lockedPDF
    case pdfNoText(page: Int)
    case tooManyScannedPages

    var errorDescription: String? {
        switch self {
        case .invalidSelection: "Выберите от 1 до 20 локальных файлов. Папки и символические ссылки не поддерживаются."
        case .unsupported: "Это преобразование не поддерживается для выбранных файлов."
        case .tooLarge: "Файл слишком большой для безопасной обработки."
        case .multipleFrames: "Анимации и многостраничные изображения пока не поддерживаются: преобразование потеряло бы кадры."
        case .invalidText: "Не удалось прочитать текст. Для TXT и Markdown нужна кодировка UTF-8."
        case .cannotWrite: "Не удалось создать копию рядом с исходным файлом. Проверьте доступ к папке."
        case let .media(reason): "Не удалось преобразовать медиафайл: \(reason)"
        case let .document(reason): "Не удалось преобразовать документ: \(reason)"
        case .lockedPDF: "PDF защищён паролем или запрещает копирование текста."
        case let .pdfNoText(page): "На странице \(page) PDF не удалось распознать текст. Возможно, она пустая или качество скана слишком низкое."
        case .tooManyScannedPages: "За один раз можно распознать не более 40 страниц-сканов в одном PDF. Разделите документ."
        }
    }
}

/// Local, bounded conversions. Every result is published exclusively; originals are never modified.
enum FileConversionService {
    // Configuration finishes before sharing. AVFoundation explicitly supports cancelling an
    // in-flight export; all other session reads happen after its completion callback.
    private final class MediaExport: @unchecked Sendable {
        private let session: AVAssetExportSession
        private let lock = NSLock()
        private var cancelled = false
        init(_ session: AVAssetExportSession) { self.session = session }

        func run() async throws {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    if cancelled { continuation.resume(); return }
                    session.exportAsynchronously { continuation.resume() }
                }
            }
            try Task.checkCancellation()
            guard session.status == .completed else {
                throw FileConversionError.media(session.error?.localizedDescription ?? "Экспорт не завершён.")
            }
        }

        func cancel() {
            lock.withLock {
                cancelled = true
                session.cancelExport()
            }
        }
    }

    private struct PublishedFile {
        let url: URL
        let device: dev_t
        let inode: ino_t

        func removeIfOwned() {
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_dev == device, info.st_ino == inode else { return }
            _ = unlink(url.path)
        }
    }

    private static let imageExtensions = Set(["jpg", "jpeg", "png", "tif", "tiff", "heic", "heif", "gif", "bmp", "webp"])
    private static let textExtensions = Set(["txt", "md", "markdown", "rtf", "docx", "pdf"])
    private static let videoExtensions = Set(["mp4", "m4v", "mov"])
    private static let audioExtensions = Set(["m4a", "mp3", "wav", "aif", "aiff", "caf", "aac"])

    nonisolated static func formats(for urls: [URL]) -> [FileConversionFormat] {
        guard !urls.isEmpty, urls.count <= 20 else { return [] }
        var common = Set(FileConversionFormat.allCases)
        for url in urls {
            guard isRegularFile(url) else { return [] }
            common.formIntersection(candidates(for: url))
        }
        return FileConversionFormat.allCases.filter { common.contains($0) }
    }

    nonisolated static func convert(
        urls: [URL], to format: FileConversionFormat,
        onProgress: (@Sendable (FileConversionProgress) -> Void)? = nil
    ) async throws -> [URL] {
        // Keep image decoding, RTF parsing and PCM conversion away from the UI actor.
        let cancellation = TextRecognitionCancellation()
        if Task.isCancelled { cancellation.cancel() }
        let work = Task.detached(priority: .userInitiated) {
            try cancellation.check()
            return try await convertBatch(urls: urls, to: format, cancellation: cancellation, onProgress: onProgress)
        }
        return try await withTaskCancellationHandler {
            // Even a pre-cancelled caller waits for the worker's rollback/cleanup.
            return try await work.value
        } onCancel: {
            cancellation.cancel()
            work.cancel()
        }
    }

    private static func candidates(for url: URL) -> Set<FileConversionFormat> {
        let ext = url.pathExtension.lowercased()
        var result: Set<FileConversionFormat>
        if imageExtensions.contains(ext) {
            let writable = Set(CGImageDestinationCopyTypeIdentifiers() as! [String])
            result = Set(FileConversionFormat.allCases.filter { $0.imageType.map { writable.contains($0.identifier) } ?? false })
            result.insert(.pdf)
        } else if textExtensions.contains(ext) {
            result = [.txt, .md, .rtf, .html, .pdf, .docx]
        } else if videoExtensions.contains(ext) {
            result = [.mp4, .mov, .m4a]
        } else if audioExtensions.contains(ext) {
            result = [.m4a, .wav, .aiff]
        } else {
            return []
        }
        let current: FileConversionFormat? = switch ext {
        case "jpg", "jpeg": .jpeg
        case "tif", "tiff": .tiff
        case "heif", "heic": .heic
        case "aif", "aiff": .aiff
        case "markdown": .md
        default: FileConversionFormat(rawValue: ext)
        }
        if let current { result.remove(current) }
        return result
    }

    private static func convertBatch(
        urls: [URL], to format: FileConversionFormat,
        cancellation: TextRecognitionCancellation,
        onProgress: (@Sendable (FileConversionProgress) -> Void)?
    ) async throws -> [URL] {
        try Task.checkCancellation()
        guard !urls.isEmpty, urls.count <= 20, urls.allSatisfy(isRegularFile) else { throw FileConversionError.invalidSelection }
        guard formats(for: urls).contains(format) else { throw FileConversionError.unsupported }
        var published: [PublishedFile] = []
        do {
            for source in urls {
                try Task.checkCancellation()
                guard isRegularFile(source) else { throw FileConversionError.invalidSelection }
                let directory = source.deletingLastPathComponent().appendingPathComponent(".nool-convert-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                defer { try? FileManager.default.removeItem(at: directory) }
                let temporary = directory.appendingPathComponent("result.\(format.fileExtension)")
                if format.imageType != nil {
                    try convertImage(source, to: temporary, format: format)
                } else if format == .pdf, imageExtensions.contains(source.pathExtension.lowercased()) {
                    try convertImage(source, to: temporary, format: format)
                } else if [.txt, .md, .rtf, .html, .pdf, .docx].contains(format) {
                    try convertText(source, to: temporary, format: format, cancellation: cancellation, onProgress: onProgress)
                } else if format == .wav || format == .aiff {
                    try convertPCM(source, to: temporary, format: format)
                } else {
                    try await convertMedia(source, to: temporary, format: format)
                }
                try Task.checkCancellation()
                published.append(try publish(temporary, source: source, format: format))
            }
            try Task.checkCancellation()
            return published.map(\.url)
        } catch {
            published.reversed().forEach { $0.removeIfOwned() }
            throw error
        }
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }

    private static func readData(_ url: URL, limit: Int) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw FileConversionError.invalidSelection }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw FileConversionError.invalidSelection }
        guard info.st_size <= limit else { throw FileConversionError.tooLarge }
        try Task.checkCancellation()
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw FileConversionError.tooLarge }
        return data
    }

    private static func convertImage(_ source: URL, to output: URL, format: FileConversionFormat) throws {
        let data = try readData(source, limit: 256 * 1_024 * 1_024)
        guard let input = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { throw FileConversionError.unsupported }
        guard CGImageSourceGetCount(input) == 1 else { throw FileConversionError.multipleFrames }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(input, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.intValue > 0, height.intValue > 0,
              width.intValue <= 16_384, height.intValue <= 16_384,
              width.int64Value * height.int64Value <= 64_000_000 else { throw FileConversionError.tooLarge }
        try Task.checkCancellation()
        guard var image = CGImageSourceCreateImageAtIndex(input, 0, nil) else { throw FileConversionError.unsupported }
        if format == .pdf {
            try FileConversionDocument.writeImagePDF(image, orientation: (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1, to: output)
            return
        }
        guard let type = format.imageType else { throw FileConversionError.unsupported }
        if format == .jpeg {
            guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw FileConversionError.tooLarge }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard let flattened = context.makeImage() else { throw FileConversionError.tooLarge }
            image = flattened
        }
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, type.identifier as CFString, 1, nil) else { throw FileConversionError.cannotWrite }
        var metadata: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.92]
        if let orientation = properties[kCGImagePropertyOrientation] { metadata[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(destination, image, metadata as CFDictionary)
        try Task.checkCancellation()
        guard CGImageDestinationFinalize(destination) else { throw FileConversionError.cannotWrite }
    }

    private static func convertText(
        _ source: URL, to output: URL, format: FileConversionFormat,
        cancellation: TextRecognitionCancellation,
        onProgress: (@Sendable (FileConversionProgress) -> Void)?
    ) throws {
        let ext = source.pathExtension.lowercased()
        let data = try readData(source, limit: (ext == "pdf" ? 32 : 8) * 1_024 * 1_024)
        try FileConversionDocument.convert(data: data, sourceExtension: ext, to: format, output: output, cancellation: cancellation, onProgress: onProgress)
    }

    private static func convertPCM(_ source: URL, to output: URL, format: FileConversionFormat) throws {
        let input = try AVAudioFile(forReading: source)
        let processing = input.processingFormat
        guard processing.channelCount > 0, processing.channelCount <= 8, processing.sampleRate > 0, processing.sampleRate <= 384_000,
              let buffer = AVAudioPCMBuffer(pcmFormat: processing, frameCapacity: 8_192) else { throw FileConversionError.unsupported }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: processing.sampleRate, AVNumberOfChannelsKey: processing.channelCount, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: format == .aiff]
        let destination = try AVAudioFile(forWriting: output, settings: settings, commonFormat: processing.commonFormat, interleaved: processing.isInterleaved)
        while input.framePosition < input.length {
            try Task.checkCancellation()
            try input.read(into: buffer)
            guard buffer.frameLength > 0 else { throw FileConversionError.media("Не удалось прочитать аудиоданные.") }
            try destination.write(from: buffer)
        }
    }

    private static func convertMedia(_ source: URL, to output: URL, format: FileConversionFormat) async throws {
        let asset = AVURLAsset(url: source)
        let tracks = try await asset.loadTracks(withMediaType: format == .m4a ? .audio : .video)
        guard !tracks.isEmpty else { throw FileConversionError.media("В файле нет нужной аудио- или видеодорожки.") }
        let preset = format == .m4a ? AVAssetExportPresetAppleM4A : AVAssetExportPresetHighestQuality
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { throw FileConversionError.unsupported }
        let type: AVFileType = format == .mp4 ? .mp4 : format == .mov ? .mov : .m4a
        guard session.supportedFileTypes.contains(type) else { throw FileConversionError.media("Системный кодек не поддерживает этот формат для файла.") }
        session.outputURL = output
        session.outputFileType = type
        let export = MediaExport(session)
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await export.run()
        } onCancel: {
            export.cancel()
        }
    }

    private static func publish(_ temporary: URL, source: URL, format: FileConversionFormat) throws -> PublishedFile {
        var info = stat()
        guard lstat(temporary.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw FileConversionError.cannotWrite }
        let base = source.deletingPathExtension().lastPathComponent
        for number in 1...1_000 {
            try Task.checkCancellation()
            let suffix = number == 1 ? "" : " \(number)"
            let destination = source.deletingLastPathComponent().appendingPathComponent("\(base)\(suffix).\(format.fileExtension)")
            if renamex_np(temporary.path, destination.path, UInt32(RENAME_EXCL)) == 0 {
                return PublishedFile(url: destination, device: info.st_dev, inode: info.st_ino)
            }
            guard errno == EEXIST else { throw FileConversionError.cannotWrite }
        }
        throw FileConversionError.cannotWrite
    }
}

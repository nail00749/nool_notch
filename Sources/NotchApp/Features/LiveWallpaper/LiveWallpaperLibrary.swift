import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum LiveWallpaperLibraryError: LocalizedError {
    case unsupportedFile(String)
    case unplayable(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFile(let name): "«\(name)» — поддерживаются видео MP4, MOV, M4V и картинки JPEG, PNG, HEIC."
        case .unplayable(let name): "«\(name)» не удаётся открыть на этом Mac."
        }
    }
}

/// Local video folder. File operations are synchronous and must be called off the main actor.
struct LiveWallpaperLibrary: Sendable {
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic"]
    static let supportedExtensions = videoExtensions.union(imageExtensions)
    private static let posterDirectoryName = ".posters"

    let directory: URL

    static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nool Notch", isDirectory: true)
            .appendingPathComponent("Wallpapers", isDirectory: true)
    }

    /// Only plain file names inside the library are accepted; stored names never address other folders.
    static func isAcceptableFileName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && !name.contains("/") && name != ".."
            && supportedExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    static func isImageFileName(_ name: String) -> Bool {
        imageExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    func url(for fileName: String) -> URL? {
        guard Self.isAcceptableFileName(fileName) else { return nil }
        return directory.appendingPathComponent(fileName, isDirectory: false)
    }

    func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func items() -> [LiveWallpaperItem] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter(Self.isAcceptableFileName)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .compactMap { name in
                guard let url = url(for: name) else { return nil }
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                      !isDirectory.boolValue else { return nil }
                return LiveWallpaperItem(fileName: name, url: url)
            }
    }

    /// Copies through a hidden temporary name, so an interrupted copy never appears as a wallpaper.
    func importFile(from source: URL) throws -> LiveWallpaperItem {
        let original = source.lastPathComponent
        guard Self.supportedExtensions.contains(source.pathExtension.lowercased()) else {
            throw LiveWallpaperLibraryError.unsupportedFile(original)
        }
        try ensureDirectory()
        let fileName = uniqueFileName(for: original)
        let destination = directory.appendingPathComponent(fileName, isDirectory: false)
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).partial", isDirectory: false)
        do {
            try FileManager.default.copyItem(at: source, to: temporary)
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        return LiveWallpaperItem(fileName: fileName, url: destination)
    }

    func trash(_ item: LiveWallpaperItem) throws {
        guard let url = url(for: item.fileName) else { return }
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        try? FileManager.default.removeItem(at: posterURL(for: item.fileName))
    }

    func posterURL(for fileName: String) -> URL {
        directory.appendingPathComponent(Self.posterDirectoryName, isDirectory: true)
            .appendingPathComponent((fileName as NSString).deletingPathExtension + ".png", isDirectory: false)
    }

    func writePoster(_ image: CGImage, for fileName: String) throws -> URL {
        let url = posterURL(for: fileName)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return url
    }

    func uniqueFileName(for original: String) -> String {
        let base = Self.sanitizedBaseName((original as NSString).deletingPathExtension)
        let ext = (original as NSString).pathExtension.lowercased()
        var candidate = "\(base).\(ext)"
        var index = 2
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            candidate = "\(base) \(index).\(ext)"
            index += 1
        }
        return candidate
    }

    private static func sanitizedBaseName(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines))
        return cleaned.isEmpty ? "Wallpaper" : String(cleaned.prefix(120))
    }
}

enum LiveWallpaperMedia {
    static func isPlayable(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard (try? await asset.load(.isPlayable)) == true else { return false }
        let tracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        return !tracks.isEmpty
    }

    /// Returns a frame at the start of the clip; `maximumSize` of zero keeps the original resolution.
    static func frame(of url: URL, maximumSize: CGSize) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maximumSize
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        return try? await generator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600)).image
    }

    /// Decodes a picture at most `maxPixelSize` on its long edge; zero keeps the original size.
    static func image(at url: URL, maxPixelSize: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        if maxPixelSize <= 0 { return CGImageSourceCreateImageAtIndex(source, 0, nil) }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func isUsable(_ url: URL) async -> Bool {
        if LiveWallpaperLibrary.isImageFileName(url.lastPathComponent) {
            return await Task.detached { image(at: url, maxPixelSize: 64) != nil }.value
        }
        return await isPlayable(url)
    }
}

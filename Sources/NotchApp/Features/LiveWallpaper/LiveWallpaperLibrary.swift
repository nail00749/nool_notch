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

    static let wallpaperEngineExtension = "noolwe"

    /// Only plain file names inside the library are accepted; stored names never address other folders.
    static func isAcceptableFileName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && !name.contains("/") && !name.contains("\\") && name != ".."
            && supportedExtensions.union([wallpaperEngineExtension]).contains((name as NSString).pathExtension.lowercased())
    }

    static func isImageFileName(_ name: String) -> Bool {
        imageExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    func url(for fileName: String) -> URL? {
        guard Self.isAcceptableFileName(fileName) else { return nil }
        return directory.appendingPathComponent(fileName, isDirectory: (fileName as NSString).pathExtension.lowercased() == Self.wallpaperEngineExtension)
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
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
                if (name as NSString).pathExtension.lowercased() == Self.wallpaperEngineExtension {
                    guard isDirectory.boolValue, Self.isStoredWallpaperEngineProject(at: url) else { return nil }
                } else if isDirectory.boolValue { return nil }
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

    /// Imports only the package and bounded metadata. All I/O must run off the main actor.
    func importWallpaperEngine(from source: URL) throws -> LiveWallpaperItem {
        try WallpaperEnginePackage.rejectSymlinks(at: source)
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
        let isFolder = values.isDirectory == true
        let isManifest = source.lastPathComponent.lowercased() == "project.json"
        guard isFolder || isManifest || (values.isRegularFile == true && source.pathExtension.lowercased() == "pkg") else {
            throw WallpaperEngineImportError.invalid("выберите scene.pkg, project.json или папку проекта.")
        }
        let root = isFolder ? source : source.deletingLastPathComponent()
        let manifestURL = isManifest ? source : root.appendingPathComponent("project.json")
        var manifest: [String: Any]?
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            manifest = try WallpaperEnginePackage.jsonObject(
                WallpaperEnginePackage.boundedData(at: manifestURL, maximum: WallpaperEnginePackage.maximumJSONSize), description: "project.json")
            guard (manifest?["type"] as? String)?.lowercased() == "scene" else {
                throw WallpaperEngineImportError.invalid("project.json должен описывать обои типа scene.")
            }
        } else if isManifest {
            throw WallpaperEngineImportError.invalid("project.json не найден.")
        }
        let packageURL: URL
        if !isFolder && !isManifest {
            packageURL = source
        } else if let file = manifest?["file"] as? String {
            guard WallpaperEnginePackage.isSafeRelativePath(file),
                  ["pkg", "json"].contains((file as NSString).pathExtension.lowercased()) else {
                throw WallpaperEngineImportError.invalid("недопустимый путь к пакету в project.json.")
            }
            if file.lowercased() == "scene.json" {
                packageURL = root.appendingPathComponent("scene.pkg")
            } else {
                guard (file as NSString).pathExtension.lowercased() == "pkg" else {
                    throw WallpaperEngineImportError.invalid("выберите проект с упакованным scene.pkg.")
                }
                packageURL = root.appendingPathComponent(file)
            }
        } else {
            packageURL = root.appendingPathComponent("scene.pkg")
        }
        _ = try WallpaperEnginePackage.validate(at: packageURL)
        let fallbackTitle = packageURL.lastPathComponent.lowercased() == "scene.pkg"
            ? root.lastPathComponent : packageURL.deletingPathExtension().lastPathComponent
        let title = (manifest?["title"] as? String) ?? fallbackTitle
        try ensureDirectory()
        let fileName = uniqueFileName(for: sanitizedImportName(title))
        let destination = directory.appendingPathComponent(fileName, isDirectory: true)
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).partial", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
            let copiedPackage = temporary.appendingPathComponent("scene.pkg")
            try FileManager.default.copyItem(at: packageURL, to: copiedPackage)
            // Recheck the actual copy, so a changing source cannot publish a malformed library item.
            _ = try WallpaperEnginePackage.validate(at: copiedPackage)
            do {
                var metadata = manifest ?? ["type": "scene", "title": title]
                metadata["type"] = "scene"
                metadata["title"] = title
                metadata["file"] = "scene.pkg"
                metadata.removeValue(forKey: "preview")
                if let preview = manifest?["preview"] as? String {
                    guard WallpaperEnginePackage.isSafeRelativePath(preview),
                          ["png", "jpg", "jpeg", "gif"].contains((preview as NSString).pathExtension.lowercased()) else {
                        throw WallpaperEngineImportError.invalid("недопустимый путь к обложке в project.json.")
                    }
                    let previewURL = root.appendingPathComponent(preview)
                    if FileManager.default.fileExists(atPath: previewURL.path) {
                        metadata["preview"] = try Self.copyWallpaperEnginePreview(from: previewURL, to: temporary)
                    }
                }
                let data = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
                guard data.count <= WallpaperEnginePackage.maximumJSONSize else {
                    throw WallpaperEngineImportError.invalid("project.json превышает допустимый размер.")
                }
                try data.write(to: temporary.appendingPathComponent("project.json"), options: .atomic)
            }
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        return LiveWallpaperItem(fileName: fileName, url: destination)
    }

    /// Keep animated covers static in the library and decode only a bounded first-frame thumbnail.
    private static func copyWallpaperEnginePreview(from source: URL, to directory: URL) throws -> String {
        let maximumSize = 16 * 1024 * 1024
        let data = try WallpaperEnginePackage.boundedData(at: source, maximum: maximumSize)
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(imageSource) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 16_777_216 / height else {
            throw WallpaperEngineImportError.invalid("обложка проекта не является изображением допустимого размера.")
        }
        if source.pathExtension.lowercased() == "gif" {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048,
                kCGImageSourceShouldCacheImmediately: true
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
                throw WallpaperEngineImportError.invalid("не удалось прочитать первый кадр обложки проекта.")
            }
            let name = "preview.png"
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination), output.length <= maximumSize else {
                throw WallpaperEngineImportError.invalid("не удалось сохранить обложку проекта.")
            }
            try (output as Data).write(to: directory.appendingPathComponent(name), options: .atomic)
            return name
        }
        let name = "preview." + source.pathExtension.lowercased()
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        return name
    }

    private func sanitizedImportName(_ title: String) -> String {
        let printable = title.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let base = Self.sanitizedBaseName(String(String.UnicodeScalarView(printable)).replacingOccurrences(of: "\\", with: "-"))
        var bounded = ""
        for character in base {
            guard bounded.utf8.count + String(character).utf8.count <= 180 else { break }
            bounded.append(character)
        }
        return (bounded.isEmpty ? "Wallpaper" : bounded) + "." + Self.wallpaperEngineExtension
    }

    /// Library enumeration checks metadata and file type, not a potentially large package index.
    private static func isStoredWallpaperEngineProject(at url: URL) -> Bool {
        guard (try? WallpaperEnginePackage.regularFileSize(at: url.appendingPathComponent("scene.pkg"), maximum: WallpaperEnginePackage.maximumPackageSize)) != nil else { return false }
        let manifest = url.appendingPathComponent("project.json")
        guard FileManager.default.fileExists(atPath: manifest.path) else { return false }
        guard let data = try? WallpaperEnginePackage.boundedData(at: manifest, maximum: WallpaperEnginePackage.maximumJSONSize),
              let object = try? WallpaperEnginePackage.jsonObject(data, description: "project.json") else { return false }
        return (object["type"] as? String)?.lowercased() == "scene" && object["file"] as? String == "scene.pkg"
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

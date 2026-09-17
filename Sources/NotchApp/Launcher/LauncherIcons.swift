import AppKit
import ImageIO

@MainActor
final class LauncherIcons {
    private let cache = NSCache<NSString, NSImage>()

    init() { cache.countLimit = 200 }

    func image(for result: LauncherResult, clipboardData: Data?) async -> NSImage? {
        if let clipboardData {
            // Thumbnails are deliberately not cached: clearing clipboard history must
            // also release the images displayed by its rows.
            let thumbnail = await Task.detached(priority: .utility) {
                guard let source = CGImageSourceCreateWithData(clipboardData as CFData, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 80,
                        kCGImageSourceCreateThumbnailWithTransform: true
                      ] as CFDictionary) else { return Optional<Data>.none }
                return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            }.value
            guard !Task.isCancelled, let thumbnail else { return nil }
            return NSImage(data: thumbnail)
        }
        if let icon = cache.object(forKey: result.id as NSString) { return icon }
        let url: URL
        switch result.payload {
        case .application(let value), .file(let value): url = value
        default: return nil
        }
        await Task.yield()
        guard !Task.isCancelled else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(icon, forKey: result.id as NSString)
        return icon
    }
}

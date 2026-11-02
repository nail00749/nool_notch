import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import NotchApp

final class WallpaperEngineImportTests: XCTestCase {
    func testPackageVersionsAndMinimalScene() throws {
        try withFixture { root, _ in
            for version in [9, 12, 23] {
                let package = root.appendingPathComponent("\(version).pkg")
                try Self.package(version: version).write(to: package)
                XCTAssertEqual(try WallpaperEnginePackage.validate(at: package), .init(version: version, entryCount: 1))
            }
        }
    }

    func testCorruptIndexAndUnsafeEntriesAreRejected() throws {
        try withFixture { root, _ in
            let url = root.appendingPathComponent("scene.pkg")
            let cases = [
                Self.package(version: 10),
                Self.package(version: 11),
                Self.package(version: 24),
                Data(Self.package(version: 9).dropLast()),
                Self.package(version: 9, entries: [("../scene.json", Self.scene)]),
                Data(Self.package().dropLast()),
                Self.package(entries: [("../scene.json", Self.scene)]),
                Self.package(entries: [("/scene.json", Self.scene)]),
                Self.package(entries: [("folder\\scene.json", Self.scene)]),
                Self.package(entries: [("scene.json", Self.scene), ("SCENE.JSON", Self.scene)]),
                Self.package(entries: [("other.json", Self.scene)]),
                Self.package(entries: [("scene.json", Data("[]".utf8))]),
                Self.package(entries: [("scene.json", Data("{}".utf8))])
            ]
            for data in cases {
                try data.write(to: url)
                XCTAssertThrowsError(try WallpaperEnginePackage.validate(at: url))
            }
            var outOfBounds = Self.package()
            // A single scene.json index: offset at 30, size at 34.
            outOfBounds.replaceSubrange(30..<34, with: [255, 255, 255, 255])
            try outOfBounds.write(to: url)
            XCTAssertThrowsError(try WallpaperEnginePackage.validate(at: url))

            var tooMany = Self.package()
            tooMany.replaceSubrange(12..<16, with: [255, 255, 255, 255])
            try tooMany.write(to: url)
            XCTAssertThrowsError(try WallpaperEnginePackage.validate(at: url))
        }
    }

    func testOverlappingEntriesAreRejected() throws {
        try withFixture { root, _ in
            var data = Self.package(entries: [("scene.json", Self.scene), ("x", Data([1]))])
            // Second entry's offset is deliberately inside scene.json.
            data.replaceSubrange(43..<47, with: [1, 0, 0, 0])
            let url = root.appendingPathComponent("scene.pkg")
            try data.write(to: url)
            XCTAssertThrowsError(try WallpaperEnginePackage.validate(at: url))
        }
    }

    func testPackageAndSceneJSONSizeLimitsAreEnforced() throws {
        try withFixture { root, _ in
            let package = root.appendingPathComponent("large.pkg")
            try Data([0]).write(to: package)
            let handle = try FileHandle(forWritingTo: package)
            try handle.truncate(atOffset: UInt64(WallpaperEnginePackage.maximumPackageSize + 1))
            try handle.close()
            XCTAssertThrowsError(try WallpaperEnginePackage.validate(at: package))
            try Self.package(entries: [("scene.json", Data(repeating: 32, count: WallpaperEnginePackage.maximumJSONSize + 1))]).write(to: package)
            XCTAssertThrowsError(try WallpaperEnginePackage.validate(at: package))
        }
    }

    func testFolderAndManifestImportSelectPackageAndPreserveTitleWithUniqueNames() throws {
        try withFixture { root, library in
            let project = root.appendingPathComponent("Source", isDirectory: true)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            try Self.package().write(to: project.appendingPathComponent("custom.pkg"))
            let manifest = project.appendingPathComponent("project.json")
            try Data(#"{"type":"scene","file":"custom.pkg","title":"Forest / night"}"#.utf8).write(to: manifest)
            let first = try library.importWallpaperEngine(from: project)
            let second = try library.importWallpaperEngine(from: manifest)
            XCTAssertEqual(first.fileName, "Forest - night.noolwe")
            XCTAssertEqual(second.fileName, "Forest - night 2.noolwe")
            let directory = try XCTUnwrap(library.url(for: first.fileName))
            XCTAssertEqual(first.content, .wallpaperEngine(directory))
            var preferences = LiveWallpaperPreferences()
            preferences.selectedFileName = first.fileName
            preferences.displayFileNames = ["external-display": second.fileName]
            let reloadedPreferences = try JSONDecoder().decode(LiveWallpaperPreferences.self, from: JSONEncoder().encode(preferences)).sanitized
            XCTAssertEqual(reloadedPreferences.selectedFileName, first.fileName)
            XCTAssertEqual(reloadedPreferences.displayFileNames, ["external-display": second.fileName])
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("scene.pkg")), Self.package())
            let copied = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("project.json"))) as? [String: Any])
            XCTAssertEqual(copied["file"] as? String, "scene.pkg")
            XCTAssertEqual(library.items().map(\.fileName), [second.fileName, first.fileName].sorted { $0.localizedStandardCompare($1) == .orderedAscending })
            XCTAssertEqual(LiveWallpaperLibrary(directory: library.directory).items().first(where: { $0.fileName == first.fileName })?.content, .wallpaperEngine(directory))
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: library.directory.path).contains { $0.hasSuffix(".partial") })
        }
    }

    func testDirectPackageAndSceneJSONManifestFallback() throws {
        try withFixture { root, library in
            let package = root.appendingPathComponent("Clouds.pkg")
            try Self.package().write(to: package)
            let direct = try library.importWallpaperEngine(from: package)
            XCTAssertEqual(direct.fileName, "Clouds.noolwe")
            let canonical = try Data(contentsOf: XCTUnwrap(library.url(for: direct.fileName)).appendingPathComponent("project.json"))
            let metadata = try XCTUnwrap(try JSONSerialization.jsonObject(with: canonical) as? [String: Any])
            XCTAssertEqual(metadata["type"] as? String, "scene")
            XCTAssertEqual(metadata["file"] as? String, "scene.pkg")
            XCTAssertEqual(metadata["title"] as? String, "Clouds")
            let project = root.appendingPathComponent("Source", isDirectory: true)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            try Self.package().write(to: project.appendingPathComponent("scene.pkg"))
            try Data(#"{"type":"scene","file":"scene.json","title":"Fallback"}"#.utf8).write(to: project.appendingPathComponent("project.json"))
            XCTAssertEqual(try library.importWallpaperEngine(from: project).fileName, "Fallback.noolwe")
        }
    }

    func testVersion9ProjectWithAnimatedGIFCoverImportsOnlyFirstFrameAsPNG() throws {
        try withFixture { root, library in
            let project = root.appendingPathComponent("Source", isDirectory: true)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            let package = Self.package(version: 9, entries: [("scene.json", Self.scene), ("textures/test.tex", Data([1, 2, 3]))])
            try package.write(to: project.appendingPathComponent("scene.pkg"))
            let gif = try Self.animatedCover()
            try gif.write(to: project.appendingPathComponent("preview.gif"))
            try Data(#"{"type":"scene","file":"scene.json","title":"Animated cover","preview":"preview.gif"}"#.utf8)
                .write(to: project.appendingPathComponent("project.json"))

            let item = try library.importWallpaperEngine(from: project)
            let stored = try XCTUnwrap(library.url(for: item.fileName))
            let metadata = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: stored.appendingPathComponent("project.json"))) as? [String: Any])
            XCTAssertEqual(metadata["preview"] as? String, "preview.png")
            XCTAssertEqual(try Data(contentsOf: stored.appendingPathComponent("scene.pkg")), package)
            XCTAssertEqual(try Data(contentsOf: project.appendingPathComponent("preview.gif")), gif)
            XCTAssertFalse(FileManager.default.fileExists(atPath: stored.appendingPathComponent("preview.gif").path))
            let cover = try XCTUnwrap(CGImageSourceCreateWithURL(stored.appendingPathComponent("preview.png") as CFURL, nil))
            XCTAssertEqual(CGImageSourceGetType(cover) as String?, UTType.png.identifier)
            XCTAssertEqual(CGImageSourceGetCount(cover), 1)
            let firstFrame = try XCTUnwrap(CGImageSourceCreateImageAtIndex(cover, 0, nil))
            XCTAssertEqual(firstFrame.width, 128)
            XCTAssertEqual(firstFrame.height, 64)
            let context = try Self.coverContext()
            context.draw(firstFrame, in: CGRect(x: 0, y: 0, width: 128, height: 64))
            let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
            XCTAssertGreaterThan(pixels[0], 240, "The first GIF frame is red, the second blue.")
            XCTAssertLessThan(pixels[2], 15)
        }
    }

    func testGIFCoverPathEscapesSymlinksAndOversizedCanvasAreRejected() throws {
        try withFixture { root, library in
            let project = root.appendingPathComponent("Source", isDirectory: true)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            try Self.package(version: 9).write(to: project.appendingPathComponent("scene.pkg"))
            let originalGIF = try Self.animatedCover()
            let outside = root.appendingPathComponent("outside.gif")
            try originalGIF.write(to: outside)
            try FileManager.default.createSymbolicLink(at: project.appendingPathComponent("linked.gif"), withDestinationURL: outside)
            var oversizedCanvas = originalGIF
            oversizedCanvas.replaceSubrange(6..<10, with: [0, 64, 0, 64]) // 16384 × 16384 logical GIF canvas.
            try oversizedCanvas.write(to: project.appendingPathComponent("oversized.gif"))
            try Data([1, 2, 3]).write(to: project.appendingPathComponent("invalid.gif"))
            for preview in ["../outside.gif", "/outside.gif", "folder\\outside.gif", "linked.gif", "oversized.gif", "invalid.gif"] {
                let metadata = ["type": "scene", "file": "scene.pkg", "preview": preview]
                try JSONSerialization.data(withJSONObject: metadata).write(to: project.appendingPathComponent("project.json"))
                XCTAssertThrowsError(try library.importWallpaperEngine(from: project), preview)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: library.directory.path), [], preview)
            }
        }
    }

    func testManifestPathEscapeAndNonSceneAndOversizedJSONAreRejected() throws {
        try withFixture { root, library in
            let project = root.appendingPathComponent("Source", isDirectory: true)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            let manifest = project.appendingPathComponent("project.json")
            try Self.package().write(to: root.appendingPathComponent("outside.pkg"))
            for json in [#"{"type":"scene","file":"../outside.pkg"}"#, #"{"type":"video","file":"scene.pkg"}"#] {
                try Data(json.utf8).write(to: manifest)
                XCTAssertThrowsError(try library.importWallpaperEngine(from: project))
            }
            try Data(repeating: 32, count: WallpaperEnginePackage.maximumJSONSize + 1).write(to: manifest)
            XCTAssertThrowsError(try library.importWallpaperEngine(from: manifest))
            XCTAssertTrue(library.items().isEmpty)
        }
    }

    func testSymlinkAndNonRegularSourceAreRejected() throws {
        try withFixture { root, library in
            let package = root.appendingPathComponent("real.pkg")
            try Self.package().write(to: package)
            let link = root.appendingPathComponent("link.pkg")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: package)
            XCTAssertThrowsError(try library.importWallpaperEngine(from: link))
            let folderLink = root.appendingPathComponent("linked", isDirectory: true)
            let folder = root.appendingPathComponent("real", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Self.package().write(to: folder.appendingPathComponent("scene.pkg"))
            try FileManager.default.createSymbolicLink(at: folderLink, withDestinationURL: folder)
            XCTAssertThrowsError(try library.importWallpaperEngine(from: folderLink.appendingPathComponent("scene.pkg")))
            XCTAssertThrowsError(try WallpaperEnginePackage.validate(at: folder))
        }
    }

    func testMacOSTemporaryRootAliasIsAccepted() throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.package().write(to: root.appendingPathComponent("scene.pkg"))
        let alias = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent(root.lastPathComponent).appendingPathComponent("scene.pkg")
        XCTAssertEqual(try WallpaperEnginePackage.validate(at: alias), .init(version: 12, entryCount: 1))
    }

    func testFailureAfterCopyCleansTemporaryFolderAndCatalogSkipsInvalidEntries() throws {
        try withFixture { root, library in
            let project = root.appendingPathComponent("Source", isDirectory: true)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            try Self.package().write(to: project.appendingPathComponent("scene.pkg"))
            try Data(#"{"type":"scene","file":"scene.pkg","preview":"../bad.png"}"#.utf8).write(to: project.appendingPathComponent("project.json"))
            XCTAssertThrowsError(try library.importWallpaperEngine(from: project))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: library.directory.path), [])
            try Data([0]).write(to: library.directory.appendingPathComponent("file.noolwe"))
            try FileManager.default.createDirectory(at: library.directory.appendingPathComponent("empty.noolwe"), withIntermediateDirectories: true)
            XCTAssertTrue(library.items().isEmpty)
            XCTAssertFalse(LiveWallpaperLibrary.isAcceptableFileName("../escape.noolwe"))
        }
    }

    private static let scene = Data(#"{"general":{},"objects":[]}"#.utf8)

    private static func coverContext() throws -> CGContext {
        try XCTUnwrap(CGContext(data: nil, width: 128, height: 64, bitsPerComponent: 8,
                               bytesPerRow: 128 * 4, space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    }

    private static func animatedCover() throws -> Data {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, 2, nil))
        let context = try coverContext()
        for color in [CGColor(red: 1, green: 0, blue: 0, alpha: 1), CGColor(red: 0, green: 0, blue: 1, alpha: 1)] {
            context.setFillColor(color)
            context.fill(CGRect(x: 0, y: 0, width: 128, height: 64))
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private static func package(version: Int = 12, entries: [(String, Data)] = [("scene.json", scene)]) -> Data {
        var data = Data()
        func append(_ value: Int) { data.append(contentsOf: (0..<4).map { UInt8((value >> ($0 * 8)) & 255) }) }
        append(8)
        data.append(contentsOf: String(format: "PKGV%04d", version).utf8)
        append(entries.count)
        var offset = 0
        for (name, payload) in entries {
            append(name.utf8.count)
            data.append(contentsOf: name.utf8)
            append(offset)
            append(payload.count)
            offset += payload.count
        }
        for (_, payload) in entries { data.append(payload) }
        return data
    }

    private func withFixture(_ body: (URL, LiveWallpaperLibrary) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try body(root, LiveWallpaperLibrary(directory: root.appendingPathComponent("Library", isDirectory: true)))
    }
}

import Foundation

enum WallpaperEngineImportError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let reason): "Не удалось импортировать сцену Wallpaper Engine: \(reason)"
        }
    }
}

/// Only validates the container; entries are never extracted or executed by the importer.
enum WallpaperEnginePackage {
    static let maximumPackageSize = 512 * 1024 * 1024
    static let maximumJSONSize = 2 * 1024 * 1024
    private static let maximumIndexSize = 16 * 1024 * 1024
    private static let maximumEntryCount = 100_000

    struct Inspection: Equatable, Sendable {
        let version: Int
        let entryCount: Int
    }

    static func validate(at url: URL) throws -> Inspection {
        let fileSize = try regularFileSize(at: url, maximum: maximumPackageSize)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var position = 0
        func read(_ count: Int) throws -> Data {
            guard count >= 0, position <= fileSize - count else {
                throw WallpaperEngineImportError.invalid("повреждена таблица файлов scene.pkg.")
            }
            let data = try handle.read(upToCount: count) ?? Data()
            guard data.count == count else { throw WallpaperEngineImportError.invalid("файл scene.pkg обрезан.") }
            position += count
            return data
        }
        func uint32() throws -> Int {
            let bytes = try read(4)
            return bytes.enumerated().reduce(0) { $0 | (Int($1.element) << ($1.offset * 8)) }
        }
        guard try uint32() == 8,
              let magic = String(data: try read(8), encoding: .ascii), magic.hasPrefix("PKGV"),
              let version = Int(magic.dropFirst(4)), version == 9 || (12...23).contains(version),
              magic == String(format: "PKGV%04d", version) else {
            throw WallpaperEngineImportError.invalid("поддерживаются контейнеры PKGV0009 и PKGV0012–PKGV0023.")
        }
        let count = try uint32()
        guard (1...maximumEntryCount).contains(count) else {
            throw WallpaperEngineImportError.invalid("недопустимое количество файлов в scene.pkg.")
        }
        var names = Set<String>()
        var entries: [(name: String, offset: Int, size: Int)] = []
        entries.reserveCapacity(count)
        for _ in 0..<count {
            let length = try uint32()
            guard (1...1024).contains(length), position + length + 8 <= maximumIndexSize else {
                throw WallpaperEngineImportError.invalid("слишком большая таблица файлов scene.pkg.")
            }
            let nameData = try read(length)
            // Wallpaper Engine also permits Latin-1 entry names in older packages.
            guard let name = String(data: nameData, encoding: .utf8) ?? String(data: nameData, encoding: .isoLatin1),
                  isSafeRelativePath(name), names.insert(name.lowercased()).inserted else {
                throw WallpaperEngineImportError.invalid("небезопасный или повторяющийся путь в scene.pkg.")
            }
            entries.append((name, try uint32(), try uint32()))
        }
        let dataStart = position
        let available = fileSize - dataStart
        var previousEnd = 0
        for entry in entries.sorted(by: { $0.offset < $1.offset }) {
            guard entry.offset <= available, entry.size <= available - entry.offset,
                  entry.size == 0 || entry.offset >= previousEnd else {
                throw WallpaperEngineImportError.invalid("данные файлов выходят за границы scene.pkg или пересекаются.")
            }
            previousEnd = max(previousEnd, entry.offset + entry.size)
        }
        guard let scene = entries.first(where: { $0.name.lowercased() == "scene.json" }),
              (1...maximumJSONSize).contains(scene.size) else {
            throw WallpaperEngineImportError.invalid("в пакете нет допустимого scene.json.")
        }
        try handle.seek(toOffset: UInt64(dataStart + scene.offset))
        position = dataStart + scene.offset
        let object = try jsonObject(try read(scene.size), description: "scene.json")
        guard object["objects"] is [Any], object["general"] is [String: Any] else {
            throw WallpaperEngineImportError.invalid("scene.json не содержит описания сцены.")
        }
        return Inspection(version: version, entryCount: count)
    }

    static func isSafeRelativePath(_ path: String) -> Bool {
        !path.isEmpty && path.utf8.count <= 1024 && !path.contains("\\") && !path.contains(":")
            && !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
                !$0.isEmpty && $0 != "." && $0 != ".."
            }
    }

    /// Reject symlinks in every component, except macOS's two fixed temporary-directory aliases.
    static func rejectSymlinks(at url: URL) throws {
        guard url.isFileURL else { throw WallpaperEngineImportError.invalid("нужен локальный файл.") }
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in url.pathComponents.dropFirst() {
            guard component != ".", component != ".." else {
                throw WallpaperEngineImportError.invalid("недопустимый путь к файлу проекта.")
            }
            current.appendPathComponent(component)
            let values = try current.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                // Foundation may standardize /private/var back to /var. Only permit these
                // system-owned root aliases, and only while their target remains the expected one.
                let expectedTarget = ["/var": "private/var", "/tmp": "private/tmp"][current.path]
                let actualTarget = try FileManager.default.destinationOfSymbolicLink(atPath: current.path)
                guard let expectedTarget,
                      actualTarget == expectedTarget || actualTarget == "/" + expectedTarget else {
                    throw WallpaperEngineImportError.invalid("символические ссылки не поддерживаются.")
                }
            }
        }
    }

    @discardableResult
    static func regularFileSize(at url: URL, maximum: Int) throws -> Int {
        try rejectSymlinks(at: url)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= maximum else {
            throw WallpaperEngineImportError.invalid("«\(url.lastPathComponent)» — не обычный файл или превышает допустимый размер.")
        }
        return size
    }

    static func jsonObject(_ data: Data, description: String) throws -> [String: Any] {
        guard data.count <= maximumJSONSize,
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WallpaperEngineImportError.invalid("\(description) содержит некорректный JSON.")
        }
        return value
    }

    static func boundedData(at url: URL, maximum: Int) throws -> Data {
        try regularFileSize(at: url, maximum: maximum)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximum + 1) ?? Data()
        guard !data.isEmpty, data.count <= maximum else {
            throw WallpaperEngineImportError.invalid("«\(url.lastPathComponent)» превышает допустимый размер.")
        }
        return data
    }
}

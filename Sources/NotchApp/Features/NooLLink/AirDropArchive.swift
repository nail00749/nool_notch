import Foundation
import zlib

enum AirDropArchive {
    enum UploadFormat {
        case gzipCPIO
        case dvzip

        init(contentType: String?) throws {
            switch contentType?.lowercased().split(separator: ";").first.map(String.init) {
            case "application/x-cpio": self = .gzipCPIO
            case "application/x-dvzip": self = .dvzip
            default: throw AirDropProtocolError.unsupported
            }
        }
    }

    /// Parses bytes, never delegates path handling or file creation to an archive tool.
    static func files(_ archive: Data, offered: AirDropOffer) throws -> [(String, Data)] {
        guard archive.count <= AirDropProtocol.maximumArchiveBytes else { throw AirDropProtocolError.tooLarge }
        let bytes = [UInt8](archive)
        var cursor = 0, total = 0, entries = 0, foundTrailer = false
        var files: [(String, Data)] = []
        var seen = Set<String>()
        let expected = Dictionary(uniqueKeysWithValues: offered.files.map { ("./" + $0.name, $0) })
        func number(_ offset: Int, _ width: Int, radix: Int) throws -> Int {
            guard offset >= 0, offset <= bytes.count - width,
                  let value = Int(String(decoding: bytes[offset..<(offset + width)], as: UTF8.self), radix: radix), value >= 0 else {
                throw AirDropProtocolError.invalidArchive
            }
            return value
        }
        while cursor < bytes.count {
            entries += 1
            guard entries <= AirDropProtocol.maximumFiles * 2 + 2, cursor <= bytes.count - 6 else { throw AirDropProtocolError.invalidArchive }
            let magic = String(decoding: bytes[cursor..<(cursor + 6)], as: UTF8.self)
            let header: Int, mode: Int, links: Int, nameSize: Int, size: Int, alignment: Int
            if magic == "070707" {
                header = 76; alignment = 1
                guard cursor <= bytes.count - header else { throw AirDropProtocolError.invalidArchive }
                mode = try number(cursor + 18, 6, radix: 8)
                links = try number(cursor + 36, 6, radix: 8)
                nameSize = try number(cursor + 59, 6, radix: 8)
                size = try number(cursor + 65, 11, radix: 8)
            } else if magic == "070701" || magic == "070702" {
                header = 110; alignment = 4
                guard cursor <= bytes.count - header else { throw AirDropProtocolError.invalidArchive }
                mode = try number(cursor + 14, 8, radix: 16)
                links = try number(cursor + 38, 8, radix: 16)
                size = try number(cursor + 54, 8, radix: 16)
                nameSize = try number(cursor + 94, 8, radix: 16)
                // Checksum variant is accepted only when its checksum matches below.
            } else { throw AirDropProtocolError.invalidArchive }
            guard nameSize >= 1, nameSize <= 512, size <= AirDropProtocol.maximumFileBytes,
                  header + nameSize <= bytes.count - cursor else { throw AirDropProtocolError.invalidArchive }
            let nameStart = cursor + header
            guard bytes[nameStart + nameSize - 1] == 0,
                  !bytes[nameStart..<(nameStart + nameSize - 1)].contains(0),
                  let name = String(bytes: bytes[nameStart..<(nameStart + nameSize - 1)], encoding: .utf8) else {
                throw AirDropProtocolError.invalidArchive
            }
            var payload = nameStart + nameSize
            if alignment == 4 { payload = (payload + 3) & ~3 }
            guard payload <= bytes.count, size <= bytes.count - payload else { throw AirDropProtocolError.invalidArchive }
            let end = payload + size
            if name == "TRAILER!!!" {
                guard size == 0 else { throw AirDropProtocolError.invalidArchive }
                let trailerEnd = alignment == 4 ? (end + 3) & ~3 : end
                // Apple pads CPIO streams to 512-byte blocks after TRAILER!!!.
                // Only the final zero padding is accepted; trailing entries or
                // arbitrary data can never be hidden behind the trailer.
                guard trailerEnd <= bytes.count, bytes.count - trailerEnd <= 511,
                      bytes[trailerEnd...].allSatisfy({ $0 == 0 }) else { throw AirDropProtocolError.invalidArchive }
                foundTrailer = true; break
            }
            if name == "." || name == "./" {
                guard mode & 0o170000 == 0o040000, size == 0 else { throw AirDropProtocolError.invalidArchive }
            } else {
                guard mode & 0o170000 == 0o100000, links <= 1 else { throw AirDropProtocolError.invalidArchive }
                if let file = expected[name] {
                    guard seen.insert(name).inserted, file.size == nil || file.size == size else { throw AirDropProtocolError.invalidArchive }
                    total += size
                    guard total <= AirDropProtocol.maximumFileBytes else { throw AirDropProtocolError.tooLarge }
                    if magic == "070702" {
                        let checksum = try number(cursor + 102, 8, radix: 16)
                        let actual = bytes[payload..<end].reduce(UInt32(0)) { $0 &+ UInt32($1) }
                        guard UInt32(truncatingIfNeeded: checksum) == actual else { throw AirDropProtocolError.invalidArchive }
                    }
                    files.append((file.name, Data(bytes[payload..<end])))
                } else if name.hasPrefix("./._"), expected["./" + name.dropFirst(4)] != nil {
                    // AppleDouble metadata is never extracted or forwarded to Windows.
                    total += size
                    guard total <= AirDropProtocol.maximumFileBytes else { throw AirDropProtocolError.tooLarge }
                } else { throw AirDropProtocolError.invalidArchive }
            }
            cursor = alignment == 4 ? (end + 3) & ~3 : end
        }
        guard foundTrailer, files.count == expected.count else { throw AirDropProtocolError.invalidArchive }
        return files
    }

    static func extract(_ compressed: Data, offered: AirDropOffer, format: UploadFormat) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nool-airdrop-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let archive: Data
            switch format {
            case .gzipCPIO:
                guard let inflated = try inflate(compressed) else { throw AirDropProtocolError.invalidArchive }
                archive = inflated
            case .dvzip:
                archive = try inflateDVZip(compressed, offered: offered)
            }
            let decoded = try files(archive, offered: offered)
            for (name, data) in decoded {
                let url = directory.appendingPathComponent(name, isDirectory: false)
                try data.write(to: url, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
            return directory
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    /// DVZip is a sequence of independent zlib frames. Frame sizes can vary;
    /// the whole decompressed archive remains bounded by the negotiated limit.
    static func inflateDVZip(_ data: Data, offered: AirDropOffer) throws -> Data {
        guard data.count <= AirDropProtocol.maximumArchiveBytes else { throw AirDropProtocolError.tooLarge }
        let decoder = AirDropDVZipDecoder(offered: offered)
        let complete = try decoder.append(data)
        guard complete, decoder.bufferedByteCount == 0 else {
            throw AirDropProtocolError.invalidArchive
        }
        return decoder.archive
    }

    /// Returns nil for a still-incomplete gzip stream. Output is bounded while inflating.
    static func inflate(_ data: Data) throws -> Data? {
        guard data.count <= AirDropProtocol.maximumArchiveBytes,
              data.starts(with: [0x1f, 0x8b]) else { throw AirDropProtocolError.unsupported }
        var stream = z_stream()
        guard inflateInit2_(&stream, 31, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw AirDropProtocolError.invalidArchive
        }
        defer { inflateEnd(&stream) }
        return try data.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: UInt8.self).baseAddress)
            stream.avail_in = UInt32(data.count)
            var result = Data()
            var output = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let remaining = stream.avail_in
                let status = output.withUnsafeMutableBufferPointer { buffer -> Int32 in
                    stream.next_out = buffer.baseAddress
                    stream.avail_out = UInt32(buffer.count)
                    return zlib.inflate(&stream, Z_NO_FLUSH)
                }
                let produced = output.count - Int(stream.avail_out)
                guard produced <= AirDropProtocol.maximumArchiveBytes - result.count else { throw AirDropProtocolError.tooLarge }
                result.append(contentsOf: output.prefix(produced))
                if status == Z_STREAM_END {
                    // A second gzip member is unnecessary and can hide extra archive entries.
                    guard stream.avail_in == 0 else { throw AirDropProtocolError.invalidArchive }
                    return result
                }
                guard status == Z_OK || status == Z_BUF_ERROR else { throw AirDropProtocolError.invalidArchive }
                if produced == 0 && stream.avail_in == remaining && stream.avail_in > 0 { throw AirDropProtocolError.invalidArchive }
                if produced == 0 && stream.avail_in == 0 { return nil }
            }
        }
    }
}

/// Consumes DVZip framing incrementally and completes only at a structurally
/// valid CPIO trailer whose entries exactly match the accepted AirDrop offer.
final class AirDropDVZipDecoder {
    static let maximumFrameCount = 8_192
    private let offered: AirDropOffer
    private var frameBuffer = Data()
    private(set) var archive = Data()
    private var cursor = 0
    private var entries = 0
    private var completed = false
    private var frameCount = 0

    var bufferedByteCount: Int { frameBuffer.count }

    init(offered: AirDropOffer) { self.offered = offered }

    func append(_ data: Data) throws -> Bool {
        guard !completed, data.count <= AirDropProtocol.maximumArchiveBytes - frameBuffer.count else {
            throw AirDropProtocolError.tooLarge
        }
        frameBuffer.append(data)
        while frameBuffer.count >= 4 {
            guard frameCount < Self.maximumFrameCount else { throw AirDropProtocolError.tooLarge }
            let word = frameBuffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            let stored = (word & 0x8000_0000) != 0
            let length = Int(word & 0x7fff_ffff)
            guard length > 0, length <= AirDropProtocol.maximumArchiveBytes else { throw AirDropProtocolError.invalidArchive }
            guard frameBuffer.count >= length + 4 else { return false }
            let frame = Data(frameBuffer[4..<(length + 4)])
            frameBuffer.removeSubrange(..<(length + 4))
            frameCount += 1
            let remaining = AirDropProtocol.maximumArchiveBytes - archive.count
            let decoded = stored ? frame : try Self.inflateFrame(frame, maximumOutput: remaining)
            guard !decoded.isEmpty, decoded.count <= remaining else {
                throw AirDropProtocolError.tooLarge
            }
            archive.append(decoded)
            if try consumeCompleteEntries() {
                guard frameBuffer.isEmpty else { throw AirDropProtocolError.invalidArchive }
                completed = true
                return true
            }
        }
        return false
    }

    private func consumeCompleteEntries() throws -> Bool {
        while cursor < archive.count {
            guard archive.count - cursor >= 6 else { return false }
            let magic = String(data: archive[cursor..<(cursor + 6)], encoding: .ascii) ?? ""
            let header: Int, alignment: Int, mode: Int, links: Int, nameSize: Int, size: Int
            if magic == "070707" {
                header = 76; alignment = 1
                guard archive.count - cursor >= header else { return false }
                mode = try number(cursor + 18, 6, radix: 8)
                links = try number(cursor + 36, 6, radix: 8)
                nameSize = try number(cursor + 59, 6, radix: 8)
                size = try number(cursor + 65, 11, radix: 8)
            } else if magic == "070701" || magic == "070702" {
                header = 110; alignment = 4
                guard archive.count - cursor >= header else { return false }
                mode = try number(cursor + 14, 8, radix: 16)
                links = try number(cursor + 38, 8, radix: 16)
                size = try number(cursor + 54, 8, radix: 16)
                nameSize = try number(cursor + 94, 8, radix: 16)
            } else { throw AirDropProtocolError.invalidArchive }
            guard (1...512).contains(nameSize), size <= AirDropProtocol.maximumFileBytes else {
                throw AirDropProtocolError.invalidArchive
            }
            guard header + nameSize <= archive.count - cursor else { return false }
            let nameStart = cursor + header
            guard archive[nameStart + nameSize - 1] == 0,
                  !archive[nameStart..<(nameStart + nameSize - 1)].contains(0),
                  let name = String(data: archive[nameStart..<(nameStart + nameSize - 1)], encoding: .utf8) else {
                throw AirDropProtocolError.invalidArchive
            }
            var payload = nameStart + nameSize
            if alignment == 4 { payload = (payload + 3) & ~3 }
            guard payload <= archive.count, size <= archive.count - payload else { return false }
            let end = payload + size
            if name == "TRAILER!!!" {
                guard size == 0 else { throw AirDropProtocolError.invalidArchive }
                _ = try AirDropArchive.files(archive, offered: offered)
                return true
            }
            if name == "." || name == "./" {
                guard mode & 0o170000 == 0o040000, size == 0 else { throw AirDropProtocolError.invalidArchive }
            } else {
                guard mode & 0o170000 == 0o100000, links <= 1 else { throw AirDropProtocolError.invalidArchive }
            }
            guard entries < AirDropProtocol.maximumFiles * 2 + 2 else { throw AirDropProtocolError.invalidArchive }
            entries += 1
            cursor = alignment == 4 ? (end + 3) & ~3 : end
            if cursor > archive.count { return false }
        }
        return false
    }

    private func number(_ offset: Int, _ width: Int, radix: Int) throws -> Int {
        guard offset >= 0, offset <= archive.count - width,
              let value = Int(String(data: archive[offset..<(offset + width)], encoding: .ascii) ?? "", radix: radix), value >= 0 else {
            throw AirDropProtocolError.invalidArchive
        }
        return value
    }

    private static func inflateFrame(_ data: Data, maximumOutput: Int) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream, 15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw AirDropProtocolError.invalidArchive
        }
        defer { inflateEnd(&stream) }
        return try data.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: UInt8.self).baseAddress)
            stream.avail_in = UInt32(data.count)
            var result = Data(), output = [UInt8](repeating: 0, count: 65_537)
            while true {
                let oldInput = stream.avail_in
                let status = output.withUnsafeMutableBufferPointer { buffer -> Int32 in
                    stream.next_out = buffer.baseAddress; stream.avail_out = UInt32(buffer.count)
                    return zlib.inflate(&stream, Z_NO_FLUSH)
                }
                let produced = output.count - Int(stream.avail_out)
                guard produced <= maximumOutput - result.count else { throw AirDropProtocolError.tooLarge }
                result.append(contentsOf: output.prefix(produced))
                if status == Z_STREAM_END {
                    guard stream.avail_in == 0 else { throw AirDropProtocolError.invalidArchive }
                    return result
                }
                guard status == Z_OK || status == Z_BUF_ERROR,
                      produced > 0 || stream.avail_in < oldInput else { throw AirDropProtocolError.invalidArchive }
            }
        }
    }
}

/// Tracks the gzip end marker across HTTP chunks without inflating the same bytes
/// repeatedly. The complete archive is validated before any file is forwarded.
final class AirDropGzipBoundary {
    private var stream = z_stream()
    private var produced = 0
    private var completed = false
    init() throws {
        guard inflateInit2_(&stream, 31, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw AirDropProtocolError.invalidArchive
        }
    }
    deinit { inflateEnd(&stream) }

    func append(_ data: Data) throws -> Bool {
        guard !completed else { throw AirDropProtocolError.invalidArchive }
        return try data.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: UInt8.self).baseAddress)
            stream.avail_in = UInt32(data.count)
            var output = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let remaining = stream.avail_in
                let status = output.withUnsafeMutableBufferPointer { buffer -> Int32 in
                    stream.next_out = buffer.baseAddress; stream.avail_out = UInt32(buffer.count)
                    return zlib.inflate(&stream, Z_NO_FLUSH)
                }
                let count = output.count - Int(stream.avail_out)
                guard count <= AirDropProtocol.maximumArchiveBytes - produced else { throw AirDropProtocolError.tooLarge }
                produced += count
                if status == Z_STREAM_END {
                    guard stream.avail_in == 0 else { throw AirDropProtocolError.invalidArchive }
                    completed = true; return true
                }
                guard status == Z_OK || status == Z_BUF_ERROR else { throw AirDropProtocolError.invalidArchive }
                if count == 0 && stream.avail_in == remaining && stream.avail_in > 0 { throw AirDropProtocolError.invalidArchive }
                if stream.avail_in == 0 && stream.avail_out != 0 { return false }
            }
        }
    }
}

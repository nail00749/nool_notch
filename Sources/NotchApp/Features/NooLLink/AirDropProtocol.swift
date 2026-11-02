import Foundation
import CoreFoundation

struct AirDropOffer: Sendable {
    struct File: Sendable, Equatable {
        let name: String
        let size: Int?
    }
    let senderName: String
    let files: [File]
    let transferID: String?
    /// Set by the receiver when Finder on this same Mac is the sender.
    var fromThisMac = false
    var totalBytes: Int? {
        let sizes = files.compactMap(\.size)
        return sizes.count == files.count ? sizes.reduce(0, +) : nil
    }
}

enum AirDropProtocolError: Error { case malformed, tooLarge, unsupported, invalidArchive }

enum AirDropProtocol {
    static let maximumFiles = 64
    static let maximumFileBytes = 32 * 1024 * 1024
    static let maximumArchiveBytes = maximumFileBytes + 2 * 1024 * 1024
    static let maximumPlistBytes = 256 * 1024

    static func plist(_ data: Data) throws -> [String: Any] {
        guard data.count <= maximumPlistBytes else { throw AirDropProtocolError.tooLarge }
        try AirDropBinaryPlist.validate(data)
        guard let value = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw AirDropProtocolError.malformed
        }
        return value
    }

    static func offer(_ data: Data) throws -> AirDropOffer {
        let value = try plist(data)
        guard let sender = value["SenderComputerName"] as? String, safeDisplayName(sender),
              let files = value["Files"] as? [[String: Any]], !files.isEmpty, files.count <= maximumFiles,
              (value["Items"] as? [Any] ?? []).isEmpty else { throw AirDropProtocolError.unsupported }
        var names = Set<String>()
        var result: [AirDropOffer.File] = []
        var total = 0
        for file in files {
            guard let name = file["FileName"] as? String, safeFilename(name),
                  names.insert(name.lowercased()).inserted,
                  file["FileBomPath"] as? String == "./" + name,
                  let directory = file["FileIsDirectory"] as? Bool, !directory else { throw AirDropProtocolError.unsupported }
            var size: Int?
            if let number = file["FileSize"] as? NSNumber {
                guard CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue >= 0,
                      number.doubleValue <= Double(maximumFileBytes), number.doubleValue.rounded() == number.doubleValue else {
                    throw AirDropProtocolError.tooLarge
                }
                size = number.intValue
                total += number.intValue
                guard total <= maximumFileBytes else { throw AirDropProtocolError.tooLarge }
            }
            result.append(.init(name: name, size: size))
        }
        var transferID: String?
        if let raw = value["TransferID"] {
            guard let id = (raw as? [String: Any])?["id"] as? String, UUID(uuidString: id) != nil else {
                throw AirDropProtocolError.malformed
            }
            transferID = id
        }
        return .init(senderName: sender, files: result, transferID: transferID)
    }

    static func response(name: String, discover: Bool) throws -> Data {
        var value: [String: Any] = ["ReceiverComputerName": name, "ReceiverModelName": "MacPro7,1"]
        if discover { value["StatusCode"] = 100 }
        return try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
    }

    static func safeDisplayName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 240 && !name.unicodeScalars.contains { scalar in
            CharacterSet.controlCharacters.contains(scalar) || (0x202a...0x202e).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value)
        }
    }

    static func safeFilename(_ name: String) -> Bool {
        guard safeDisplayName(name), NooLLinkEnvelope.safeFilename(name),
              !name.contains(where: { "<>\"|?*".contains($0) }) else { return false }
        return true
    }
}

/// Checks object references and recursion before Foundation materializes an untrusted bplist.
private enum AirDropBinaryPlist {
    static func validate(_ data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= 40, Array(bytes.prefix(8)) == Array("bplist00".utf8) else { throw AirDropProtocolError.malformed }
        let trailer = bytes.count - 32
        let offsetWidth = Int(bytes[trailer + 6]), refWidth = Int(bytes[trailer + 7])
        func integer(_ offset: Int, _ count: Int) throws -> Int {
            guard (1...8).contains(count), offset >= 0, offset <= bytes.count - count else { throw AirDropProtocolError.malformed }
            var value: UInt64 = 0
            for index in offset..<(offset + count) { value = (value << 8) | UInt64(bytes[index]) }
            guard value <= UInt64(Int.max) else { throw AirDropProtocolError.malformed }
            return Int(value)
        }
        let count = try integer(trailer + 8, 8), top = try integer(trailer + 16, 8), table = try integer(trailer + 24, 8)
        guard (1...4096).contains(count), (1...8).contains(offsetWidth), (1...8).contains(refWidth), top < count,
              table >= 8, table <= trailer, count <= (trailer - table) / offsetWidth else { throw AirDropProtocolError.malformed }
        let offsets = try (0..<count).map { try integer(table + $0 * offsetWidth, offsetWidth) }
        guard offsets.allSatisfy({ $0 >= 8 && $0 < table }) else { throw AirDropProtocolError.malformed }
        var budget = 16_384
        var path = Set<Int>()
        func visit(_ object: Int, _ depth: Int) throws {
            budget -= 1
            guard object < count, depth <= 16, budget > 0, path.insert(object).inserted else { throw AirDropProtocolError.malformed }
            defer { path.remove(object) }
            let start = offsets[object], marker = bytes[start], kind = marker >> 4
            var length = Int(marker & 15), cursor = start + 1
            if [4, 5, 6, 8, 10, 12, 13].contains(kind), length == 15 {
                guard cursor < table, bytes[cursor] >> 4 == 1, bytes[cursor] & 15 <= 3 else { throw AirDropProtocolError.malformed }
                let width = 1 << Int(bytes[cursor] & 15)
                length = try integer(cursor + 1, width); cursor += 1 + width
            }
            let width: Int
            switch kind {
            case 0: width = 0
            case 1, 2: guard marker & 15 <= 3 else { throw AirDropProtocolError.malformed }; width = 1 << Int(marker & 15)
            case 3: guard marker == 0x33 else { throw AirDropProtocolError.malformed }; width = 8
            case 4, 5: width = length
            case 6: guard length <= AirDropProtocol.maximumPlistBytes / 2 else { throw AirDropProtocolError.tooLarge }; width = length * 2
            case 8: width = Int(marker & 15) + 1
            case 10, 12, 13:
                guard length <= 4096 else { throw AirDropProtocolError.tooLarge }
                let refs = length * (kind == 13 ? 2 : 1)
                guard refs <= (table - cursor) / refWidth else { throw AirDropProtocolError.malformed }
                for index in 0..<refs { try visit(integer(cursor + index * refWidth, refWidth), depth + 1) }
                width = refs * refWidth
            default: throw AirDropProtocolError.malformed
            }
            guard width <= table - cursor else { throw AirDropProtocolError.malformed }
        }
        try visit(top, 0)
    }
}

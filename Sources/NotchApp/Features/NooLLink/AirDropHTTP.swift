import Foundation

struct AirDropHTTPRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

/// A bounded, strict HTTP/1.1 decoder supporting both AirDrop framing variants.
struct AirDropHTTPDecoder {
    struct Head: Sendable {
        let method: String
        let path: String
        let headers: [String: String]
        let length: Int?
        let chunked: Bool
    }
    private(set) var head: Head?
    /// Method and path of a refused request line, kept only for diagnostics.
    private(set) var rejectedRequestLine: String?
    private var buffer = Data()
    private var body = Data()
    private var chunkRemaining: Int?
    private var needsChunkCRLF = false
    private var trailers = false
    private var uploadBoundary: AirDropUploadBoundary?

    mutating func append(_ data: Data) throws {
        guard buffer.count <= AirDropProtocol.maximumArchiveBytes + 32 * 1024 - data.count else { throw AirDropProtocolError.tooLarge }
        buffer.append(data)
    }

    @discardableResult
    mutating func prepareHeader() throws -> Bool {
        guard head == nil else { return false }
        guard let delimiter = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            guard buffer.count <= 16 * 1024 else { throw AirDropProtocolError.tooLarge }
            return false
        }
        guard delimiter.lowerBound <= 16 * 1024,
              let raw = String(data: buffer[..<delimiter.lowerBound], encoding: .utf8) else { throw AirDropProtocolError.malformed }
        let lines = raw.components(separatedBy: "\r\n")
        let words = (lines.first ?? "").split(separator: " ")
        rejectedRequestLine = words.prefix(2).joined(separator: " ").prefix(80).description
        guard words.count == 3, words[2] == "HTTP/1.1", ["POST", "GET", "HEAD"].contains(String(words[0])),
              ["/Discover", "/Ask", "/Upload"].contains(String(words[1])) else { throw AirDropProtocolError.unsupported }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex,
                  line[..<colon].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { throw AirDropProtocolError.malformed }
            let name = line[..<colon].lowercased()
            guard headers[name] == nil else { throw AirDropProtocolError.malformed }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0.value != 9 }) else {
                throw AirDropProtocolError.malformed
            }
            headers[name] = value
        }
        let encoding = headers["transfer-encoding"]?.lowercased()
        guard encoding == nil || encoding == "chunked", encoding == nil || headers["content-length"] == nil else { throw AirDropProtocolError.malformed }
        var length: Int?
        if let rawLength = headers["content-length"] {
            guard !rawLength.isEmpty, rawLength.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(rawLength), value >= 0 else {
                throw AirDropProtocolError.malformed
            }
            length = value
        }
        let maximum = words[1] == "/Upload" ? AirDropProtocol.maximumArchiveBytes : AirDropProtocol.maximumPlistBytes
        guard (length ?? 0) <= maximum else { throw AirDropProtocolError.tooLarge }
        if let expect = headers["expect"], expect.lowercased() != "100-continue" { throw AirDropProtocolError.unsupported }
        head = .init(method: String(words[0]), path: String(words[1]), headers: headers, length: length, chunked: encoding != nil)
        rejectedRequestLine = nil
        if words[1] == "/Upload", encoding != nil {
            let format = try AirDropArchive.UploadFormat(contentType: headers["content-type"])
            if case .gzipCPIO = format { uploadBoundary = .gzip(try AirDropGzipBoundary()) }
            else { uploadBoundary = .dvzip(nil) }
        }
        buffer = Data(buffer[delimiter.upperBound...])
        return true
    }

    mutating func nextRequest(uploadOffer: AirDropOffer? = nil) throws -> AirDropHTTPRequest? {
        guard let head else { return nil }
        if head.path == "/Upload", head.chunked, case .dvzip(nil)? = uploadBoundary {
            guard let uploadOffer else { throw AirDropProtocolError.invalidArchive }
            uploadBoundary = .dvzip(AirDropDVZipDecoder(offered: uploadOffer))
        }
        let maximum = head.path == "/Upload" ? AirDropProtocol.maximumArchiveBytes : AirDropProtocol.maximumPlistBytes
        if !head.chunked {
            let length = head.length ?? 0
            guard buffer.count >= length else { return nil }
            body = Data(buffer.prefix(length)); buffer = Data(buffer.dropFirst(length))
        } else {
            while true {
                if trailers {
                    // AirDrop doesn't need trailers. Refuse them rather than merge hostile headers.
                    guard buffer.count >= 2 else { return nil }
                    guard buffer.starts(with: [13, 10]) else { throw AirDropProtocolError.malformed }
                    buffer = Data(buffer.dropFirst(2)); break
                }
                if needsChunkCRLF {
                    guard buffer.count >= 2 else { return nil }
                    guard buffer.starts(with: [13, 10]) else { throw AirDropProtocolError.malformed }
                    buffer = Data(buffer.dropFirst(2)); needsChunkCRLF = false
                }
                if chunkRemaining == nil {
                    guard let newline = buffer.range(of: Data("\r\n".utf8)) else {
                        guard buffer.count <= 128 else { throw AirDropProtocolError.malformed }; return nil
                    }
                    guard newline.lowerBound <= 128,
                          let raw = String(data: buffer[..<newline.lowerBound], encoding: .ascii),
                          !raw.isEmpty, raw.allSatisfy({ $0.isHexDigit }), let size = Int(raw, radix: 16), size >= 0,
                          size <= maximum - body.count else { throw AirDropProtocolError.tooLarge }
                    buffer = Data(buffer[newline.upperBound...])
                    if size == 0 { trailers = true; continue }
                    chunkRemaining = size
                }
                guard let size = chunkRemaining, buffer.count >= size else { return nil }
                let piece = Data(buffer.prefix(size))
                body.append(piece); buffer = Data(buffer.dropFirst(size))
                chunkRemaining = nil; needsChunkCRLF = true
                // Finder can hold back HTTP's zero chunk until the receiver replies.
                // gzip's end marker completes the bounded archive on an Upload-only connection.
                if var uploadBoundary {
                    let complete = try uploadBoundary.append(piece)
                    self.uploadBoundary = uploadBoundary
                    if complete { break }
                }
            }
        }
        let request = AirDropHTTPRequest(method: head.method, path: head.path, headers: head.headers, body: body)
        self.head = nil; body = Data(); chunkRemaining = nil; needsChunkCRLF = false; trailers = false; uploadBoundary = nil
        return request
    }
}

private enum AirDropUploadBoundary {
    case gzip(AirDropGzipBoundary)
    case dvzip(AirDropDVZipDecoder?)

    mutating func append(_ bytes: Data) throws -> Bool {
        switch self {
        case .gzip(let decoder): return try decoder.append(bytes)
        case .dvzip(let decoder):
            guard let decoder else { throw AirDropProtocolError.invalidArchive }
            return try decoder.append(bytes)
        }
    }
}

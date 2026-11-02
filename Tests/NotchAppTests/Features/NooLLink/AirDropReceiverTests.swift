import Foundation
import XCTest
import Network
import Security
import zlib
@testable import NotchApp

final class AirDropReceiverTests: XCTestCase {
    func testAskRequiresExactSafeFilesAndRejectsDirectories() throws {
        let good = try ask(name: "hello.txt", path: "./hello.txt", size: 3)
        let offer = try AirDropProtocol.offer(good)
        XCTAssertEqual(offer.files.map(\.name), ["hello.txt"])
        XCTAssertEqual(offer.totalBytes, 3)
        XCTAssertThrowsError(try AirDropProtocol.offer(ask(name: "hello.txt", path: "../hello.txt", size: 3)))
        XCTAssertThrowsError(try AirDropProtocol.offer(ask(name: "NUL.txt", path: "./NUL.txt", size: 3)))
        XCTAssertThrowsError(try AirDropProtocol.offer(ask(name: "a\u{202e}txt", path: "./a\u{202e}txt", size: 3)))
        XCTAssertThrowsError(try AirDropProtocol.offer(ask(name: "folder", path: "./folder", size: 0, directory: true)))
    }

    func testPlistRejectsXMLAndExcessiveNestingBeforeFoundation() throws {
        let xml = try PropertyListSerialization.data(fromPropertyList: ["a": "b"], format: .xml, options: 0)
        XCTAssertThrowsError(try AirDropProtocol.plist(xml))
        var value: Any = "leaf"
        for _ in 0..<30 { value = [value] }
        let nested = try PropertyListSerialization.data(fromPropertyList: ["a": value], format: .binary, options: 0)
        XCTAssertThrowsError(try AirDropProtocol.plist(nested))
    }

    func testChunkedRequestsAndKeepAliveBoundaries() throws {
        var decoder = AirDropHTTPDecoder()
        let body = Data("hello".utf8)
        let first = Data("POST /Ask HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n".utf8)
        let second = Data("POST /Discover HTTP/1.1\r\nContent-Length: 0\r\n\r\n".utf8)
        for byte in first + second {
            try decoder.append(Data([byte]))
            try decoder.prepareHeader()
            if let request = try decoder.nextRequest() {
                if request.path == "/Ask" { XCTAssertEqual(request.body, body) }
                else { XCTAssertEqual(request.path, "/Discover"); XCTAssertTrue(request.body.isEmpty) }
            }
        }
        XCTAssertNil(decoder.head)
    }

    func testRejectsAmbiguousHTTPFramingAndOversizedBody() throws {
        for header in [
            "Content-Length: 1\r\nContent-Length: 2",
            "Transfer-Encoding: chunked\r\nContent-Length: 0",
            "Content-Length: -1",
            "Content-Length: 999999999",
            "Transfer-Encoding: gzip, chunked"
        ] {
            var decoder = AirDropHTTPDecoder()
            try decoder.append(Data("POST /Ask HTTP/1.1\r\n\(header)\r\n\r\n".utf8))
            XCTAssertThrowsError(try decoder.prepareHeader(), header)
        }
    }

    func testArchiveMatchesConsentAndRefusesLinksAndUnexpectedMembers() throws {
        let offer = try AirDropProtocol.offer(ask(name: "hello.txt", path: "./hello.txt", size: 3))
        let valid = entry(".", mode: 0o040755, bytes: Data()) + entry("./hello.txt", bytes: Data("abc".utf8)) + entry("TRAILER!!!", mode: 0, bytes: Data())
        let files = try AirDropArchive.files(valid, offered: offer)
        XCTAssertEqual(files.count, 1); XCTAssertEqual(files[0].0, "hello.txt"); XCTAssertEqual(files[0].1, Data("abc".utf8))
        XCTAssertThrowsError(try AirDropArchive.files(entry("./hello.txt", mode: 0o120777, bytes: Data("abc".utf8)) + entry("TRAILER!!!", mode: 0, bytes: Data()), offered: offer))
        XCTAssertThrowsError(try AirDropArchive.files(entry("../hello.txt", bytes: Data("abc".utf8)) + entry("TRAILER!!!", mode: 0, bytes: Data()), offered: offer))
        XCTAssertThrowsError(try AirDropArchive.files(entry("./hello.txt", links: 2, bytes: Data("abc".utf8)) + entry("TRAILER!!!", mode: 0, bytes: Data()), offered: offer))
    }

    func testArchiveAcceptsCpioZeroPaddingTo512ByteBlockButNoTrailingData() throws {
        let offer = try AirDropProtocol.offer(ask(name: "hello.txt", path: "./hello.txt", size: 3))
        let archive = entry("./hello.txt", bytes: Data("abc".utf8)) + entry("TRAILER!!!", mode: 0, bytes: Data())
        let padding = (512 - archive.count % 512) % 512
        let blocked = archive + Data(repeating: 0, count: padding)
        XCTAssertEqual(try AirDropArchive.files(blocked, offered: offer).map(\.0), ["hello.txt"])
        XCTAssertThrowsError(try AirDropArchive.files(blocked + Data([1]), offered: offer))
        XCTAssertThrowsError(try AirDropArchive.files(archive + Data(repeating: 0, count: 512), offered: offer))
    }

    func testGzipUploadCompletesBeforeHTTPZeroChunkAndBoundsExpansion() throws {
        let compressed = try gzip(entry("TRAILER!!!", mode: 0, bytes: Data()))
        var decoder = AirDropHTTPDecoder()
        let header = "POST /Upload HTTP/1.1\r\nContent-Type: application/x-cpio\r\nTransfer-Encoding: chunked\r\n\r\n"
        try decoder.append(Data(header.utf8) + Data(String(compressed.count, radix: 16).utf8) + Data("\r\n".utf8) + compressed)
        try decoder.prepareHeader()
        let request = try XCTUnwrap(decoder.nextRequest())
        XCTAssertEqual(request.body, compressed)
        let bomb = try gzip(Data(repeating: 0, count: AirDropProtocol.maximumArchiveBytes + 1))
        XCTAssertThrowsError(try AirDropArchive.inflate(bomb))
    }

    func testDVZipUploadCompletesAtValidatedCPIOTrailerWithoutHTTPZeroChunk() throws {
        let file = Data("abc".utf8)
        let archive = entry(".", mode: 0o040755, bytes: Data()) +
            entry("./hello.txt", bytes: file) + entry("TRAILER!!!", mode: 0, bytes: Data())
        let offer = try AirDropProtocol.offer(ask(name: "hello.txt", path: "./hello.txt", size: file.count))
        let encoded = try dvzip(archive, stored: true)
        var decoder = AirDropHTTPDecoder()
        let header = Data("POST /Upload HTTP/1.1\r\nContent-Type: application/x-dvzip\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)
        let chunk = Data(String(encoded.count, radix: 16).utf8) + Data("\r\n".utf8) + encoded
        var result: AirDropHTTPRequest?
        for byte in header + chunk {
            try decoder.append(Data([byte]))
            _ = try decoder.prepareHeader()
            if let request = try decoder.nextRequest(uploadOffer: offer) { result = request }
        }
        let request = try XCTUnwrap(result)
        XCTAssertEqual(request.path, "/Upload")
        XCTAssertEqual(try AirDropArchive.files(try AirDropArchive.inflateDVZip(request.body, offered: offer), offered: offer)[0].1, file)
    }

    func testDVZipAcceptsCompressedFramesAndRejectsBadOrTruncatedFrames() throws {
        let file = Data("abc".utf8)
        let archive = entry("./hello.txt", bytes: file) + entry("TRAILER!!!", mode: 0, bytes: Data())
        let offer = try AirDropProtocol.offer(ask(name: "hello.txt", path: "./hello.txt", size: file.count))
        let compressed = try dvzip(archive, stored: false)
        let decoded = try AirDropArchive.inflateDVZip(compressed, offered: offer)
        XCTAssertEqual(try AirDropArchive.files(decoded, offered: offer)[0].1, file)
        XCTAssertThrowsError(try AirDropArchive.inflateDVZip(Data([0, 0, 0, 0]), offered: offer))
        XCTAssertThrowsError(try AirDropArchive.inflateDVZip(Data(compressed.dropLast()), offered: offer))
    }

    func testDVZipScansCpioIncrementallyAcrossMultipleFrames() throws {
        let file = Data(repeating: 0x41, count: 150_000)
        let archive = entry("./hello.txt", bytes: file) + entry("TRAILER!!!", mode: 0, bytes: Data())
        let offer = try AirDropProtocol.offer(ask(name: "hello.txt", path: "./hello.txt", size: file.count))
        let frames = try dvzipFrames(archive, stored: true)
        var decoder = AirDropHTTPDecoder()
        let header = Data("POST /Upload HTTP/1.1\r\nContent-Type: application/x-dvzip\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)
        let chunk = Data(String(frames.count, radix: 16).utf8) + Data("\r\n".utf8) + frames
        var result: AirDropHTTPRequest?
        for byte in header + chunk {
            try decoder.append(Data([byte]))
            _ = try decoder.prepareHeader()
            if let request = try decoder.nextRequest(uploadOffer: offer) { result = request }
        }
        let request = try XCTUnwrap(result)
        let decoded = try AirDropArchive.inflateDVZip(request.body, offered: offer)
        XCTAssertEqual(try AirDropArchive.files(decoded, offered: offer)[0].1, file)
    }

    func testDVZipAllowsSingleLargeStoredOrCompressedFrameWithinArchiveLimit() throws {
        let file = Data(repeating: 0x41, count: 175_000)
        let archive = entry("./hello.txt", bytes: file) + entry("TRAILER!!!", mode: 0, bytes: Data())
        let offer = try AirDropProtocol.offer(ask(name: "hello.txt", path: "./hello.txt", size: file.count))
        for stored in [true, false] {
            let decoded = try AirDropArchive.inflateDVZip(dvzip(archive, stored: stored), offered: offer)
            XCTAssertEqual(try AirDropArchive.files(decoded, offered: offer)[0].1, file)
        }
    }

    func testDVZipStillBoundsTotalExpansionOfLargeSingleFrame() throws {
        let offer = try AirDropProtocol.offer(ask(name: "hello.txt", path: "./hello.txt", size: 3))
        let bomb = try dvzip(Data(repeating: 0, count: AirDropProtocol.maximumArchiveBytes + 1), stored: false)
        XCTAssertThrowsError(try AirDropArchive.inflateDVZip(bomb, offered: offer))
    }

    func testDVZipAcceptsManySmallStoredFramesButCapsFrameCount() throws {
        let acceptedFile = Data(repeating: 0x41, count: 7_800)
        let acceptedArchive = entry("./hello.txt", bytes: acceptedFile) + entry("TRAILER!!!", mode: 0, bytes: Data())
        XCTAssertLessThan(acceptedArchive.count, AirDropDVZipDecoder.maximumFrameCount)
        let acceptedOffer = try AirDropProtocol.offer(ask(name: "hello.txt", path: "./hello.txt", size: acceptedFile.count))
        let acceptedDVZip = try dvzipFrames(acceptedArchive, stored: true, fragmentSize: 1)
        let decoded = try AirDropArchive.inflateDVZip(acceptedDVZip, offered: acceptedOffer)
        XCTAssertEqual(try AirDropArchive.files(decoded, offered: acceptedOffer)[0].1, acceptedFile)

        let oversizedFile = Data(repeating: 0x41, count: 9_000)
        let oversizedArchive = entry("./hello.txt", bytes: oversizedFile) + entry("TRAILER!!!", mode: 0, bytes: Data())
        let oversizedOffer = try AirDropProtocol.offer(ask(name: "hello.txt", path: "./hello.txt", size: oversizedFile.count))
        let excessiveDVZip = try dvzipFrames(oversizedArchive, stored: true, fragmentSize: 1)
        XCTAssertThrowsError(try AirDropArchive.inflateDVZip(excessiveDVZip, offered: oversizedOffer))
    }

    func testLoopbackAskUploadWaitsForDeliveryAndRejectsUnsolicitedUpload() async throws {
        guard ProcessInfo.processInfo.environment["NOOL_LINK_NETWORK_TESTS"] == "1" else { throw XCTSkip("Opt-in loopback transport") }
        guard #available(macOS 15.0, *) else { throw XCTSkip("Memory-only identity") }
        let receiver = AirDropReceiver()
        defer { receiver.stop() }
        let identity = try NooLLinkIdentity.ephemeral()
        let ready = expectation(description: "listener")
        let delivered = expectation(description: "delivery acknowledged")
        let port = AirDropTestPort()
        try receiver.start(identity: identity, deviceName: "Test Windows", consent: { offer in
            offer.files.map(\.name) == ["hello.txt"]
        }, deliver: { paths in
            XCTAssertEqual(paths.count, 1)
            XCTAssertEqual(try Data(contentsOf: paths[0]), Data("abc".utf8))
            try await Task.sleep(for: .milliseconds(50))
            delivered.fulfill()
        }, ready: { value in port.set(value); ready.fulfill() }, advertise: false)
        await fulfillment(of: [ready], timeout: 5)
        let value = try XCTUnwrap(port.get())
        let ask = try ask(name: "hello.txt", path: "./hello.txt", size: 3)
        // Legacy Ask permits an absent TransferID header; keep the same TLS connection.
        var askValue = try AirDropProtocol.plist(ask)
        askValue.removeValue(forKey: "TransferID")
        let legacy = try PropertyListSerialization.data(fromPropertyList: askValue, format: .binary, options: 0)
        let archive = try gzip(entry("./hello.txt", bytes: Data("abc".utf8)) + entry("TRAILER!!!", mode: 0, bytes: Data()))
        let upload = Data("POST /Upload HTTP/1.1\r\nContent-Type: application/x-cpio\r\nTransfer-Encoding: chunked\r\n\r\n\(String(archive.count, radix: 16))\r\n".utf8) + archive
        let combined = Data("POST /Ask HTTP/1.1\r\nContent-Length: \(legacy.count)\r\n\r\n".utf8) + legacy + upload
        let response = try await exchange(combined, port: value)
        XCTAssertEqual(response.components(separatedBy: "HTTP/1.1 200 OK").count - 1, 2)
        await fulfillment(of: [delivered], timeout: 2)
        let refused = try await exchange(upload, port: value)
        XCTAssertTrue(refused.hasPrefix("HTTP/1.1 403"))
    }

    func testUploadSendsSingle100ContinueAcrossFragmentedHeaderAndBody() async throws {
        guard ProcessInfo.processInfo.environment["NOOL_LINK_NETWORK_TESTS"] == "1" else { throw XCTSkip("Opt-in loopback transport") }
        guard #available(macOS 15.0, *) else { throw XCTSkip("Memory-only identity") }
        let receiver = AirDropReceiver()
        defer { receiver.stop() }
        let ready = expectation(description: "listener")
        let delivered = expectation(description: "file delivered")
        let port = AirDropTestPort()
        try receiver.start(identity: NooLLinkIdentity.ephemeral(), deviceName: "Test Windows", consent: { _ in true }, deliver: { paths in
            XCTAssertEqual(try Data(contentsOf: paths[0]), Data("abc".utf8))
            delivered.fulfill()
        }, ready: { value in port.set(value); ready.fulfill() }, advertise: false)
        await fulfillment(of: [ready], timeout: 5)
        var askValue = try AirDropProtocol.plist(ask(name: "hello.txt", path: "./hello.txt", size: 3))
        askValue.removeValue(forKey: "TransferID")
        let legacy = try PropertyListSerialization.data(fromPropertyList: askValue, format: .binary, options: 0)
        let askRequest = Data("POST /Ask HTTP/1.1\r\nContent-Length: \(legacy.count)\r\n\r\n".utf8) + legacy
        let archive = try gzip(entry("./hello.txt", bytes: Data("abc".utf8)) + entry("TRAILER!!!", mode: 0, bytes: Data()))
        let uploadHeader = Data("POST /Upload HTTP/1.1\r\nContent-Type: application/x-cpio\r\nExpect: 100-continue\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)
        let uploadBody = Data("\(String(archive.count, radix: 16))\r\n".utf8) + archive
        let responses = try await exchangeFragmentedExpect(askRequest, uploadHeader: uploadHeader, uploadBody: uploadBody, port: try XCTUnwrap(port.get()))
        XCTAssertEqual(responses.components(separatedBy: "HTTP/1.1 100 Continue").count - 1, 1)
        XCTAssertEqual(responses.components(separatedBy: "HTTP/1.1 200 OK").count - 1, 2)
        await fulfillment(of: [delivered], timeout: 2)
    }

    private func exchange(_ request: Data, port: UInt16) async throws -> String {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in complete(true) }, .global())
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: NWParameters(tls: tls))
        defer { connection.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            let exchange = AirDropTestExchange(connection: connection, continuation: continuation)
            exchange.start(request)
        }
    }

    private func exchangeFragmentedExpect(_ ask: Data, uploadHeader: Data, uploadBody: Data, port: UInt16) async throws -> String {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in complete(true) }, .global())
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: NWParameters(tls: tls))
        defer { connection.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            let exchange = AirDropContinueTestFlow(connection: connection, continuation: continuation,
                uploadHeader: uploadHeader, uploadBody: uploadBody)
            exchange.start(ask)
        }
    }

    private func gzip(_ data: Data) throws -> Data {
        var stream = z_stream()
        guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 31, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw AirDropProtocolError.invalidArchive
        }
        defer { deflateEnd(&stream) }
        return try data.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: UInt8.self).baseAddress)
            stream.avail_in = UInt32(data.count)
            var result = Data(), output = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let status = output.withUnsafeMutableBufferPointer { buffer in
                    stream.next_out = buffer.baseAddress; stream.avail_out = UInt32(buffer.count)
                    return deflate(&stream, Z_FINISH)
                }
                result.append(contentsOf: output.prefix(output.count - Int(stream.avail_out)))
                if status == Z_STREAM_END { return result }
                guard status == Z_OK else { throw AirDropProtocolError.invalidArchive }
            }
        }
    }

    private func dvzip(_ data: Data, stored: Bool) throws -> Data {
        let frame: Data
        if stored { frame = data }
        else {
            var stream = z_stream()
            guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15, 8, Z_DEFAULT_STRATEGY,
                                ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                throw AirDropProtocolError.invalidArchive
            }
            defer { deflateEnd(&stream) }
            frame = try data.withUnsafeBytes { input in
                stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: UInt8.self).baseAddress)
                stream.avail_in = UInt32(data.count)
                var result = Data(), output = [UInt8](repeating: 0, count: 64 * 1024)
                while true {
                    let status = output.withUnsafeMutableBufferPointer { buffer in
                        stream.next_out = buffer.baseAddress; stream.avail_out = UInt32(buffer.count)
                        return deflate(&stream, Z_FINISH)
                    }
                    result.append(contentsOf: output.prefix(output.count - Int(stream.avail_out)))
                    if status == Z_STREAM_END { return result }
                    guard status == Z_OK else { throw AirDropProtocolError.invalidArchive }
                }
            }
        }
        let size = UInt32(frame.count) | (stored ? 0x8000_0000 : 0)
        var output = Data([UInt8((size >> 24) & 0xff), UInt8((size >> 16) & 0xff), UInt8((size >> 8) & 0xff), UInt8(size & 0xff)])
        output.append(frame)
        return output
    }

    private func dvzipFrames(_ data: Data, stored: Bool, fragmentSize: Int = 65_536) throws -> Data {
        var result = Data()
        var offset = 0
        while offset < data.count {
            let end = min(offset + fragmentSize, data.count)
            result.append(try dvzip(Data(data[offset..<end]), stored: stored))
            offset = end
        }
        return result
    }

    private func ask(name: String, path: String, size: Int, directory: Bool = false) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: [
            "SenderComputerName": "My Mac", "Files": [["FileName": name, "FileBomPath": path, "FileSize": size, "FileIsDirectory": directory]],
            "TransferID": ["id": UUID().uuidString]
        ], format: .binary, options: 0)
    }

    private func entry(_ name: String, mode: Int = 0o100644, links: Int = 1, bytes: Data) -> Data {
        func octal(_ value: Int, _ width: Int) -> String { String(repeating: "0", count: max(0, width - String(value, radix: 8).count)) + String(value, radix: 8) }
        let encoded = Data(name.utf8) + Data([0])
        var header = "070707"
        for value in [0, 0, mode, 0, 0, links, 0] { header += octal(value, 6) }
        header += octal(0, 11) + octal(encoded.count, 6) + octal(bytes.count, 11)
        return Data(header.utf8) + encoded + bytes
    }
}

private final class AirDropTestPort: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt16?
    func set(_ value: UInt16?) { lock.lock(); defer { lock.unlock() }; self.value = value }
    func get() -> UInt16? { lock.lock(); defer { lock.unlock() }; return value }
}

private final class AirDropTestExchange: @unchecked Sendable {
    let connection: NWConnection
    var continuation: CheckedContinuation<String, any Error>?
    var data = Data()
    let queue = DispatchQueue(label: "nool.airdrop.test")
    init(connection: NWConnection, continuation: CheckedContinuation<String, any Error>) { self.connection = connection; self.continuation = continuation }
    func start(_ request: Data) {
        connection.start(queue: queue)
        connection.send(content: request, completion: .contentProcessed { [self] error in
            if let error { finish(.failure(error)) } else { receive() }
        })
        queue.asyncAfter(deadline: .now() + 10) { [self] in finish(.failure(AirDropProtocolError.malformed)) }
    }
    func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] part, _, complete, error in
            if let part { data.append(part) }
            if let error { finish(.failure(error)) }
            else if complete { finish(.success(String(decoding: data, as: UTF8.self))) }
            else { receive() }
        }
    }
    func finish(_ result: Result<String, any Error>) {
        guard let continuation else { return }
        self.continuation = nil; connection.cancel(); continuation.resume(with: result)
    }
}

private final class AirDropContinueTestFlow: @unchecked Sendable {
    private enum Stage { case askResponse, continueResponse, finalResponse }
    private let connection: NWConnection
    private let continuation: CheckedContinuation<String, any Error>
    private let uploadHeader: Data
    private let uploadBody: Data
    private let queue = DispatchQueue(label: "nool.airdrop.expect.test")
    private var stage = Stage.askResponse
    private var received = Data()
    private var responses = ""
    private var finished = false

    init(connection: NWConnection, continuation: CheckedContinuation<String, any Error>, uploadHeader: Data, uploadBody: Data) {
        self.connection = connection; self.continuation = continuation
        self.uploadHeader = uploadHeader; self.uploadBody = uploadBody
    }

    func start(_ ask: Data) {
        connection.start(queue: queue)
        send([ask]) { self.receive() }
        queue.asyncAfter(deadline: .now() + 10) { [self] in finish(.failure(AirDropProtocolError.malformed)) }
    }

    private func receive() {
        guard !finished else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, complete, error in
            if let error { finish(.failure(error)); return }
            if let data { received.append(data) }
            do {
                guard let (status, response) = try takeResponse() else {
                    if complete { finish(.failure(AirDropProtocolError.malformed)) }
                    else { receive() }
                    return
                }
                responses += response
                switch stage {
                case .askResponse:
                    guard status == 200 else { finish(.failure(AirDropProtocolError.unsupported)); return }
                    stage = .continueResponse
                    let split = uploadHeader.count / 2
                    send([Data(uploadHeader.prefix(split)), Data(uploadHeader.dropFirst(split))]) { self.receive() }
                case .continueResponse:
                    guard status == 100 else { finish(.failure(AirDropProtocolError.unsupported)); return }
                    stage = .finalResponse
                    let split = uploadBody.count / 2
                    send([Data(uploadBody.prefix(split)), Data(uploadBody.dropFirst(split))]) { self.receive() }
                case .finalResponse:
                    guard status == 200 else { finish(.failure(AirDropProtocolError.unsupported)); return }
                    finish(.success(responses))
                }
            } catch { finish(.failure(error)) }
        }
    }

    private func takeResponse() throws -> (Int, String)? {
        guard let delimiter = received.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let headers = String(data: received[..<delimiter.lowerBound], encoding: .utf8),
              let statusText = headers.components(separatedBy: "\r\n").first?.split(separator: " ").dropFirst().first,
              let status = Int(statusText) else { throw AirDropProtocolError.malformed }
        let length = headers.components(separatedBy: "\r\n").dropFirst().compactMap { line -> Int? in
            let pieces = line.split(separator: ":", maxSplits: 1)
            guard pieces.count == 2, pieces[0].lowercased() == "content-length" else { return nil }
            return Int(pieces[1].trimmingCharacters(in: .whitespaces))
        }.first ?? 0
        let bodyStart = delimiter.upperBound
        guard received.count - bodyStart >= length else { return nil }
        let end = bodyStart + length
        let response = String(decoding: received[..<end], as: UTF8.self)
        received = Data(received[end...])
        return (status, response)
    }

    private func send(_ messages: [Data], index: Int = 0, completion: @escaping @Sendable () -> Void) {
        guard index < messages.count else { completion(); return }
        connection.send(content: messages[index], completion: .contentProcessed { [self] error in
            if let error { finish(.failure(error)) }
            else { send(messages, index: index + 1, completion: completion) }
        })
    }

    private func finish(_ result: Result<String, any Error>) {
        guard !finished else { return }
        finished = true; connection.cancel(); continuation.resume(with: result)
    }
}


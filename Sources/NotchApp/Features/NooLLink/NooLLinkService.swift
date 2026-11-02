import AppKit
import Combine
import Darwin
import Foundation
import ImageIO
import SystemConfiguration
import UniformTypeIdentifiers

@MainActor
final class NooLLinkService: ObservableObject {
    static let shared = NooLLinkService()
    @Published private(set) var isEnabled: Bool
    @Published private(set) var connectionState = "Выключено"
    @Published private(set) var pairedDeviceName: String?
    @Published private(set) var invitation: String?
    @Published private(set) var lastError: String?
    @Published private(set) var fileTransferState: String?
    @Published var clipboardSyncEnabled: Bool { didSet {
        defaults.set(clipboardSyncEnabled, forKey: "noolLink.clipboard")
        lastChangeCount = pasteboard.changeCount; latest = nil
    } }
    @Published var fileTransferEnabled: Bool { didSet {
        defaults.set(fileTransferEnabled, forKey: "noolLink.files")
        lastChangeCount = pasteboard.changeCount
        if !fileTransferEnabled, latest?.kind == "files" { latest = nil }
        if !fileTransferEnabled { outgoingTransfers.cancel(NooLLinkTransferError.disabled) }
    } }

    private struct Pair: Codable { let deviceID: String; let deviceName: String; let token: String }
    private struct PairRequest: Codable { let deviceID: String; let deviceName: String; let token: String }
    private struct PairReply: Codable { let deviceID: String; let deviceName: String; let token: String }
    private let defaults: UserDefaults
    private let pasteboard: NSPasteboard
    private let deviceID: String
    private var pair: Pair?
    private var server: NooLLinkHTTPServer?
    private var identity: NooLLinkIdentity?
    private var port: UInt16?
    private var pairingToken: String?
    private var pairingDeadline: Date?
    private var timer: Timer?
    private var lastChangeCount: Int
    private var latest: NooLLinkEnvelope?
    private var generation = 0
    private var captureInFlight = false
    private var recentIDs: [String] = []
    private var lastContact: Date?
    private let outgoingTransfers = NooLLinkTransferQueue()
    private var completedTransfers: [String] = []
    private var incomingTransfers = Set<String>()
    private var preparingTransfer = false

    var canReceiveFileTransfers: Bool {
        isEnabled && fileTransferEnabled && pair != nil &&
            lastContact.map { Date().timeIntervalSince($0) <= 5 } == true
    }

    var canSendFiles: Bool { canReceiveFileTransfers }
    var airDropIdentity: NooLLinkIdentity? { identity }

    /// Sends files explicitly and returns only after Windows confirms saving.
    /// This path never reads or writes either computer's clipboard.
    func sendFiles(_ urls: [URL]) async throws {
        guard fileTransferEnabled else { throw NooLLinkTransferError.disabled }
        guard canReceiveFileTransfers else { throw NooLLinkTransferError.unavailable }
        guard !preparingTransfer, outgoingTransfers.pending == nil else { throw NooLLinkTransferError.busy }
        let epoch = generation
        preparingTransfer = true
        defer { preparingTransfer = false }
        fileTransferState = "Подготовка файлов…"
        do {
            let origin = deviceID
            let envelope = try await Task.detached {
                let files = try Self.readFiles(urls)
                return try NooLLinkEnvelope(id: UUID().uuidString, originDeviceID: origin,
                    createdAt: ISO8601DateFormatter().string(from: Date()), kind: "files", files: files).validated()
            }.value
            try Task.checkCancellation()
            guard generation == epoch, canReceiveFileTransfers else { throw NooLLinkTransferError.unavailable }
            fileTransferState = "Отправка файлов…"
            try await outgoingTransfers.deliver(envelope)
            guard generation == epoch, canReceiveFileTransfers else { throw NooLLinkTransferError.cancelled }
            fileTransferState = "Файлы сохранены на Windows"
            lastError = nil
        } catch {
            fileTransferState = nil
            lastError = error.localizedDescription
            throw error
        }
    }

    init(defaults: UserDefaults = .standard, pasteboard: NSPasteboard = .general) {
        self.defaults = defaults; self.pasteboard = pasteboard
        isEnabled = defaults.bool(forKey: "noolLink.enabled")
        clipboardSyncEnabled = defaults.object(forKey: "noolLink.clipboard") as? Bool ?? true
        fileTransferEnabled = defaults.object(forKey: "noolLink.files") as? Bool ?? false
        deviceID = defaults.string(forKey: "noolLink.deviceID") ?? UUID().uuidString
        defaults.set(deviceID, forKey: "noolLink.deviceID")
        lastChangeCount = pasteboard.changeCount
        if isEnabled { start() }
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: "noolLink.enabled")
        if enabled { start() } else { stop() }
    }

    func stop() {
        generation += 1
        outgoingTransfers.cancel(NooLLinkTransferError.unavailable)
        server?.stop(); server = nil
        timer?.invalidate(); timer = nil
        port = nil; invitation = nil; pairingToken = nil; pairingDeadline = nil
        latest = nil; recentIDs = []; lastContact = nil
        completedTransfers = []; incomingTransfers = []; fileTransferState = nil
        connectionState = "Выключено"
    }

    func createInvitation() {
        guard isEnabled, let port, let identity else {
            lastError = "Включите NooL Link и дождитесь готовности соединения."; return
        }
        guard let host = Self.localIPv4() else { lastError = NooLLinkError.unavailable.localizedDescription; return }
        do {
            let token = try NooLLinkKeychain.randomToken()
            pairingToken = token; pairingDeadline = Date().addingTimeInterval(300)
            var url = URLComponents()
            url.scheme = "nool-link"; url.host = "pair"
            url.queryItems = [URLQueryItem(name: "host", value: host), URLQueryItem(name: "port", value: String(port)),
                              URLQueryItem(name: "token", value: token), URLQueryItem(name: "fingerprint", value: identity.fingerprint)]
            if let hostname = SCDynamicStoreCopyLocalHostName(nil) as String? {
                url.queryItems?.append(URLQueryItem(name: "hostname", value: hostname + ".local"))
            }
            invitation = url.string
            lastError = nil
        } catch { lastError = error.localizedDescription }
    }

    func unpair() {
        do {
            try NooLLinkKeychain.delete("paired-device")
            generation += 1
            outgoingTransfers.cancel(NooLLinkTransferError.unavailable)
            pair = nil; pairedDeviceName = nil; latest = nil; recentIDs = []; lastContact = nil
            invitation = nil; pairingToken = nil; pairingDeadline = nil
            completedTransfers = []; incomingTransfers = []; fileTransferState = nil
            connectionState = isEnabled ? "Ожидает сопряжения" : "Выключено"
        } catch { lastError = error.localizedDescription }
    }

    private func start() {
        generation += 1
        let epoch = generation
        lastError = nil; connectionState = "Подготовка защищённого соединения…"
        lastChangeCount = pasteboard.changeCount
        Task { [self] in
            do {
                let material = try await Task.detached { try NooLLinkIdentity.loadOrCreate() }.value
                guard isEnabled, generation == epoch else { return }
                if let saved = try NooLLinkKeychain.load("paired-device") { pair = try JSONDecoder().decode(Pair.self, from: saved) }
                pairedDeviceName = pair?.deviceName
                identity = material
                let transport = NooLLinkHTTPServer()
                server = transport
                try transport.start(identity: material, authorize: { [weak self] request in
                    await self?.authorize(request) ?? false
                }, handle: { [weak self] request in
                    await self?.handle(request) ?? .init(status: 503)
                }, ready: { [weak self] port in
                    Task { @MainActor in
                        guard let self, self.generation == epoch else { return }
                        self.port = port
                        if port == nil { self.lastError = "Не удалось открыть локальный порт 52961. Проверьте, не запущен ли второй экземпляр NooL, и выключите и включите NooL Link." }
                        self.connectionState = port == nil ? "Ошибка соединения" : self.pair == nil ? "Ожидает сопряжения" : "Ожидает Windows"
                    }
                })
                timer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.tick() }
                }
            } catch {
                guard generation == epoch else { return }
                lastError = error.localizedDescription; connectionState = "Ошибка соединения"
                server?.stop(); server = nil
            }
        }
    }

    private func authorize(_ request: NooLLinkHTTPRequest) -> Bool {
        guard isEnabled else { return false }
        if request.method == "POST", request.target == "/v1/pair" {
            return pairingToken != nil && (pairingDeadline ?? .distantPast) > Date()
        }
        guard let pair, let value = request.headers["authorization"] else { return false }
        return NooLLinkKeychain.equal(value, "Bearer " + pair.token)
    }

    private func handle(_ request: NooLLinkHTTPRequest) async -> NooLLinkHTTPResponse {
        guard authorize(request) else { return .init(status: 401) }
        if request.target == "/v1/pair", request.method == "POST" {
            guard let incoming = try? JSONDecoder().decode(PairRequest.self, from: request.body),
                  let token = pairingToken, NooLLinkKeychain.equal(incoming.token, token),
                  UUID(uuidString: incoming.deviceID) != nil,
                  !incoming.deviceName.isEmpty, incoming.deviceName.utf8.count <= 128 else { return .init(status: 401) }
            do {
                let paired = Pair(deviceID: incoming.deviceID, deviceName: incoming.deviceName,
                                  token: try NooLLinkKeychain.randomToken())
                try NooLLinkKeychain.save(JSONEncoder().encode(paired), account: "paired-device")
                generation += 1
                outgoingTransfers.cancel(NooLLinkTransferError.unavailable)
                pair = paired; pairedDeviceName = paired.deviceName
                pairingToken = nil; invitation = nil; pairingDeadline = nil
                latest = nil; recentIDs = []; lastChangeCount = pasteboard.changeCount
                completedTransfers = []; incomingTransfers = []; fileTransferState = nil
                lastContact = Date(); connectionState = "Подключено"
                let reply = PairReply(deviceID: deviceID, deviceName: Host.current().localizedName ?? "Mac", token: paired.token)
                return .init(status: 200, body: try JSONEncoder().encode(reply))
            } catch { lastError = error.localizedDescription; return .init(status: 503) }
        }
        lastContact = Date()
        connectionState = "Подключено"
        if request.method == "GET", request.target == "/v1/transfers" {
            guard fileTransferEnabled, let envelope = outgoingTransfers.pending else { return .init(status: 204) }
            let epoch = generation
            let data = await Task.detached { try? JSONEncoder().encode(envelope) }.value
            guard generation == epoch, authorize(request), fileTransferEnabled, let data else { return .init(status: 401) }
            return .init(status: 200, body: data)
        }
        if request.method == "POST", request.target == "/v1/transfers/ack" {
            guard request.body.count <= 1024,
                  let acknowledgement = try? JSONDecoder().decode(NooLLinkTransferAcknowledgement.self, from: request.body),
                  acknowledgement.isValid else { return .init(status: 400) }
            // An already processed acknowledgement is harmless: the Windows
            // receiver may retry after losing the successful HTTP response.
            _ = outgoingTransfers.acknowledge(acknowledgement)
            return .init(status: 204)
        }
        if request.method == "POST", request.target == "/v1/transfers" {
            return await receiveFileTransfer(request)
        }
        if request.method == "GET", request.target.hasPrefix("/v1/clipboard?") || request.target == "/v1/clipboard" {
            guard let latest, let date = NooLLinkEnvelope.date(latest.createdAt), Date().timeIntervalSince(date) <= 300,
                  clipboardSyncEnabled || (fileTransferEnabled && latest.kind == "files") else { return .init(status: 204) }
            let after = URLComponents(string: "https://local" + request.target)?.queryItems?.first(where: { $0.name == "after" })?.value
            if after == latest.id { return .init(status: 204) }
            let epoch = generation
            let data = await Task.detached { try? JSONEncoder().encode(latest) }.value
            guard generation == epoch, authorize(request), let data else { return .init(status: 401) }
            return .init(status: 200, body: data)
        }
        if request.method == "POST", request.target == "/v1/clipboard" {
            let epoch = generation
            let pairedID = pair?.deviceID
            do {
                let envelope = try await Task.detached {
                    try JSONDecoder().decode(NooLLinkEnvelope.self, from: request.body).validated()
                }.value
                guard epoch == generation, isEnabled, pair?.deviceID == pairedID,
                      envelope.originDeviceID == pairedID else { return .init(status: 401) }
                guard !recentIDs.contains(envelope.id) else { return .init(status: 204) }
                guard envelope.kind == "files" ? fileTransferEnabled : clipboardSyncEnabled else { return .init(status: 409) }
                latest = nil
                try await apply(envelope, epoch: epoch)
                recentIDs.append(envelope.id)
                if recentIDs.count > 64 { recentIDs.removeFirst() }
                return .init(status: 204)
            } catch { lastError = error.localizedDescription; return .init(status: 400) }
        }
        return .init(status: 400)
    }

    private func receiveFileTransfer(_ request: NooLLinkHTTPRequest) async -> NooLLinkHTTPResponse {
        guard fileTransferEnabled else { return .init(status: 409) }
        let epoch = generation
        let pairedID = pair?.deviceID
        do {
            let envelope = try await Task.detached {
                try JSONDecoder().decode(NooLLinkEnvelope.self, from: request.body).validated()
            }.value
            guard generation == epoch, authorize(request), envelope.originDeviceID == pairedID else { return .init(status: 401) }
            guard envelope.kind == "files", let files = envelope.files else { return .init(status: 400) }
            if completedTransfers.contains(envelope.id) { return .init(status: 204) }
            guard incomingTransfers.isEmpty else { return .init(status: 409) }
            incomingTransfers.insert(envelope.id)
            defer { incomingTransfers.remove(envelope.id) }
            let urls = try await Task.detached { try Self.saveToDownloads(files) }.value
            guard generation == epoch, authorize(request), fileTransferEnabled else {
                await Task.detached { for url in urls { try? FileManager.default.removeItem(at: url) } }.value
                return .init(status: 401)
            }
            completedTransfers.append(envelope.id)
            if completedTransfers.count > 64 { completedTransfers.removeFirst() }
            fileTransferState = urls.count == 1 ? "Получен файл «\(urls[0].lastPathComponent)»" : "Получено файлов: \(urls.count)"
            lastError = nil
            // Like AirDrop: the Dock's Downloads stack bounces for each received file.
            for url in urls {
                DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: url.path)
            }
            return .init(status: 204)
        } catch {
            if generation == epoch { lastError = error.localizedDescription }
            return .init(status: 400)
        }
    }

    private func tick() {
        if let deadline = pairingDeadline, deadline < Date() { pairingToken = nil; invitation = nil; pairingDeadline = nil }
        if let lastContact, Date().timeIntervalSince(lastContact) > 5 { connectionState = "Ожидает Windows" }
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount, !captureInFlight else { return }
        lastChangeCount = changeCount
        guard pair != nil, let lastContact, Date().timeIntervalSince(lastContact) <= 5 else { return }
        let types = pasteboard.types?.map { $0.rawValue.lowercased() } ?? []
        guard !types.contains(where: Self.sensitiveType) else { return }
        let id = UUID().uuidString
        let date = ISO8601DateFormatter().string(from: Date())
        let epoch = generation
        if types.contains(NSPasteboard.PasteboardType.fileURL.rawValue) {
            guard fileTransferEnabled else { return }
            let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            captureInFlight = true
            Task {
                defer { captureInFlight = false }
                do {
                    let origin = deviceID
                    let envelope = try await Task.detached {
                        let files = try Self.readFiles(urls)
                        return try NooLLinkEnvelope(id: id, originDeviceID: origin, createdAt: date, kind: "files", files: files).validated()
                    }.value
                    guard generation == epoch, isEnabled, fileTransferEnabled, pasteboard.changeCount == changeCount else { return }
                    latest = envelope
                    lastError = nil
                } catch { lastError = error.localizedDescription }
            }
        } else if clipboardSyncEnabled {
            if let text = pasteboard.string(forType: .string), !text.isEmpty,
               !text.hasPrefix("nool-link://pair"), text.utf8.count <= 1024 * 1024 {
                guard pasteboard.changeCount == changeCount else { return }
                latest = NooLLinkEnvelope(id: id, originDeviceID: deviceID, createdAt: date, kind: "text", text: text)
            } else if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff), data.count <= 10 * 1024 * 1024 {
                captureInFlight = true
                Task {
                    defer { captureInFlight = false }
                    let png = await Task.detached { Self.normalizedPNG(data) }.value
                    guard generation == epoch, isEnabled, clipboardSyncEnabled, pasteboard.changeCount == changeCount,
                          let png else { return }
                    latest = NooLLinkEnvelope(id: id, originDeviceID: deviceID, createdAt: date, kind: "image", imageBase64: png.base64EncodedString())
                }
            }
        }
    }

    private func apply(_ envelope: NooLLinkEnvelope, epoch: Int) async throws {
        let baseline = pasteboard.changeCount
        var urls: [URL] = []
        if envelope.kind == "files", let files = envelope.files {
            urls = try await Task.detached { try Self.writeFiles(files) }.value
        }
        var image: Data?
        if envelope.kind == "image" {
            guard let encoded = envelope.imageBase64, let bytes = Data(base64Encoded: encoded) else { throw NooLLinkError.invalidPayload }
            image = await Task.detached { Self.normalizedPNG(bytes) }.value
            guard image != nil else { throw NooLLinkError.invalidPayload }
        }
        guard generation == epoch, isEnabled,
              envelope.kind == "files" ? fileTransferEnabled : clipboardSyncEnabled else {
            if let directory = urls.first?.deletingLastPathComponent() {
                await Task.detached { try? FileManager.default.removeItem(at: directory) }.value
            }
            throw NooLLinkError.invalidPayload
        }
        // A new local copy wins over an older, slower network file transfer.
        guard pasteboard.changeCount == baseline else {
            if let directory = urls.first?.deletingLastPathComponent() {
                await Task.detached { try? FileManager.default.removeItem(at: directory) }.value
            }
            return
        }
        pasteboard.clearContents()
        switch envelope.kind {
        case "text": pasteboard.setString(envelope.text ?? "", forType: .string)
        case "image": pasteboard.setData(image, forType: .png)
        case "files": pasteboard.writeObjects(urls as [NSURL])
        default: throw NooLLinkError.invalidPayload
        }
        lastChangeCount = pasteboard.changeCount
        // Our monitors and local history ignore automatically imported clipboard writes.
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"))
        lastChangeCount = pasteboard.changeCount
    }

    nonisolated private static func sensitiveType(_ type: String) -> Bool {
        ["concealed", "transient", "autogenerated", "password", "1password", "lastpass", "bitwarden", "keepass"].contains(where: type.contains)
    }

    nonisolated private static func normalizedPNG(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.int64Value > 0, height.int64Value > 0,
              width.int64Value <= 40_000_000 / height.int64Value,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), output.length <= 10 * 1024 * 1024 else { return nil }
        return output as Data
    }

    nonisolated private static func readFiles(_ urls: [URL]) throws -> [NooLLinkFile] {
        guard !urls.isEmpty, urls.count <= 64 else { throw NooLLinkError.invalidFiles }
        var total = 0
        return try urls.map { url in
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  NooLLinkEnvelope.safeFilename(url.lastPathComponent), let size = values.fileSize,
                  size >= 0, size <= NooLLinkEnvelope.maximumFilesBytes - total else { throw NooLLinkError.invalidFiles }
            // Read one byte beyond the remaining cap, so concurrently growing files remain bounded.
            let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard descriptor >= 0 else { throw NooLLinkError.invalidFiles }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw NooLLinkError.invalidFiles }
            let data = try handle.read(upToCount: NooLLinkEnvelope.maximumFilesBytes - total + 1) ?? Data()
            total += data.count
            guard total <= NooLLinkEnvelope.maximumFilesBytes else { throw NooLLinkError.invalidFiles }
            return NooLLinkFile(name: url.lastPathComponent, dataBase64: data.base64EncodedString())
        }
    }

    nonisolated private static func writeFiles(_ files: [NooLLinkFile]) throws -> [URL] {
        // Clipboard files only need to outlive the paste, so they stay out of Downloads.
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let folder = caches.appendingPathComponent("NooL Link/Clipboard", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            return try files.map { file in
                guard NooLLinkEnvelope.safeFilename(file.name), let data = Data(base64Encoded: file.dataBase64) else { throw NooLLinkError.invalidPayload }
                let url = folder.appendingPathComponent(file.name)
                try data.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                return url
            }
        } catch { try? FileManager.default.removeItem(at: folder); throw error }
    }

    /// Explicit transfers land directly in Downloads, renamed Finder-style on conflict.
    nonisolated private static func saveToDownloads(_ files: [NooLLinkFile]) throws -> [URL] {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        var saved: [URL] = []
        do {
            for file in files {
                guard NooLLinkEnvelope.safeFilename(file.name), let data = Data(base64Encoded: file.dataBase64) else { throw NooLLinkError.invalidPayload }
                saved.append(try writeUnique(data, named: file.name, in: downloads))
            }
            return saved
        } catch {
            for url in saved { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }

    nonisolated static func writeUnique(_ data: Data, named name: String, in directory: URL) throws -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        for index in 1...999 {
            let candidate = index == 1 ? name : ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            let url = directory.appendingPathComponent(candidate, isDirectory: false)
            do {
                try data.write(to: url, options: .withoutOverwriting)
                return url
            } catch CocoaError.fileWriteFileExists {
                continue
            }
        }
        throw NooLLinkError.invalidFiles
    }

    nonisolated private static func localIPv4() -> String? {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0 else { return nil }
        defer { freeifaddrs(addresses) }
        var current = addresses
        while let entry = current {
            defer { current = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  String(cString: entry.pointee.ifa_name).hasPrefix("en"),
                  entry.pointee.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
        }
        return nil
    }
}

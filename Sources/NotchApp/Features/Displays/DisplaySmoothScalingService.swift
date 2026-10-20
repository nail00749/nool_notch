import CoreGraphics
import ColorSync
import CryptoKit
import Darwin
import Foundation

struct DisplaySmoothScalingState: Equatable, Sendable {
    let isEnabled: Bool
    let canModify: Bool
    let needsReconnect: Bool
    let detail: String?
}

protocol DisplaySmoothScalingServing: Sendable {
    func read(_ target: DisplayHardwareTarget) async throws -> DisplaySmoothScalingState?
    func setEnabled(_ enabled: Bool, for target: DisplayHardwareTarget) async throws -> DisplaySmoothScalingState
}

enum DisplaySmoothScalingError: LocalizedError, Equatable {
    case unavailable, disconnected, foreignManaged, conflict, invalidJournal, authorization, installerFailed, busy
    var errorDescription: String? {
        switch self {
        case .unavailable: "Плавное масштабирование недоступно для этого дисплея."
        case .disconnected: "Дисплей отключён или изменился."
        case .foreignManaged: "Масштабирование настроено другим приложением. NooL не будет изменять его файл."
        case .conflict: "Файл настроек дисплея изменился. NooL сохранил его без изменений."
        case .invalidJournal: "Журнал масштабирования повреждён. NooL не будет изменять системные настройки."
        case .authorization: "Установка не подтверждена администратором."
        case .installerFailed: "Не удалось безопасно изменить настройки масштабирования."
        case .busy: "Дождитесь завершения текущего изменения масштабирования."
        }
    }
}

struct DisplaySmoothScalingSize: Codable, Hashable, Sendable {
    let width: Int
    let height: Int
}

struct DisplaySmoothScalingDisplay: Sendable, Equatable {
    let target: DisplayHardwareTarget
    let vendor: UInt32
    let product: UInt32
    let nativeSize: DisplaySmoothScalingSize
    let availableHiDPI: Set<DisplaySmoothScalingSize>
}

struct DisplaySmoothScalingInstallRequest: Sendable {
    enum Operation: String, Sendable { case install, remove }
    let operation: Operation
    let display: DisplaySmoothScalingDisplay
    let callerUID: UInt32
    let owner: UUID
    let expectedHash: String?
    let payload: Data
}

protocol DisplaySmoothScalingInstalling: Sendable {
    func apply(_ request: DisplaySmoothScalingInstallRequest) async throws
}

struct DisplaySmoothScalingJournal: Codable, Sendable {
    enum Phase: String, Codable { case prepared, installed, removing, removed }
    let version: Int
    let owner: UUID
    let vendor: UInt32
    let product: UInt32
    let originalWasMissing: Bool
    let payload: Data
    let payloadHash: String
    let baseline: Set<DisplaySmoothScalingSize>
    let requested: Set<DisplaySmoothScalingSize>
    var phase: Phase

    func validate(vendor: UInt32, product: UInt32) throws {
        guard version == 1, originalWasMissing, self.vendor == vendor, self.product == product,
              !requested.isEmpty, requested.count <= 512, baseline.count <= 4096,
              payload.count <= DisplaySmoothScalingFiles.maximumBytes,
              DisplaySmoothScalingPlan.hash(payload) == payloadHash,
              let plist = try? PropertyListSerialization.propertyList(from: payload, format: nil) as? [String: Any],
              plist[DisplaySmoothScalingPlan.ownerKey] as? String == owner.uuidString,
              (plist["DisplayVendorID"] as? NSNumber)?.uint32Value == vendor,
              (plist["DisplayProductID"] as? NSNumber)?.uint32Value == product,
              Set(plist.keys) == [DisplaySmoothScalingPlan.ownerKey, "DisplayVendorID", "DisplayProductID", "scale-resolutions"],
              requested.allSatisfy({ (800...8192).contains($0.width) && (600...8192).contains($0.height) }),
              let modes = plist["scale-resolutions"] as? [Data],
              Set(modes) == Set(requested.map(DisplaySmoothScalingPlan.encode)) else { throw DisplaySmoothScalingError.invalidJournal }
    }
}

enum DisplaySmoothScalingPlan {
    static let ownerKey = "NooLDisplayOverrideOwner"
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func sizes(native: DisplaySmoothScalingSize) throws -> Set<DisplaySmoothScalingSize> {
        guard (800...16384).contains(native.width), (600...16384).contains(native.height) else {
            throw DisplaySmoothScalingError.unavailable
        }
        var result: Set<DisplaySmoothScalingSize> = []
        for width in stride(from: native.width, through: (native.width + 1) / 2, by: -16) {
            let height = Int((Double(width) * Double(native.height) / Double(native.width)).rounded())
            if (800...8192).contains(width), (600...8192).contains(height) { result.insert(.init(width: width, height: height)) }
        }
        guard result.count > 1, result.count <= 512 else { throw DisplaySmoothScalingError.unavailable }
        return result
    }

    static func encode(_ size: DisplaySmoothScalingSize) -> Data {
        var width = UInt32(size.width * 2).bigEndian, height = UInt32(size.height * 2).bigEndian
        var bytes = withUnsafeBytes(of: &width) { Data($0) }
        bytes.append(withUnsafeBytes(of: &height) { Data($0) })
        return bytes
    }

    static func journal(for display: DisplaySmoothScalingDisplay, previous: DisplaySmoothScalingJournal? = nil) throws -> DisplaySmoothScalingJournal {
        let owner = UUID(), requested = try sizes(native: display.nativeSize)
        let ordered = requested.sorted { $0.width > $1.width }
        let plist: [String: Any] = [ownerKey: owner.uuidString, "DisplayVendorID": display.vendor,
            "DisplayProductID": display.product, "scale-resolutions": ordered.map(encode)]
        let payload = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let baseline = previous.flatMap { $0.requested == requested ? $0.baseline : nil } ?? display.availableHiDPI
        return .init(version: 1, owner: owner, vendor: display.vendor, product: display.product,
            originalWasMissing: true, payload: payload, payloadHash: hash(payload),
            baseline: baseline,
            requested: requested, phase: .prepared)
    }

    static func isDense(_ modes: Set<DisplaySmoothScalingSize>, native: DisplaySmoothScalingSize) -> Bool {
        guard let requested = try? sizes(native: native) else { return false }
        // One ordinary Retina mode is not a dense ladder. Some requested backings exceed GPU limits.
        return modes.intersection(requested).count >= min(8, requested.count)
    }
}

/// Only explicit user writes reach the installer. Configuration stays installed across quit/reboot.
actor SystemDisplaySmoothScalingService: DisplaySmoothScalingServing {
    typealias Resolve = @Sendable (DisplayHardwareTarget) throws -> DisplaySmoothScalingDisplay?
    private let resolve: Resolve
    private let files: DisplaySmoothScalingFiles
    private let installer: any DisplaySmoothScalingInstalling
    private var busy = false

    init() {
        resolve = Self.liveDisplay
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        files = .init(overrides: URL(fileURLWithPath: "/Library/Displays/Contents/Resources/Overrides"),
            journals: support.appendingPathComponent("NooL App/DisplayOverrides", isDirectory: true))
        installer = AuthorizedDisplaySmoothScalingInstaller()
    }

    init(files: DisplaySmoothScalingFiles, installer: any DisplaySmoothScalingInstalling, resolve: @escaping Resolve) {
        self.files = files; self.installer = installer; self.resolve = resolve
    }

    func read(_ target: DisplayHardwareTarget) async throws -> DisplaySmoothScalingState? {
        guard let display = try resolve(target) else { return nil }
        return try state(display)
    }

    func setEnabled(_ enabled: Bool, for target: DisplayHardwareTarget) async throws -> DisplaySmoothScalingState {
        guard !busy else { throw DisplaySmoothScalingError.busy }
        guard let display = try resolve(target) else { throw DisplaySmoothScalingError.unavailable }
        busy = true
        defer { busy = false }
        let existing = try files.readOverride(display)
        let saved = try files.readJournal(display)
        if let existing {
            guard let saved else { throw DisplaySmoothScalingError.foreignManaged }
            guard DisplaySmoothScalingPlan.hash(existing) == saved.payloadHash else { throw DisplaySmoothScalingError.conflict }
            if enabled { busy = false; return try state(display) }
            var removing = saved; removing.phase = .removing
            try files.writeJournal(removing)
            try fresh(display)
            let request = DisplaySmoothScalingInstallRequest(operation: .remove, display: display, callerUID: getuid(), owner: saved.owner,
                expectedHash: saved.payloadHash, payload: saved.payload)
            do { try await installer.apply(request) }
            catch {
                if try files.readOverride(display) != nil { throw error }
            }
            removing.phase = .removed
            try files.writeJournal(removing)
        } else if enabled {
            let prepared = try DisplaySmoothScalingPlan.journal(for: display, previous: saved)
            try files.writeJournal(prepared) // Durable ownership intent precedes the administrator prompt.
            try fresh(display)
            let request = DisplaySmoothScalingInstallRequest(operation: .install, display: display, callerUID: getuid(), owner: prepared.owner,
                expectedHash: nil, payload: prepared.payload)
            do { try await installer.apply(request) }
            catch {
                guard let actual = try files.readOverride(display), DisplaySmoothScalingPlan.hash(actual) == prepared.payloadHash else { throw error }
            }
            guard let actual = try files.readOverride(display), DisplaySmoothScalingPlan.hash(actual) == prepared.payloadHash else {
                throw DisplaySmoothScalingError.conflict
            }
            var installed = prepared; installed.phase = .installed
            try files.writeJournal(installed)
        }
        guard let after = try resolve(target) else { throw DisplaySmoothScalingError.disconnected }
        busy = false
        return try state(after)
    }

    private func fresh(_ display: DisplaySmoothScalingDisplay) throws {
        guard let now = try resolve(display.target), now.target == display.target,
              now.vendor == display.vendor, now.product == display.product, now.nativeSize == display.nativeSize else {
            throw DisplaySmoothScalingError.disconnected
        }
    }

    private func state(_ display: DisplaySmoothScalingDisplay) throws -> DisplaySmoothScalingState {
        let existing = try files.readOverride(display), saved = try files.readJournal(display)
        if let existing {
            guard let saved else {
                let plist = try? PropertyListSerialization.propertyList(from: existing, format: nil) as? [String: Any]
                let data = plist?["scale-resolutions"] as? [Data] ?? []
                let installed = Set(data)
                let common = display.availableHiDPI.filter { installed.contains(DisplaySmoothScalingPlan.encode($0)) }
                return .init(isEnabled: DisplaySmoothScalingPlan.isDense(common, native: display.nativeSize),
                    canModify: false, needsReconnect: false, detail: "Настроено другим приложением. Общая настройка для дисплеев этой модели.")
            }
            guard DisplaySmoothScalingPlan.hash(existing) == saved.payloadHash else { throw DisplaySmoothScalingError.conflict }
            let added = saved.requested.subtracting(saved.baseline)
            let active = added.isEmpty || display.availableHiDPI.intersection(added).count >= min(3, added.count)
            return .init(isEnabled: true, canModify: !busy, needsReconnect: !active,
                detail: active ? "Настройка общая для всех дисплеев этой модели." : "Установлено. Переподключите дисплей или перезагрузите Mac. Настройка общая для всех дисплеев этой модели.")
        }
        let pendingRemoval = saved.map { journal in
            journal.phase != .prepared && !display.availableHiDPI.intersection(journal.requested.subtracting(journal.baseline)).isEmpty
        } ?? false
        return .init(isEnabled: false, canModify: !busy, needsReconnect: pendingRemoval,
            detail: pendingRemoval ? "Удалено. Переподключите дисплей или перезагрузите Mac." : "Добавляет промежуточные HiDPI-размеры. Потребуется пароль администратора и переподключение дисплея.")
    }

    nonisolated static func liveDisplay(_ target: DisplayHardwareTarget) throws -> DisplaySmoothScalingDisplay? {
        guard !target.isBuiltin else { return nil }
        guard target.displayID != 0, CGDisplayIsOnline(target.displayID) != 0,
              CGDisplayIsBuiltin(target.displayID) == 0,
              let uuid = CGDisplayCreateUUIDFromDisplayID(target.displayID)?.takeRetainedValue(),
              (CFUUIDCreateString(nil, uuid) as String).caseInsensitiveCompare(target.uuid) == .orderedSame else {
            throw DisplaySmoothScalingError.disconnected
        }
        let vendor = CGDisplayVendorNumber(target.displayID), product = CGDisplayModelNumber(target.displayID)
        guard vendor > 0, vendor <= 0xffff, product > 0, product <= 0xffff else { return nil }
        let raw = CGDisplayCopyAllDisplayModes(target.displayID,
            [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary) as? [CGDisplayMode] ?? []
        // IOGraphicsTypes.h kDisplayModeNativeFlag identifies the panel, unlike the largest scaled backing.
        guard let native = raw.filter({ $0.ioFlags & 0x02000000 != 0 })
            .max(by: { $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight }) else { return nil }
        let size = DisplaySmoothScalingSize(width: native.pixelWidth, height: native.pixelHeight)
        guard (try? DisplaySmoothScalingPlan.sizes(native: size)) != nil else { return nil }
        let available = Set(raw.filter { $0.isUsableForDesktopGUI() && $0.pixelWidth > $0.width }
            .map { DisplaySmoothScalingSize(width: $0.width, height: $0.height) })
        return .init(target: target, vendor: vendor, product: product, nativeSize: size, availableHiDPI: available)
    }
}

struct DisplaySmoothScalingFiles: Sendable {
    static let maximumBytes = 262_144
    let overrides: URL
    let journals: URL
    var expectedOwner: uid_t = 0

    func overrideURL(_ display: DisplaySmoothScalingDisplay) -> URL {
        overrides.appendingPathComponent(String(format: "DisplayVendorID-%x", display.vendor), isDirectory: true)
            .appendingPathComponent(String(format: "DisplayProductID-%x", display.product))
    }

    func journalURL(vendor: UInt32, product: UInt32) -> URL {
        journals.appendingPathComponent(String(format: "%x-%x.json", vendor, product))
    }

    func readOverride(_ display: DisplaySmoothScalingDisplay) throws -> Data? {
        let url = overrideURL(display)
        // Production validates every component below /Library. Test fixtures use their own anchor.
        let anchor = overrides.path.hasPrefix("/Library/") ? URL(fileURLWithPath: "/Library") : overrides
        guard try validateDirectories(to: url.deletingLastPathComponent(), anchor: anchor, owner: expectedOwner) else { return nil }
        return try readRegularFile(url, owner: expectedOwner, privateFile: false)
    }

    func readJournal(_ display: DisplaySmoothScalingDisplay) throws -> DisplaySmoothScalingJournal? {
        guard try validateDirectories(to: journals, anchor: journals, owner: getuid()) else { return nil }
        guard let data = try readRegularFile(journalURL(vendor: display.vendor, product: display.product), owner: getuid(), privateFile: true) else { return nil }
        guard let journal = try? JSONDecoder().decode(DisplaySmoothScalingJournal.self, from: data) else { throw DisplaySmoothScalingError.invalidJournal }
        try journal.validate(vendor: display.vendor, product: display.product)
        return journal
    }

    func writeJournal(_ journal: DisplaySmoothScalingJournal) throws {
        try journal.validate(vendor: journal.vendor, product: journal.product)
        try FileManager.default.createDirectory(at: journals, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard try validateDirectories(to: journals, anchor: journals, owner: getuid()) else { throw DisplaySmoothScalingError.invalidJournal }
        let destination = journalURL(vendor: journal.vendor, product: journal.product)
        _ = try readRegularFile(destination, owner: getuid(), privateFile: true)
        let temporary = journals.appendingPathComponent(".\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw DisplaySmoothScalingError.invalidJournal }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); _ = unlink(temporary.path) }
        try handle.write(contentsOf: JSONEncoder().encode(journal))
        try handle.synchronize()
        try handle.close()
        guard rename(temporary.path, destination.path) == 0 else { throw DisplaySmoothScalingError.invalidJournal }
        let directory = open(journals.path, O_RDONLY | O_NOFOLLOW)
        guard directory >= 0 else { throw DisplaySmoothScalingError.invalidJournal }
        defer { close(directory) }
        guard fsync(directory) == 0 else { throw DisplaySmoothScalingError.invalidJournal }
    }

    private func validateDirectories(to directory: URL, anchor: URL, owner: uid_t) throws -> Bool {
        guard directory.path == anchor.path || directory.path.hasPrefix(anchor.path + "/") else { throw DisplaySmoothScalingError.conflict }
        var current = anchor
        var paths = [anchor]
        for part in directory.path.dropFirst(anchor.path.count).split(separator: "/") {
            current.appendPathComponent(String(part), isDirectory: true); paths.append(current)
        }
        for path in paths {
            var info = stat()
            if lstat(path.path, &info) != 0 {
                if errno == ENOENT { return false }
                throw DisplaySmoothScalingError.conflict
            }
            guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == owner, info.st_mode & 0o022 == 0 else { throw DisplaySmoothScalingError.conflict }
        }
        return true
    }

    private func readRegularFile(_ url: URL, owner: uid_t, privateFile: Bool) throws -> Data? {
        var before = stat()
        if lstat(url.path, &before) != 0 {
            if errno == ENOENT { return nil }
            throw DisplaySmoothScalingError.conflict
        }
        guard before.st_mode & S_IFMT == S_IFREG, before.st_uid == owner, before.st_nlink == 1,
              before.st_size >= 0, before.st_size <= Self.maximumBytes,
              before.st_mode & (privateFile ? 0o077 : 0o022) == 0 else { throw DisplaySmoothScalingError.conflict }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw DisplaySmoothScalingError.conflict }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, before.st_dev == opened.st_dev, before.st_ino == opened.st_ino else { throw DisplaySmoothScalingError.conflict }
        let data = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
        guard data.count <= Self.maximumBytes, data.count == before.st_size else { throw DisplaySmoothScalingError.conflict }
        return data
    }
}

/// No helper file is executed from a user-writable location. The administrator operation
/// receives immutable inline code and validated data arguments, never a display name/path.
struct AuthorizedDisplaySmoothScalingInstaller: DisplaySmoothScalingInstalling {
    func apply(_ request: DisplaySmoothScalingInstallRequest) async throws {
        let command = DisplaySmoothScalingRootCommand.command(request)
        let data = try JSONSerialization.data(withJSONObject: [command])
        guard let quoted = String(data: data, encoding: .utf8) else { throw DisplaySmoothScalingError.installerFailed }
        let source = "var app=Application.currentApplication(); app.includeStandardAdditions=true; app.doShellScript(\(quoted)[0], {administratorPrivileges:true});"
        // Cancellation never kills a root commit halfway through or spawns a replacement prompt.
        let result = try await Self.run(executable: "/usr/bin/osascript", arguments: ["-l", "JavaScript", "-e", source])
        guard result.status == 0 else {
            if result.output.contains("E_CONFLICT") || result.output.contains("E_MARKER") || result.output.contains("E_PATH") { throw DisplaySmoothScalingError.conflict }
            if result.output.contains("E_IDENTITY") { throw DisplaySmoothScalingError.disconnected }
            if result.output.contains("(-128)") || result.output.localizedCaseInsensitiveContains("cancel") { throw DisplaySmoothScalingError.authorization }
            throw DisplaySmoothScalingError.installerFailed
        }
    }

    struct Result: Sendable { let status: Int32; let output: String }
    static func run(executable: String, arguments: [String]) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = pipe
            process.terminationHandler = { child in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: .init(status: child.terminationStatus,
                    output: String(decoding: data.prefix(8192), as: UTF8.self)))
            }
            do { try process.run() }
            catch { continuation.resume(throwing: error) }
        }
    }
}

enum DisplaySmoothScalingRootCommand {
    static let base = URL(fileURLWithPath: "/Library/Displays/Contents/Resources/Overrides")

    static func command(_ request: DisplaySmoothScalingInstallRequest) -> String {
        let args = ["/usr/bin/env", "-i", "PATH=/usr/bin:/bin", "/usr/bin/perl", "-e", script,
            "--"] + arguments(request)
        return args.map(shellLiteral).joined(separator: " ")
    }

    static func arguments(_ request: DisplaySmoothScalingInstallRequest) -> [String] {
        [request.operation.rawValue, String(request.display.vendor, radix: 16), String(request.display.product, radix: 16),
         String(request.display.target.displayID), request.display.target.uuid, String(request.callerUID),
         request.owner.uuidString, request.expectedHash ?? "missing", DisplaySmoothScalingPlan.hash(request.payload),
         request.payload.base64EncodedString()]
    }

    private static func shellLiteral(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private static func perlLiteral(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
    }

    static let script = makeScript(base: base, ownerUID: 0, verifyIdentity: true)

    /// Tests execute the same filesystem/CAS code unprivileged against their temporary anchor.
    static func fixtureScript(base: URL, ownerUID: uid_t) -> String {
        makeScript(base: base, ownerUID: ownerUID, verifyIdentity: false)
    }

    private static let identityJavaScript = #"""
    ObjC.import('Foundation'); ObjC.import('CoreGraphics');
    ObjC.bindFunction('CGDisplayCreateUUIDFromDisplayID',['void *',['unsigned int']]);
    ObjC.bindFunction('CFUUIDCreateString',['id',['void *','void *']]);
    ObjC.bindFunction('CFRelease',['void',['void *']]);
    ObjC.bindFunction('CGDisplayVendorNumber',['unsigned int',['unsigned int']]);
    ObjC.bindFunction('CGDisplayModelNumber',['unsigned int',['unsigned int']]);
    ObjC.bindFunction('CGDisplayIsOnline',['unsigned int',['unsigned int']]);
    ObjC.bindFunction('CGDisplayIsBuiltin',['unsigned int',['unsigned int']]);
    function run(args) {
      var id=Number(args[0]), vendor=Number(args[2]), model=Number(args[3]);
      if (!$.CGDisplayIsOnline(id) || $.CGDisplayIsBuiltin(id) ||
          Number($.CGDisplayVendorNumber(id))!==vendor || Number($.CGDisplayModelNumber(id))!==model)
        throw Error('E_IDENTITY');
      var nativeUUID=$.CGDisplayCreateUUIDFromDisplayID(id);
      if (!nativeUUID) throw Error('E_IDENTITY');
      var uuid=String(ObjC.unwrap($.CFUUIDCreateString(null,nativeUUID)));
      $.CFRelease(nativeUUID);
      if (uuid.toUpperCase()!==args[1].toUpperCase()) throw Error('E_IDENTITY');
      return '';
    }
    """#

    private static let schemaJavaScript = #"""
    ObjC.import('Foundation');
    function fail() { throw Error('E_SCHEMA'); }
    function bytes(text) {
      var alphabet='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/', out=[], value=0, bits=0;
      for(var i=0;i<text.length;i++) {
        if(text[i]==='=') break;
        var n=alphabet.indexOf(text[i]); if(n<0) fail();
        value=(value<<6)|n; bits+=6;
        if(bits>=8) { bits-=8; out.push((value>>bits)&255); }
      }
      return out;
    }
    function run(args) {
      var data=$.NSData.alloc.initWithBase64EncodedStringOptions($(args[0]),0);
      if(!data) fail();
      var dict=$.NSPropertyListSerialization.propertyListWithDataOptionsFormatError(data,0,null,null);
      if(!dict || !dict.isKindOfClass($.NSDictionary)) fail();
      var keys=ObjC.deepUnwrap(dict.allKeys).sort().join(',');
      if(keys!=='DisplayProductID,DisplayVendorID,NooLDisplayOverrideOwner,scale-resolutions') fail();
      var owner=dict.objectForKey('NooLDisplayOverrideOwner');
      if(!owner.isKindOfClass($.NSString) || ObjC.unwrap(owner)!==args[1]) fail();
      var vendor=dict.objectForKey('DisplayVendorID'), product=dict.objectForKey('DisplayProductID');
      if(!vendor.isKindOfClass($.NSNumber) || !product.isKindOfClass($.NSNumber) ||
         ObjC.unwrap(vendor)!==Number(args[2]) || ObjC.unwrap(product)!==Number(args[3])) fail();
      var modes=dict.objectForKey('scale-resolutions');
      if(!modes.isKindOfClass($.NSArray) || Number(modes.count)<2 || Number(modes.count)>512) fail();
      var seen={};
      for(var i=0;i<Number(modes.count);i++) {
        var mode=modes.objectAtIndex(i);
        if(!mode.isKindOfClass($.NSData) || Number(mode.length)!==8) fail();
        var b=bytes(ObjC.unwrap(mode.base64EncodedStringWithOptions(0)));
        if(b.length!==8) fail();
        var w=b[0]*16777216+b[1]*65536+b[2]*256+b[3], h=b[4]*16777216+b[5]*65536+b[6]*256+b[7];
        if(w<1600 || h<1200 || w>16384 || h>16384 || w%2 || h%2) fail();
        var key=w+'x'+h; if(seen[key]) fail(); seen[key]=true;
      }
      return '';
    }
    """#

    private static func makeScript(base: URL, ownerUID: uid_t, verifyIdentity: Bool) -> String {
        let anchor = verifyIdentity ? "/Library" : base.path
        let identity = Data(identityJavaScript.utf8).base64EncodedString()
        let schema = Data(schemaJavaScript.utf8).base64EncodedString()
        let check = verifyIdentity ? #"""
        my $js = decode_base64('\#(identity)');
        system('/bin/launchctl','asuser',$uid,'/usr/bin/sudo','-n','-u',"#$uid",
          '/usr/bin/osascript','-l','JavaScript','-e',$js,'--',$id,$uuid,hex($vendor),hex($product)) == 0
          or die "E_IDENTITY\n";
        """# : ""
        return #"""
        use strict; use warnings;
        use Fcntl qw(O_RDONLY O_WRONLY O_CREAT O_EXCL O_NOFOLLOW S_ISDIR S_ISREG);
        use Digest::SHA qw(sha256_hex); use MIME::Base64 qw(decode_base64); use IO::Handle;
        umask 0022;
        my ($op,$vendor,$product,$id,$uuid,$uid,$owner,$expected,$hash,$encoded)=@ARGV;
        @ARGV==10 or die "E_INPUT\n";
        $op =~ /\A(?:install|remove)\z/ && $vendor =~ /\A[0-9a-f]{1,4}\z/ && hex($vendor)>0 &&
          $product =~ /\A[0-9a-f]{1,4}\z/ && hex($product)>0 &&
          $id =~ /\A[1-9][0-9]{0,9}\z/ && $id<=4294967295 &&
          $uid =~ /\A[1-9][0-9]{0,9}\z/ && $uid<=4294967295 &&
          $uuid =~ /\A[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\z/ &&
          $owner =~ /\A[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\z/ &&
          $hash =~ /\A[0-9a-f]{64}\z/ && length($encoded)<=400000 &&
          $encoded =~ /\A[A-Za-z0-9+\/=]+\z/ or die "E_INPUT\n";
        ($op eq 'install' ? $expected eq 'missing' : $expected =~ /\A[0-9a-f]{64}\z/) or die "E_INPUT\n";
        $> == \#(ownerUID) or die "E_UID\n";
        my $payload=decode_base64($encoded);
        length($payload)<=262144 && sha256_hex($payload) eq $hash or die "E_INPUT\n";
        $payload =~ m{<key>NooLDisplayOverrideOwner</key>\s*<string>\Q$owner\E</string>} or die "E_MARKER\n";
        my $schema = decode_base64('\#(schema)');
        system('/usr/bin/osascript','-l','JavaScript','-e',$schema,'--',$encoded,$owner,hex($vendor),hex($product)) == 0
          or die "E_SCHEMA\n";
        \#(check)
        my $base=\#(perlLiteral(base.path));
        my $anchor=\#(perlLiteral(anchor));
        my $dir="$base/DisplayVendorID-$vendor";
        my $path="$dir/DisplayProductID-$product";
        sub sync_dir {
          sysopen(my $directory,$dir,O_RDONLY|O_NOFOLLOW) or die "E_WRITE\n";
          $directory->sync or die "E_WRITE\n"; close($directory) or die "E_WRITE\n";
        }
        sub guard_dir {
          my ($p,$create)=@_;
          if (!lstat($p)) { $!{ENOENT} && $create or die "E_PATH\n"; mkdir($p,0755) or die "E_PATH\n"; }
          my @s=lstat($p);
          @s && S_ISDIR($s[2]) && $s[4]==\#(ownerUID) && ($s[2]&0022)==0 or die "E_PATH\n";
        }
        guard_dir($anchor,0);
        index($dir,"$anchor/")==0 || $dir eq $anchor or die "E_PATH\n";
        my $walk=$anchor;
        for my $part (split('/',substr($dir,length($anchor)+1))) {
          length($part) && $part ne '.' && $part ne '..' or die "E_PATH\n";
          $walk.="/$part"; guard_dir($walk,$op eq 'install');
        }
        my @before=lstat($path);
        if ($op eq 'install') {
          @before==0 && $!{ENOENT} or die "E_CONFLICT\n";
        } else {
          @before && S_ISREG($before[2]) && $before[4]==\#(ownerUID) && $before[3]==1 &&
            ($before[2]&0022)==0 && $before[7]<=262144 or die "E_CONFLICT\n";
          sysopen(my $in,$path,O_RDONLY|O_NOFOLLOW) or die "E_CONFLICT\n";
          binmode($in); my @opened=stat($in);
          $opened[0]==$before[0] && $opened[1]==$before[1] or die "E_CONFLICT\n";
          local $/; my $contents=<$in>; close($in);
          length($contents)==$before[7] && sha256_hex($contents) eq $expected && $expected eq $hash or die "E_CONFLICT\n";
          my @last=lstat($path);
          @last && $last[0]==$before[0] && $last[1]==$before[1] && $last[7]==$before[7] && $last[9]==$before[9] or die "E_CONFLICT\n";
          unlink($path) or die "E_CONFLICT\n";
          sync_dir();
          exit 0;
        }
        my $temporary="$dir/.nool-$owner-$$.tmp"; my $createdTemporary=0;
        END { unlink($temporary) if $createdTemporary && defined($temporary) && -e $temporary; }
        sysopen(my $out,$temporary,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600) or die "E_PATH\n";
        $createdTemporary=1;
        binmode($out); my $offset=0;
        while ($offset<length($payload)) {
          my $written=syswrite($out,$payload,length($payload)-$offset,$offset);
          defined($written) && $written>0 or die "E_WRITE\n"; $offset+=$written;
        }
        $out->sync or die "E_WRITE\n"; close($out) or die "E_WRITE\n";
        chmod(0644,$temporary)==1 or die "E_WRITE\n";
        # link is atomic create-only: a concurrent foreign file is never overwritten.
        link($temporary,$path) or die "E_CONFLICT\n";
        unlink($temporary) or die "E_WRITE\n";
        $createdTemporary=0;
        sync_dir();
        exit 0;
        """#
    }
}

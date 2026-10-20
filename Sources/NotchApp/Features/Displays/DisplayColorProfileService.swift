import AppKit
@preconcurrency import ColorSync
import CoreGraphics
import Foundation

struct DisplayColorProfileOption: Identifiable, Codable, Equatable, Sendable {
    static let factoryID = "factory"
    let id: String
    let name: String
}

struct DisplayColorProfileState: Equatable, Sendable {
    let options: [DisplayColorProfileOption]
    let selectedID: String
}

@MainActor
protocol DisplayColorProfileServing {
    func state(for display: DisplayInfo) async throws -> DisplayColorProfileState
    func setProfile(_ profileID: String, for display: DisplayInfo) async throws
}

enum DisplayColorProfileError: Error, LocalizedError {
    case disconnected
    case unavailable
    case invalidProfile
    case couldNotApply

    var errorDescription: String? {
        switch self {
        case .disconnected: "Дисплей отключён или изменился."
        case .unavailable: "Цветовые профили этого дисплея недоступны."
        case .invalidProfile: "Цветовой профиль недоступен или несовместим с дисплеем."
        case .couldNotApply: "Не удалось применить цветовой профиль."
        }
    }
}

@MainActor
final class ColorSyncDisplayColorProfileService: DisplayColorProfileServing {
    private let worker: DisplayColorProfileWorker

    init(driver: any DisplayColorProfileDriving = SystemDisplayColorProfileDriver()) {
        worker = DisplayColorProfileWorker(driver: driver)
    }

    func state(for display: DisplayInfo) async throws -> DisplayColorProfileState {
        guard display.isEnabled else { throw DisplayColorProfileError.disconnected }
        return try await worker.state(displayID: display.displayID, uuid: display.id)
    }

    func setProfile(_ profileID: String, for display: DisplayInfo) async throws {
        guard display.isEnabled else { throw DisplayColorProfileError.disconnected }
        try await worker.setProfile(profileID, displayID: display.displayID, uuid: display.id)
    }
}

struct DisplayColorProfileEntry: Equatable, Sendable {
    let url: URL
    let name: String

    var option: DisplayColorProfileOption {
        DisplayColorProfileOption(id: url.absoluteString, name: name)
    }

    /// Only ordinary RGB monitor profiles belong in the display picker. Printer,
    /// device-link, abstract, and grayscale profiles must never become options.
    static func isUsableHeader(_ header: Data) -> Bool {
        guard header.count >= 128 else { return false }
        let bytes = Array(header.prefix(128))
        let fields = [Array(bytes[12..<16]), Array(bytes[16..<20]), Array(bytes[36..<40])]
        let signatures = [Array("mntr".utf8), Array("RGB ".utf8), Array("acsp".utf8)]
        // ColorSync's copied/cached header uses native-endian signature words;
        // raw ICC headers use big endian. Require a consistent representation.
        return fields == signatures || fields == signatures.map { Array($0.reversed()) }
    }

    static func canonicalFileURL(_ url: URL) -> URL? {
        guard url.isFileURL else { return nil }
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }
}

struct DisplayColorProfileDeviceSelection: Equatable, Sendable {
    let factoryURL: URL?
    let customURL: URL?
    let currentURL: URL?

    var selectedID: String {
        customURL.flatMap(DisplayColorProfileEntry.canonicalFileURL)?.absoluteString
            ?? DisplayColorProfileOption.factoryID
    }

    static func parse(_ info: [String: Any], currentURL: URL? = nil, defaultIsFactory: Bool? = nil) throws -> Self {
        guard let factory = info[kColorSyncFactoryProfiles.takeUnretainedValue() as String] as? [String: Any],
              let defaultID = factory[kColorSyncDeviceDefaultProfileID.takeUnretainedValue() as String] as? String else {
            throw DisplayColorProfileError.unavailable
        }
        let definition = factory[defaultID] as? [String: Any]
        let factoryURL = definition?[kColorSyncDeviceProfileURL.takeUnretainedValue() as String] as? URL
        let custom = info[kColorSyncCustomProfiles.takeUnretainedValue() as String] as? [String: Any]
        let customValue = custom?[defaultID] ?? custom?[kColorSyncDeviceDefaultProfileID.takeUnretainedValue() as String]
        var customURL = customValue as? URL
        // NSNull explicitly means the factory profile, not a custom copy of the
        // same file. Preserve that distinction when a preset stores selectedID.
        if let customValue, !(customValue is NSNull), customURL == nil { throw DisplayColorProfileError.invalidProfile }
        if let customURL, !customURL.isFileURL { throw DisplayColorProfileError.invalidProfile }
        if defaultIsFactory == true {
            customURL = nil
        } else if defaultIsFactory == false {
            // Registered DEFAULT+CURRENT metadata is authoritative. A matching
            // URL in an unrelated legacy slot can be dormant even when that URL
            // is also the active factory file.
            guard let activeURL = currentURL ?? customURL, activeURL.isFileURL else {
                throw DisplayColorProfileError.invalidProfile
            }
            customURL = activeURL
        }
        return Self(factoryURL: factoryURL, customURL: customURL, currentURL: currentURL)
    }
}

protocol DisplayColorProfileDriving: Sendable {
    func activeDisplayUUID(for displayID: UInt32) -> String?
    func deviceSelection(uuid: String, displayID: UInt32) throws -> DisplayColorProfileDeviceSelection
    func installedProfiles() throws -> [DisplayColorProfileEntry]
    func profile(at url: URL) -> DisplayColorProfileEntry?
    func setCustomProfile(_ url: URL?, uuid: String) throws
}

private actor DisplayColorProfileWorker {
    private let driver: any DisplayColorProfileDriving
    private var cachedCatalog: [DisplayColorProfileEntry]?
    private var catalogDate = Date.distantPast

    init(driver: any DisplayColorProfileDriving) { self.driver = driver }

    func state(displayID: UInt32, uuid: String) throws -> DisplayColorProfileState {
        try validate(displayID: displayID, uuid: uuid)
        let selection = try driver.deviceSelection(uuid: uuid, displayID: displayID)
        var entries = try catalog()
        for url in [selection.factoryURL, selection.customURL, selection.currentURL].compactMap({ $0 }) {
            if let entry = driver.profile(at: url) { entries.append(entry) }
        }
        var seen = Set<String>()
        let options = entries.map(\.option).filter { seen.insert($0.id).inserted }.sorted {
            let comparison = $0.name.localizedStandardCompare($1.name)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
        // Never silently label an existing custom override as the factory profile.
        guard selection.selectedID == DisplayColorProfileOption.factoryID
                || options.contains(where: { $0.id == selection.selectedID }) else {
            throw DisplayColorProfileError.invalidProfile
        }
        try validate(displayID: displayID, uuid: uuid)
        return DisplayColorProfileState(options: [DisplayColorProfileOption(id: DisplayColorProfileOption.factoryID,
                                                                           name: "Заводской профиль")] + options,
                                        selectedID: selection.selectedID)
    }

    func setProfile(_ profileID: String, displayID: UInt32, uuid: String) throws {
        try validate(displayID: displayID, uuid: uuid)
        if profileID == DisplayColorProfileOption.factoryID {
            try driver.setCustomProfile(nil, uuid: uuid)
            try verifySelection(profileID, displayID: displayID, uuid: uuid)
            return
        }
        let current = try state(displayID: displayID, uuid: uuid)
        guard current.options.contains(where: { $0.id == profileID }), let url = URL(string: profileID),
              let entry = driver.profile(at: url), entry.option.id == profileID else {
            throw DisplayColorProfileError.invalidProfile
        }
        // A catalog ID is not permission to act on a display ID reused while
        // profile validation or ColorSync's cache refresh was in progress.
        try validate(displayID: displayID, uuid: uuid)
        try driver.setCustomProfile(entry.url, uuid: uuid)
        try verifySelection(profileID, displayID: displayID, uuid: uuid)
    }

    private func verifySelection(_ profileID: String, displayID: UInt32, uuid: String) throws {
        let selectedID = try state(displayID: displayID, uuid: uuid).selectedID
        if selectedID == profileID { return }
        // ColorSync can coalesce an explicit selection of the factory's own ICC
        // file into factory state. Accept that only when both native URLs prove
        // the requested file is actually effective.
        let selection = try driver.deviceSelection(uuid: uuid, displayID: displayID)
        guard profileID != DisplayColorProfileOption.factoryID, selectedID == DisplayColorProfileOption.factoryID,
              let current = selection.currentURL.flatMap(DisplayColorProfileEntry.canonicalFileURL),
              let factory = selection.factoryURL.flatMap(DisplayColorProfileEntry.canonicalFileURL),
              current == factory, current.absoluteString == profileID else { throw DisplayColorProfileError.couldNotApply }
    }

    private func catalog() throws -> [DisplayColorProfileEntry] {
        if let cachedCatalog, Date().timeIntervalSince(catalogDate) < 60 { return cachedCatalog }
        let entries = try driver.installedProfiles()
        cachedCatalog = entries
        catalogDate = Date()
        return entries
    }

    private func validate(displayID: UInt32, uuid: String) throws {
        try Task.checkCancellation()
        guard let current = driver.activeDisplayUUID(for: displayID),
              current.caseInsensitiveCompare(uuid) == .orderedSame else { throw DisplayColorProfileError.disconnected }
    }
}

struct SystemDisplayColorProfileDriver: DisplayColorProfileDriving {
    func activeDisplayUUID(for displayID: UInt32) -> String? {
        guard CGDisplayIsOnline(displayID) != 0, CGDisplayIsActive(displayID) != 0,
              let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    func deviceSelection(uuid: String, displayID: UInt32) throws -> DisplayColorProfileDeviceSelection {
        guard let id = CFUUIDCreateFromString(nil, uuid as CFString),
              let info = ColorSyncDeviceCopyDeviceInfo(kColorSyncDisplayDeviceClass.takeUnretainedValue(), id)?.takeRetainedValue() as? [String: Any] else {
            throw DisplayColorProfileError.unavailable
        }
        let registered = registeredDefaultProfile(deviceID: id, info: info)
        let profile = ColorSyncProfileCreateWithDisplayID(displayID)?.takeRetainedValue()
        let currentURL = registered?.url ?? profile.flatMap { ColorSyncProfileGetURL($0, nil)?.takeUnretainedValue() as URL? }
        return try DisplayColorProfileDeviceSelection.parse(info, currentURL: currentURL, defaultIsFactory: registered?.isFactory)
    }

    func installedProfiles() throws -> [DisplayColorProfileEntry] {
        let collector = DisplayColorProfileCollector()
        var error: Unmanaged<CFError>?
        ColorSyncIterateInstalledProfilesWithOptions({ info, context in
            guard let context, let info else { return false }
            return Unmanaged<DisplayColorProfileCollector>.fromOpaque(context).takeUnretainedValue().append(info)
        }, nil, Unmanaged.passUnretained(collector).toOpaque(),
           [kColorSyncWaitForCacheReply.takeUnretainedValue() as String: true] as CFDictionary, &error)
        if let error { throw error.takeRetainedValue() }
        return collector.entries
    }

    func profile(at url: URL) -> DisplayColorProfileEntry? {
        guard let url = DisplayColorProfileEntry.canonicalFileURL(url),
              let properties = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              properties.isRegularFile == true, let size = properties.fileSize, (128...33_554_432).contains(size),
              let profile = ColorSyncProfileCreateWithURL(url as CFURL, nil)?.takeRetainedValue(),
              ColorSyncProfileVerify(profile, nil, nil),
              let header = ColorSyncProfileCopyHeader(profile)?.takeRetainedValue(),
              DisplayColorProfileEntry.isUsableHeader(header as Data) else { return nil }
        let description = ColorSyncProfileCopyDescriptionString(profile)?.takeRetainedValue() as String?
        return DisplayColorProfileEntry(url: url, name: description?.isEmpty == false ? description! : url.deletingPathExtension().lastPathComponent)
    }

    func setCustomProfile(_ url: URL?, uuid: String) throws {
        guard let id = CFUUIDCreateFromString(nil, uuid as CFString),
              let info = ColorSyncDeviceCopyDeviceInfo(kColorSyncDisplayDeviceClass.takeUnretainedValue(), id)?.takeRetainedValue() as? [String: Any],
              let registered = registeredDefaultProfile(deviceID: id, info: info),
              ColorSyncDeviceSetCustomProfiles(kColorSyncDisplayDeviceClass.takeUnretainedValue(), id,
                                               Self.customProfileDictionary(url, profileID: registered.id) as CFDictionary) else {
            throw DisplayColorProfileError.couldNotApply
        }
    }

    static func customProfileDictionary(_ url: URL?, profileID: String = kColorSyncDeviceDefaultProfileID.takeUnretainedValue() as String) -> [String: Any] {
        [profileID: url.map { $0 as Any } ?? kCFNull! as Any,
         kColorSyncProfileUserScope.takeUnretainedValue() as String: kCFPreferencesCurrentUser as Any,
         kColorSyncProfileHostScope.takeUnretainedValue() as String: kCFPreferencesCurrentHost as Any]
    }

    private func registeredDefaultProfile(deviceID: CFUUID, info: [String: Any]) -> DisplayRegisteredColorProfile? {
        guard let factory = info[kColorSyncFactoryProfiles.takeUnretainedValue() as String] as? [String: Any],
              let defaultID = factory[kColorSyncDeviceDefaultProfileID.takeUnretainedValue() as String] as? String else { return nil }
        let collector = DisplayRegisteredColorProfileCollector(deviceID: deviceID, defaultID: defaultID)
        ColorSyncIterateDeviceProfiles({ info, context in
            guard let info, let context else { return false }
            return Unmanaged<DisplayRegisteredColorProfileCollector>.fromOpaque(context).takeUnretainedValue().append(info)
        }, Unmanaged.passUnretained(collector).toOpaque())
        return collector.matches.count == 1 ? collector.matches[0] : nil
    }
}

private struct DisplayRegisteredColorProfile: Equatable {
    let id: String
    let isFactory: Bool
    let url: URL?
}

private final class DisplayRegisteredColorProfileCollector {
    let deviceID: CFUUID
    let defaultID: String
    private(set) var matches: [DisplayRegisteredColorProfile] = []
    private var inspected = 0

    init(deviceID: CFUUID, defaultID: String) {
        self.deviceID = deviceID
        self.defaultID = defaultID
    }

    func append(_ raw: CFDictionary) -> Bool {
        inspected += 1
        guard inspected <= 1024 else { return false }
        let info = raw as NSDictionary
        guard info[kColorSyncDeviceClass.takeUnretainedValue()] as? String == kColorSyncDisplayDeviceClass.takeUnretainedValue() as String,
              let id = info[kColorSyncDeviceID.takeUnretainedValue()], CFEqual(id as CFTypeRef, deviceID),
              info[kColorSyncDeviceProfileID.takeUnretainedValue()] as? String == defaultID,
              info[kColorSyncDeviceProfileIsDefault.takeUnretainedValue()] as? Bool == true,
              info[kColorSyncDeviceProfileIsCurrent.takeUnretainedValue()] as? Bool == true,
              let isFactory = info[kColorSyncDeviceProfileIsFactory.takeUnretainedValue()] as? Bool else { return true }
        let match = DisplayRegisteredColorProfile(id: defaultID, isFactory: isFactory,
                                                  url: info[kColorSyncDeviceProfileURL.takeUnretainedValue()] as? URL)
        if !matches.contains(match) { matches.append(match) }
        return true
    }
}

private final class DisplayColorProfileCollector {
    private(set) var entries: [DisplayColorProfileEntry] = []
    private var inspected = 0

    func append(_ info: CFDictionary) -> Bool {
        inspected += 1
        guard inspected <= 1024 else { return false }
        let info = info as NSDictionary
        guard let header = info[kColorSyncProfileHeader.takeUnretainedValue()] as? Data,
              DisplayColorProfileEntry.isUsableHeader(header), let rawURL = info[kColorSyncProfileURL.takeUnretainedValue()] as? URL,
              let url = DisplayColorProfileEntry.canonicalFileURL(rawURL) else { return true }
        let name = info[kColorSyncProfileDescription.takeUnretainedValue()] as? String ?? url.deletingPathExtension().lastPathComponent
        entries.append(DisplayColorProfileEntry(url: url, name: name))
        return true
    }
}

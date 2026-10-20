@preconcurrency import ColorSync
import XCTest
@testable import NotchApp

final class DisplayColorProfileServiceTests: XCTestCase {
    func testICCHeaderAcceptsOnlyRGBDisplayProfiles() {
        XCTAssertTrue(DisplayColorProfileEntry.isUsableHeader(header()))
        XCTAssertFalse(DisplayColorProfileEntry.isUsableHeader(header(profileClass: "prtr")))
        XCTAssertFalse(DisplayColorProfileEntry.isUsableHeader(header(profileClass: "link")))
        XCTAssertFalse(DisplayColorProfileEntry.isUsableHeader(header(colorSpace: "GRAY")))
        XCTAssertFalse(DisplayColorProfileEntry.isUsableHeader(header(signature: "nope")))
        XCTAssertFalse(DisplayColorProfileEntry.isUsableHeader(Data(header().prefix(127))))
    }

    func testColorSyncNativeEndianHeaderAndMixedEndianRejection() {
        var native = Array(header())
        for range in [12..<16, 16..<20, 36..<40] {
            native.replaceSubrange(range, with: Array(native[range].reversed()))
        }
        XCTAssertTrue(DisplayColorProfileEntry.isUsableHeader(Data(native)))
        native.replaceSubrange(16..<20, with: "RGB ".utf8)
        XCTAssertFalse(DisplayColorProfileEntry.isUsableHeader(Data(native)))
    }

    func testFactorySelectionIsDistinctFromCustomOverrideUsingSameFile() throws {
        let url = URL(fileURLWithPath: "/Library/ColorSync/Profiles/Example.icc")
        let factory = try DisplayColorProfileDeviceSelection.parse(deviceInfo(factoryURL: url))
        let custom = try DisplayColorProfileDeviceSelection.parse(deviceInfo(factoryURL: url, custom: url))
        XCTAssertEqual(factory.factoryURL, url)
        XCTAssertEqual(factory.selectedID, DisplayColorProfileOption.factoryID)
        XCTAssertEqual(custom.selectedID, url.absoluteString)
    }

    func testExplicitNullClearsOverrideAndMalformedCustomURLIsRejected() throws {
        let url = URL(fileURLWithPath: "/Library/ColorSync/Profiles/Example.icc")
        let reset = try DisplayColorProfileDeviceSelection.parse(deviceInfo(factoryURL: url, custom: NSNull()))
        XCTAssertEqual(reset.selectedID, DisplayColorProfileOption.factoryID)
        XCTAssertThrowsError(try DisplayColorProfileDeviceSelection.parse(deviceInfo(factoryURL: url, custom: "invalid")))
        XCTAssertThrowsError(try DisplayColorProfileDeviceSelection.parse(deviceInfo(factoryURL: url, custom: URL(string: "https://example.test/a.icc")!)))
        XCTAssertThrowsError(try DisplayColorProfileDeviceSelection.parse([:]))
    }

    func testDefaultProfileAliasAndConcreteIDBothResolveCustomOverride() throws {
        let url = URL(fileURLWithPath: "/Library/ColorSync/Profiles/Example.icc")
        var info = deviceInfo(factoryURL: url)
        info[kColorSyncCustomProfiles.takeUnretainedValue() as String] = [kColorSyncDeviceDefaultProfileID.takeUnretainedValue() as String: url]
        XCTAssertEqual(try DisplayColorProfileDeviceSelection.parse(info).selectedID, url.absoluteString)
    }

    func testUnknownHDMILegacySlotDoesNotProveActiveCustomProfile() throws {
        let url = URL(fileURLWithPath: "/Library/ColorSync/Profiles/Example.icc")
        let info = hdmiDeviceInfo(factoryURL: url, legacyURL: url)
        XCTAssertEqual(try DisplayColorProfileDeviceSelection.parse(info, currentURL: url).selectedID, DisplayColorProfileOption.factoryID)
        XCTAssertEqual(try DisplayColorProfileDeviceSelection.parse(info).selectedID, DisplayColorProfileOption.factoryID)
        let other = URL(fileURLWithPath: "/Library/ColorSync/Profiles/Other.icc")
        XCTAssertEqual(try DisplayColorProfileDeviceSelection.parse(info, currentURL: other).selectedID, DisplayColorProfileOption.factoryID)
    }

    func testExplicitDefaultNullWinsOverMatchingLegacySlot() throws {
        let url = URL(fileURLWithPath: "/Library/ColorSync/Profiles/Example.icc")
        for key in ["HDMI HD", kColorSyncDeviceDefaultProfileID.takeUnretainedValue() as String] {
            var info = hdmiDeviceInfo(factoryURL: url, legacyURL: url)
            var custom = info[kColorSyncCustomProfiles.takeUnretainedValue() as String] as! [String: Any]
            custom[key] = NSNull()
            info[kColorSyncCustomProfiles.takeUnretainedValue() as String] = custom
            XCTAssertEqual(try DisplayColorProfileDeviceSelection.parse(info, currentURL: url).selectedID,
                           DisplayColorProfileOption.factoryID)
        }
    }

    func testHDMILegacySlotsIgnoreDormantProfilesAndExplicitDefaultWins() throws {
        let url = URL(fileURLWithPath: "/Library/ColorSync/Profiles/Example.icc")
        let other = URL(fileURLWithPath: "/Library/ColorSync/Profiles/Other.icc")
        var info = hdmiDeviceInfo(factoryURL: url, legacyURL: other)
        XCTAssertEqual(try DisplayColorProfileDeviceSelection.parse(info, currentURL: url).selectedID, DisplayColorProfileOption.factoryID)
        info[kColorSyncCustomProfiles.takeUnretainedValue() as String] = ["1": url, "2": other]
        XCTAssertEqual(try DisplayColorProfileDeviceSelection.parse(info, currentURL: url).selectedID, DisplayColorProfileOption.factoryID)
        info[kColorSyncCustomProfiles.takeUnretainedValue() as String] = ["1": url, "HDMI HD": other]
        XCTAssertEqual(try DisplayColorProfileDeviceSelection.parse(info, currentURL: url).selectedID, other.absoluteString)
    }

    func testRegisteredDefaultFactoryFlagIsAuthoritativeForSameProfileFile() throws {
        let url = URL(fileURLWithPath: "/Library/ColorSync/Profiles/Example.icc")
        let info = hdmiDeviceInfo(factoryURL: url, legacyURL: url)
        XCTAssertEqual(try DisplayColorProfileDeviceSelection.parse(info, currentURL: url, defaultIsFactory: true).selectedID,
                       DisplayColorProfileOption.factoryID)
        XCTAssertEqual(try DisplayColorProfileDeviceSelection.parse(info, currentURL: url, defaultIsFactory: false).selectedID,
                       url.absoluteString)
    }

    func testConcreteProfileIDPayloadDoesNotWriteDefaultAliasOrAnyUserScope() {
        let payload = SystemDisplayColorProfileDriver.customProfileDictionary(nil, profileID: "HDMI HD")
        XCTAssertTrue(payload["HDMI HD"] is NSNull)
        XCTAssertNil(payload[kColorSyncDeviceDefaultProfileID.takeUnretainedValue() as String])
        XCTAssertEqual(payload[kColorSyncProfileUserScope.takeUnretainedValue() as String] as? String, kCFPreferencesCurrentUser as String)
    }

    func testFactoryResetPayloadUsesNullAndExplicitCurrentUserHostScopes() {
        let payload = SystemDisplayColorProfileDriver.customProfileDictionary(nil)
        XCTAssertTrue(payload[kColorSyncDeviceDefaultProfileID.takeUnretainedValue() as String] is NSNull)
        XCTAssertEqual(payload[kColorSyncProfileUserScope.takeUnretainedValue() as String] as? String, kCFPreferencesCurrentUser as String)
        XCTAssertEqual(payload[kColorSyncProfileHostScope.takeUnretainedValue() as String] as? String, kCFPreferencesCurrentHost as String)
        let url = URL(fileURLWithPath: "/Library/ColorSync/Profiles/Example.icc")
        XCTAssertEqual(SystemDisplayColorProfileDriver.customProfileDictionary(url)[kColorSyncDeviceDefaultProfileID.takeUnretainedValue() as String] as? URL, url)
    }

    @MainActor
    func testStateIncludesFactoryAndCurrentCustomProfileAndCachesInstalledCatalog() async throws {
        let driver = FakeColorProfileDriver()
        let current = DisplayColorProfileEntry(url: URL(fileURLWithPath: "/Library/ColorSync/Profiles/Current.icc"), name: "Current")
        driver.selection = .init(factoryURL: nil, customURL: current.url, currentURL: current.url)
        driver.validProfiles = [current]
        let service = ColorSyncDisplayColorProfileService(driver: driver)
        let first = try await service.state(for: display())
        _ = try await service.state(for: display())
        XCTAssertEqual(first.options.map(\.id), [DisplayColorProfileOption.factoryID, current.option.id])
        XCTAssertEqual(first.selectedID, current.option.id)
        XCTAssertEqual(driver.catalogReads, 1)
    }

    @MainActor
    func testCustomSelectionAndFactoryResetCallDriverWithDifferentValues() async throws {
        let driver = FakeColorProfileDriver()
        let profile = DisplayColorProfileEntry(url: URL(fileURLWithPath: "/Library/ColorSync/Profiles/Example.icc"), name: "Example")
        driver.installed = [profile]
        driver.validProfiles = [profile]
        let service = ColorSyncDisplayColorProfileService(driver: driver)
        try await service.setProfile(profile.option.id, for: display())
        try await service.setProfile(DisplayColorProfileOption.factoryID, for: display())
        XCTAssertEqual(driver.writes.count, 2)
        XCTAssertEqual(driver.writes[0], profile.url)
        XCTAssertNil(driver.writes[1])
    }

    @MainActor
    func testUnknownProfileIDCannotBecomeArbitraryFileWrite() async {
        let driver = FakeColorProfileDriver()
        let service = ColorSyncDisplayColorProfileService(driver: driver)
        do {
            try await service.setProfile("file:///tmp/unlisted.icc", for: display())
            XCTFail("Unlisted profiles must be rejected")
        } catch {
            XCTAssertTrue(driver.writes.isEmpty)
        }
    }

    @MainActor
    func testReusedDisplayIDAndDisabledDisplayNeverReadOrWriteColorSyncState() async {
        let driver = FakeColorProfileDriver()
        driver.uuid = "OTHER-DISPLAY"
        let service = ColorSyncDisplayColorProfileService(driver: driver)
        for target in [display(), display(enabled: false)] {
            do {
                _ = try await service.state(for: target)
                XCTFail("Stale/disabled display must be rejected")
            } catch { }
            do {
                try await service.setProfile(DisplayColorProfileOption.factoryID, for: target)
                XCTFail("Stale/disabled display must be rejected")
            } catch { }
        }
        XCTAssertEqual(driver.deviceReads, 0)
        XCTAssertTrue(driver.writes.isEmpty)
    }

    @MainActor
    func testIdentityIsRecheckedAfterCatalogWorkBeforeApplyingProfile() async {
        let driver = FakeColorProfileDriver()
        let profile = DisplayColorProfileEntry(url: URL(fileURLWithPath: "/Library/ColorSync/Profiles/Example.icc"), name: "Example")
        driver.installed = [profile]
        driver.validProfiles = [profile]
        driver.disconnectAfterCatalogRead = true
        let service = ColorSyncDisplayColorProfileService(driver: driver)
        do {
            try await service.setProfile(profile.option.id, for: display())
            XCTFail("Display identity changed during catalog load")
        } catch {
            XCTAssertTrue(driver.writes.isEmpty)
        }
    }

    @MainActor
    func testSuccessfulColorSyncReturnWithoutMatchingReadbackIsReportedAsFailure() async {
        let driver = FakeColorProfileDriver()
        let profile = DisplayColorProfileEntry(url: URL(fileURLWithPath: "/Library/ColorSync/Profiles/Example.icc"), name: "Example")
        driver.installed = [profile]
        driver.validProfiles = [profile]
        driver.ignoreWrites = true
        let service = ColorSyncDisplayColorProfileService(driver: driver)
        do {
            try await service.setProfile(profile.option.id, for: display())
            XCTFail("A successful API return must not hide a mismatched readback")
        } catch { XCTAssertEqual(driver.writes.count, 1) }
    }

    @MainActor
    func testExplicitFactoryFileCanCoalesceIntoNativeFactorySelection() async throws {
        let driver = FakeColorProfileDriver()
        let profile = DisplayColorProfileEntry(url: URL(fileURLWithPath: "/Library/ColorSync/Profiles/Example.icc"), name: "Example")
        driver.selection = .init(factoryURL: profile.url, customURL: nil, currentURL: profile.url)
        driver.installed = [profile]
        driver.validProfiles = [profile]
        driver.ignoreWrites = true
        let service = ColorSyncDisplayColorProfileService(driver: driver)
        try await service.setProfile(profile.option.id, for: display())
        let selected = try await service.state(for: display())
        XCTAssertEqual(selected.selectedID, DisplayColorProfileOption.factoryID)
    }

    private func hdmiDeviceInfo(factoryURL: URL, legacyURL: URL) -> [String: Any] {
        [kColorSyncFactoryProfiles.takeUnretainedValue() as String:
            [kColorSyncDeviceDefaultProfileID.takeUnretainedValue() as String: "HDMI HD",
             "HDMI HD": [kColorSyncDeviceProfileURL.takeUnretainedValue() as String: factoryURL]],
         kColorSyncCustomProfiles.takeUnretainedValue() as String: ["1": legacyURL]]
    }

    private func deviceInfo(factoryURL: URL, custom: Any? = nil) -> [String: Any] {
        var info: [String: Any] = [kColorSyncFactoryProfiles.takeUnretainedValue() as String:
                                    [kColorSyncDeviceDefaultProfileID.takeUnretainedValue() as String: "1",
                                     "1": [kColorSyncDeviceProfileURL.takeUnretainedValue() as String: factoryURL]]]
        if let custom { info[kColorSyncCustomProfiles.takeUnretainedValue() as String] = ["1": custom] }
        return info
    }

    private func header(profileClass: String = "mntr", colorSpace: String = "RGB ", signature: String = "acsp") -> Data {
        var bytes = [UInt8](repeating: 0, count: 128)
        bytes.replaceSubrange(12..<16, with: profileClass.utf8)
        bytes.replaceSubrange(16..<20, with: colorSpace.utf8)
        bytes.replaceSubrange(36..<40, with: signature.utf8)
        return Data(bytes)
    }

    private func display(enabled: Bool = true) -> DisplayInfo {
        DisplayInfo(id: "TEST-DISPLAY", displayID: 7, name: "Test", isBuiltin: false, isMain: false,
                    mirrorMasterID: nil, modes: [], currentMode: nil, isEnabled: enabled)
    }
}

private final class FakeColorProfileDriver: DisplayColorProfileDriving, @unchecked Sendable {
    // Tests only mutate fixtures before awaiting service work; the worker actor
    // serializes every protocol call. The lock also protects observations.
    private let lock = NSLock()
    var uuid = "TEST-DISPLAY"
    var selection = DisplayColorProfileDeviceSelection(factoryURL: nil, customURL: nil, currentURL: nil)
    var installed: [DisplayColorProfileEntry] = []
    var validProfiles: [DisplayColorProfileEntry] = []
    var disconnectAfterCatalogRead = false
    var ignoreWrites = false
    private(set) var catalogReads = 0
    private(set) var deviceReads = 0
    private(set) var writes: [URL?] = []

    func activeDisplayUUID(for displayID: UInt32) -> String? { lock.withLock { uuid } }
    func deviceSelection(uuid: String, displayID: UInt32) throws -> DisplayColorProfileDeviceSelection {
        lock.withLock { deviceReads += 1; return selection }
    }
    func installedProfiles() throws -> [DisplayColorProfileEntry] {
        lock.withLock {
            catalogReads += 1
            if disconnectAfterCatalogRead { uuid = "REPLACEMENT" }
            return installed
        }
    }
    func profile(at url: URL) -> DisplayColorProfileEntry? { lock.withLock { validProfiles.first { $0.url == url } } }
    func setCustomProfile(_ url: URL?, uuid: String) throws {
        lock.withLock {
            writes.append(url)
            if !ignoreWrites {
                selection = .init(factoryURL: selection.factoryURL, customURL: url,
                                  currentURL: url ?? selection.factoryURL)
            }
        }
    }
}

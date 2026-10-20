import Darwin
import Foundation
import XCTest
@testable import NotchApp

final class DisplaySmoothScalingServiceTests: XCTestCase {
    func testPlannerEncodesNewIntermediateTwoTimesBackingSizes() throws {
        let sizes = try DisplaySmoothScalingPlan.sizes(native: .init(width: 5120, height: 1440))
        XCTAssertEqual(sizes.count, 161)
        XCTAssertTrue(sizes.contains(.init(width: 5104, height: 1436)))
        XCTAssertEqual(DisplaySmoothScalingPlan.encode(.init(width: 1920, height: 1080)),
            Data([0, 0, 15, 0, 0, 0, 8, 112]))
        XCTAssertFalse(DisplaySmoothScalingPlan.isDense([.init(width: 2560, height: 720)], native: .init(width: 5120, height: 1440)))
    }

    func testInstallPersistsOwnedJournalAndTruthfulPendingStateThenCatalogConfirms() async throws {
        let fixture = try SmoothScalingFixture(), service = fixture.service()
        let off = try await service.read(fixture.target)
        XCTAssertEqual(off?.isEnabled, false)
        let installed = try await service.setEnabled(true, for: fixture.target)
        XCTAssertTrue(installed.isEnabled)
        XCTAssertTrue(installed.canModify)
        XCTAssertTrue(installed.needsReconnect)
        let calls = await fixture.installer.callCount()
        XCTAssertEqual(calls, 1)
        let journal = try XCTUnwrap(fixture.files.readJournal(fixture.display.value()))
        XCTAssertEqual(journal.phase, .installed)
        fixture.display.available(journal.requested)
        let active = try await fixture.service().read(fixture.target)
        XCTAssertEqual(active?.isEnabled, true)
        XCTAssertEqual(active?.needsReconnect, false)
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.files.journalURL(vendor: 123, product: 456).path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testDisableEnableDisableBeforeReconnectPreservesOriginalBaseline() async throws {
        let fixture = try SmoothScalingFixture(), service = fixture.service()
        _ = try await service.setEnabled(true, for: fixture.target)
        let original = try XCTUnwrap(fixture.files.readJournal(fixture.display.value()))
        fixture.display.available(original.requested)
        let removed = try await service.setEnabled(false, for: fixture.target)
        XCTAssertFalse(removed.isEnabled)
        XCTAssertTrue(removed.needsReconnect)
        _ = try await service.setEnabled(true, for: fixture.target)
        let again = try XCTUnwrap(fixture.files.readJournal(fixture.display.value()))
        XCTAssertEqual(again.baseline, original.baseline)
        let twice = try await service.setEnabled(false, for: fixture.target)
        XCTAssertTrue(twice.needsReconnect)
        fixture.display.available(original.baseline)
        let final = try await fixture.service().read(fixture.target)
        XCTAssertEqual(final?.needsReconnect, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.files.overrideURL(fixture.display.value()).path))
    }

    func testForeignDenseOverrideIsReadOnlyAndNeverAdopted() async throws {
        let fixture = try SmoothScalingFixture(), service = fixture.service()
        let requested = try DisplaySmoothScalingPlan.sizes(native: fixture.display.value().nativeSize)
        let foreign = try PropertyListSerialization.data(fromPropertyList: ["scale-resolutions": requested.map(DisplaySmoothScalingPlan.encode), "ForeignKey": "keep"], format: .xml, options: 0)
        try fixture.writeOverride(foreign)
        fixture.display.available(requested)
        let state = try await service.read(fixture.target)
        XCTAssertEqual(state?.isEnabled, true)
        XCTAssertEqual(state?.canModify, false)
        XCTAssertTrue(state?.detail?.contains("другим приложением") == true)
        await assertError(.foreignManaged) { _ = try await service.setEnabled(false, for: fixture.target) }
        await assertError(.foreignManaged) { _ = try await service.setEnabled(true, for: fixture.target) }
        XCTAssertEqual(try Data(contentsOf: fixture.files.overrideURL(fixture.display.value())), foreign)
        let calls = await fixture.installer.callCount()
        XCTAssertEqual(calls, 0)
    }

    func testForeignOrdinaryOverrideIsNotMisreportedAsDenseScaling() async throws {
        let fixture = try SmoothScalingFixture()
        try fixture.writeOverride(try PropertyListSerialization.data(fromPropertyList: ["DisplayProductName": "foreign"], format: .xml, options: 0))
        let state = try await fixture.service().read(fixture.target)
        XCTAssertEqual(state?.isEnabled, false)
        XCTAssertEqual(state?.canModify, false)
    }

    func testDisjointForeignFileAndCatalogDenseSubsetsAreNotReportedAsLoaded() async throws {
        let fixture = try SmoothScalingFixture()
        let grid = try DisplaySmoothScalingPlan.sizes(native: fixture.display.value().nativeSize).sorted { $0.width < $1.width }
        let plist = ["scale-resolutions": grid.prefix(8).map(DisplaySmoothScalingPlan.encode)]
        try fixture.writeOverride(PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0))
        fixture.display.available(Set(grid.dropFirst(8).prefix(8)))
        let state = try await fixture.service().read(fixture.target)
        XCTAssertEqual(state?.isEnabled, false)
        XCTAssertEqual(state?.canModify, false)
    }

    func testForeignModifiedOwnedFileAndKeysArePreservedOnConflict() async throws {
        let fixture = try SmoothScalingFixture(), service = fixture.service()
        _ = try await service.setEnabled(true, for: fixture.target)
        let url = fixture.files.overrideURL(fixture.display.value())
        var plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        plist["ForeignKey"] = "keep"
        let modified = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try modified.write(to: url)
        await assertError(.conflict) { _ = try await service.setEnabled(false, for: fixture.target) }
        XCTAssertEqual(try Data(contentsOf: url), modified)
        let calls = await fixture.installer.callCount()
        XCTAssertEqual(calls, 1)
    }

    func testAuthorizationCancellationLeavesNoRootFileAndRetryablePreparedJournal() async throws {
        let fixture = try SmoothScalingFixture()
        await fixture.installer.fail(with: .authorization)
        await assertError(.authorization) { _ = try await fixture.service().setEnabled(true, for: fixture.target) }
        XCTAssertNil(try fixture.files.readOverride(fixture.display.value()))
        let journal = try XCTUnwrap(fixture.files.readJournal(fixture.display.value()))
        XCTAssertEqual(journal.phase, .prepared)
        let state = try await fixture.service().read(fixture.target)
        XCTAssertEqual(state?.isEnabled, false)
        XCTAssertEqual(state?.canModify, true)
        XCTAssertEqual(state?.needsReconnect, false)
    }

    func testCrashAfterRootCommitWithPreparedJournalIsRecoveredReadOnly() async throws {
        let fixture = try SmoothScalingFixture()
        let journal = try DisplaySmoothScalingPlan.journal(for: fixture.display.value())
        try fixture.files.writeJournal(journal)
        try fixture.writeOverride(journal.payload)
        let state = try await fixture.service().read(fixture.target)
        XCTAssertEqual(state?.isEnabled, true)
        XCTAssertEqual(state?.needsReconnect, true)
        let calls = await fixture.installer.callCount()
        XCTAssertEqual(calls, 0)
    }

    func testCorruptJournalPreventsAnySystemMutation() async throws {
        let fixture = try SmoothScalingFixture()
        let journal = try DisplaySmoothScalingPlan.journal(for: fixture.display.value())
        try fixture.files.writeJournal(journal)
        let url = fixture.files.journalURL(vendor: 123, product: 456)
        try Data("broken".utf8).write(to: url)
        await assertError(.invalidJournal) { _ = try await fixture.service().setEnabled(true, for: fixture.target) }
        let calls = await fixture.installer.callCount()
        XCTAssertEqual(calls, 0)
    }

    func testFreshIdentityIsRecheckedBeforeInstallerRuns() async throws {
        let fixture = try SmoothScalingFixture()
        let resolve = SmoothScalingResolutionGate(display: fixture.display.value())
        let service = SystemDisplaySmoothScalingService(files: fixture.files, installer: fixture.installer,
            resolve: { target in try resolve.resolve(target) })
        await assertError(.disconnected) { _ = try await service.setEnabled(true, for: fixture.target) }
        let calls = await fixture.installer.callCount()
        XCTAssertEqual(calls, 0)
    }

    func testRootFixtureRejectsRaceCreatedForeignDestinationWithoutOverwrite() async throws {
        let fixture = try SmoothScalingFixture()
        let journal = try DisplaySmoothScalingPlan.journal(for: fixture.display.value())
        let foreign = Data("foreign".utf8)
        try fixture.writeOverride(foreign)
        let result = try await fixture.runRoot(fixture.request(.install, journal: journal))
        XCTAssertNotEqual(result.status, 0)
        XCTAssertEqual(try Data(contentsOf: fixture.files.overrideURL(fixture.display.value())), foreign)
    }

    func testRootFixtureRejectsSymlinkDirectoryAndFile() async throws {
        let fixture = try SmoothScalingFixture()
        let journal = try DisplaySmoothScalingPlan.journal(for: fixture.display.value())
        let destination = fixture.files.overrideURL(fixture.display.value()), vendor = destination.deletingLastPathComponent()
        let outside = fixture.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: vendor, withDestinationURL: outside)
        let directoryResult = try await fixture.runRoot(fixture.request(.install, journal: journal))
        XCTAssertNotEqual(directoryResult.status, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent(destination.lastPathComponent).path))
        try FileManager.default.removeItem(at: vendor)
        try FileManager.default.createDirectory(at: vendor, withIntermediateDirectories: true)
        let outsideFile = outside.appendingPathComponent("keep")
        try Data("keep".utf8).write(to: outsideFile)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: outsideFile)
        let fileResult = try await fixture.runRoot(fixture.request(.install, journal: journal))
        XCTAssertNotEqual(fileResult.status, 0)
        XCTAssertEqual(try String(contentsOf: outsideFile, encoding: .utf8), "keep")
    }

    func testRootFixtureRejectsWrongOwnerMarkerAndChangedExpectedHash() async throws {
        let fixture = try SmoothScalingFixture()
        let journal = try DisplaySmoothScalingPlan.journal(for: fixture.display.value())
        let wrongOwner = DisplaySmoothScalingInstallRequest(operation: .install, display: fixture.display.value(), callerUID: getuid(),
            owner: UUID(), expectedHash: nil, payload: journal.payload)
        let marker = try await fixture.runRoot(wrongOwner)
        XCTAssertNotEqual(marker.status, 0)
        XCTAssertTrue(marker.output.contains("E_MARKER"))
        try fixture.writeOverride(journal.payload)
        let wrongHash = DisplaySmoothScalingInstallRequest(operation: .remove, display: fixture.display.value(), callerUID: getuid(),
            owner: journal.owner, expectedHash: String(repeating: "0", count: 64), payload: journal.payload)
        let cas = try await fixture.runRoot(wrongHash)
        XCTAssertNotEqual(cas.status, 0)
        XCTAssertEqual(try Data(contentsOf: fixture.files.overrideURL(fixture.display.value())), journal.payload)
    }

    func testProductionRootCommandUsesFixedPathFreshIdentityAndClearedEnvironment() throws {
        let fixture = try SmoothScalingFixture()
        let journal = try DisplaySmoothScalingPlan.journal(for: fixture.display.value())
        let command = DisplaySmoothScalingRootCommand.command(fixture.request(.install, journal: journal))
        XCTAssertTrue(command.hasPrefix("'/usr/bin/env' '-i'"))
        XCTAssertTrue(command.contains("/Library/Displays/Contents/Resources/Overrides"))
        XCTAssertTrue(DisplaySmoothScalingRootCommand.script.contains("/bin/launchctl"))
        XCTAssertTrue(DisplaySmoothScalingRootCommand.script.contains("E_IDENTITY"))
        XCTAssertTrue(DisplaySmoothScalingRootCommand.script.contains("O_NOFOLLOW"))
        XCTAssertFalse(DisplaySmoothScalingRootCommand.script.contains("#(ownerUID)"))
        XCTAssertFalse(DisplaySmoothScalingRootCommand.script.contains("#(check)"))
    }

    func testPlannerNeverRequestsTwoTimesBackingBeyond16384Pixels() throws {
        let sizes = try DisplaySmoothScalingPlan.sizes(native: .init(width: 12000, height: 7000))
        XCTAssertTrue(sizes.allSatisfy { $0.width * 2 <= 16384 && $0.height * 2 <= 16384 })
        XCTAssertThrowsError(try DisplaySmoothScalingPlan.sizes(native: .init(width: 16384, height: 16384)))
        XCTAssertEqual(try DisplaySmoothScalingPlan.sizes(native: .init(width: 5120, height: 1440)).count, 161)
    }

    func testRootIndependentlyRejectsForeignKeysIDsMalformedDataAndOversizedBacking() async throws {
        let fixture = try SmoothScalingFixture()
        let journal = try DisplaySmoothScalingPlan.journal(for: fixture.display.value())
        let original = try XCTUnwrap(PropertyListSerialization.propertyList(from: journal.payload, format: nil) as? [String: Any])
        var extra = original; extra["IODisplayEDID"] = Data([1, 2])
        var wrongVendor = original; wrongVendor["DisplayVendorID"] = 999
        var shortData = original; shortData["scale-resolutions"] = [Data([1]), Data([2])]
        var oversized = original; oversized["scale-resolutions"] = [DisplaySmoothScalingPlan.encode(.init(width: 8193, height: 1000)), DisplaySmoothScalingPlan.encode(.init(width: 800, height: 600))]
        var tooMany = original; tooMany["scale-resolutions"] = Array(repeating: DisplaySmoothScalingPlan.encode(.init(width: 800, height: 600)), count: 513)
        for plist in [extra, wrongVendor, shortData, oversized, tooMany] {
            let payload = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            let request = DisplaySmoothScalingInstallRequest(operation: .install, display: fixture.display.value(), callerUID: getuid(), owner: journal.owner, expectedHash: nil, payload: payload)
            let result = try await fixture.runRoot(request)
            XCTAssertNotEqual(result.status, 0)
            XCTAssertTrue(result.output.contains("E_SCHEMA"), result.output)
            XCTAssertNil(try fixture.files.readOverride(fixture.display.value()))
        }
    }

    func testCrashAfterRemovalKeepsReconnectPendingUntilOldModesDisappear() async throws {
        let fixture = try SmoothScalingFixture()
        var journal = try DisplaySmoothScalingPlan.journal(for: fixture.display.value())
        journal.phase = .removing
        try fixture.files.writeJournal(journal)
        fixture.display.available(journal.requested)
        let pending = try await fixture.service().read(fixture.target)
        XCTAssertEqual(pending?.isEnabled, false)
        XCTAssertEqual(pending?.needsReconnect, true)
        fixture.display.available(journal.baseline)
        let settled = try await fixture.service().read(fixture.target)
        XCTAssertEqual(settled?.needsReconnect, false)
    }

    func testConcurrentUserCommandsCannotStartDuplicateAuthorization() async throws {
        let fixture = try SmoothScalingFixture()
        let entered = expectation(description: "installer entered")
        let installer = SmoothScalingWaitingInstaller(entered: { entered.fulfill() })
        let service = SystemDisplaySmoothScalingService(files: fixture.files, installer: installer, resolve: { [display = fixture.display] _ in display.value() })
        let first = Task { try await service.setEnabled(true, for: fixture.target) }
        await fulfillment(of: [entered], timeout: 2)
        await assertError(.busy) { _ = try await service.setEnabled(true, for: fixture.target) }
        await installer.release()
        do { _ = try await first.value; XCTFail("Expected injected authorization cancellation") }
        catch { XCTAssertEqual(error as? DisplaySmoothScalingError, .authorization) }
        let calls = await installer.callCount()
        XCTAssertEqual(calls, 1)
    }

    private func assertError(_ expected: DisplaySmoothScalingError, _ operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected \(expected)") }
        catch { XCTAssertEqual(error as? DisplaySmoothScalingError, expected) }
    }
}

private actor SmoothScalingWaitingInstaller: DisplaySmoothScalingInstalling {
    private let entered: @Sendable () -> Void
    private var gate: CheckedContinuation<Void, Never>?
    private var calls = 0
    init(entered: @escaping @Sendable () -> Void) { self.entered = entered }
    func apply(_ request: DisplaySmoothScalingInstallRequest) async throws {
        calls += 1
        await withCheckedContinuation { continuation in gate = continuation; entered() }
        throw DisplaySmoothScalingError.authorization
    }
    func release() { gate?.resume(); gate = nil }
    func callCount() -> Int { calls }
}

private final class SmoothScalingDisplayBox: @unchecked Sendable {
    private let lock = NSLock()
    private var display: DisplaySmoothScalingDisplay
    init(_ display: DisplaySmoothScalingDisplay) { self.display = display }
    func value() -> DisplaySmoothScalingDisplay { lock.lock(); defer { lock.unlock() }; return display }
    func available(_ sizes: Set<DisplaySmoothScalingSize>) {
        lock.lock(); defer { lock.unlock() }
        display = .init(target: display.target, vendor: display.vendor, product: display.product,
            nativeSize: display.nativeSize, availableHiDPI: sizes)
    }
}

private final class SmoothScalingResolutionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let display: DisplaySmoothScalingDisplay
    init(display: DisplaySmoothScalingDisplay) { self.display = display }
    func resolve(_ target: DisplayHardwareTarget) throws -> DisplaySmoothScalingDisplay? {
        lock.lock(); defer { lock.unlock() }; calls += 1
        guard calls == 1 else { throw DisplaySmoothScalingError.disconnected }
        return display
    }
}

private actor SmoothScalingFixtureInstaller: DisplaySmoothScalingInstalling {
    let root: URL
    private var calls = 0
    private var failure: DisplaySmoothScalingError?
    init(root: URL) { self.root = root }
    func fail(with error: DisplaySmoothScalingError) { failure = error }
    func callCount() -> Int { calls }
    func apply(_ request: DisplaySmoothScalingInstallRequest) async throws {
        calls += 1
        if let failure { throw failure }
        let result = try await AuthorizedDisplaySmoothScalingInstaller.run(executable: "/usr/bin/perl", arguments:
            ["-e", DisplaySmoothScalingRootCommand.fixtureScript(base: root, ownerUID: getuid()), "--"] + DisplaySmoothScalingRootCommand.arguments(request))
        guard result.status == 0 else { throw DisplaySmoothScalingError.conflict }
    }
}

private final class SmoothScalingFixture: @unchecked Sendable {
    let root: URL
    let files: DisplaySmoothScalingFiles
    let installer: SmoothScalingFixtureInstaller
    let display: SmoothScalingDisplayBox
    var target: DisplayHardwareTarget { display.value().target }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("NooL smooth '\(UUID().uuidString)", isDirectory: true)
        let overrides = root.appendingPathComponent("overrides", isDirectory: true)
        try FileManager.default.createDirectory(at: overrides, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        files = .init(overrides: overrides, journals: root.appendingPathComponent("journals", isDirectory: true), expectedOwner: getuid())
        installer = SmoothScalingFixtureInstaller(root: overrides)
        display = SmoothScalingDisplayBox(.init(target: .init(uuid: "01234567-89AB-CDEF-0123-456789ABCDEF", displayID: 3, isBuiltin: false),
            vendor: 123, product: 456, nativeSize: .init(width: 2560, height: 1440), availableHiDPI: [.init(width: 1280, height: 720)]))
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func service() -> SystemDisplaySmoothScalingService {
        SystemDisplaySmoothScalingService(files: files, installer: installer, resolve: { [display] _ in display.value() })
    }
    func writeOverride(_ data: Data) throws {
        let url = files.overrideURL(display.value())
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
    }
    func request(_ operation: DisplaySmoothScalingInstallRequest.Operation, journal: DisplaySmoothScalingJournal) -> DisplaySmoothScalingInstallRequest {
        .init(operation: operation, display: display.value(), callerUID: getuid(), owner: journal.owner,
            expectedHash: operation == .remove ? journal.payloadHash : nil, payload: journal.payload)
    }
    func runRoot(_ request: DisplaySmoothScalingInstallRequest) async throws -> AuthorizedDisplaySmoothScalingInstaller.Result {
        try await AuthorizedDisplaySmoothScalingInstaller.run(executable: "/usr/bin/perl", arguments:
            ["-e", DisplaySmoothScalingRootCommand.fixtureScript(base: files.overrides, ownerUID: getuid()), "--"] + DisplaySmoothScalingRootCommand.arguments(request))
    }
}

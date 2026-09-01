import AppKit
import Darwin
import Foundation

enum NowPlayingPlaybackState: Equatable {
    case playing
    case paused
    case unknown

    var isPlaying: Bool {
        self == .playing
    }
}

struct NowPlayingSnapshot: Equatable {
    let id: String
    let title: String
    let artist: String
    let album: String?
    let appName: String?
    let applicationBundleIdentifier: String?
    let artworkData: Data?
    let duration: TimeInterval
    let elapsedTime: TimeInterval
    let playbackRate: Double
    let playbackState: NowPlayingPlaybackState
    let updatedAt: Date

    init(
        id: String,
        title: String,
        artist: String,
        album: String?,
        appName: String?,
        applicationBundleIdentifier: String? = nil,
        artworkData: Data?,
        duration: TimeInterval,
        elapsedTime: TimeInterval,
        playbackRate: Double,
        playbackState: NowPlayingPlaybackState,
        updatedAt: Date
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.appName = appName
        self.applicationBundleIdentifier = applicationBundleIdentifier
        self.artworkData = artworkData
        self.duration = duration
        self.elapsedTime = elapsedTime
        self.playbackRate = playbackRate
        self.playbackState = playbackState
        self.updatedAt = updatedAt
    }

    func elapsedTime(at date: Date) -> TimeInterval {
        guard playbackState.isPlaying else {
            return max(elapsedTime, 0)
        }

        let elapsed = elapsedTime + date.timeIntervalSince(updatedAt) * playbackRate
        return min(max(elapsed, 0), duration > 0 ? duration : elapsed)
    }

    func progress(at date: Date) -> Double {
        guard duration > 0 else { return 0 }
        return min(max(elapsedTime(at: date) / duration, 0), 1)
    }

    func isSemanticallyEquivalent(to other: NowPlayingSnapshot) -> Bool {
        guard id == other.id,
              title == other.title,
              artist == other.artist,
              album == other.album,
              appName == other.appName,
              applicationBundleIdentifier == other.applicationBundleIdentifier,
              artworkData == other.artworkData,
              abs(duration - other.duration) < 0.25,
              abs(playbackRate - other.playbackRate) < 0.01,
              playbackState == other.playbackState else {
            return false
        }

        let expectedElapsed = elapsedTime(at: other.updatedAt)
        let tolerance: TimeInterval = playbackState.isPlaying ? 1.5 : 0.5
        return abs(expectedElapsed - other.elapsedTime) <= tolerance
    }

    func replacingArtworkData(_ artworkData: Data) -> NowPlayingSnapshot {
        NowPlayingSnapshot(
            id: id,
            title: title,
            artist: artist,
            album: album,
            appName: appName,
            applicationBundleIdentifier: applicationBundleIdentifier,
            artworkData: artworkData,
            duration: duration,
            elapsedTime: elapsedTime,
            playbackRate: playbackRate,
            playbackState: playbackState,
            updatedAt: updatedAt
        )
    }
}

@MainActor
final class NowPlayingApplicationEventObserver {
    private let notificationCenter: NotificationCenter
    private let names: [Notification.Name]
    private var tokens: [NSObjectProtocol] = []
    private var onChange: (() -> Void)?

    init(
        notificationCenter: NotificationCenter,
        names: [Notification.Name]
    ) {
        self.notificationCenter = notificationCenter
        self.names = names
    }

    func start(onChange: @escaping () -> Void) {
        stop()
        self.onChange = onChange
        tokens = names.map { name in
            notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.onChange?()
                }
            }
        }
    }

    func stop() {
        tokens.forEach(notificationCenter.removeObserver)
        tokens.removeAll()
        onChange = nil
    }
}

enum NowPlayingPublicationPolicy {
    static func shouldPublish(
        previous: NowPlayingSnapshot?,
        next: NowPlayingSnapshot?
    ) -> Bool {
        switch (previous, next) {
        case (nil, nil):
            false
        case let (previous?, next?):
            previous.isSemanticallyEquivalent(to: next) == false
        default:
            true
        }
    }
}

enum NowPlayingSourcePolicy {
    static func accessibilitySnapshot(
        _ snapshot: NowPlayingSnapshot?
    ) -> NowPlayingSnapshot? {
        guard snapshot?.playbackState.isPlaying == true else { return nil }
        return snapshot
    }
}

struct NowPlayingRefreshGate {
    private var latestGeneration: UInt64 = 0

    mutating func beginRequest() -> UInt64 {
        latestGeneration &+= 1
        return latestGeneration
    }

    func accepts(_ generation: UInt64) -> Bool {
        generation == latestGeneration
    }

    mutating func invalidate() {
        latestGeneration &+= 1
    }
}

enum NowPlayingControlCommand: Equatable {
    case togglePlayPause
    case previousTrack
    case nextTrack
    case seek(to: TimeInterval)
}

struct MediaRemoteCommandRequest {
    let command: UInt32
    let options: [String: Any]

    init(command: UInt32, options: [String: Any] = [:]) {
        self.command = command
        self.options = options
    }
}

enum NowPlayingCommandDelivery: Equatable {
    case delivered
    case unavailable
    case noPlayer
    case rejected(UInt32)
    case timedOut
}

@MainActor
final class NowPlayingCommandRequest {
    private(set) var isFinished = false
    var timeoutTask: Task<Void, Never>?
    private var playerPath: AnyObject?
    private var isSendInFlight = false
    private let completion: @MainActor (NowPlayingCommandDelivery) -> Void

    init(completion: @escaping @MainActor (NowPlayingCommandDelivery) -> Void) {
        self.completion = completion
    }

    func beginSend(to playerPath: AnyObject) {
        guard isFinished == false else { return }
        self.playerPath = playerPath
        isSendInFlight = true
    }

    func completeSend(sendError: UInt32) {
        isSendInFlight = false
        playerPath = nil
        resolve(sendError == 0 ? .delivered : .rejected(sendError))
    }

    func sendDidNotStart() {
        isSendInFlight = false
        playerPath = nil
        resolve(.unavailable)
    }

    func resolve(_ delivery: NowPlayingCommandDelivery) {
        guard isFinished == false else { return }
        isFinished = true
        timeoutTask?.cancel()
        timeoutTask = nil
        if isSendInFlight == false {
            playerPath = nil
        }
        completion(delivery)
    }

    func cancel() {
        guard isFinished == false else { return }
        isFinished = true
        timeoutTask?.cancel()
        timeoutTask = nil
        if isSendInFlight == false {
            playerPath = nil
        }
    }
}

@MainActor
final class ElectedPlayerCommandTransport {
    typealias PlayerPathCompletion = @MainActor (AnyObject?) -> Void
    typealias IsPlayingCompletion = @MainActor (Bool) -> Void
    typealias DeliveryCompletion = @MainActor (NowPlayingCommandDelivery) -> Void
    typealias GetElectedPlayerPath = (@escaping PlayerPathCompletion) -> Bool
    typealias GetIsPlaying = (@escaping IsPlayingCompletion) -> Bool
    typealias SendCommand = (
        MediaRemoteCommandRequest,
        AnyObject,
        @escaping @MainActor (UInt32) -> Void
    ) -> Bool

    private let timeout: TimeInterval
    private let getElectedPlayerPath: GetElectedPlayerPath
    private let getIsPlaying: GetIsPlaying
    private let sendCommand: SendCommand

    init(
        timeout: TimeInterval = 1,
        getElectedPlayerPath: @escaping GetElectedPlayerPath,
        getIsPlaying: @escaping GetIsPlaying = { _ in false },
        sendCommand: @escaping SendCommand
    ) {
        self.timeout = timeout
        self.getElectedPlayerPath = getElectedPlayerPath
        self.getIsPlaying = getIsPlaying
        self.sendCommand = sendCommand
    }

    @discardableResult
    func send(
        _ command: NowPlayingControlCommand,
        completion: @escaping DeliveryCompletion
    ) -> NowPlayingCommandRequest {
        let request = NowPlayingCommandRequest(completion: completion)
        request.timeoutTask = Task { @MainActor in
            let nanoseconds = UInt64(max(0, timeout) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard Task.isCancelled == false else { return }
            request.resolve(.timedOut)
        }

        let lookupStarted = getElectedPlayerPath {
            [getIsPlaying, sendCommand] playerPath in
            guard request.isFinished == false else { return }
            guard let playerPath else {
                request.resolve(.noPlayer)
                return
            }

            let startSend: @MainActor (MediaRemoteCommandRequest) -> Void = {
                mediaRemoteRequest in
                guard request.isFinished == false else { return }
                request.beginSend(to: playerPath)
                let sendStarted = sendCommand(
                    mediaRemoteRequest,
                    playerPath
                ) { sendError in
                    request.completeSend(sendError: sendError)
                }
                if sendStarted == false {
                    request.sendDidNotStart()
                }
            }

            switch command {
            case .togglePlayPause:
                let stateLookupStarted = getIsPlaying { isPlaying in
                    startSend(MediaRemoteCommandRequest(command: isPlaying ? 1 : 0))
                }
                if stateLookupStarted == false {
                    request.resolve(.unavailable)
                }
            case .nextTrack:
                startSend(MediaRemoteCommandRequest(command: 4))
            case .previousTrack:
                startSend(MediaRemoteCommandRequest(command: 5))
            case .seek(let time):
                startSend(MediaRemoteCommandRequest(
                    command: 24,
                    options: [
                        "kMRMediaRemoteOptionPlaybackPosition": max(0, time)
                    ]
                ))
            }
        }
        if lookupStarted == false {
            request.resolve(.unavailable)
        }
        return request
    }
}

@MainActor
final class NowPlayingProvider: NowPlayingProviding {
    private let bridge = MediaRemoteBridge()
    private let accessibilitySource = AccessibilityNowPlayingSource()
    private let applicationEventObserver = NowPlayingApplicationEventObserver(
        notificationCenter: NSWorkspace.shared.notificationCenter,
        names: [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification
        ]
    )
    private lazy var commandTransport = ElectedPlayerCommandTransport(
        getElectedPlayerPath: { [bridge] completion in
            bridge.getElectedPlayerPath(completion: completion)
        },
        getIsPlaying: { [bridge] completion in
            bridge.getIsPlaying(completion: completion)
        },
        sendCommand: { [bridge] request, playerPath, completion in
            bridge.send(
                request: request,
                to: playerPath,
                completion: completion
            )
        }
    )
    private var notificationTokens: [NSObjectProtocol] = []
    private var pollingTask: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?
    private var commandRequest: NowPlayingCommandRequest?
    private var commandGeneration: UInt64 = 0
    private var hasStarted = false
    private var usesAccessibilityFallback = false
    private var pollingMode: NowPlayingPollingMode = .background
    private var refreshGate = NowPlayingRefreshGate()
    private var lastAccessibilitySample: NowPlayingSnapshot?

    private(set) var requiresAccessibilityAccess = false {
        didSet {
            guard oldValue != requiresAccessibilityAccess else { return }
            onAccessStateChange?(requiresAccessibilityAccess)
        }
    }

    private(set) var snapshot: NowPlayingSnapshot?
    private(set) var diagnostics = NowPlayingDiagnostics.unavailable {
        didSet {
            guard oldValue != diagnostics else { return }
            onDiagnosticsChange?(diagnostics)
        }
    }

    var onChange: ((NowPlayingSnapshot?) -> Void)?
    var onAccessStateChange: ((Bool) -> Void)?
    var onDiagnosticsChange: ((NowPlayingDiagnostics) -> Void)?

    init() {
        accessibilitySource.onMetadataChange = { [weak self] in
            guard let self, self.usesAccessibilityFallback else { return }
            self.refreshGate.invalidate()
            self.refreshFromAccessibility()
        }
        accessibilitySource.onArtworkChange = { [weak self] trackID, artworkData in
            guard let self,
                  self.usesAccessibilityFallback,
                  let snapshot = self.snapshot,
                  snapshot.id == trackID else {
                return
            }
            self.publishSnapshot(
                snapshot.replacingArtworkData(artworkData),
                source: .accessibility
            )
        }
    }

    func start() {
        guard hasStarted == false else { return }
        hasStarted = true

        if bridge.isAvailable {
            bridge.registerForNowPlayingNotifications()
            observeNowPlayingChanges()
        }
        applicationEventObserver.start { [weak self] in
            self?.refresh()
        }

        refresh()
        startPolling()
    }

    func stop() {
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
        notificationTokens.removeAll()
        pollingTask?.cancel()
        pollingTask = nil
        commandTask?.cancel()
        commandTask = nil
        commandRequest?.cancel()
        commandRequest = nil
        commandGeneration &+= 1
        bridge.unregisterForNowPlayingNotifications()
        applicationEventObserver.stop()
        accessibilitySource.stop()
        refreshGate.invalidate()
        hasStarted = false
        usesAccessibilityFallback = false
        lastAccessibilitySample = nil
    }

    func refresh() {
        let generation = refreshGate.beginRequest()
        guard bridge.isAvailable else {
            if refreshGate.accepts(generation) {
                refreshFromAccessibility()
            }
            return
        }

        bridge.getNowPlayingInfo { [weak self] info in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.refreshGate.accepts(generation) else { return }
                if self.apply(info: info) == false {
                    self.refreshFromAccessibility()
                }
            }
        }
    }

    func setPollingMode(_ mode: NowPlayingPollingMode) {
        guard pollingMode != mode else { return }
        pollingMode = mode
        if hasStarted {
            startPolling()
        }
    }

    func togglePlayPause() {
        executeControlCommand(.togglePlayPause)
    }

    func previousTrack() {
        executeControlCommand(.previousTrack)
    }

    func nextTrack() {
        executeControlCommand(.nextTrack)
    }

    func seek(to time: TimeInterval) {
        let target = max(0, time)
        if usesAccessibilityFallback,
           accessibilitySource.seek(to: target) {
            scheduleRefreshAfterControl(delay: 0.15)
            return
        }
        executeControlCommand(.seek(to: target))
    }

    func openPlayer() {
        guard let snapshot,
              let application = runningApplication(for: snapshot),
              application.bundleIdentifier != Bundle.main.bundleIdentifier else {
            return
        }
        application.activate(options: [.activateAllWindows])
    }

    private func executeControlCommand(_ command: NowPlayingControlCommand) {
        commandTask?.cancel()
        commandTask = nil
        commandRequest?.cancel()
        commandRequest = nil
        commandGeneration &+= 1
        let generation = commandGeneration
        refreshGate.invalidate()

        let request = commandTransport.send(command) { [weak self] delivery in
            guard let self else { return }
            self.commandRequest = nil
            guard self.commandGeneration == generation,
                  delivery == .delivered else {
                return
            }

            self.scheduleRefreshAfterControl(delay: 0.35)
        }
        commandRequest = request.isFinished ? nil : request
    }

    private func scheduleRefreshAfterControl(delay: TimeInterval) {
        commandTask?.cancel()
        commandTask = Task { @MainActor [weak self] in
            let nanoseconds = UInt64(max(0, delay) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard Task.isCancelled == false, let self else { return }
            self.commandTask = nil
            if self.usesAccessibilityFallback {
                self.refreshFromAccessibility()
            } else {
                self.refresh()
            }
        }
    }

    private func runningApplication(for snapshot: NowPlayingSnapshot) -> NSRunningApplication? {
        let applications = NSWorkspace.shared.runningApplications
        if let bundleIdentifier = snapshot.applicationBundleIdentifier,
           let exactBundleMatch = applications.first(where: {
               $0.bundleIdentifier == bundleIdentifier
           }) {
            return exactBundleMatch
        }
        guard let appName = snapshot.appName else { return nil }
        return applications.first {
            $0.localizedName?.compare(
                appName,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) == .orderedSame
        }
    }

    private func startPolling() {
        pollingTask?.cancel()
        let interval = pollingMode.interval
        pollingTask = Task { @MainActor [weak self] in
            while Task.isCancelled == false {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard Task.isCancelled == false else { return }
                self?.refresh()
            }
        }
    }

    private func refreshFromAccessibility() {
        publishAccessibilitySnapshot(accessibilitySource.snapshot())
    }

    private func publishAccessibilitySnapshot(_ nextSnapshot: NowPlayingSnapshot?) {
        usesAccessibilityFallback = true
        requiresAccessibilityAccess = accessibilitySource.requiresAccessibilityAccess
        let acceptedSnapshot = NowPlayingSourcePolicy.accessibilitySnapshot(nextSnapshot)
        defer { lastAccessibilitySample = acceptedSnapshot }

        guard isRepeatedAccessibilitySample(
            previous: lastAccessibilitySample,
            next: acceptedSnapshot
        ) == false else {
            recordObservation(acceptedSnapshot, source: .accessibility)
            return
        }

        publishSnapshot(acceptedSnapshot, source: .accessibility)
    }

    private func isRepeatedAccessibilitySample(
        previous: NowPlayingSnapshot?,
        next: NowPlayingSnapshot?
    ) -> Bool {
        guard let previous,
              let next,
              previous.playbackState.isPlaying,
              next.playbackState.isPlaying else {
            return false
        }

        return previous.id == next.id
            && previous.title == next.title
            && previous.artist == next.artist
            && previous.album == next.album
            && previous.appName == next.appName
            && previous.artworkData == next.artworkData
            && abs(previous.duration - next.duration) < 0.25
            && abs(previous.elapsedTime - next.elapsedTime) < 0.01
            && abs(previous.playbackRate - next.playbackRate) < 0.01
    }

    private func observeNowPlayingChanges() {
        let names = [
            Notification.Name("kMRMediaRemoteNowPlayingInfoDidChangeNotification"),
            Notification.Name("kMRMediaRemoteNowPlayingApplicationDidChangeNotification")
        ]

        notificationTokens = names.map { name in
            NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refresh()
                }
            }
        }
    }

    @discardableResult
    private func apply(info: NSDictionary?) -> Bool {
        guard let info,
              let title = stringValue(for: [
                  "kMRMediaRemoteNowPlayingInfoTitle",
                  "title"
              ], in: info),
              title.isEmpty == false else {
            return false
        }

        usesAccessibilityFallback = false
        requiresAccessibilityAccess = false
        lastAccessibilitySample = nil

        let artist = stringValue(for: [
            "kMRMediaRemoteNowPlayingInfoArtist",
            "artist"
        ], in: info) ?? "Неизвестный исполнитель"
        let album = stringValue(for: [
            "kMRMediaRemoteNowPlayingInfoAlbum",
            "album"
        ], in: info)
        let appName = stringValue(for: [
            "kMRMediaRemoteNowPlayingInfoAppDisplayName",
            "kMRMediaRemoteNowPlayingInfoPlayerName",
            "appName"
        ], in: info)
        let applicationBundleIdentifier = stringValue(for: [
            "kMRMediaRemoteNowPlayingInfoApplicationBundleIdentifier",
            "kMRMediaRemoteNowPlayingInfoAppBundleIdentifier",
            "bundleIdentifier"
        ], in: info)
        let duration = doubleValue(for: [
            "kMRMediaRemoteNowPlayingInfoDuration",
            "duration"
        ], in: info) ?? 0
        let elapsedTime = doubleValue(for: [
            "kMRMediaRemoteNowPlayingInfoElapsedTime",
            "elapsedTime"
        ], in: info) ?? 0
        let playbackRate = doubleValue(for: [
            "kMRMediaRemoteNowPlayingInfoPlaybackRate",
            "playbackRate"
        ], in: info) ?? 0
        let artworkData = dataValue(for: [
            "kMRMediaRemoteNowPlayingInfoArtworkData",
            "artworkData"
        ], in: info)
        let id = stringValue(for: [
            "kMRMediaRemoteNowPlayingInfoUniqueIdentifier",
            "kMRMediaRemoteNowPlayingInfoContentItemIdentifier",
            "uniqueIdentifier"
        ], in: info) ?? "\(title)-\(artist)"

        let nextSnapshot = NowPlayingSnapshot(
            id: id,
            title: title,
            artist: artist,
            album: album,
            appName: appName,
            applicationBundleIdentifier: applicationBundleIdentifier,
            artworkData: artworkData,
            duration: duration,
            elapsedTime: elapsedTime,
            playbackRate: playbackRate,
            playbackState: playbackRate > 0 ? .playing : .paused,
            updatedAt: Date()
        )
        publishSnapshot(nextSnapshot, source: .mediaRemote)

        return true
    }

    private func publishSnapshot(
        _ nextSnapshot: NowPlayingSnapshot?,
        source: NowPlayingSource
    ) {
        let shouldPublish = NowPlayingPublicationPolicy.shouldPublish(
            previous: snapshot,
            next: nextSnapshot
        )
        if shouldPublish {
            snapshot = nextSnapshot
            onChange?(nextSnapshot)
        }

        recordObservation(nextSnapshot, source: source)
    }

    private func recordObservation(
        _ nextSnapshot: NowPlayingSnapshot?,
        source: NowPlayingSource
    ) {
        diagnostics = diagnostics.recordingObservation(
            source: source,
            applicationName: nextSnapshot?.appName,
            hasSnapshot: nextSnapshot != nil,
            requiresAccessibilityAccess: requiresAccessibilityAccess,
            at: Date()
        )
    }

    private func stringValue(for keys: [String], in info: NSDictionary) -> String? {
        for key in keys {
            if let value = info[key] as? String, value.isEmpty == false {
                return value
            }
        }
        return nil
    }

    private func doubleValue(for keys: [String], in info: NSDictionary) -> Double? {
        for key in keys {
            if let value = info[key] as? NSNumber {
                return value.doubleValue
            }
        }
        return nil
    }

    private func dataValue(for keys: [String], in info: NSDictionary) -> Data? {
        for key in keys {
            if let value = info[key] as? Data {
                return value
            }
            if let value = info[key] as? NSData {
                return Data(referencing: value)
            }
        }
        return nil
    }
}

@MainActor
private final class MediaRemoteBridge {
    private typealias RegisterFunction = @convention(c) (DispatchQueue) -> Void
    private typealias GetInfoFunction = @convention(c) (DispatchQueue, @escaping (NSDictionary?) -> Void) -> Void
    private typealias GetElectedPlayerPathFunction = @convention(c) (
        DispatchQueue,
        @escaping (AnyObject?) -> Void
    ) -> Void
    private typealias GetIsPlayingFunction = @convention(c) (
        DispatchQueue,
        @escaping (Bool) -> Void
    ) -> Void
    private typealias ObjectGetterFunction = @convention(c) (
        AnyObject,
        Selector
    ) -> AnyObject?
    private typealias ObjectInitializerFunction = @convention(c) (
        AnyObject,
        Selector,
        AnyObject
    ) -> AnyObject?
    private typealias VoidMessageFunction = @convention(c) (
        AnyObject,
        Selector
    ) -> Void
    private typealias ControllerSendFunction = @convention(c) (
        AnyObject,
        Selector,
        UInt32,
        NSDictionary?,
        UInt32,
        @escaping (AnyObject?) -> Void
    ) -> Void
    private typealias UnregisterFunction = @convention(c) () -> Void

    private let handle: UnsafeMutableRawPointer?
    private let registerFunction: RegisterFunction?
    private let getInfoFunction: GetInfoFunction?
    private let getElectedPlayerPathFunction: GetElectedPlayerPathFunction?
    private let getIsPlayingFunction: GetIsPlayingFunction?
    private let destinationClass: AnyClass?
    private let nowPlayingControllerClass: AnyClass?
    private let objectGetterFunction: ObjectGetterFunction?
    private let objectInitializerFunction: ObjectInitializerFunction?
    private let voidMessageFunction: VoidMessageFunction?
    private let controllerSendFunction: ControllerSendFunction?
    private let unregisterFunction: UnregisterFunction?
    private var activeCommandRequests: [ObjectIdentifier: AnyObject] = [:]

    var isAvailable: Bool {
        getInfoFunction != nil
    }

    init() {
        let paths = [
            "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
            "/System/Library/PrivateFrameworks/MediaRemote.framework/Versions/Current/MediaRemote"
        ]

        var loadedHandle: UnsafeMutableRawPointer?
        for path in paths {
            if let candidate = dlopen(path, RTLD_LAZY) {
                loadedHandle = candidate
                break
            }
        }

        handle = loadedHandle
        guard let loadedHandle else {
            registerFunction = nil
            getInfoFunction = nil
            getElectedPlayerPathFunction = nil
            getIsPlayingFunction = nil
            destinationClass = nil
            nowPlayingControllerClass = nil
            objectGetterFunction = nil
            objectInitializerFunction = nil
            voidMessageFunction = nil
            controllerSendFunction = nil
            unregisterFunction = nil
            return
        }

        registerFunction = Self.loadFunction(
            named: "MRMediaRemoteRegisterForNowPlayingNotifications",
            from: loadedHandle,
            as: RegisterFunction.self
        )
        getInfoFunction = Self.loadFunction(
            named: "MRMediaRemoteGetNowPlayingInfo",
            from: loadedHandle,
            as: GetInfoFunction.self
        )
        getElectedPlayerPathFunction = Self.loadFunction(
            named: "MRMediaRemoteGetElectedPlayerPath",
            from: loadedHandle,
            as: GetElectedPlayerPathFunction.self
        )
        getIsPlayingFunction = Self.loadFunction(
            named: "MRMediaRemoteGetNowPlayingApplicationIsPlaying",
            from: loadedHandle,
            as: GetIsPlayingFunction.self
        )
        destinationClass = NSClassFromString("MRDestination")
        nowPlayingControllerClass = NSClassFromString(
            "MRNowPlayingController"
        )
        if let messageSend = dlsym(
            UnsafeMutableRawPointer(bitPattern: -2),
            "objc_msgSend"
        ) {
            objectGetterFunction = unsafeBitCast(
                messageSend,
                to: ObjectGetterFunction.self
            )
            objectInitializerFunction = unsafeBitCast(
                messageSend,
                to: ObjectInitializerFunction.self
            )
            voidMessageFunction = unsafeBitCast(
                messageSend,
                to: VoidMessageFunction.self
            )
            controllerSendFunction = unsafeBitCast(
                messageSend,
                to: ControllerSendFunction.self
            )
        } else {
            objectGetterFunction = nil
            objectInitializerFunction = nil
            voidMessageFunction = nil
            controllerSendFunction = nil
        }
        unregisterFunction = Self.loadFunction(
            named: "MRMediaRemoteUnregisterForNowPlayingNotifications",
            from: loadedHandle,
            as: UnregisterFunction.self
        )
    }

    func registerForNowPlayingNotifications() {
        registerFunction?(DispatchQueue.main)
    }

    func unregisterForNowPlayingNotifications() {
        unregisterFunction?()
    }

    func getNowPlayingInfo(completion: @escaping (NSDictionary?) -> Void) {
        guard let getInfoFunction else {
            completion(nil)
            return
        }
        getInfoFunction(DispatchQueue.main, completion)
    }

    func getElectedPlayerPath(
        completion: @escaping ElectedPlayerCommandTransport.PlayerPathCompletion
    ) -> Bool {
        guard let getElectedPlayerPathFunction else { return false }
        getElectedPlayerPathFunction(DispatchQueue.main) { playerPath in
            DispatchQueue.main.async {
                completion(playerPath)
            }
        }
        return true
    }

    func getIsPlaying(
        completion: @escaping ElectedPlayerCommandTransport.IsPlayingCompletion
    ) -> Bool {
        guard let getIsPlayingFunction else { return false }
        getIsPlayingFunction(DispatchQueue.main) { isPlaying in
            DispatchQueue.main.async {
                completion(isPlaying)
            }
        }
        return true
    }

    func send(
        request: MediaRemoteCommandRequest,
        to playerPath: AnyObject,
        completion: @escaping @MainActor (UInt32) -> Void
    ) -> Bool {
        guard let destinationClass,
              let nowPlayingControllerClass,
              let objectGetterFunction,
              let objectInitializerFunction,
              let voidMessageFunction,
              let controllerSendFunction,
              let allocatedDestination = objectGetterFunction(
                  destinationClass,
                  NSSelectorFromString("alloc")
              ),
              let destination = objectInitializerFunction(
                  allocatedDestination,
                  NSSelectorFromString("initWithPlayerPath:"),
                  playerPath
              ),
              let allocatedController = objectGetterFunction(
                  nowPlayingControllerClass,
                  NSSelectorFromString("alloc")
              ),
              let controller = objectInitializerFunction(
                  allocatedController,
                  NSSelectorFromString("initWithDestination:"),
                  destination
              ) else {
            return false
        }

        let requestIdentifier = ObjectIdentifier(controller)
        activeCommandRequests[requestIdentifier] = controller
        voidMessageFunction(
            controller,
            NSSelectorFromString("beginLoadingUpdates")
        )
        controllerSendFunction(
            controller,
            NSSelectorFromString("sendCommand:options:appOptions:completion:"),
            request.command,
            request.options as NSDictionary,
            0
        ) { [weak self] result in
            DispatchQueue.main.async {
                voidMessageFunction(
                    controller,
                    NSSelectorFromString("endLoadingUpdates")
                )
                self?.activeCommandRequests.removeValue(
                    forKey: requestIdentifier
                )
                let sendError = (result as? NSObject)?
                    .value(forKey: "sendError") as? NSNumber
                completion(sendError?.uint32Value ?? UInt32.max)
            }
        }
        return true
    }

    private static func loadFunction<T>(
        named name: String,
        from handle: UnsafeMutableRawPointer,
        as type: T.Type
    ) -> T? {
        guard let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: type)
    }
}

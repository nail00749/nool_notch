import AppKit
import ApplicationServices

@MainActor
final class NowPlayingEventRelay {
    private let delayNanoseconds: UInt64
    private let onRefresh: @MainActor () -> Void
    private var task: Task<Void, Never>?

    init(
        delayNanoseconds: UInt64 = 100_000_000,
        onRefresh: @MainActor @escaping () -> Void
    ) {
        self.delayNanoseconds = delayNanoseconds
        self.onRefresh = onRefresh
    }

    func signal() {
        task?.cancel()
        let delayNanoseconds = delayNanoseconds
        task = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard Task.isCancelled == false, let self else { return }
            task = nil
            onRefresh()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

@MainActor
final class AccessibilityNowPlayingSource {
    private enum ArtworkCandidate {
        case inline(Data)
        case remote(URL)
    }

    private struct Session {
        let titleElement: AXUIElement
        let playPauseButton: AXUIElement
        let timeSlider: AXUIElement?
    }

    private struct ObservedNotification {
        let element: AXUIElement
        let name: CFString
    }

    private var session: Session?
    private var cachedApplication: NSRunningApplication?
    private var cachedPlayerRoot: AXUIElement?
    private var cachedMetadata: (title: String, artist: String, album: String?)?
    private var cachedArtwork: (trackID: String, data: Data)?
    private var artworkDiscoveryTrackID: String?
    private var artworkDiscoveryRetryAt: Date?
    private var artworkTask: Task<Void, Never>?
    private var accessibilityObserver: AXObserver?
    private var observedNotifications: [ObservedNotification] = []
    private var observedProcessIdentifier: pid_t?
    private var observedPlayerRoot: AXUIElement?
    private var observedTitleElement: AXUIElement?
    private var observedPlayPauseButton: AXUIElement?
    private lazy var eventRelay = NowPlayingEventRelay { [weak self] in
        self?.onMetadataChange?()
    }
    private(set) var requiresAccessibilityAccess = false
    var onArtworkChange: ((String, Data) -> Void)?
    var onMetadataChange: (() -> Void)?

    private static let observerCallback: AXObserverCallback = { _, _, _, refcon in
        guard let refcon else { return }
        let source = Unmanaged<AccessibilityNowPlayingSource>
            .fromOpaque(refcon)
            .takeUnretainedValue()
        MainActor.assumeIsolated {
            source.eventRelay.signal()
        }
    }

    func snapshot() -> NowPlayingSnapshot? {
        guard ensureAccessibilityAccess() else {
            resetPlayerSession()
            return nil
        }

        requiresAccessibilityAccess = false

        if let app = cachedApplication,
           app.isTerminated == false,
           let playerRoot = cachedPlayerRoot,
           let player = snapshot(for: app, playerRoot: playerRoot) {
            return player
        }

        resetPlayerSession()

        for app in candidateApplications() {
            let root = AXUIElementCreateApplication(app.processIdentifier)
            guard let playerRoot = findPlayerRoot(in: root),
                  let player = snapshot(for: app, playerRoot: playerRoot) else {
                continue
            }
            cachedApplication = app
            cachedPlayerRoot = playerRoot
            return player
        }

        resetPlayerSession()
        return nil
    }

    func stop() {
        artworkTask?.cancel()
        artworkTask = nil
        eventRelay.cancel()
        stopObservingChanges()
    }

    func seek(to time: TimeInterval) -> Bool {
        guard let slider = session?.timeSlider else { return false }
        let result = AXUIElementSetAttributeValue(
            slider,
            kAXValueAttribute as CFString,
            NSNumber(value: max(0, time))
        )
        return result == .success
    }

    private func snapshot(for app: NSRunningApplication, playerRoot: AXUIElement) -> NowPlayingSnapshot? {
        let titleResult: (element: AXUIElement, value: String)
        if let titleElement = session?.titleElement,
           let title = trackTitleValue(of: titleElement, appName: app.localizedName) {
            titleResult = (titleElement, title)
        } else if let discoveredTitle = trackTitle(in: playerRoot, appName: app.localizedName) {
            titleResult = discoveredTitle
        } else {
            return nil
        }

        let title = titleResult.value
        let playPauseButton = findButton(in: playerRoot, matching: playPauseButtonText)
        guard let playPauseButton else { return nil }
        let timeSlider = session?.timeSlider ?? findSlider(in: playerRoot)
        let localizedTimeRange = timeSlider.flatMap {
            timeRange(in: combinedText(for: $0))
        }
        let elapsedTime = timeSlider.flatMap {
            numberAttribute($0, key: kAXValueAttribute)
        } ?? localizedTimeRange?.elapsed ?? 0
        let duration = timeSlider.flatMap {
            numberAttribute($0, key: kAXMaxValueAttribute)
        }.flatMap { value in
            value > 0 ? value : nil
        } ?? localizedTimeRange?.duration ?? 0
        let isPlaying = containsAny(buttonText(playPauseButton), ["пауза", "pause", "stop"])
        let artist: String
        let album: String?
        let metadataRoot = parent(of: playerRoot) ?? playerRoot
        if let metadata = cachedMetadata, metadata.title == title {
            artist = metadata.artist
            album = metadata.album
        } else {
            artist = artistName(in: metadataRoot) ?? "Неизвестный исполнитель"
            album = albumName(in: playerRoot)
            cachedMetadata = (title, artist, album)
        }

        let nextSession = Session(
            titleElement: titleResult.element,
            playPauseButton: playPauseButton,
            timeSlider: timeSlider
        )
        session = nextSession
        observeChanges(for: app, playerRoot: playerRoot, session: nextSession)

        let trackID = "accessibility:\(app.bundleIdentifier ?? app.localizedName ?? "player"):\(title):\(artist)"
        let artworkData = artworkData(
            for: trackID,
            primaryRoot: playerRoot,
            fallbackRoot: AXUIElementCreateApplication(app.processIdentifier),
            matchingAny: [album, title].compactMap { $0 }
        )

        return NowPlayingSnapshot(
            id: trackID,
            title: title,
            artist: artist,
            album: album,
            appName: app.localizedName,
            applicationBundleIdentifier: app.bundleIdentifier,
            artworkData: artworkData,
            duration: max(duration, 0),
            elapsedTime: max(elapsedTime, 0),
            playbackRate: isPlaying ? 1 : 0,
            playbackState: isPlaying ? .playing : .paused,
            updatedAt: Date()
        )
    }

    private func artworkData(
        for trackID: String,
        primaryRoot: AXUIElement,
        fallbackRoot: AXUIElement,
        matchingAny labels: [String]
    ) -> Data? {
        if let cachedArtwork, cachedArtwork.trackID == trackID {
            return cachedArtwork.data
        }
        if artworkDiscoveryTrackID == trackID {
            if artworkTask != nil {
                return nil
            }
            if let artworkDiscoveryRetryAt,
               artworkDiscoveryRetryAt > Date() {
                return nil
            }
        }

        artworkTask?.cancel()
        artworkTask = nil
        cachedArtwork = nil
        artworkDiscoveryRetryAt = nil

        guard let candidate = artworkCandidate(in: primaryRoot)
            ?? artworkCandidate(in: fallbackRoot, matchingAny: labels) else {
            artworkDiscoveryTrackID = trackID
            artworkDiscoveryRetryAt = Date().addingTimeInterval(10)
            return nil
        }
        artworkDiscoveryTrackID = trackID
        switch candidate {
        case let .inline(data):
            cachedArtwork = (trackID, data)
            return data
        case let .remote(url):
            artworkTask = Task { @MainActor [weak self] in
                let data = try? await AccessibilityArtworkLoader.load(url: url)
                guard let self,
                      self.artworkDiscoveryTrackID == trackID else {
                    return
                }
                guard let data, Task.isCancelled == false else {
                    self.artworkTask = nil
                    self.artworkDiscoveryRetryAt = Date().addingTimeInterval(10)
                    return
                }
                self.cachedArtwork = (trackID, data)
                self.artworkTask = nil
                self.artworkDiscoveryRetryAt = nil
                self.onArtworkChange?(trackID, data)
            }
            return nil
        }
    }

    private func artworkCandidate(
        in root: AXUIElement,
        matchingAny labels: [String] = []
    ) -> ArtworkCandidate? {
        for element in descendants(of: root) where role(of: element) == "AXImage" {
            if labels.isEmpty == false {
                let text = combinedText(for: element)
                guard labels.contains(where: { label in
                    let normalized = label.trimmingCharacters(in: .whitespacesAndNewlines)
                    return normalized.count >= 2
                        && text.localizedCaseInsensitiveContains(normalized)
                }) else {
                    continue
                }
            }
            for key in [kAXValueAttribute, kAXURLAttribute] {
                guard let value = attribute(element, key: key) else { continue }
                if let data = inlineArtworkData(from: value) {
                    return .inline(data)
                }
                if let url = artworkURL(from: value) {
                    return .remote(url)
                }
            }
        }
        return nil
    }

    private func inlineArtworkData(from value: CFTypeRef) -> Data? {
        let data: Data?
        if let value = value as? Data {
            data = value
        } else if let value = value as? NSData {
            data = Data(referencing: value)
        } else if let image = value as? NSImage {
            data = image.tiffRepresentation
        } else {
            data = nil
        }

        guard let data,
              data.count <= AccessibilityArtworkLoader.maximumResponseBytes,
              NSImage(data: data) != nil else {
            return nil
        }
        return data
    }

    private func artworkURL(from value: CFTypeRef) -> URL? {
        if let url = value as? URL {
            return url
        }
        if let url = value as? NSURL {
            return url as URL
        }
        if let string = value as? String {
            return URL(string: string)
        }
        return nil
    }

    private func resetPlayerSession() {
        eventRelay.cancel()
        stopObservingChanges()
        cachedApplication = nil
        cachedPlayerRoot = nil
        cachedMetadata = nil
        cachedArtwork = nil
        artworkDiscoveryTrackID = nil
        artworkDiscoveryRetryAt = nil
        artworkTask?.cancel()
        artworkTask = nil
        session = nil
    }

    private func observeChanges(
        for app: NSRunningApplication,
        playerRoot: AXUIElement,
        session: Session
    ) {
        if observedProcessIdentifier == app.processIdentifier,
           isSameElement(observedPlayerRoot, playerRoot),
           isSameElement(observedTitleElement, session.titleElement),
           isSameElement(observedPlayPauseButton, session.playPauseButton) {
            return
        }

        stopObservingChanges()

        var observer: AXObserver?
        guard AXObserverCreate(
            app.processIdentifier,
            Self.observerCallback,
            &observer
        ) == .success, let observer else {
            return
        }

        var registrations: [ObservedNotification] = []
        let candidates: [(AXUIElement, CFString)] = [
            (session.titleElement, kAXValueChangedNotification as CFString),
            (session.titleElement, kAXTitleChangedNotification as CFString),
            (session.titleElement, kAXUIElementDestroyedNotification as CFString),
            (session.playPauseButton, kAXValueChangedNotification as CFString),
            (session.playPauseButton, kAXTitleChangedNotification as CFString),
            (session.playPauseButton, kAXUIElementDestroyedNotification as CFString)
        ]
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        for (element, name) in candidates where AXObserverAddNotification(
            observer,
            element,
            name,
            refcon
        ) == .success {
            registrations.append(ObservedNotification(element: element, name: name))
        }

        guard registrations.isEmpty == false else { return }

        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .commonModes
        )
        accessibilityObserver = observer
        observedNotifications = registrations
        observedProcessIdentifier = app.processIdentifier
        observedPlayerRoot = playerRoot
        observedTitleElement = session.titleElement
        observedPlayPauseButton = session.playPauseButton
    }

    private func stopObservingChanges() {
        guard let observer = accessibilityObserver else {
            observedNotifications.removeAll()
            observedProcessIdentifier = nil
            observedPlayerRoot = nil
            observedTitleElement = nil
            observedPlayPauseButton = nil
            return
        }

        for registration in observedNotifications {
            AXObserverRemoveNotification(observer, registration.element, registration.name)
        }
        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .commonModes
        )
        accessibilityObserver = nil
        observedNotifications.removeAll()
        observedProcessIdentifier = nil
        observedPlayerRoot = nil
        observedTitleElement = nil
        observedPlayPauseButton = nil
    }

    private func isSameElement(_ lhs: AXUIElement?, _ rhs: AXUIElement) -> Bool {
        guard let lhs else { return false }
        return CFEqual(lhs, rhs)
    }

    private func candidateApplications() -> [NSRunningApplication] {
        let currentProcessID = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { app in
                app.processIdentifier != currentProcessID
                    && app.isFinishedLaunching
                    && app.isTerminated == false
                    && app.activationPolicy != .prohibited
                    && mediaApplicationPriority(app) > 0
            }
            .sorted { lhs, rhs in
                if lhs.isActive != rhs.isActive {
                    return lhs.isActive
                }
                return (lhs.localizedName ?? "") < (rhs.localizedName ?? "")
            }
    }

    private func mediaApplicationPriority(_ app: NSRunningApplication) -> Int {
        let identity = [app.bundleIdentifier, app.localizedName]
            .compactMap { $0 }
            .joined(separator: " ")

        return containsAny(identity, [
            "music", "музык", "spotify", "tidal", "deezer", "audio", "player"
        ]) ? 1 : 0
    }

    private func ensureAccessibilityAccess() -> Bool {
        guard AXIsProcessTrusted() == false else { return true }

        requiresAccessibilityAccess = true
        return false
    }

    private func findPlayerRoot(in root: AXUIElement) -> AXUIElement? {
        firstDescendant(of: root) { element in
            let text = combinedText(for: element)
            return containsAny(text, ["плеер", "player", "now playing", "сейчас играет"])
                && findButton(in: element, matching: playPauseButtonText) != nil
        }
    }

    private func trackTitle(
        in root: AXUIElement,
        appName: String?
    ) -> (element: AXUIElement, value: String)? {
        descendants(of: root)
            .compactMap { element in
                trackTitleValue(of: element, appName: appName).map { (element, $0) }
            }
            .sorted { lhs, rhs in
                let lhsScore = titleScore(lhs.1)
                let rhsScore = titleScore(rhs.1)
                if lhsScore != rhsScore { return lhsScore > rhsScore }
                return lhs.1.count > rhs.1.count
            }
            .first
    }

    private func trackTitleValue(of element: AXUIElement, appName: String?) -> String? {
        let excluded = [
            "плеер", "player", "now playing", "сейчас играет", "альбом", "album",
            "исполнитель", "artist", "пауза", "pause", "воспроизведение", "play",
            "предыдущ", "previous", "следующ", "next", "музыка", "music"
        ]

        guard ["AXStaticText", "AXTextField"].contains(role(of: element)),
              let value = stringAttribute(element, key: kAXValueAttribute) else {
            return nil
        }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false,
              normalized.count <= 160,
              normalized != appName,
              containsAny(normalized, excluded) == false,
              normalized.range(of: #"^\d{1,2}:\d{2}"#, options: .regularExpression) == nil else {
            return nil
        }
        return normalized
    }

    private func titleScore(_ value: String) -> Int {
        var score = 0
        if value.contains("-") || value.contains("–") { score += 2 }
        if value.split(separator: " ").count >= 2 { score += 1 }
        if value.count >= 4 { score += 1 }
        return score
    }

    private func artistName(in root: AXUIElement) -> String? {
        labeledValue(in: root, labels: ["исполнитель", "артист", "artist"])
    }

    private func albumName(in root: AXUIElement) -> String? {
        labeledValue(in: root, labels: ["альбом", "album"])
    }

    private func labeledValue(in root: AXUIElement, labels: [String]) -> String? {
        for element in descendants(of: root) {
            let text = combinedText(for: element)
            guard let label = labels.first(where: { text.localizedCaseInsensitiveContains($0) }) else {
                continue
            }

            let value = text
                .replacingOccurrences(of: label, with: "", options: .caseInsensitive)
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            if value.isEmpty == false {
                return value
            }
        }
        return nil
    }

    private func findButton(in root: AXUIElement, matching predicate: (String) -> Bool) -> AXUIElement? {
        firstDescendant(of: root) { element in
            ["AXButton", "AXCheckBox"].contains(role(of: element)) && predicate(buttonText(element))
        }
    }

    private func findSlider(in root: AXUIElement) -> AXUIElement? {
        let sliders = descendants(of: root).filter { role(of: $0) == "AXSlider" }
        return sliders.first { containsAny(combinedText(for: $0), [
            "таймкод", "врем", "прогресс", "time", "progress", "position", "seek"
        ]) }
    }

    private var playPauseButtonText: (String) -> Bool {
        { [weak self] text in self?.containsAny(text, [
            "пауза", "воспроизвед", "pause", "play", "toggle"
        ]) ?? false }
    }

    private func buttonText(_ element: AXUIElement) -> String {
        combinedText(for: element)
    }

    private func combinedText(for element: AXUIElement) -> String {
        [
            stringAttribute(element, key: kAXTitleAttribute),
            stringAttribute(element, key: kAXValueAttribute),
            stringAttribute(element, key: kAXDescriptionAttribute),
            stringAttribute(element, key: kAXRoleDescriptionAttribute)
        ]
        .compactMap { $0 }
        .joined(separator: " ")
    }

    private func role(of element: AXUIElement) -> String {
        stringAttribute(element, key: kAXRoleAttribute) ?? ""
    }

    private func stringAttribute(_ element: AXUIElement, key: String) -> String? {
        guard let value = attribute(element, key: key) else { return nil }
        if let string = value as? String { return string }
        if let string = value as? NSString { return string as String }
        return nil
    }

    private func numberAttribute(_ element: AXUIElement, key: String) -> Double? {
        guard let value = attribute(element, key: key) else { return nil }
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private func timeRange(
        in text: String
    ) -> (elapsed: TimeInterval, duration: TimeInterval)? {
        let parts = text.split(
            separator: "/",
            maxSplits: 1,
            omittingEmptySubsequences: true
        )
        guard parts.count == 2,
              let elapsed = timeInterval(in: parts[0]),
              let duration = timeInterval(in: parts[1]) else {
            return nil
        }
        return (elapsed, duration)
    }

    private func timeInterval(in text: Substring) -> TimeInterval? {
        let values = text
            .split { character in
                character.isNumber == false && character != "."
            }
            .compactMap { Double(String($0)) }

        switch values.count {
        case 1:
            return values[0]
        case 2:
            return values[0] * 60 + values[1]
        case 3:
            return values[0] * 3_600 + values[1] * 60 + values[2]
        default:
            return nil
        }
    }

    private func attribute(_ element: AXUIElement, key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private func descendants(of root: AXUIElement) -> [AXUIElement] {
        var result: [AXUIElement] = []
        var stack = [root]
        var visited = Set<AXUIElement>()

        while let element = stack.popLast() {
            guard visited.insert(element).inserted else { continue }
            result.append(element)
            stack.append(contentsOf: children(of: element))
        }

        return result
    }

    private func firstDescendant(
        of root: AXUIElement,
        matching predicate: (AXUIElement) -> Bool
    ) -> AXUIElement? {
        var stack = [root]
        var visited = Set<AXUIElement>()

        while let element = stack.popLast() {
            guard visited.insert(element).inserted else { continue }
            if predicate(element) {
                return element
            }
            stack.append(contentsOf: children(of: element))
        }

        return nil
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        guard let value = attribute(element, key: kAXChildrenAttribute),
              CFGetTypeID(value) == CFArrayGetTypeID() else {
            return []
        }

        let array = unsafeDowncast(value, to: CFArray.self)
        return (0..<CFArrayGetCount(array)).map { index in
            unsafeBitCast(CFArrayGetValueAtIndex(array, index), to: AXUIElement.self)
        }
    }

    private func parent(of element: AXUIElement) -> AXUIElement? {
        guard let value = attribute(element, key: kAXParentAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func containsAny(_ value: String, _ fragments: [String]) -> Bool {
        fragments.contains { value.localizedCaseInsensitiveContains($0) }
    }
}

import Foundation

/// One line of the bundled MediaRemote adapter's stdout stream.
struct MediaRemoteAdapterPayload: Decodable, Equatable, Sendable {
    var type: String
    var title: String?
    var artist: String?
    var album: String?
    var id: String?
    var duration: Double?
    var elapsed: Double?
    var rate: Double?
    var timestamp: Double?
    var playing: Bool?
    var bundleIdentifier: String?
    var appName: String?
    var artworkId: String?
    var artwork: String?
    var name: String?
    var ok: Bool?
}

enum MediaRemoteAdapterEvent: Equatable, Sendable {
    case ready
    case nowPlaying(MediaRemoteAdapterPayload)
    case idle
    case command(name: String, ok: Bool)
    case unavailable
}

/// Splits the adapter's byte stream into newline-delimited JSON events.
/// Lines longer than `maximumLineLength` are dropped instead of buffered
/// without bound; malformed lines are ignored.
struct MediaRemoteAdapterLineDecoder: Sendable {
    static let defaultMaximumLineLength = 8 * 1024 * 1024

    private let maximumLineLength: Int
    private var buffer = Data()
    private var isDiscardingOversizedLine = false

    init(maximumLineLength: Int = Self.defaultMaximumLineLength) {
        self.maximumLineLength = maximumLineLength
    }

    mutating func append(_ data: Data) -> [MediaRemoteAdapterEvent] {
        var events: [MediaRemoteAdapterEvent] = []
        var remaining = data[...]
        while let newline = remaining.firstIndex(of: 0x0A) {
            let fragment = remaining[remaining.startIndex..<newline]
            remaining = remaining[remaining.index(after: newline)...]
            if isDiscardingOversizedLine {
                isDiscardingOversizedLine = false
                buffer.removeAll(keepingCapacity: false)
                continue
            }
            buffer.append(fragment)
            if buffer.count <= maximumLineLength,
               let event = Self.decode(line: buffer) {
                events.append(event)
            }
            buffer.removeAll(keepingCapacity: true)
        }
        if isDiscardingOversizedLine == false {
            buffer.append(remaining)
            if buffer.count > maximumLineLength {
                buffer.removeAll(keepingCapacity: false)
                isDiscardingOversizedLine = true
            }
        }
        return events
    }

    static func decode(line: Data) -> MediaRemoteAdapterEvent? {
        guard let payload = try? JSONDecoder().decode(
            MediaRemoteAdapterPayload.self,
            from: line
        ) else {
            return nil
        }
        switch payload.type {
        case "ready":
            return .ready
        case "idle":
            return .idle
        case "unavailable":
            return .unavailable
        case "command":
            return .command(name: payload.name ?? "", ok: payload.ok ?? false)
        case "nowPlaying":
            guard let title = payload.title, title.isEmpty == false else {
                return .idle
            }
            return .nowPlaying(payload)
        default:
            return nil
        }
    }
}

/// Turns adapter payloads into snapshots and keeps the last artwork, because
/// the adapter sends artwork bytes only when they change.
struct MediaRemoteAdapterSnapshotBuilder {
    private var artworkIdentifier: String?
    private var artworkData: Data?

    mutating func snapshot(
        from payload: MediaRemoteAdapterPayload,
        receivedAt date: Date
    ) -> NowPlayingSnapshot? {
        guard let title = payload.title, title.isEmpty == false else {
            return nil
        }

        let artwork: Data?
        if let identifier = payload.artworkId {
            if let encoded = payload.artwork,
               let decoded = Data(base64Encoded: encoded) {
                artworkIdentifier = identifier
                artworkData = decoded
            }
            artwork = artworkIdentifier == identifier ? artworkData : nil
        } else {
            artworkIdentifier = nil
            artworkData = nil
            artwork = nil
        }

        let reportedRate = payload.rate ?? 0
        let isPlaying = payload.playing ?? (reportedRate > 0)
        let playbackRate = isPlaying ? (reportedRate > 0 ? reportedRate : 1) : 0
        let artist = payload.artist ?? "Неизвестный исполнитель"
        let updatedAt = payload.timestamp.map(Date.init(timeIntervalSince1970:))
            .map { min($0, date) } ?? date

        return NowPlayingSnapshot(
            id: payload.id ?? "\(title)-\(artist)",
            title: title,
            artist: artist,
            album: payload.album,
            appName: payload.appName,
            applicationBundleIdentifier: payload.bundleIdentifier,
            artworkData: artwork,
            duration: max(payload.duration ?? 0, 0),
            elapsedTime: max(payload.elapsed ?? 0, 0),
            playbackRate: playbackRate,
            playbackState: isPlaying ? .playing : .paused,
            updatedAt: updatedAt
        )
    }

    mutating func reset() {
        artworkIdentifier = nil
        artworkData = nil
    }
}

/// Process I/O seam so tests can drive the adapter without launching perl.
protocol MediaRemoteAdapterProcess: AnyObject {
    /// Starts the process. `onOutput` and `onExit` may run on any thread.
    func launch(
        onOutput: @escaping @Sendable (Data) -> Void,
        onExit: @escaping @Sendable () -> Void
    ) throws
    func write(line: String)
    func terminate()
}

enum MediaRemoteAdapterLaunchError: Error, Equatable {
    case adapterMissing
    case hostMissing
}

/// Hosts the adapter dylib inside the Apple-signed `/usr/bin/perl` through
/// core DynaLoader, which is the process MediaRemote still answers.
final class PerlMediaRemoteAdapterProcess: MediaRemoteAdapterProcess, @unchecked Sendable {
    static let perlURL = URL(fileURLWithPath: "/usr/bin/perl")
    static let bundledAdapterName = "nool-media-remote-adapter.dylib"
    static let buildProductAdapterName = "libNoolMediaRemoteAdapter.dylib"

    private static let loaderScript = """
    use strict;
    use DynaLoader;
    my $path = shift @ARGV;
    my $handle = DynaLoader::dl_load_file($path, 0) or exit 4;
    my $symbol = DynaLoader::dl_find_symbol($handle, "nool_media_remote_adapter_main") or exit 5;
    DynaLoader::dl_install_xsub("main::nool_media_remote_adapter_main", $symbol);
    nool_media_remote_adapter_main();
    """

    private let adapterURL: URL?
    private let lock = NSLock()
    private var process: Process?
    private var input: FileHandle?

    init(adapterURL: URL? = PerlMediaRemoteAdapterProcess.locateAdapter()) {
        self.adapterURL = adapterURL
    }

    static func locateAdapter(bundle: Bundle = .main) -> URL? {
        var candidates: [URL] = []
        if let resourceURL = bundle.resourceURL {
            candidates.append(resourceURL.appendingPathComponent(bundledAdapterName))
        }
        if let executableURL = bundle.executableURL {
            // `swift run` and tests: the dylib sits next to the executable.
            candidates.append(
                executableURL.deletingLastPathComponent()
                    .appendingPathComponent(buildProductAdapterName)
            )
        }
        return candidates.first {
            FileManager.default.isReadableFile(atPath: $0.path)
        }
    }

    func launch(
        onOutput: @escaping @Sendable (Data) -> Void,
        onExit: @escaping @Sendable () -> Void
    ) throws {
        guard let adapterURL else { throw MediaRemoteAdapterLaunchError.adapterMissing }
        guard FileManager.default.isExecutableFile(atPath: Self.perlURL.path) else {
            throw MediaRemoteAdapterLaunchError.hostMissing
        }

        let process = Process()
        process.executableURL = Self.perlURL
        process.arguments = ["-e", Self.loaderScript, adapterURL.path]
        // An empty environment keeps PERL5OPT/PERL5LIB from injecting code.
        process.environment = [:]
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        let output = stdoutPipe.fileHandleForReading
        output.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            onOutput(data)
        }
        process.terminationHandler = { _ in
            output.readabilityHandler = nil
            onExit()
        }

        try process.run()
        lock.withLock {
            self.process = process
            self.input = stdinPipe.fileHandleForWriting
        }
    }

    func write(line: String) {
        let handle = lock.withLock { input }
        guard let handle, let data = (line + "\n").data(using: .utf8) else { return }
        try? handle.write(contentsOf: data)
    }

    func terminate() {
        let (process, input) = lock.withLock {
            let pair = (self.process, self.input)
            self.process = nil
            self.input = nil
            return pair
        }
        // Closing stdin is the adapter's own shutdown signal.
        try? input?.close()
        if process?.isRunning == true {
            process?.terminate()
        }
    }
}

/// Owns the adapter process lifecycle: decoding off the main actor, restart
/// with backoff, and giving up when the host cannot run the adapter at all.
@MainActor
final class MediaRemoteAdapterSource {
    enum State: Equatable {
        case stopped
        case starting
        case active
        case unavailable
    }

    typealias ProcessFactory = @MainActor () -> any MediaRemoteAdapterProcess
    typealias Sleep = @Sendable (TimeInterval) async -> Void

    static let restartDelays: [TimeInterval] = [1, 2, 4, 8, 16, 30, 60]
    static let maximumFailuresBeforeReady = 4

    private let makeProcess: ProcessFactory
    private let sleep: Sleep
    private let now: @MainActor () -> Date
    private var process: (any MediaRemoteAdapterProcess)?
    private var generation: UInt64 = 0
    private var consecutiveFailures = 0
    private var restartTask: Task<Void, Never>?
    private var snapshotBuilder = MediaRemoteAdapterSnapshotBuilder()

    private(set) var state: State = .stopped {
        didSet {
            guard oldValue != state else { return }
            onStateChange?(state)
        }
    }
    /// The latest adapter answer; `nil` while active means nothing is playing.
    private(set) var snapshot: NowPlayingSnapshot?

    var onStateChange: ((State) -> Void)?
    var onSnapshotChange: ((NowPlayingSnapshot?) -> Void)?

    var isActive: Bool { state == .active }

    init(
        makeProcess: @escaping ProcessFactory = { PerlMediaRemoteAdapterProcess() },
        sleep: @escaping Sleep = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        },
        now: @escaping @MainActor () -> Date = Date.init
    ) {
        self.makeProcess = makeProcess
        self.sleep = sleep
        self.now = now
    }

    func start() {
        guard state == .stopped else { return }
        consecutiveFailures = 0
        launch()
    }

    func stop() {
        generation &+= 1
        restartTask?.cancel()
        restartTask = nil
        process?.terminate()
        process = nil
        snapshot = nil
        snapshotBuilder.reset()
        state = .stopped
    }

    /// Returns false when the adapter cannot take commands right now.
    @discardableResult
    func send(_ command: NowPlayingControlCommand) -> Bool {
        guard isActive, let process else { return false }
        switch command {
        case .togglePlayPause:
            process.write(line: "toggle")
        case .nextTrack:
            process.write(line: "next")
        case .previousTrack:
            process.write(line: "previous")
        case .seek(let time):
            let position = max(0, time)
            guard position.isFinite else { return false }
            process.write(line: String(format: "seek %.3f", position))
        }
        return true
    }

    func requestRefresh() {
        guard isActive else { return }
        process?.write(line: "refresh")
    }

    private func launch() {
        generation &+= 1
        let launchGeneration = generation
        state = .starting
        let process = makeProcess()
        self.process = process

        let decoder = DecoderBox()
        do {
            try process.launch(
                onOutput: { [weak self] data in
                    let events = decoder.append(data)
                    guard events.isEmpty == false else { return }
                    Task { @MainActor [weak self] in
                        self?.handle(events, generation: launchGeneration)
                    }
                },
                onExit: { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.handleExit(generation: launchGeneration)
                    }
                }
            )
        } catch {
            self.process = nil
            // A missing perl or adapter will not appear by retrying.
            state = .unavailable
        }
    }

    private func handle(_ events: [MediaRemoteAdapterEvent], generation: UInt64) {
        guard generation == self.generation else { return }
        for event in events {
            switch event {
            case .ready:
                consecutiveFailures = 0
                state = .active
            case .idle:
                snapshotBuilder.reset()
                publish(nil)
            case .nowPlaying(let payload):
                publish(snapshotBuilder.snapshot(from: payload, receivedAt: now()))
            case .command:
                break
            case .unavailable:
                giveUp()
                return
            }
        }
    }

    private func handleExit(generation: UInt64) {
        guard generation == self.generation, state != .unavailable else { return }
        process = nil
        consecutiveFailures += 1
        snapshotBuilder.reset()
        publish(nil)

        if consecutiveFailures > Self.maximumFailuresBeforeReady {
            giveUp()
            return
        }
        state = .starting
        let delay = Self.restartDelays[
            min(consecutiveFailures - 1, Self.restartDelays.count - 1)
        ]
        let sleep = self.sleep
        restartTask = Task { @MainActor [weak self] in
            await sleep(delay)
            guard Task.isCancelled == false,
                  let self,
                  self.generation == generation else { return }
            self.restartTask = nil
            self.launch()
        }
    }

    private func giveUp() {
        generation &+= 1
        process?.terminate()
        process = nil
        snapshot = nil
        state = .unavailable
    }

    private func publish(_ next: NowPlayingSnapshot?) {
        guard snapshot != next else { return }
        snapshot = next
        onSnapshotChange?(next)
    }
}

private final class DecoderBox: @unchecked Sendable {
    private let lock = NSLock()
    private var decoder = MediaRemoteAdapterLineDecoder()

    func append(_ data: Data) -> [MediaRemoteAdapterEvent] {
        lock.withLock { decoder.append(data) }
    }
}

/// Which reader answers a now-playing refresh, in priority order.
enum NowPlayingReadPath: Equatable {
    /// The perl-hosted adapter; when it reports nothing, Accessibility runs.
    case adapter
    /// Direct MediaRemote reads, which still work on older macOS releases.
    case inProcessMediaRemote
    case accessibility
}

enum NowPlayingReadPolicy {
    static func path(
        adapterState: MediaRemoteAdapterSource.State,
        bridgeIsAvailable: Bool
    ) -> NowPlayingReadPath {
        if adapterState == .active {
            return .adapter
        }
        return bridgeIsAvailable ? .inProcessMediaRemote : .accessibility
    }
}

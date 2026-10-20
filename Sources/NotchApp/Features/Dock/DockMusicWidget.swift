import AppKit
import QuartzCore
import SwiftUI

/// Dock music tile: artwork with a live equalizer while playing, play/pause on hover,
/// scroll to change tracks, a progress line, and a details popover with seeking.
struct DockMusicWidget: View {
    @ObservedObject var model: NotchViewModel
    let span: Int
    let interactionChanged: (Bool) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsDetails = false
    @State private var artworkImage: NSImage?
    @State private var hovered = false

    static let showDetails = Notification.Name("nool.dock.music.showDetails")

    private var snapshot: NowPlayingSnapshot? { model.nowPlayingSnapshot }
    private var isPlaying: Bool { snapshot?.playbackState.isPlaying == true }

    var body: some View {
        HStack(spacing: 9) {
            artworkControl
            if span > 1 {
                VStack(alignment: .leading, spacing: 4) {
                    Text(snapshot?.title ?? "Музыка").font(.system(size: 11, weight: .semibold))
                    Text(snapshot?.artist ?? "Ничего не играет")
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.56))
                    if let snapshot, snapshot.duration > 0 {
                        DockMusicProgressLine(snapshot: snapshot)
                    }
                }.lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    .dockTapTarget("Подробнее о треке") { showsDetails = true }
            }
            if span > 2 {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12)).frame(width: 25, height: 32)
                    .contentTransition(.symbolEffect(.replace))
                    .opacity(snapshot == nil ? 0.4 : 1)
                    .dockTapTarget(isPlaying ? "Пауза" : "Воспроизвести") {
                        if snapshot != nil { model.nowPlayingTogglePlayPause() }
                    }
            }
        }.padding(.horizontal, span > 1 ? 8 : 0).dockWidgetSurface()
            .background(DockScrollWheelReader { delta in
                guard snapshot != nil else { return }
                // Like scrolling a playlist: down or right moves forward.
                if delta > 0 { model.nowPlayingNextTrack() } else { model.nowPlayingPreviousTrack() }
            })
            .onHover { hovered = $0 }
            .help(snapshot.map { "\($0.title) — \($0.artist)\nПрокрутка: переключить трек" } ?? "Музыка")
            .onChange(of: snapshot?.artworkData, initial: true) { _, data in
                artworkImage = data.flatMap { NSImage(data: $0) }
            }
            // The cell's menu (width, removal) belongs to DockView; it adds the player items
            // and asks for details through this notification.
            .onReceive(NotificationCenter.default.publisher(for: DockMusicWidget.showDetails)) { _ in
                showsDetails = true
            }
            .popover(isPresented: $showsDetails, arrowEdge: .top) {
                DockMusicDetails(model: model, artwork: artworkImage)
                    .onAppear { interactionChanged(true) }.onDisappear { interactionChanged(false) }
            }
    }

    /// Artwork with the equalizer badge; hovering shows play/pause, a click toggles playback.
    private var artworkControl: some View {
        DockMusicArtwork(image: artworkImage, size: 42)
            .overlay(alignment: .bottomLeading) {
                if snapshot != nil, !hovered {
                    DockEqualizerView(isPlaying: isPlaying && !reduceMotion)
                        .frame(width: 14, height: 11)
                        .padding(3)
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
                        .padding(3)
                        .transition(.opacity)
                }
            }
            .overlay {
                if hovered, snapshot != nil {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9).fill(.black.opacity(0.45))
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .contentTransition(.symbolEffect(.replace))
                    }.transition(.opacity)
                }
            }
            .scaleEffect(isPlaying && !reduceMotion ? 1 : 0.94)
            .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7), value: isPlaying)
            .animation(.easeOut(duration: 0.15), value: hovered)
            .dockTapTarget(snapshot == nil ? "Информация о музыке" : (isPlaying ? "Пауза" : "Воспроизвести")) {
                if snapshot == nil { showsDetails = true } else { model.nowPlayingTogglePlayPause() }
            }
    }
}

struct DockMusicArtwork: View {
    let image: NSImage?
    let size: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "music.note").font(.system(size: size * 0.52))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.white.opacity(0.07))
            }
        }.frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size * 0.21))
    }
}

/// Thin elapsed-time line; ticks once a second and only while playing.
private struct DockMusicProgressLine: View {
    let snapshot: NowPlayingSnapshot

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let progress = snapshot.progress(at: snapshot.playbackState.isPlaying ? context.date : snapshot.updatedAt)
            GeometryReader { proxy in
                Capsule().fill(.white.opacity(0.15))
                    .overlay(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.75)).frame(width: proxy.size.width * progress)
                    }
            }.frame(height: 2.5)
                .animation(.linear(duration: 1), value: progress)
        }.accessibilityHidden(true)
    }
}

private struct DockMusicDetails: View {
    @ObservedObject var model: NotchViewModel
    let artwork: NSImage?
    @State private var scrubbing: Double?

    private var snapshot: NowPlayingSnapshot? { model.nowPlayingSnapshot }

    var body: some View {
        VStack(spacing: 12) {
            DockMusicArtwork(image: artwork, size: 120)
                .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
            VStack(spacing: 3) {
                Text(snapshot?.title ?? "Ничего не играет").font(.headline).lineLimit(2).multilineTextAlignment(.center)
                Text(snapshot?.artist ?? "").foregroundStyle(.secondary).lineLimit(1)
                if let app = snapshot?.appName { Text(app).font(.caption).foregroundStyle(.tertiary) }
            }
            if let snapshot, snapshot.duration > 0 {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let elapsed = scrubbing ?? snapshot.elapsedTime(at: snapshot.playbackState.isPlaying ? context.date : snapshot.updatedAt)
                    VStack(spacing: 2) {
                        Slider(value: Binding(get: { elapsed }, set: { scrubbing = $0 }),
                               in: 0...max(snapshot.duration, 1)) { editing in
                            if !editing, let target = scrubbing {
                                model.nowPlayingSeek(to: target)
                                scrubbing = nil
                            }
                        }.controlSize(.small)
                        HStack {
                            Text(Self.format(elapsed))
                            Spacer()
                            Text("-" + Self.format(max(0, snapshot.duration - elapsed)))
                        }.font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            HStack(spacing: 28) {
                Button(action: model.nowPlayingPreviousTrack) { Image(systemName: "backward.fill") }
                    .accessibilityLabel("Предыдущий трек")
                Button(action: model.nowPlayingTogglePlayPause) {
                    Image(systemName: snapshot?.playbackState.isPlaying == true ? "pause.fill" : "play.fill")
                        .font(.system(size: 22)).frame(width: 28)
                        .contentTransition(.symbolEffect(.replace))
                }.accessibilityLabel(snapshot?.playbackState.isPlaying == true ? "Пауза" : "Воспроизвести")
                Button(action: model.nowPlayingNextTrack) { Image(systemName: "forward.fill") }
                    .accessibilityLabel("Следующий трек")
            }.font(.system(size: 16)).buttonStyle(.plain).disabled(snapshot == nil)
        }.padding(20).frame(width: 260).preferredColorScheme(.dark)
    }

    static func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Equalizer bars animated by Core Animation on the render server: no SwiftUI updates
/// per frame. Paused, the bars settle low and stop.
struct DockEqualizerView: NSViewRepresentable {
    let isPlaying: Bool

    func makeNSView(context: Context) -> DockEqualizerNSView { DockEqualizerNSView() }

    func updateNSView(_ view: DockEqualizerNSView, context: Context) { view.isPlaying = isPlaying }
}

final class DockEqualizerNSView: NSView {
    static let barCount = 4
    /// Distinct periods so the bars never fall into step.
    static let periods: [CFTimeInterval] = [0.42, 0.57, 0.36, 0.49]
    private let bars: [CALayer] = (0..<DockEqualizerNSView.barCount).map { _ in CALayer() }

    var isPlaying = false {
        didSet { if isPlaying != oldValue { updateAnimations() } }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        for bar in bars {
            bar.backgroundColor = NSColor.white.cgColor
            bar.anchorPoint = CGPoint(x: 0.5, y: 0)
            layer?.addSublayer(bar)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let gap: CGFloat = 1.5
        let width = max(1, (bounds.width - gap * CGFloat(bars.count - 1)) / CGFloat(bars.count))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, bar) in bars.enumerated() {
            bar.bounds = CGRect(x: 0, y: 0, width: width, height: bounds.height)
            bar.position = CGPoint(x: CGFloat(index) * (width + gap) + width / 2, y: 0)
            bar.cornerRadius = width / 2
        }
        CATransaction.commit()
        updateAnimations()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateAnimations()
    }

    private func updateAnimations() {
        let animate = isPlaying && window != nil
        for (index, bar) in bars.enumerated() {
            if animate {
                guard bar.animation(forKey: "eq") == nil else { continue }
                let pulse = CABasicAnimation(keyPath: "transform.scale.y")
                pulse.fromValue = 0.25
                pulse.toValue = 1
                pulse.duration = Self.periods[index % Self.periods.count]
                pulse.autoreverses = true
                pulse.repeatCount = .infinity
                pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                pulse.timeOffset = Double(index) * 0.13
                bar.add(pulse, forKey: "eq")
            } else {
                bar.removeAnimation(forKey: "eq")
                bar.transform = CATransform3DMakeScale(1, [0.35, 0.55, 0.3, 0.45][index % 4], 1)
            }
        }
        if animate {
            for bar in bars { bar.transform = CATransform3DIdentity }
        }
    }
}

/// Reports one step per scroll gesture over the view: positive for down/right.
struct DockScrollWheelReader: NSViewRepresentable {
    let step: (Int) -> Void

    init(_ step: @escaping (Int) -> Void) { self.step = step }

    func makeNSView(context: Context) -> DockScrollWheelNSView {
        let view = DockScrollWheelNSView()
        view.step = step
        return view
    }

    func updateNSView(_ view: DockScrollWheelNSView, context: Context) { view.step = step }

    static func dismantleNSView(_ view: DockScrollWheelNSView, coordinator: ()) { view.stop() }
}

final class DockScrollWheelNSView: NSView {
    var step: (Int) -> Void = { _ in }
    private var monitor: Any?
    private var accumulated: CGFloat = 0
    private var consumed = false
    private var lastEvent = Date.distantPast
    static let threshold: CGFloat = 24

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        guard window != nil else { return }
        // A local monitor sees the wheel without taking clicks or drags from the tile.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }
            let point = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(point) else { return event }
            self.handle(event)
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) {
        let now = Date()
        if event.phase == .began || now.timeIntervalSince(lastEvent) > 0.35 { accumulated = 0; consumed = false }
        lastEvent = now
        // Momentum belongs to the gesture that already changed the track.
        guard event.momentumPhase == [] || !consumed else { return }
        let dominant = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? -event.scrollingDeltaX : -event.scrollingDeltaY
        let delta = event.hasPreciseScrollingDeltas ? dominant : dominant * 10
        accumulated += delta
        guard let direction = Self.step(for: accumulated, consumed: consumed) else { return }
        consumed = true
        step(direction)
    }

    /// One track change per gesture once the threshold is crossed.
    static func step(for accumulated: CGFloat, consumed: Bool) -> Int? {
        guard !consumed, abs(accumulated) >= threshold else { return nil }
        return accumulated > 0 ? 1 : -1
    }
}

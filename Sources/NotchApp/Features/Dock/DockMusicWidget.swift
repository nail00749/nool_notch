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
                VStack(alignment: .leading, spacing: 2) {
                    VStack(alignment: .leading, spacing: 1) {
                        DockMarqueeText(text: snapshot?.title ?? "Музыка",
                                        font: .system(size: 11, weight: .semibold),
                                        isActive: isPlaying && !reduceMotion)
                        Text(snapshot?.artist ?? "Ничего не играет").lineLimit(1)
                            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.56))
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .dockTapTarget("Подробнее о треке") { showsDetails = true }
                    HStack(spacing: 6) {
                        DockMusicTransportControls(model: model, isPlaying: isPlaying,
                                                   isEnabled: snapshot != nil, compact: span == 2)
                        if span > 2, let snapshot, snapshot.duration > 0 {
                            DockMusicProgressLine(snapshot: snapshot)
                        }
                    }
                    // Two cells have no room beside the buttons, so progress sits below them.
                    if span == 2, let snapshot, snapshot.duration > 0 {
                        DockMusicProgressLine(snapshot: snapshot)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
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
            .dockPopover(isPresented: $showsDetails, arrowEdge: .top) {
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

/// Previous / play-pause / next row for widgets two or three cells wide.
private struct DockMusicTransportControls: View {
    @ObservedObject var model: NotchViewModel
    let isPlaying: Bool
    let isEnabled: Bool
    let compact: Bool

    var body: some View {
        HStack(spacing: compact ? 0 : 2) {
            button("backward.fill", label: "Предыдущий трек", size: 9, action: model.nowPlayingPreviousTrack)
            button(isPlaying ? "pause.fill" : "play.fill", label: isPlaying ? "Пауза" : "Воспроизвести",
                   size: 12, action: model.nowPlayingTogglePlayPause)
            button("forward.fill", label: "Следующий трек", size: 9, action: model.nowPlayingNextTrack)
        }.opacity(isEnabled ? 1 : 0.35)
    }

    private func button(_ symbol: String, label: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .semibold))
            .contentTransition(.symbolEffect(.replace))
            .frame(width: compact ? 21 : 22, height: compact ? 15 : 18)
            .dockTapTarget(label) { if isEnabled { action() } }
    }
}

/// One-line label that scrolls like a ticker when the text does not fit.
/// It moves only while `isActive`; otherwise it is truncated in place.
struct DockMarqueeText: View {
    let text: String
    let font: Font
    let isActive: Bool
    static let gap: CGFloat = 28
    static let pointsPerSecond: CGFloat = 26
    static let pauseBetweenPasses: TimeInterval = 1.6

    static func overflows(textWidth: CGFloat, containerWidth: CGFloat) -> Bool {
        containerWidth > 0 && textWidth > containerWidth + 0.5
    }

    static func passDuration(textWidth: CGFloat) -> TimeInterval {
        TimeInterval((textWidth + gap) / pointsPerSecond)
    }

    var body: some View {
        // Keep SwiftUI's original font metrics and accessibility. Only the static labels
        // are hosted below; their translation and fade run on the render server.
        Text(text).font(font).lineLimit(1).hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay {
                DockMarqueeNativeText(text: text, font: font, isActive: isActive)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
    }
}

private struct DockMarqueeNativeText: NSViewRepresentable {
    let text: String
    let font: Font
    let isActive: Bool

    func makeNSView(context: Context) -> DockMarqueeNSView { DockMarqueeNSView() }
    func updateNSView(_ view: DockMarqueeNSView, context: Context) {
        view.configure(text: text, font: font, isActive: isActive)
    }
    static func dismantleNSView(_ view: DockMarqueeNSView, coordinator: ()) { view.stopAnimations() }
}

/// A shared event-driven visibility boundary. Ordering out the Dock does not remove
/// its hosting view, so `window != nil` alone leaves native animations running.
class DockMusicAnimationNSView: NSView {
    private var windowVisibility: NSKeyValueObservation?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var animationIsVisible: Bool {
        guard let window else { return false }
        return window.isVisible && window.occlusionState.contains(.visible) && !isHiddenOrHasHiddenAncestor
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        windowVisibility = nil
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: window)
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            windowVisibility = window.observe(\.isVisible) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.visibilityChanged() }
            }
            NotificationCenter.default.addObserver(self, selector: #selector(windowVisibilityChanged),
                                                  name: NSWindow.didChangeOcclusionStateNotification, object: window)
        }
        visibilityChanged()
    }

    override func viewDidHide() { super.viewDidHide(); visibilityChanged() }
    override func viewDidUnhide() { super.viewDidUnhide(); visibilityChanged() }
    @objc private func windowVisibilityChanged(_ notification: Notification) { visibilityChanged() }
    func visibilityChanged() {}
    func stopAnimations() {}
}

/// Retains static SwiftUI Text rendering while Core Animation moves its layers.
/// No SwiftUI state, display-link, Task loop, or per-frame layout is involved.
final class DockMarqueeNSView: DockMusicAnimationNSView {
    private let resting = NSHostingView(rootView: AnyView(EmptyView()))
    private let first = NSHostingView(rootView: AnyView(EmptyView()))
    private let second = NSHostingView(rootView: AnyView(EmptyView()))
    private let strip = NSView()
    private let fade = CAGradientLayer()
    private var text = ""
    private var font: Font = .body
    private var isActive = false
    private var titleWidth: CGFloat = 0
    private var animationSize: CGSize?
    static let translationKey = "marquee.translation"
    static let fadeKey = "marquee.fade"

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        strip.wantsLayer = true
        resting.sizingOptions = []
        // Full titles supply their intrinsic width once; the viewport itself never
        // participates in hosting-window sizing.
        first.sizingOptions = [.intrinsicContentSize]
        second.sizingOptions = [.intrinsicContentSize]
        addSubview(resting)
        addSubview(strip)
        strip.addSubview(first)
        strip.addSubview(second)
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        fade.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
    }

    convenience init() { self.init(frame: .zero) }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(text: String, font: Font, isActive: Bool) {
        let labelsChanged = self.text != text || self.font != font
        let activityChanged = self.isActive != isActive
        guard labelsChanged || activityChanged else { return }
        self.text = text
        self.font = font
        self.isActive = isActive
        if labelsChanged {
            let label = Text(text).font(font).foregroundStyle(.white).lineLimit(1)
            resting.rootView = AnyView(label.truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading))
            first.rootView = AnyView(label.fixedSize())
            second.rootView = AnyView(label.fixedSize())
            first.layoutSubtreeIfNeeded()
            titleWidth = first.fittingSize.width
        }
        stopAnimations()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        resting.frame = bounds
        strip.frame = CGRect(x: 0, y: 0, width: 2 * titleWidth + DockMarqueeText.gap, height: bounds.height)
        first.frame = CGRect(x: 0, y: 0, width: titleWidth, height: bounds.height)
        second.frame = CGRect(x: titleWidth + DockMarqueeText.gap, y: 0, width: titleWidth, height: bounds.height)
        fade.frame = bounds
        let width = max(bounds.width, 1)
        fade.locations = [0, NSNumber(value: Double(min(6 / width, 0.5))),
                          NSNumber(value: Double(max(1 - 10 / width, 0.5))), 1]
        CATransaction.commit()
        updateAnimation()
    }

    override func visibilityChanged() { updateAnimation() }

    override func stopAnimations() {
        strip.layer?.removeAnimation(forKey: Self.translationKey)
        fade.removeAnimation(forKey: Self.fadeKey)
        animationSize = nil
    }

    private func updateAnimation() {
        let scrolls = isActive && DockMarqueeText.overflows(textWidth: titleWidth, containerWidth: bounds.width)
        resting.isHidden = scrolls
        strip.isHidden = !scrolls
        layer?.mask = scrolls ? fade : nil
        guard scrolls && animationIsVisible else { stopAnimations(); return }
        guard animationSize != bounds.size else { return }
        stopAnimations()
        animationSize = bounds.size
        let duration = DockMarqueeText.passDuration(textWidth: titleWidth)
        let cycle = duration + DockMarqueeText.pauseBetweenPasses
        let pause = DockMarqueeText.pauseBetweenPasses / cycle
        let translation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        translation.values = [0, 0, -(titleWidth + DockMarqueeText.gap)]
        translation.keyTimes = [0, NSNumber(value: pause), 1]
        translation.duration = cycle
        translation.repeatCount = .infinity
        translation.calculationMode = .linear
        let solid = NSColor.black.cgColor
        let clear = NSColor.clear.cgColor
        let restingColors = [solid, solid, solid, clear]
        let movingColors = [clear, solid, solid, clear]
        fade.colors = restingColors
        let edge = CAKeyframeAnimation(keyPath: "colors")
        edge.values = [restingColors, restingColors, movingColors, movingColors]
        edge.keyTimes = [0, NSNumber(value: pause), NSNumber(value: min(1, pause + 0.001)), 1]
        edge.duration = cycle
        edge.repeatCount = .infinity
        // One clock for text and mask keeps the leading fade solid during every pause.
        let begin = CACurrentMediaTime()
        translation.beginTime = strip.layer?.convertTime(begin, from: nil) ?? begin
        edge.beginTime = fade.convertTime(begin, from: nil)
        strip.layer?.add(translation, forKey: Self.translationKey)
        fade.add(edge, forKey: Self.fadeKey)
    }

    var marqueeAnimation: CAKeyframeAnimation? { strip.layer?.animation(forKey: Self.translationKey) as? CAKeyframeAnimation }
}

/// Smooth playback progress interpolated on the render server, without a TimelineView.
struct DockMusicProgressLine: NSViewRepresentable {
    let snapshot: NowPlayingSnapshot

    func makeNSView(context: Context) -> DockMusicProgressNSView { DockMusicProgressNSView() }
    func updateNSView(_ view: DockMusicProgressNSView, context: Context) {
        view.configure(snapshot: snapshot)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DockMusicProgressNSView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: 2.5)
    }
    static func dismantleNSView(_ view: DockMusicProgressNSView, coordinator: ()) { view.stopAnimations() }
}

final class DockMusicProgressNSView: DockMusicAnimationNSView {
    private let fill = CALayer()
    private var snapshot: NowPlayingSnapshot?
    static let progressKey = "playback.progress"

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.15).cgColor
        layer?.masksToBounds = true
        fill.backgroundColor = NSColor.white.withAlphaComponent(0.75).cgColor
        fill.anchorPoint = CGPoint(x: 0, y: 0.5)
        layer?.addSublayer(fill)
        setAccessibilityElement(false)
    }

    convenience init() { self.init(frame: .zero) }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(snapshot: NowPlayingSnapshot) {
        guard self.snapshot != snapshot else { return }
        self.snapshot = snapshot
        updateAnimation()
    }

    override func layout() { super.layout(); updateAnimation() }
    override func visibilityChanged() { updateAnimation() }
    override func stopAnimations() { fill.removeAnimation(forKey: Self.progressKey) }

    private func updateAnimation() {
        guard let snapshot else { return }
        stopAnimations()
        let now = Date()
        let progress = snapshot.progress(at: now)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.cornerRadius = bounds.height / 2
        fill.cornerRadius = bounds.height / 2
        fill.position = CGPoint(x: 0, y: bounds.midY)
        fill.bounds = CGRect(x: 0, y: 0, width: bounds.width * progress, height: bounds.height)
        CATransaction.commit()
        // This functional time indicator remains accurate with Reduce Motion, as
        // before; only the decorative title/equalizer motion is disabled there.
        guard animationIsVisible, snapshot.playbackState.isPlaying,
              snapshot.playbackRate > 0, progress < 1, snapshot.duration > 0, bounds.width > 0 else { return }
        let remaining = (snapshot.duration - snapshot.elapsedTime(at: now)) / snapshot.playbackRate
        let animation = CABasicAnimation(keyPath: "bounds.size.width")
        animation.fromValue = bounds.width * progress
        animation.toValue = bounds.width
        animation.duration = remaining
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.isRemovedOnCompletion = false
        animation.fillMode = .forwards
        fill.add(animation, forKey: Self.progressKey)
    }

    var progressAnimation: CABasicAnimation? { fill.animation(forKey: Self.progressKey) as? CABasicAnimation }
    var progressWidth: CGFloat { fill.bounds.width }
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

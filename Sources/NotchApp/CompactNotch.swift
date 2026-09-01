import AppKit
import SwiftUI

enum CompactMusicArtwork {
    static func image(from data: Data?) -> NSImage? {
        guard let data else { return nil }
        return NSImage(data: data)
    }
}

struct CompactNotch: View {
    @ObservedObject var model: NotchViewModel
    @ObservedObject var visualSettings: NotchVisualSettings
    let onExpand: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isPlaying: Bool {
        model.nowPlayingSnapshot?.playbackState.isPlaying == true
    }

    private var compactSize: CGSize {
        NotchLayout.compactSize(
            isPlaying: isPlaying,
            compactHeight: visualSettings.compactHeight
        )
    }

    var body: some View {
        Button(action: onExpand) {
            compactContent
                .frame(
                    width: compactSize.width,
                    height: visualSettings.compactHeight
                )
                .background(Color.black)
                .clipShape(
                    UnevenRoundedRectangle(
                        cornerRadii: RectangleCornerRadii(
                            topLeading: 0,
                            bottomLeading: NotchLayout.compactBottomRadius,
                            bottomTrailing: NotchLayout.compactBottomRadius,
                            topTrailing: 0
                        ),
                        style: .continuous
                    )
                )
                .overlay {
                    CompactQuotaBorder(
                        remainingRatio: model.compactWeeklyRemainingRatio,
                        lineColor: visualSettings.lineColor,
                        lineGradientColor: visualSettings.lineGradientColor,
                        lineMode: visualSettings.lineMode,
                        showsLine: visualSettings.showsLine,
                        pulsesLine: visualSettings.pulsesLine,
                        pulseIntensity: visualSettings.pulseIntensity,
                        pulseSpeed: visualSettings.pulseSpeed,
                        reduceMotion: reduceMotion
                    )
                }
                .compositingGroup()
                .animation(
                    reduceMotion ? .linear(duration: 0.01) : .easeInOut(duration: 0.30),
                    value: isPlaying
                )
                .animation(
                    reduceMotion ? .linear(duration: 0.01) : .easeInOut(duration: 0.24),
                    value: visualSettings.compactHeight
                )
        }
        .buttonStyle(NotchButtonStyle())
        .frame(
            width: compactSize.width,
            height: compactSize.height,
            alignment: .top
        )
        .contentShape(Rectangle())
        .accessibilityLabel("Открыть Notch")
    }

    @ViewBuilder
    private var compactContent: some View {
        let physicalNotchSize = NotchLayout.physicalNotchSize

        if physicalNotchSize.width > 0, physicalNotchSize.height > 0 {
            if isPlaying {
                HStack(spacing: 0) {
                    musicIndicator
                        .frame(width: NotchLayout.compactWingWidth)

                    PhysicalNotchSafeZone(size: physicalNotchSize)
                        .frame(width: physicalNotchSize.width)

                    CompactWeeklyQuotaIndicator(
                        remainingRatio: model.compactWeeklyRemainingRatio,
                        providerName: model.compactQuotaProviderName
                    )
                    .frame(width: NotchLayout.compactWingWidth)
                }
            } else {
                PhysicalNotchSafeZone(size: physicalNotchSize)
                    .frame(width: physicalNotchSize.width)
            }
        } else {
            HStack(spacing: 0) {
                if isPlaying {
                    musicIndicator
                        .padding(.leading, 14)
                }

                Spacer(minLength: 0)

                if isPlaying {
                    CompactWeeklyQuotaIndicator(
                        remainingRatio: model.compactWeeklyRemainingRatio,
                        providerName: model.compactQuotaProviderName
                    )
                    .padding(.trailing, 14)
                }
            }
        }
    }

    @ViewBuilder
    private var musicIndicator: some View {
        if let snapshot = model.nowPlayingSnapshot {
            CompactMusicIndicator(snapshot: snapshot, reduceMotion: reduceMotion)
        } else {
            Color.clear
        }
    }
}

private struct CompactWeeklyQuotaIndicator: View {
    let remainingRatio: Double?
    let providerName: String

    private var percentage: Int? {
        remainingRatio.map { ratio in
            Int((min(max(ratio, 0), 1) * 100).rounded())
        }
    }

    private var valueColor: Color {
        guard let remainingRatio else { return .white.opacity(0.34) }
        return remainingRatio < 0.2 ? .signalCoral : .signalMint
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text("7d")
                .font(.system(size: 8, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.42))

            Text(percentage.map { "\($0)%" } ?? "--")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(valueColor)
        }
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        if let percentage {
            return "Недельный лимит \(providerName): осталось \(percentage) процентов"
        }
        return "Недельный лимит \(providerName) недоступен"
    }
}

private struct CompactMusicIndicator: View {
    let snapshot: NowPlayingSnapshot
    let reduceMotion: Bool

    var body: some View {
        HStack(spacing: 5) {
            CompactMusicArtworkView(data: snapshot.artworkData)

            CompactMusicActivityBars(
                isPlaying: snapshot.playbackState.isPlaying,
                reduceMotion: reduceMotion
            )
            .frame(width: 12, height: 14)
        }
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        if snapshot.playbackState.isPlaying {
            "Сейчас играет: \(snapshot.title), \(snapshot.artist)"
        } else {
            "Музыка на паузе: \(snapshot.title), \(snapshot.artist)"
        }
    }
}

private struct CompactMusicArtworkView: View {
    let data: Data?

    var body: some View {
        Group {
            if let image = CompactMusicArtwork.image(from: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .overlay {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(.white.opacity(0.14), lineWidth: 0.5)
                    }
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.signalMint)
            }
        }
        .frame(width: 18, height: 18)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

private struct CompactMusicActivityBars: NSViewRepresentable {
    let isPlaying: Bool
    let reduceMotion: Bool

    func makeNSView(context: Context) -> CompactMusicActivityBarsView {
        let view = CompactMusicActivityBarsView(frame: .zero)
        view.update(isPlaying: isPlaying, reduceMotion: reduceMotion)
        return view
    }

    func updateNSView(_ nsView: CompactMusicActivityBarsView, context: Context) {
        nsView.update(isPlaying: isPlaying, reduceMotion: reduceMotion)
    }

    static func dismantleNSView(_ nsView: CompactMusicActivityBarsView, coordinator: ()) {
        nsView.stopAnimating()
    }
}

private final class CompactMusicActivityBarsView: NSView {
    private static let animationKey = "musicActivity"
    private static let pausedScales: [CGFloat] = [0.45, 0.72, 0.55]
    private static let playingScales: [[CGFloat]] = [
        [0.42, 1.0, 0.68, 0.42],
        [0.78, 0.46, 1.0, 0.78],
        [1.0, 0.72, 0.42, 1.0]
    ]

    private let barLayers = (0..<3).map { _ in CALayer() }
    private var currentState: (isPlaying: Bool, reduceMotion: Bool)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        for barLayer in barLayers {
            barLayer.cornerRadius = 1.25
            layer?.addSublayer(barLayer)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()

        let barWidth: CGFloat = 2.5
        let barHeight: CGFloat = 12
        let spacing: CGFloat = 2
        let contentWidth = barWidth * 3 + spacing * 2
        let originX = (bounds.width - contentWidth) / 2

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, barLayer) in barLayers.enumerated() {
            barLayer.bounds = CGRect(x: 0, y: 0, width: barWidth, height: barHeight)
            barLayer.position = CGPoint(
                x: originX + barWidth / 2 + CGFloat(index) * (barWidth + spacing),
                y: bounds.midY
            )
        }
        CATransaction.commit()
    }

    func update(isPlaying: Bool, reduceMotion: Bool) {
        guard currentState?.isPlaying != isPlaying || currentState?.reduceMotion != reduceMotion else {
            return
        }
        currentState = (isPlaying, reduceMotion)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let color = NSColor(
            red: 0.37,
            green: 0.96,
            blue: 0.72,
            alpha: isPlaying ? 0.9 : 0.42
        ).cgColor

        for (index, barLayer) in barLayers.enumerated() {
            barLayer.backgroundColor = color
            barLayer.removeAnimation(forKey: Self.animationKey)

            if isPlaying, reduceMotion == false {
                barLayer.transform = CATransform3DIdentity
                barLayer.add(activityAnimation(for: index), forKey: Self.animationKey)
            } else {
                let scales = isPlaying ? Self.playingScales.map { $0[0] } : Self.pausedScales
                barLayer.transform = CATransform3DMakeScale(1, scales[index], 1)
            }
        }
        CATransaction.commit()
    }

    func stopAnimating() {
        barLayers.forEach { $0.removeAnimation(forKey: Self.animationKey) }
    }

    private func activityAnimation(for index: Int) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: "transform.scale.y")
        animation.values = Self.playingScales[index]
        animation.keyTimes = [0, 0.33, 0.66, 1]
        animation.timingFunctions = Array(
            repeating: CAMediaTimingFunction(name: .easeInEaseOut),
            count: 3
        )
        animation.duration = 1.14
        animation.repeatCount = .infinity
        return animation
    }
}

private struct CompactQuotaGradient: NSViewRepresentable {
    let primaryColor: Color
    let secondaryColor: Color
    let isAnimating: Bool
    let rotationsPerSecond: Double

    func makeNSView(context: Context) -> CompactQuotaGradientView {
        let view = CompactQuotaGradientView(frame: .zero)
        update(view)
        return view
    }

    func updateNSView(_ nsView: CompactQuotaGradientView, context: Context) {
        update(nsView)
    }

    static func dismantleNSView(_ nsView: CompactQuotaGradientView, coordinator: ()) {
        nsView.stopAnimating()
    }

    private func update(_ view: CompactQuotaGradientView) {
        view.update(
            primaryColor: NSColor(primaryColor).usingColorSpace(.deviceRGB) ?? .white,
            secondaryColor: NSColor(secondaryColor).usingColorSpace(.deviceRGB) ?? .white,
            isAnimating: isAnimating,
            rotationsPerSecond: rotationsPerSecond
        )
    }
}

final class CompactQuotaGradientView: NSView {
    private static let animationKey = "quotaGradientRotation"

    private let gradientLayer = CAGradientLayer()
    private var currentPrimaryColor: NSColor?
    private var currentSecondaryColor: NSColor?
    private var currentAnimationSpeed: Double?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true

        gradientLayer.type = .conic
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradientLayer.endPoint = CGPoint(x: 0.5, y: 0)
        gradientLayer.locations = [0, 0.5, 1]
        layer?.addSublayer(gradientLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()

        let side = hypot(bounds.width, bounds.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradientLayer.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        gradientLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    func update(
        primaryColor: NSColor,
        secondaryColor: NSColor,
        isAnimating: Bool,
        rotationsPerSecond: Double
    ) {
        if currentPrimaryColor != primaryColor || currentSecondaryColor != secondaryColor {
            currentPrimaryColor = primaryColor
            currentSecondaryColor = secondaryColor

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            gradientLayer.colors = [
                primaryColor.cgColor,
                secondaryColor.cgColor,
                primaryColor.cgColor
            ]
            CATransaction.commit()
        }

        let animationSpeed = isAnimating ? min(max(rotationsPerSecond, 0.1), 1.5) : nil
        guard currentAnimationSpeed != animationSpeed else { return }
        currentAnimationSpeed = animationSpeed

        gradientLayer.removeAnimation(forKey: Self.animationKey)
        guard let animationSpeed else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            gradientLayer.transform = CATransform3DIdentity
            CATransaction.commit()
            return
        }

        let animation = CABasicAnimation(keyPath: "transform.rotation.z")
        animation.fromValue = 0
        animation.toValue = Double.pi * 2
        animation.duration = 1 / animationSpeed
        animation.repeatCount = .infinity
        gradientLayer.add(animation, forKey: Self.animationKey)
    }

    func stopAnimating() {
        gradientLayer.removeAnimation(forKey: Self.animationKey)
    }
}

private struct CompactQuotaBorder: View {
    let remainingRatio: Double?
    let lineColor: Color
    let lineGradientColor: Color
    let lineMode: IndicatorColorMode
    let showsLine: Bool
    let pulsesLine: Bool
    let pulseIntensity: Double
    let pulseSpeed: Double
    let reduceMotion: Bool

    var body: some View {
        borderContent(glow: pulsesLine ? min(max(pulseIntensity, 0), 2) : 0)
    }

    @ViewBuilder
    private func borderContent(glow: Double) -> some View {
        ZStack {
            if showsLine {
                LowerNotchBorderShape(radius: NotchLayout.compactBottomRadius - 1)
                    .stroke(.white.opacity(0.11), lineWidth: 1)

                if let remainingRatio, remainingRatio > 0 {
                    let clampedRatio = min(max(remainingRatio, 0), 1)

                    progressStroke(
                        to: clampedRatio,
                        style: StrokeStyle(lineWidth: 2.5 + glow * 0.6)
                    )
                        .opacity(0.3 + glow * 0.12)
                        .blur(radius: 2.5 + glow * 0.8)

                    progressStroke(
                        to: clampedRatio,
                        style: StrokeStyle(
                            lineWidth: 1.6,
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                        .opacity(0.78)
                        .shadow(
                            color: lineColor.opacity(0.35 + glow * 0.18),
                            radius: 3 + glow * 1.2
                        )
                        .animation(.easeInOut(duration: 0.25), value: remainingRatio)
                }
            }
        }
        .clipShape(
            UnevenRoundedRectangle(
                cornerRadii: RectangleCornerRadii(
                    topLeading: 0,
                    bottomLeading: NotchLayout.compactBottomRadius,
                    bottomTrailing: NotchLayout.compactBottomRadius,
                    topTrailing: 0
                ),
                style: .continuous
            )
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func progressStroke(to ratio: Double, style: StrokeStyle) -> some View {
        let shape = LowerNotchBorderShape(radius: NotchLayout.compactBottomRadius - 1)

        if lineMode == .gradient {
            CompactQuotaGradient(
                primaryColor: lineColor,
                secondaryColor: lineGradientColor,
                isAnimating: pulsesLine && reduceMotion == false,
                rotationsPerSecond: pulseSpeed
            )
            .mask {
                shape
                    .trim(from: 0, to: ratio)
                    .stroke(style: style)
            }
        } else {
            shape
                .trim(from: 0, to: ratio)
                .stroke(lineColor, style: style)
        }
    }

}

private struct LowerNotchBorderShape: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let insetRect = rect.insetBy(dx: 1, dy: 1)
        let radius = min(self.radius, min(insetRect.width, insetRect.height / 2))

        var path = Path()
        path.move(to: CGPoint(x: insetRect.minX, y: insetRect.minY))
        path.addLine(to: CGPoint(x: insetRect.minX, y: insetRect.maxY - radius))
        path.addQuadCurve(
            to: CGPoint(x: insetRect.minX + radius, y: insetRect.maxY),
            control: CGPoint(x: insetRect.minX, y: insetRect.maxY)
        )
        path.addLine(to: CGPoint(x: insetRect.maxX - radius, y: insetRect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: insetRect.maxX, y: insetRect.maxY - radius),
            control: CGPoint(x: insetRect.maxX, y: insetRect.maxY)
        )
        path.addLine(to: CGPoint(x: insetRect.maxX, y: insetRect.minY))
        return path
    }
}

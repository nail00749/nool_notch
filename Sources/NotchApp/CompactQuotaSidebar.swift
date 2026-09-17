import NotchCore
import SwiftUI

enum QuotaEdgePanelLayout {
    static let railWidth: CGFloat = 70
    static let rowHeight: CGFloat = 60
    static let verticalPadding: CGFloat = 40
    static let triggerHitWidth: CGFloat = 8
    static let triggerIndicatorWidth: CGFloat = 2
    static let triggerIndicatorHeight: CGFloat = 72
    static let screenTopInset: CGFloat = 72
    static let detailGap: CGFloat = 6
    static let detailScreenMargin: CGFloat = 8
    static let detailContentWidth: CGFloat = 220
    static let detailMaximumHeight: CGFloat = 156
    static let detailShadowPadding: CGFloat = 12

    static var detailWindowSize: CGSize {
        CGSize(
            width: detailContentWidth + detailShadowPadding * 2,
            height: detailMaximumHeight + detailShadowPadding * 2
        )
    }

    static func railSize(providerCount: Int) -> CGSize {
        CGSize(
            width: railWidth,
            height: verticalPadding * 2 + CGFloat(max(providerCount, 0)) * rowHeight
        )
    }

    static func railFrame(
        in screenFrame: CGRect,
        edge: QuotaPanelEdge,
        providerCount: Int
    ) -> CGRect {
        let size = railSize(providerCount: providerCount)
        return CGRect(
            x: edge == .left ? screenFrame.minX : screenFrame.maxX - size.width,
            y: max(screenFrame.minY, screenFrame.maxY - screenTopInset - size.height),
            width: size.width,
            height: size.height
        )
    }

    static func triggerFrame(
        in screenFrame: CGRect,
        edge: QuotaPanelEdge,
        providerCount: Int
    ) -> CGRect {
        let railFrame = railFrame(
            in: screenFrame,
            edge: edge,
            providerCount: providerCount
        )
        return CGRect(
            x: edge == .left
                ? screenFrame.minX
                : screenFrame.maxX - triggerHitWidth,
            y: railFrame.minY,
            width: triggerHitWidth,
            height: railFrame.height
        )
    }

    static func detailFrame(
        in screenFrame: CGRect,
        railFrame: CGRect,
        edge: QuotaPanelEdge,
        providerIndex: Int
    ) -> CGRect {
        let size = detailWindowSize
        let rowCenterFromTop = verticalPadding
            + (CGFloat(max(providerIndex, 0)) + 0.5) * rowHeight
        let rowCenterY = railFrame.maxY - rowCenterFromTop
        let unclampedY = rowCenterY - size.height / 2
        let minimumY = screenFrame.minY + detailScreenMargin
        let maximumY = screenFrame.maxY - size.height - detailScreenMargin
        let x = edge == .left
            ? railFrame.maxX + detailGap
            : railFrame.minX - detailGap - size.width
        return CGRect(
            x: x,
            y: min(max(unclampedY, minimumY), max(minimumY, maximumY)),
            width: size.width,
            height: size.height
        )
    }
}

enum QuotaEdgeVisibilityDecision: Equatable {
    case show
    case waitForGracePeriod
    case hide
}

enum QuotaEdgeVisibilityPolicy {
    static func showsRail(triggerHovered: Bool, railHovered: Bool) -> Bool {
        triggerHovered || railHovered
    }

    static func decision(
        triggerHovered: Bool,
        railHovered: Bool,
        hideScheduled: Bool
    ) -> QuotaEdgeVisibilityDecision {
        if showsRail(triggerHovered: triggerHovered, railHovered: railHovered) {
            return .show
        }
        return hideScheduled ? .waitForGracePeriod : .hide
    }
}

struct CompactQuotaEdgeTrigger: View {
    let edge: QuotaPanelEdge
    let onHover: (Bool) -> Void

    var body: some View {
        ZStack(alignment: edge == .left ? .leading : .trailing) {
            Color.clear

            Capsule(style: .continuous)
                .fill(.black)
                .frame(
                    width: QuotaEdgePanelLayout.triggerIndicatorWidth,
                    height: QuotaEdgePanelLayout.triggerIndicatorHeight
                )
        }
        .contentShape(Rectangle())
        .onHover(perform: onHover)
        .accessibilityElement()
        .accessibilityLabel("Показать панель лимитов")
    }
}

struct CompactQuotaSidebar: View {
    @ObservedObject var model: NotchViewModel
    let edge: QuotaPanelEdge
    let onOpen: () -> Void
    let onPanelHover: (Bool) -> Void
    let onProviderHover: (String?) -> Void

    private var providers: [any QuotaProvider] {
        model.visibleQuotaProviders
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(providers, id: \.id) { provider in
                providerButton(provider)
            }
        }
        .padding(.vertical, QuotaEdgePanelLayout.verticalPadding)
        .frame(
            width: QuotaEdgePanelLayout.railWidth,
            height: QuotaEdgePanelLayout.railSize(providerCount: providers.count).height
        )
        .background {
            QuotaEdgeWaveShape(edge: edge)
                .fill(.black)
                .shadow(color: .black.opacity(0.34), radius: 12, x: edge == .left ? 5 : -5, y: 4)
        }
        .overlay {
            QuotaEdgeWaveShape(edge: edge)
                .stroke(.white.opacity(0.09), lineWidth: 0.5)
        }
        .onHover(perform: onPanelHover)
        .onDisappear {
            onPanelHover(false)
            onProviderHover(nil)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Панель лимитов")
    }

    private func providerButton(_ provider: any QuotaProvider) -> some View {
        let snapshot = model.snapshot(for: provider.id)
        let remainingRatio = preferredWindow(in: snapshot)?.remainingRatio
        let visuals = QuotaProviderVisuals(providerID: provider.id)

        return Button(action: onOpen) {
            VStack(spacing: 3) {
                ZStack {
                    Circle()
                        .stroke(
                            .white.opacity(0.14),
                            lineWidth: QuotaProviderRingStyle.trackLineWidth
                        )

                    if let remainingRatio {
                        Circle()
                            .trim(from: 0, to: min(max(remainingRatio, 0), 1))
                            .stroke(
                                visuals.color,
                                style: StrokeStyle(
                                    lineWidth: QuotaProviderRingStyle.activeLineWidth,
                                    lineCap: .round
                                )
                            )
                            .rotationEffect(.degrees(-90))
                            .shadow(
                                color: visuals.color.opacity(QuotaProviderRingStyle.glowOpacity),
                                radius: QuotaProviderRingStyle.glowRadius
                            )
                    }

                    QuotaProviderBrandIcon(
                        providerID: provider.id,
                        size: 15,
                        color: .white.opacity(0.9)
                    )
                }
                .frame(width: 34, height: 34)
                .contentShape(Circle())
                .onHover { isHovering in
                    onProviderHover(isHovering ? provider.id : nil)
                }

                Text(percentageText(remainingRatio))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(remainingRatio == nil ? 0.38 : 0.82))
            }
            .frame(width: 58, height: QuotaEdgePanelLayout.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(
            width: QuotaEdgePanelLayout.railWidth,
            height: QuotaEdgePanelLayout.rowHeight,
            alignment: edge == .left ? .trailing : .leading
        )
        .accessibilityLabel(accessibilityLabel(
            providerName: provider.displayName,
            remainingRatio: remainingRatio
        ))
        .accessibilityHint("Открывает AI, Лимиты")
    }

    private func preferredWindow(in snapshot: QuotaSnapshot?) -> QuotaWindow? {
        guard let windows = snapshot?.windows else { return nil }
        return windows.first { $0.label == "7d" && $0.unit == .percentage }
            ?? windows.first { $0.label.hasSuffix("· 7d") && $0.unit == .percentage }
            ?? windows.first { $0.unit == .percentage }
    }

    private func percentageText(_ remainingRatio: Double?) -> String {
        remainingRatio.map { "\(Int((min(max($0, 0), 1) * 100).rounded()))%" } ?? "--"
    }

    private func accessibilityLabel(providerName: String, remainingRatio: Double?) -> String {
        guard let remainingRatio else { return "\(providerName): лимит недоступен" }
        return "\(providerName): осталось \(Int((remainingRatio * 100).rounded())) процентов"
    }
}

struct CompactQuotaDetailPanel: View {
    @ObservedObject var model: NotchViewModel
    let providerID: String
    let edge: QuotaPanelEdge

    private var provider: (any QuotaProvider)? {
        model.visibleQuotaProviders.first { $0.id == providerID }
    }

    private var snapshot: QuotaSnapshot? {
        model.snapshot(for: providerID)
    }

    private var visuals: QuotaProviderVisuals {
        QuotaProviderVisuals(providerID: providerID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                QuotaProviderBrandIcon(
                    providerID: providerID,
                    size: 13,
                    color: .white.opacity(0.9)
                )
                Text(provider?.displayName ?? snapshot?.providerName ?? "Лимит")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Spacer(minLength: 4)
                Text(snapshot?.connection.label ?? "ОЖИДАНИЕ")
                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                    .tracking(0.4)
                    .foregroundStyle(statusColor)
            }

            if let snapshot, snapshot.windows.isEmpty == false {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 8, alignment: .topLeading),
                        GridItem(.flexible(), spacing: 8, alignment: .topLeading)
                    ],
                    alignment: .leading,
                    spacing: 8
                ) {
                    ForEach(Array(snapshot.windows.prefix(4))) { window in
                        CompactQuotaHoverWindow(window: window, accent: visuals.color)
                    }
                }

                if snapshot.windows.count > 4 {
                    Text("Еще \(snapshot.windows.count - 4) — в полной панели")
                        .font(.system(size: 7, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.34))
                }
            } else {
                Text(snapshot?.message ?? "Обновляю данные…")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.46))
                    .lineLimit(2)
            }
        }
        .padding(.leading, edge == .left ? 16 : 10)
        .padding(.trailing, edge == .right ? 16 : 10)
        .padding(.vertical, 10)
        .frame(width: QuotaEdgePanelLayout.detailContentWidth)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            QuotaDetailBubbleShape(edge: edge)
                .fill(.black)
                .shadow(color: .black.opacity(0.40), radius: 12, y: 6)
        }
        .overlay {
            QuotaDetailBubbleShape(edge: edge)
                .stroke(.white.opacity(0.10), lineWidth: 0.5)
        }
        .padding(QuotaEdgePanelLayout.detailShadowPadding)
        .frame(
            width: QuotaEdgePanelLayout.detailWindowSize.width,
            height: QuotaEdgePanelLayout.detailWindowSize.height
        )
        .accessibilityElement(children: .contain)
    }

    private var statusColor: Color {
        switch snapshot?.connection {
        case .live: .signalMint
        case .stale, .requiresAuthentication: .signalAmber
        case .unavailable, nil: .white.opacity(0.34)
        }
    }
}

struct QuotaEdgeWaveShape: Shape {
    let edge: QuotaPanelEdge

    func path(in rect: CGRect) -> Path {
        let mirroredX: (CGFloat) -> CGFloat = { x in
            edge == .right ? x : rect.width - x
        }
        let edgeX = mirroredX(rect.width)
        let bodyX = mirroredX(1)
        let shoulderHeight = min(56, rect.height * 0.24)
        let topShoulderY = rect.minY + shoulderHeight
        let bottomShoulderY = rect.maxY - shoulderHeight
        var path = Path()

        path.move(to: CGPoint(x: edgeX, y: rect.minY))
        path.addCurve(
            to: CGPoint(x: bodyX, y: topShoulderY),
            control1: CGPoint(x: edgeX, y: rect.minY + shoulderHeight * 0.76),
            control2: CGPoint(x: bodyX, y: rect.minY + shoulderHeight * 0.38)
        )
        path.addLine(to: CGPoint(x: bodyX, y: bottomShoulderY))
        path.addCurve(
            to: CGPoint(x: edgeX, y: rect.maxY),
            control1: CGPoint(x: bodyX, y: rect.maxY - shoulderHeight * 0.38),
            control2: CGPoint(x: edgeX, y: rect.maxY - shoulderHeight * 0.76)
        )
        path.addLine(to: CGPoint(x: edgeX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

private struct QuotaDetailBubbleShape: Shape {
    let edge: QuotaPanelEdge

    func path(in rect: CGRect) -> Path {
        let arrowWidth: CGFloat = 8
        let bodyRect = edge == .left
            ? CGRect(x: arrowWidth, y: 0, width: rect.width - arrowWidth, height: rect.height)
            : CGRect(x: 0, y: 0, width: rect.width - arrowWidth, height: rect.height)
        var path = Path(roundedRect: bodyRect, cornerRadius: 14, style: .continuous)
        let midY = rect.midY
        if edge == .left {
            path.move(to: CGPoint(x: arrowWidth + 1, y: midY - 8))
            path.addQuadCurve(
                to: CGPoint(x: 0, y: midY),
                control: CGPoint(x: arrowWidth * 0.35, y: midY - 4)
            )
            path.addQuadCurve(
                to: CGPoint(x: arrowWidth + 1, y: midY + 8),
                control: CGPoint(x: arrowWidth * 0.35, y: midY + 4)
            )
        } else {
            let baseX = rect.maxX - arrowWidth - 1
            path.move(to: CGPoint(x: baseX, y: midY - 8))
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX, y: midY),
                control: CGPoint(x: rect.maxX - arrowWidth * 0.35, y: midY - 4)
            )
            path.addQuadCurve(
                to: CGPoint(x: baseX, y: midY + 8),
                control: CGPoint(x: rect.maxX - arrowWidth * 0.35, y: midY + 4)
            )
        }
        path.closeSubpath()
        return path
    }
}

private struct CompactQuotaHoverWindow: View {
    let window: QuotaWindow
    let accent: Color

    private var percentage: Int? {
        window.remainingRatio.map { Int((min(max($0, 0), 1) * 100).rounded()) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(window.label)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.68))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(percentage.map { "\($0)%" } ?? "--")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.90))
            }

            if let remainingRatio = window.remainingRatio {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.10))
                        Capsule()
                            .fill(remainingRatio < 0.2 ? Color.signalCoral : accent)
                            .frame(width: proxy.size.width * min(max(remainingRatio, 0), 1))
                    }
                }
                .frame(height: 3)
            }

            if let resetAt = window.resetAt {
                (Text("Сброс ") + Text(resetAt, style: .relative))
                    .font(.system(size: 7, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.34))
                    .lineLimit(1)
            }
        }
    }
}

enum QuotaProviderIcon: Equatable {
    case asset(String)
    case system(String)
}

struct QuotaProviderAccent: Equatable {
    let red: Double
    let green: Double
    let blue: Double

    var color: Color {
        Color(red: red, green: green, blue: blue)
    }

    static let chatGPT = QuotaProviderAccent(
        red: 16.0 / 255.0,
        green: 163.0 / 255.0,
        blue: 127.0 / 255.0
    )
    static let claude = QuotaProviderAccent(
        red: 217.0 / 255.0,
        green: 119.0 / 255.0,
        blue: 87.0 / 255.0
    )
    static let ollama = QuotaProviderAccent(
        red: 125.0 / 255.0,
        green: 211.0 / 255.0,
        blue: 252.0 / 255.0
    )
    static let fallback = QuotaProviderAccent(red: 0.37, green: 0.96, blue: 0.72)
}

enum QuotaProviderRingStyle {
    static let trackLineWidth: CGFloat = 3
    static let activeLineWidth: CGFloat = 3.5
    static let glowRadius: CGFloat = 3
    static let glowOpacity = 0.46
}

struct QuotaProviderVisuals {
    let icon: QuotaProviderIcon
    let accent: QuotaProviderAccent
    let opticalScale: CGFloat

    var color: Color { accent.color }

    init(providerID: String) {
        switch providerID {
        case "chatgpt-subscription":
            icon = .asset("QuotaChatGPT")
            accent = .chatGPT
            opticalScale = 1
        case "claude-code-subscription":
            icon = .asset("QuotaClaude")
            accent = .claude
            opticalScale = 0.92
        case "ollama-cloud":
            icon = .asset("QuotaOllama")
            accent = .ollama
            opticalScale = 0.86
        default:
            icon = .system("gauge.with.dots.needle.67percent")
            accent = .fallback
            opticalScale = 0.88
        }
    }
}

struct QuotaProviderBrandIcon: View {
    let providerID: String
    let size: CGFloat
    let color: Color

    var body: some View {
        let visuals = QuotaProviderVisuals(providerID: providerID)

        Group {
            switch visuals.icon {
            case let .asset(name):
                Image(name, bundle: .module)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
            case let .system(name):
                Image(systemName: name)
                    .resizable()
                    .scaledToFit()
            }
        }
        .foregroundStyle(color)
        .frame(
            width: size * visuals.opticalScale,
            height: size * visuals.opticalScale
        )
        .accessibilityHidden(true)
    }
}

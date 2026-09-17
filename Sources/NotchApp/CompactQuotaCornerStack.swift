import Foundation
import NotchCore
import SwiftUI

enum QuotaCornerStackLayout {
    static let itemWidth: CGFloat = 252
    static let itemHeight: CGFloat = 76
    static let ringSize: CGFloat = 48
    static let labelWidth: CGFloat = 180
    static let itemStep: CGFloat = 72
    static let fanStep: CGFloat = 12
    static let revealedMargin: CGFloat = 12
    static let firstItemOffset: CGFloat = itemHeight / 2 + revealedMargin
    static let triggerHitWidth: CGFloat = 8
    static let triggerHitHeight: CGFloat = 56
    static let triggerCornerInset: CGFloat = 0
    static let triggerIndicatorWidth: CGFloat = 2
    static let triggerIndicatorHeight: CGFloat = 40

    static var itemSize: CGSize {
        CGSize(width: itemWidth, height: itemHeight)
    }

    static func triggerFrame(in screenFrame: CGRect, corner: QuotaStackCorner) -> CGRect {
        CGRect(
            x: corner.edge == .left
                ? screenFrame.minX
                : screenFrame.maxX - triggerHitWidth,
            y: corner.isTop
                ? screenFrame.maxY - triggerCornerInset - triggerHitHeight
                : screenFrame.minY + triggerCornerInset,
            width: triggerHitWidth,
            height: triggerHitHeight
        )
    }

    static func itemFrame(
        in screenFrame: CGRect,
        corner: QuotaStackCorner,
        index: Int
    ) -> CGRect {
        let safeIndex = CGFloat(max(index, 0))
        let inwardOffset = revealedMargin + safeIndex * fanStep
        let unclampedX = corner.edge == .left
            ? screenFrame.minX + inwardOffset
            : screenFrame.maxX - itemWidth - inwardOffset
        let centerY = corner.isTop
            ? screenFrame.maxY - firstItemOffset - safeIndex * itemStep
            : screenFrame.minY + firstItemOffset + safeIndex * itemStep
        let unclampedY = centerY - itemHeight / 2
        let minimumX = screenFrame.minX + revealedMargin
        let maximumX = max(minimumX, screenFrame.maxX - itemWidth - revealedMargin)
        let minimumY = screenFrame.minY + revealedMargin
        let maximumY = max(minimumY, screenFrame.maxY - itemHeight - revealedMargin)
        return CGRect(
            x: min(max(unclampedX, minimumX), maximumX),
            y: min(max(unclampedY, minimumY), maximumY),
            width: itemWidth,
            height: itemHeight
        )
    }

    static func collapsedFrame(in screenFrame: CGRect, corner: QuotaStackCorner) -> CGRect {
        return CGRect(
            x: corner.edge == .left
                ? screenFrame.minX
                : screenFrame.maxX - itemWidth,
            y: corner.isTop
                ? screenFrame.maxY - itemHeight
                : screenFrame.minY,
            width: itemWidth,
            height: itemHeight
        )
    }

    static func restingRotation(index: Int, corner: QuotaStackCorner) -> Double {
        guard index > 0 else { return 0 }
        let magnitude = index.isMultiple(of: 2) ? 1.25 : -1.25
        return corner.edge == .left ? magnitude : -magnitude
    }
}

enum QuotaCornerStackMotion {
    static let revealDuration: TimeInterval = 0.32
    static let revealStagger: TimeInterval = 0.035
    static let hideDuration: TimeInterval = 0.22
    static let hideStagger: TimeInterval = 0.025
    static let hoverGraceDuration = Duration.milliseconds(180)
    static let initialAlpha: CGFloat = 0.08
    static let reducedMotionDuration: TimeInterval = 0.16
}

enum QuotaCornerStackVisibilityDecision: Equatable {
    case show
    case waitForGracePeriod
    case hide
}

enum QuotaCornerStackVisibilityPolicy {
    static func decision(
        triggerHovered: Bool,
        hoveredProviderIDs: Set<String>,
        hideScheduled: Bool
    ) -> QuotaCornerStackVisibilityDecision {
        if triggerHovered || hoveredProviderIDs.isEmpty == false {
            return .show
        }
        return hideScheduled ? .waitForGracePeriod : .hide
    }
}

struct CompactQuotaCornerTrigger: View {
    let corner: QuotaStackCorner
    let onHover: (Bool) -> Void

    var body: some View {
        ZStack(alignment: cornerAlignment) {
            Color.clear

            Capsule(style: .continuous)
                .fill(.black)
                .frame(
                    width: QuotaCornerStackLayout.triggerIndicatorWidth,
                    height: QuotaCornerStackLayout.triggerIndicatorHeight
                )
        }
        .contentShape(Rectangle())
        .onHover(perform: onHover)
        .accessibilityElement()
        .accessibilityLabel("Показать стек лимитов")
    }

    private var cornerAlignment: Alignment {
        switch corner {
        case .topLeft: .topLeading
        case .topRight: .topTrailing
        case .bottomLeft: .bottomLeading
        case .bottomRight: .bottomTrailing
        }
    }
}

struct CompactQuotaCornerStackItem: View {
    @ObservedObject var model: NotchViewModel
    let providerID: String
    let corner: QuotaStackCorner
    let index: Int
    let onOpen: () -> Void
    let onHover: (Bool) -> Void

    @State private var isHovered = false

    private var provider: (any QuotaProvider)? {
        model.visibleQuotaProviders.first { $0.id == providerID }
    }

    private var snapshot: QuotaSnapshot? {
        model.snapshot(for: providerID)
    }

    private var preferredWindow: QuotaWindow? {
        guard let windows = snapshot?.windows else { return nil }
        return windows.first { $0.label == "7d" && $0.unit == .percentage }
            ?? windows.first { $0.label.hasSuffix("· 7d") && $0.unit == .percentage }
            ?? windows.first { $0.unit == .percentage }
    }

    private var remainingRatio: Double? {
        preferredWindow?.remainingRatio
    }

    private var percentageText: String {
        remainingRatio.map { "\(Int((min(max($0, 0), 1) * 100).rounded()))%" } ?? "--"
    }

    private var resetHint: String {
        if let resetAt = preferredWindow?.resetAt {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            return "Сброс \(formatter.localizedString(for: resetAt, relativeTo: Date()))"
        }
        return switch snapshot?.connection {
        case .requiresAuthentication: "Нужен вход"
        case .stale: "Данные устарели"
        case .unavailable, nil: "Лимит недоступен"
        case .live: "Сброс неизвестен"
        }
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: -10) {
                if corner.edge == .left {
                    quotaRing
                        .zIndex(1)
                    quotaLabel
                } else {
                    quotaLabel
                    quotaRing
                        .zIndex(1)
                }
            }
            .frame(
                width: QuotaCornerStackLayout.itemWidth,
                height: QuotaCornerStackLayout.itemHeight,
                alignment: cornerAlignment
            )
            .rotationEffect(.degrees(QuotaCornerStackLayout.restingRotation(index: index, corner: corner)))
            .scaleEffect(isHovered ? 1.025 : 1)
            .animation(.easeOut(duration: 0.14), value: isHovered)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
            onHover(hovering)
        }
        .onDisappear { onHover(false) }
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Открывает AI, Лимиты")
    }

    private var cornerAlignment: Alignment {
        switch corner {
        case .topLeft: .topLeading
        case .topRight: .topTrailing
        case .bottomLeft: .bottomLeading
        case .bottomRight: .bottomTrailing
        }
    }

    private var quotaRing: some View {
        let visuals = QuotaProviderVisuals(providerID: providerID)
        return ZStack {
            Circle()
                .fill(.black.opacity(0.90))
                .shadow(color: .black.opacity(0.52), radius: 9, y: 5)

            Circle()
                .stroke(.white.opacity(0.13), lineWidth: QuotaProviderRingStyle.trackLineWidth)
                .padding(3)

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
                    .padding(3)
            }

            QuotaProviderBrandIcon(
                providerID: providerID,
                size: 18,
                color: .white.opacity(0.94)
            )
        }
        .frame(width: QuotaCornerStackLayout.ringSize, height: QuotaCornerStackLayout.ringSize)
        .overlay {
            Circle().stroke(.white.opacity(0.09), lineWidth: 0.75)
        }
    }

    private var quotaLabel: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(provider?.displayName ?? snapshot?.providerName ?? "Лимит")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.94))
                    .lineLimit(1)
                Text(resetHint)
                    .font(.system(size: 8, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.42))
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Text(percentageText)
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(remainingRatio == nil ? 0.38 : 0.92))
        }
        .padding(.leading, corner.edge == .left ? 18 : 14)
        .padding(.trailing, corner.edge == .right ? 18 : 14)
        .frame(width: QuotaCornerStackLayout.labelWidth, height: 48)
        .background(
            Color.black.opacity(0.82),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(.white.opacity(isHovered ? 0.14 : 0.08), lineWidth: 0.75)
        }
        .shadow(color: .black.opacity(0.34), radius: 10, y: 5)
    }

    private var accessibilityLabel: String {
        let name = provider?.displayName ?? snapshot?.providerName ?? "Лимит"
        guard remainingRatio != nil else { return "\(name): лимит недоступен. \(resetHint)" }
        return "\(name): осталось \(percentageText). \(resetHint)"
    }
}

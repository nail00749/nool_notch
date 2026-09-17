import AppKit
import CoreGraphics
import QuartzCore
import SwiftUI
import XCTest
@testable import NotchApp

final class NotchInteractionTests: XCTestCase {
    @MainActor
    func testCompactHeightDefaultsToFortyAndPersists() {
        let suiteName = "NotchInteractionTests.compactHeight.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = NotchVisualSettings(defaults: defaults)
        XCTAssertEqual(settings.compactHeight, 40)

        settings.compactHeight = 42

        let restoredSettings = NotchVisualSettings(defaults: defaults)
        XCTAssertEqual(restoredSettings.compactHeight, 42)
    }

    @MainActor
    func testCompactQuotaGradientUsesOversizedCompositorRotation() throws {
        let view = CompactQuotaGradientView(
            frame: CGRect(x: 0, y: 0, width: 340, height: 44)
        )
        view.update(
            primaryColor: .systemMint,
            secondaryColor: .systemBlue,
            isAnimating: true,
            rotationsPerSecond: 0.55
        )
        view.layoutSubtreeIfNeeded()

        let gradientLayer = try XCTUnwrap(
            view.layer?.sublayers?.compactMap { $0 as? CAGradientLayer }.first
        )
        let animation = try XCTUnwrap(
            gradientLayer.animation(forKey: "quotaGradientRotation") as? CABasicAnimation
        )

        XCTAssertEqual(gradientLayer.type, .conic)
        XCTAssertEqual(gradientLayer.bounds.width, gradientLayer.bounds.height, accuracy: 0.001)
        XCTAssertGreaterThan(gradientLayer.bounds.width, view.bounds.width)
        XCTAssertEqual(animation.keyPath, "transform.rotation.z")
        XCTAssertEqual(animation.repeatCount, .infinity)
    }

    @MainActor
    func testCompactQuotaGradientStopsRotationWhenMotionIsReduced() {
        let view = CompactQuotaGradientView(
            frame: CGRect(x: 0, y: 0, width: 340, height: 44)
        )
        view.update(
            primaryColor: .systemMint,
            secondaryColor: .systemBlue,
            isAnimating: true,
            rotationsPerSecond: 0.55
        )
        view.update(
            primaryColor: .systemMint,
            secondaryColor: .systemBlue,
            isAnimating: false,
            rotationsPerSecond: 0.55
        )

        let gradientLayer = view.layer?.sublayers?.compactMap { $0 as? CAGradientLayer }.first
        XCTAssertNil(gradientLayer?.animation(forKey: "quotaGradientRotation"))
    }

    func testCompactLayoutUsesSideWingsAroundPhysicalNotch() {
        let metrics = NotchLayout.metrics(
            safeAreaTop: 38,
            leftAuxiliaryArea: CGRect(x: 0, y: 1_131, width: 790, height: 38),
            rightAuxiliaryArea: CGRect(x: 1_010, y: 1_131, width: 790, height: 38)
        )

        XCTAssertEqual(metrics.physicalNotchSize, CGSize(width: 220, height: 38))
        XCTAssertEqual(metrics.compactSize, CGSize(width: 340, height: 40))
        XCTAssertEqual(metrics.expandedSize, CGSize(width: 500, height: 338))
        XCTAssertEqual(metrics.expandedMusicSize, CGSize(width: 500, height: 380))
        XCTAssertEqual(metrics.expandedCalendarSize, CGSize(width: 500, height: 498))
    }

    func testCompactHeightRangeKeepsMinimumInteractionFrame() {
        let metrics = NotchLayout.metrics(
            safeAreaTop: 0,
            leftAuxiliaryArea: nil,
            rightAuxiliaryArea: nil
        )

        XCTAssertEqual(NotchLayout.compactHeightRange, 39...42)
        XCTAssertEqual(
            metrics.compactSize(isPlaying: true, compactHeight: 39),
            CGSize(width: 226, height: 40)
        )
        XCTAssertEqual(
            metrics.compactSize(isPlaying: true, compactHeight: 40),
            CGSize(width: 226, height: 40)
        )
        XCTAssertEqual(
            metrics.compactSize(isPlaying: true, compactHeight: 42),
            CGSize(width: 226, height: 42)
        )
    }

    func testExpandedHeaderUsesEqualSideWingsAroundPhysicalNotch() {
        let metrics = NotchLayout.metrics(
            safeAreaTop: 38,
            leftAuxiliaryArea: CGRect(x: 0, y: 1_131, width: 790, height: 38),
            rightAuxiliaryArea: CGRect(x: 1_010, y: 1_131, width: 790, height: 38)
        )

        XCTAssertEqual(metrics.expandedHeaderWingWidth, 140)
    }

    func testExpandedHeaderUsesFullWidthWithoutPhysicalNotch() {
        let metrics = NotchLayout.metrics(
            safeAreaTop: 0,
            leftAuxiliaryArea: nil,
            rightAuxiliaryArea: nil
        )

        XCTAssertNil(metrics.expandedHeaderWingWidth)
    }

    func testLayoutKeepsOriginalSizesOnADisplayWithoutANotch() {
        let metrics = NotchLayout.metrics(
            safeAreaTop: 0,
            leftAuxiliaryArea: nil,
            rightAuxiliaryArea: nil
        )

        XCTAssertEqual(metrics.physicalNotchSize, .zero)
        XCTAssertEqual(metrics.compactSize, CGSize(width: 226, height: 40))
        XCTAssertEqual(metrics.expandedSize, CGSize(width: 500, height: 300))
        XCTAssertEqual(metrics.expandedMusicSize, CGSize(width: 500, height: 404))
        XCTAssertEqual(metrics.expandedCalendarSize, CGSize(width: 500, height: 460))
    }

    func testHoverOnlyEnlargesCompactGeometryAndDoesNotChangeExpandedGeometry() {
        let metrics = NotchLayoutMetrics(physicalNotchSize: .zero)
        let idle = metrics.compactSize(isPlaying: false)
        let hovered = metrics.compactSize(isPlaying: false, isHovered: true)
        XCTAssertEqual(hovered.width - idle.width, 24)
        XCTAssertEqual(hovered.height - idle.height, 6)
        let window = NotchWindowSizingPolicy.compactInteractionSize(
            metrics: metrics, isPlaying: false, isHovered: true
        )
        XCTAssertGreaterThan(window.width, hovered.width)
        XCTAssertGreaterThan(window.height, hovered.height)
        XCTAssertEqual(
            NotchWindowSizingPolicy.size(
                metrics: metrics, isExpanded: true, selectedPanel: .music,
                calendarViewMode: .month, isShowingSettings: false, isHovered: true
            ),
            metrics.expandedMusicSize
        )
    }

    func testPersistentRootHoverPolicyOwnsOpenAndCloseActions() {
        XCTAssertEqual(
            NotchHoverPolicy.action(
                isHovering: true,
                isExpanded: false,
                hoverExpansionEnabled: true,
                isContextMenuVisible: false
            ),
            .none
        )
        XCTAssertEqual(
            NotchHoverPolicy.action(
                isHovering: true,
                isExpanded: true,
                hoverExpansionEnabled: true,
                isContextMenuVisible: false
            ),
            .cancelCollapse
        )
        XCTAssertEqual(
            NotchHoverPolicy.action(
                isHovering: false,
                isExpanded: true,
                hoverExpansionEnabled: true,
                isContextMenuVisible: false
            ),
            .scheduleCollapse
        )
        XCTAssertEqual(
            NotchHoverPolicy.action(
                isHovering: false,
                isExpanded: true,
                hoverExpansionEnabled: true,
                isContextMenuVisible: true
            ),
            .none
        )
    }

    func testCollapseWaitsUntilExpansionAnimationHasSettled() {
        XCTAssertEqual(
            NotchHoverPolicy.collapseDelay(elapsedSinceExpansion: 0.10),
            0.62,
            accuracy: 0.001
        )
        XCTAssertEqual(
            NotchHoverPolicy.collapseDelay(elapsedSinceExpansion: 1.0),
            0.18,
            accuracy: 0.001
        )
    }

    @MainActor
    func testHostingViewCannotResizeNotchWindowBeforeCoordinator() {
        let initialFrame = NSRect(x: 650, y: 1_378, width: 500, height: 380)
        let window = NSPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow],
            backing: .buffered,
            defer: false
        )
        let hostingView = NSHostingView(
            rootView: AnyView(Color.clear.frame(width: 500, height: 380))
        )
        hostingView.sizingOptions = NotchWindowHostingPolicy.sizingOptions
        window.contentView = hostingView

        hostingView.rootView = AnyView(Color.clear.frame(width: 340, height: 40))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(window.frame, initialFrame)
    }

    @MainActor
    func testTransitionStackPinsCompactChildToTopDuringCoexistence() throws {
        let recorder = LayoutFrameRecorder()
        let initialFrame = NSRect(x: 100, y: 100, width: 500, height: 380)
        let window = NSPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow],
            backing: .buffered,
            defer: false
        )
        let hostingView = NSHostingView(
            rootView: NotchTransitionStack {
                Color.red.frame(width: 500, height: 380)
                Color.green
                    .frame(width: 340, height: 40)
                    .overlay(LayoutFrameProbe(recorder: recorder))
            }
        )
        hostingView.sizingOptions = NotchWindowHostingPolicy.sizingOptions
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        hostingView.layoutSubtreeIfNeeded()

        let compactFrame = try XCTUnwrap(recorder.frame)
        XCTAssertEqual(
            compactFrame.maxY,
            hostingView.bounds.maxY,
            accuracy: 1
        )
    }

    func testHoverExpansionUsesConfiguredDelay() {
        XCTAssertEqual(
            NotchHoverPolicy.expansionDelay(configuredDelay: 0.46),
            0.5,
            accuracy: 0.001
        )
        XCTAssertEqual(
            NotchHoverPolicy.expansionDelay(configuredDelay: -1),
            0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            NotchHoverPolicy.expansionDelay(configuredDelay: 2),
            1.5,
            accuracy: 0.001
        )
    }

    func testCollapseGuardUsesActualExpandedWindowFrame() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1_800, height: 1_169)
        let windowSize = CGSize(width: 500, height: 338)

        XCTAssertFalse(
            NotchHoverPolicy.shouldCollapse(
                pointerLocation: CGPoint(x: 900, y: 1_109),
                screenFrame: screenFrame,
                windowSize: windowSize
            )
        )
        XCTAssertTrue(
            NotchHoverPolicy.shouldCollapse(
                pointerLocation: CGPoint(x: 100, y: 669),
                screenFrame: screenFrame,
                windowSize: windowSize
            )
        )
    }

    func testWindowSizingPolicyUsesPanelSpecificExpandedHeights() {
        let metrics = NotchLayout.metrics(
            safeAreaTop: 38,
            leftAuxiliaryArea: CGRect(x: 0, y: 1_131, width: 790, height: 38),
            rightAuxiliaryArea: CGRect(x: 1_010, y: 1_131, width: 790, height: 38)
        )
        let noNotchMetrics = NotchLayout.metrics(
            safeAreaTop: 0,
            leftAuxiliaryArea: nil,
            rightAuxiliaryArea: nil
        )

        XCTAssertEqual(
            NotchWindowSizingPolicy.size(
                metrics: noNotchMetrics,
                isExpanded: true,
                selectedPanel: .music,
                calendarViewMode: .list,
                isShowingSettings: false
            ),
            CGSize(width: 500, height: 404)
        )
        XCTAssertEqual(
            NotchWindowSizingPolicy.size(
                metrics: metrics,
                isExpanded: true,
                selectedPanel: .music,
                calendarViewMode: .list,
                isShowingSettings: false
            ),
            CGSize(width: 500, height: 380)
        )
        XCTAssertEqual(
            NotchWindowSizingPolicy.size(
                metrics: metrics,
                isExpanded: true,
                selectedPanel: .jira,
                calendarViewMode: .list,
                isShowingSettings: false
            ),
            CGSize(width: 500, height: 380)
        )
        XCTAssertEqual(
            NotchWindowSizingPolicy.size(
                metrics: metrics,
                isExpanded: true,
                selectedPanel: .music,
                calendarViewMode: .list,
                isShowingSettings: true
            ),
            CGSize(width: 500, height: 338)
        )
        XCTAssertEqual(
            NotchWindowSizingPolicy.size(
                metrics: metrics,
                isExpanded: true,
                selectedPanel: .calendar,
                calendarViewMode: .month,
                isShowingSettings: false
            ),
            CGSize(width: 500, height: 498)
        )
        XCTAssertEqual(
            NotchWindowSizingPolicy.size(
                metrics: metrics,
                isExpanded: true,
                selectedPanel: .ai,
                calendarViewMode: .list,
                isShowingSettings: false
            ),
            CGSize(width: 500, height: 338)
        )
        XCTAssertEqual(
            NotchWindowSizingPolicy.size(
                metrics: metrics,
                isExpanded: false,
                selectedPanel: .music,
                calendarViewMode: .list,
                isShowingSettings: false
            ),
            CGSize(width: 376, height: 56)
        )
        XCTAssertEqual(
            NotchWindowSizingPolicy.size(
                metrics: metrics,
                isExpanded: false,
                selectedPanel: .music,
                calendarViewMode: .list,
                isShowingSettings: false,
                compactHeight: 42
            ),
            CGSize(width: 376, height: 58)
        )
    }

    func testCompactWindowHoverAreaExtendsBeyondVisibleNotch() {
        let metrics = NotchLayoutMetrics(
            physicalNotchSize: CGSize(width: 220, height: 38)
        )

        XCTAssertEqual(metrics.compactSize, CGSize(width: 340, height: 40))
        XCTAssertEqual(
            NotchWindowSizingPolicy.compactInteractionSize(metrics: metrics),
            CGSize(width: 376, height: 56)
        )

        let screen = CGRect(x: 0, y: 0, width: 1_800, height: 1_169)
        XCTAssertFalse(
            NotchHoverPolicy.shouldCollapse(
                pointerLocation: CGPoint(x: 900, y: 1_116),
                screenFrame: screen,
                windowSize: CGSize(width: 376, height: 56)
            )
        )
    }

    func testQuotaEdgeRailPinsToSelectedScreenSideNearTop() {
        let screen = CGRect(x: 100, y: 50, width: 1_800, height: 1_100)
        let expectedSize = QuotaEdgePanelLayout.railSize(providerCount: 3)

        let left = QuotaEdgePanelLayout.railFrame(
            in: screen,
            edge: .left,
            providerCount: 3
        )
        let right = QuotaEdgePanelLayout.railFrame(
            in: screen,
            edge: .right,
            providerCount: 3
        )

        XCTAssertEqual(left.size, expectedSize)
        XCTAssertEqual(left.minX, screen.minX)
        XCTAssertEqual(right.maxX, screen.maxX)
        XCTAssertEqual(left.maxY, screen.maxY - QuotaEdgePanelLayout.screenTopInset)
        XCTAssertEqual(right.maxY, left.maxY)
    }

    func testQuotaEdgeTriggerKeepsTwoPointMarkerInsideEightPointHitArea() {
        let screen = CGRect(x: 100, y: 50, width: 1_800, height: 1_100)
        let left = QuotaEdgePanelLayout.triggerFrame(
            in: screen,
            edge: .left,
            providerCount: 3
        )
        let right = QuotaEdgePanelLayout.triggerFrame(
            in: screen,
            edge: .right,
            providerCount: 3
        )

        XCTAssertEqual(QuotaEdgePanelLayout.triggerIndicatorWidth, 2)
        XCTAssertEqual(left.width, 8)
        XCTAssertEqual(left.minX, screen.minX)
        XCTAssertEqual(right.maxX, screen.maxX)
        XCTAssertEqual(left.height, QuotaEdgePanelLayout.railSize(providerCount: 3).height)
    }

    func testQuotaEdgeTriggerStaysAboveRailDuringStationaryPointerHandoff() {
        XCTAssertGreaterThan(
            QuotaEdgeWindowLevel.trigger.rawValue,
            QuotaEdgeWindowLevel.rail.rawValue
        )
    }

    func testQuotaEdgePanelMotionOffsetsOutwardFromEitherScreenEdge() {
        let frame = NSRect(x: 100, y: 200, width: 70, height: 260)
        let leftReveal = QuotaEdgePanelMotion.frame(
            offsetOutwardFrom: frame,
            edge: .left,
            distance: QuotaEdgePanelMotion.revealOffset
        )
        let rightReveal = QuotaEdgePanelMotion.frame(
            offsetOutwardFrom: frame,
            edge: .right,
            distance: QuotaEdgePanelMotion.revealOffset
        )

        XCTAssertEqual(leftReveal.origin.x, frame.origin.x - 56)
        XCTAssertEqual(rightReveal.origin.x, frame.origin.x + 56)
        XCTAssertEqual(leftReveal.size, frame.size)
        XCTAssertEqual(rightReveal.size, frame.size)
        XCTAssertEqual(QuotaEdgePanelMotion.revealInitialAlpha, 0.16)
        XCTAssertEqual(QuotaEdgePanelMotion.revealDuration, 0.30)
        XCTAssertGreaterThan(QuotaEdgePanelMotion.revealDuration, QuotaEdgePanelMotion.hideDuration)
    }

    func testQuotaEdgeRailVisibilityDependsOnlyOnItsOwnHoverSurfaces() {
        XCTAssertFalse(QuotaEdgeVisibilityPolicy.showsRail(
            triggerHovered: false,
            railHovered: false
        ))
        XCTAssertTrue(QuotaEdgeVisibilityPolicy.showsRail(
            triggerHovered: true,
            railHovered: false
        ))
        XCTAssertTrue(QuotaEdgeVisibilityPolicy.showsRail(
            triggerHovered: false,
            railHovered: true
        ))
    }

    func testQuotaEdgeVisibilityWaitsForHoverGraceAcrossModelUpdates() {
        XCTAssertEqual(
            QuotaEdgeVisibilityPolicy.decision(
                triggerHovered: false,
                railHovered: false,
                hideScheduled: true
            ),
            .waitForGracePeriod
        )
        XCTAssertEqual(
            QuotaEdgeVisibilityPolicy.decision(
                triggerHovered: false,
                railHovered: true,
                hideScheduled: true
            ),
            .show
        )
        XCTAssertEqual(
            QuotaEdgeVisibilityPolicy.decision(
                triggerHovered: false,
                railHovered: false,
                hideScheduled: false
            ),
            .hide
        )
    }

    func testQuotaCornerStackFansInwardFromEveryCorner() {
        let screen = CGRect(x: -1_920, y: 40, width: 1_920, height: 1_080)
        let topLeftFirst = QuotaCornerStackLayout.itemFrame(
            in: screen,
            corner: .topLeft,
            index: 0
        )
        let topLeftSecond = QuotaCornerStackLayout.itemFrame(
            in: screen,
            corner: .topLeft,
            index: 1
        )
        let topRightFirst = QuotaCornerStackLayout.itemFrame(
            in: screen,
            corner: .topRight,
            index: 0
        )
        let bottomLeftFirst = QuotaCornerStackLayout.itemFrame(
            in: screen,
            corner: .bottomLeft,
            index: 0
        )
        let bottomLeftSecond = QuotaCornerStackLayout.itemFrame(
            in: screen,
            corner: .bottomLeft,
            index: 1
        )
        let bottomRightFirst = QuotaCornerStackLayout.itemFrame(
            in: screen,
            corner: .bottomRight,
            index: 0
        )

        XCTAssertGreaterThan(topLeftSecond.minX, topLeftFirst.minX)
        XCTAssertLessThan(topLeftSecond.midY, topLeftFirst.midY)
        XCTAssertLessThan(bottomLeftFirst.midY, bottomLeftSecond.midY)
        XCTAssertEqual(topLeftFirst.minX, bottomLeftFirst.minX)
        XCTAssertEqual(topRightFirst.maxX, bottomRightFirst.maxX)
        for frame in [topLeftFirst, topLeftSecond, topRightFirst, bottomLeftFirst, bottomLeftSecond, bottomRightFirst] {
            XCTAssertTrue(screen.contains(frame))
        }
    }

    func testQuotaCornerStackTriggerTouchesPhysicalCorner() {
        let screen = CGRect(x: 100, y: 50, width: 1_800, height: 1_100)
        let topLeft = QuotaCornerStackLayout.triggerFrame(in: screen, corner: .topLeft)
        let bottomRight = QuotaCornerStackLayout.triggerFrame(in: screen, corner: .bottomRight)

        XCTAssertEqual(QuotaCornerStackLayout.triggerIndicatorWidth, 2)
        XCTAssertEqual(topLeft.minX, screen.minX)
        XCTAssertEqual(topLeft.maxY, screen.maxY)
        XCTAssertEqual(bottomRight.maxX, screen.maxX)
        XCTAssertEqual(bottomRight.minY, screen.minY)
    }

    func testQuotaCornerStackRevealInsetsItemsWhileAnchorStaysAtPhysicalCorner() {
        let screen = CGRect(x: -1_920, y: 40, width: 1_920, height: 1_080)

        for corner in QuotaStackCorner.allCases {
            let trigger = QuotaCornerStackLayout.triggerFrame(in: screen, corner: corner)
            let firstItem = QuotaCornerStackLayout.itemFrame(
                in: screen,
                corner: corner,
                index: 0
            )
            let collapsedItem = QuotaCornerStackLayout.collapsedFrame(
                in: screen,
                corner: corner
            )

            XCTAssertTrue(screen.contains(trigger))
            XCTAssertTrue(screen.contains(firstItem))
            XCTAssertTrue(screen.contains(collapsedItem))

            if corner.edge == .left {
                XCTAssertEqual(trigger.minX, screen.minX)
                XCTAssertEqual(firstItem.minX, screen.minX + QuotaCornerStackLayout.revealedMargin)
                XCTAssertEqual(collapsedItem.minX, screen.minX)
            } else {
                XCTAssertEqual(trigger.maxX, screen.maxX)
                XCTAssertEqual(firstItem.maxX, screen.maxX - QuotaCornerStackLayout.revealedMargin)
                XCTAssertEqual(collapsedItem.maxX, screen.maxX)
            }

            if corner.isTop {
                XCTAssertEqual(trigger.maxY, screen.maxY)
                XCTAssertEqual(firstItem.maxY, screen.maxY - QuotaCornerStackLayout.revealedMargin)
                XCTAssertEqual(collapsedItem.maxY, screen.maxY)
            } else {
                XCTAssertEqual(trigger.minY, screen.minY)
                XCTAssertEqual(firstItem.minY, screen.minY + QuotaCornerStackLayout.revealedMargin)
                XCTAssertEqual(collapsedItem.minY, screen.minY)
            }
        }
    }

    func testQuotaCornerStackVisibilityUsesTriggerAndAllItemWindows() {
        XCTAssertEqual(
            QuotaCornerStackVisibilityPolicy.decision(
                triggerHovered: true,
                hoveredProviderIDs: [],
                hideScheduled: false
            ),
            .show
        )
        XCTAssertEqual(
            QuotaCornerStackVisibilityPolicy.decision(
                triggerHovered: false,
                hoveredProviderIDs: ["claude"],
                hideScheduled: true
            ),
            .show
        )
        XCTAssertEqual(
            QuotaCornerStackVisibilityPolicy.decision(
                triggerHovered: false,
                hoveredProviderIDs: [],
                hideScheduled: true
            ),
            .waitForGracePeriod
        )
        XCTAssertEqual(
            QuotaCornerStackVisibilityPolicy.decision(
                triggerHovered: false,
                hoveredProviderIDs: [],
                hideScheduled: false
            ),
            .hide
        )
    }

    func testQuotaCornerStackMotionUsesStaggeredSofterExit() {
        XCTAssertEqual(QuotaCornerStackMotion.revealDuration, 0.32)
        XCTAssertEqual(QuotaCornerStackMotion.revealStagger, 0.035)
        XCTAssertEqual(QuotaCornerStackMotion.hideDuration, 0.22)
        XCTAssertLessThan(
            QuotaCornerStackMotion.hideDuration,
            QuotaCornerStackMotion.revealDuration
        )
        XCTAssertGreaterThan(QuotaCornerStackLayout.itemHeight, 44)
        XCTAssertGreaterThanOrEqual(QuotaCornerStackLayout.ringSize, 44)
        XCTAssertEqual(
            QuotaCornerStackLayout.restingRotation(index: 0, corner: .bottomRight),
            0
        )
    }

    func testQuotaProviderVisualsUseBrandedAssetsWithOpticalSizing() {
        let chatGPT = QuotaProviderVisuals(providerID: "chatgpt-subscription")
        let claude = QuotaProviderVisuals(providerID: "claude-code-subscription")
        let ollama = QuotaProviderVisuals(providerID: "ollama-cloud")
        let fallback = QuotaProviderVisuals(providerID: "unknown")

        XCTAssertEqual(chatGPT.icon, .asset("QuotaChatGPT"))
        XCTAssertEqual(chatGPT.accent, .chatGPT)
        XCTAssertEqual(chatGPT.opticalScale, 1)
        XCTAssertEqual(claude.icon, .asset("QuotaClaude"))
        XCTAssertEqual(claude.accent, .claude)
        XCTAssertEqual(claude.opticalScale, 0.92)
        XCTAssertEqual(ollama.icon, .asset("QuotaOllama"))
        XCTAssertEqual(ollama.accent, .ollama)
        XCTAssertEqual(ollama.opticalScale, 0.86)
        XCTAssertEqual(fallback.icon, .system("gauge.with.dots.needle.67percent"))
        XCTAssertEqual(fallback.accent, .fallback)
        XCTAssertEqual(QuotaProviderRingStyle.activeLineWidth, 3.5)
        XCTAssertEqual(QuotaProviderRingStyle.glowRadius, 3)
    }

    func testQuotaEdgeDetailOpensInwardAndStaysOnScreen() {
        let screen = CGRect(x: 100, y: 50, width: 1_800, height: 1_100)
        let leftRail = QuotaEdgePanelLayout.railFrame(
            in: screen,
            edge: .left,
            providerCount: 3
        )
        let rightRail = QuotaEdgePanelLayout.railFrame(
            in: screen,
            edge: .right,
            providerCount: 3
        )

        let leftDetail = QuotaEdgePanelLayout.detailFrame(
            in: screen,
            railFrame: leftRail,
            edge: .left,
            providerIndex: 0
        )
        let rightDetail = QuotaEdgePanelLayout.detailFrame(
            in: screen,
            railFrame: rightRail,
            edge: .right,
            providerIndex: 2
        )

        XCTAssertEqual(leftDetail.minX, leftRail.maxX + QuotaEdgePanelLayout.detailGap)
        XCTAssertEqual(rightDetail.maxX, rightRail.minX - QuotaEdgePanelLayout.detailGap)
        XCTAssertGreaterThanOrEqual(leftDetail.minY, screen.minY)
        XCTAssertLessThanOrEqual(rightDetail.maxY, screen.maxY)
    }

    func testJiraDisconnectIsEnabledOnlyWhenConfiguredAndNoAsyncIntentIsBusy() {
        XCTAssertFalse(
            JiraConnectionInteractionPolicy.canDisconnect(
                isConfigured: false,
                isBusy: false
            )
        )
        XCTAssertTrue(
            JiraConnectionInteractionPolicy.canDisconnect(
                isConfigured: true,
                isBusy: false
            )
        )
        XCTAssertFalse(
            JiraConnectionInteractionPolicy.canDisconnect(
                isConfigured: true,
                isBusy: true
            )
        )
        XCTAssertFalse(
            JiraConnectionInteractionPolicy.canDisconnect(
                isConfigured: false,
                isBusy: true
            )
        )
    }

    func testJiraLoadedIssueNoticeAppearsOnlyWhenServerTotalExceedsVisibleCount() {
        XCTAssertNil(
            JiraLoadedIssueNoticePolicy.text(visibleCount: 3, total: 2)
        )
        XCTAssertNil(
            JiraLoadedIssueNoticePolicy.text(visibleCount: 3, total: 3)
        )
        XCTAssertEqual(
            JiraLoadedIssueNoticePolicy.text(visibleCount: 3, total: 8),
            "Показано 3 из 8 задач"
        )
    }

    func testJiraQuickFiltersCombineWithAND() {
        let calendar = jiraTestCalendar()
        let today = jiraTestDate(day: 28, calendar: calendar)
        let issues = [
            jiraTestIssue(
                key: "MATCH-1",
                statusCategory: "indeterminate",
                priority: "Highest",
                dueDate: jiraTestDate(day: 27, calendar: calendar)
            ),
            jiraTestIssue(
                key: "FUTURE-1",
                statusCategory: "indeterminate",
                priority: "High",
                dueDate: jiraTestDate(day: 29, calendar: calendar)
            ),
            jiraTestIssue(
                key: "NEW-1",
                statusCategory: "new",
                priority: "Critical",
                dueDate: jiraTestDate(day: 27, calendar: calendar)
            ),
            jiraTestIssue(
                key: "MEDIUM-1",
                statusCategory: "indeterminate",
                priority: "Medium",
                dueDate: jiraTestDate(day: 27, calendar: calendar)
            )
        ]

        let filtered = JiraIssueFilterPolicy.filteredIssues(
            issues,
            active: [.inProgress, .overdue, .highPriority],
            now: today,
            calendar: calendar
        )

        XCTAssertEqual(filtered.map(\.key), ["MATCH-1"])
    }

    func testJiraHighPriorityFilterRecognizesJiraPriorityNames() {
        XCTAssertTrue(JiraIssueFilterPolicy.isHighPriority("High"))
        XCTAssertTrue(JiraIssueFilterPolicy.isHighPriority("HIGHEST"))
        XCTAssertTrue(JiraIssueFilterPolicy.isHighPriority("critical"))
        XCTAssertFalse(JiraIssueFilterPolicy.isHighPriority("Medium"))
        XCTAssertFalse(JiraIssueFilterPolicy.isHighPriority(nil))
    }

    func testJiraDueDatePresentationUsesRelativeLabelsAroundToday() {
        let calendar = jiraTestCalendar()
        let today = jiraTestDate(day: 28, calendar: calendar)

        XCTAssertEqual(
            JiraIssuePresentation.dueDateText(
                jiraTestDate(day: 27, calendar: calendar),
                relativeTo: today,
                calendar: calendar
            ),
            "Просрочено на 1 д."
        )
        XCTAssertEqual(
            JiraIssuePresentation.dueDateText(
                today,
                relativeTo: today,
                calendar: calendar
            ),
            "Сегодня"
        )
        XCTAssertEqual(
            JiraIssuePresentation.dueDateText(
                jiraTestDate(day: 29, calendar: calendar),
                relativeTo: today,
                calendar: calendar
            ),
            "Завтра"
        )
    }

    func testJiraNotConfiguredRecoveryOffersConnectSettingsIntent() {
        XCTAssertEqual(
            JiraPanelConnectionRecoveryPolicy.presentation(for: .notConfigured),
            JiraPanelConnectionRecoveryPresentation(
                title: "Подключите Jira",
                detail: "Откройте Настройки и укажите Base URL и PAT.",
                actionTitle: "Подключить Jira",
                intent: .openSettings
            )
        )
    }

    func testJiraUnauthorizedRecoveryOffersInvalidPATSettingsIntent() {
        XCTAssertEqual(
            JiraPanelConnectionRecoveryPolicy.presentation(for: .failed(.unauthorized)),
            JiraPanelConnectionRecoveryPresentation(
                title: "PAT недействителен",
                detail: "Укажите новый PAT в настройках Jira.",
                actionTitle: "Открыть настройки",
                intent: .openSettings
            )
        )
    }

    func testJiraOtherConnectionErrorsKeepExistingSafeHandling() {
        XCTAssertNil(
            JiraPanelConnectionRecoveryPolicy.presentation(for: .failed(.forbidden))
        )
        XCTAssertNil(
            JiraPanelConnectionRecoveryPolicy.presentation(for: .failed(.network))
        )
    }

    func testJiraConnectionResultAcceptanceRequiresTheExactCurrentDraft() {
        XCTAssertTrue(
            JiraConnectionResultAcceptancePolicy.shouldAccept(
                submittedDraft: "draft-a",
                currentDraft: "draft-a"
            )
        )
        XCTAssertFalse(
            JiraConnectionResultAcceptancePolicy.shouldAccept(
                submittedDraft: "draft-a",
                currentDraft: "edited-draft"
            )
        )
    }

    @MainActor
    func testWorklogIconUsesSystemSymbolsAvailableOnMacOS() {
        for symbolName in JiraWorklogIcon.symbolNames {
            XCTAssertNotNil(
                NSImage(systemSymbolName: symbolName, accessibilityDescription: nil),
                "Expected SF Symbol \(symbolName) to be available on macOS"
            )
        }
    }

    @MainActor
    func testWorklogWheelHapticEmitsOnePulsePerSelection() {
        var pulseCount = 0

        NotchHaptics.wheelSelectionChanged(performPulse: {
            pulseCount += 1
        })

        XCTAssertEqual(pulseCount, 1)
    }

    func testWorklogPopoverDisablesAnimationOnlyWhenDismissing() {
        XCTAssertFalse(
            JiraWorklogPopoverAnimationPolicy.disablesAnimations(isPresented: true)
        )
        XCTAssertTrue(
            JiraWorklogPopoverAnimationPolicy.disablesAnimations(isPresented: false)
        )
    }

    private func jiraTestCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func jiraTestDate(day: Int, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 8, day: day, hour: 12))!
    }

    private func jiraTestIssue(
        key: String,
        statusCategory: String,
        priority: String?,
        dueDate: Date?
    ) -> JiraIssue {
        JiraIssue(
            id: key,
            key: key,
            summary: "Issue \(key)",
            projectKey: "APP",
            projectName: "Application",
            status: JiraStatus(id: statusCategory, name: statusCategory, categoryKey: statusCategory),
            priorityName: priority,
            dueDate: dueDate,
            updatedAt: nil
        )
    }

}

@MainActor
private final class LayoutFrameRecorder {
    var frame: NSRect?
}

private struct LayoutFrameProbe: NSViewRepresentable {
    let recorder: LayoutFrameRecorder

    func makeNSView(context: Context) -> LayoutFrameProbeView {
        LayoutFrameProbeView(recorder: recorder)
    }

    func updateNSView(_ nsView: LayoutFrameProbeView, context: Context) {
        nsView.recorder = recorder
        nsView.needsLayout = true
    }
}

@MainActor
private final class LayoutFrameProbeView: NSView {
    var recorder: LayoutFrameRecorder

    init(recorder: LayoutFrameRecorder) {
        self.recorder = recorder
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        recorder.frame = convert(bounds, to: nil)
    }
}

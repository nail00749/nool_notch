import AppKit
import SwiftUI

enum HorizontalSwipeDirection {
    case previous
    case next
}

struct HorizontalSwipeMonitor: NSViewRepresentable {
    let onChanged: (CGFloat) -> Void
    let onThresholdReached: (HorizontalSwipeDirection) -> Bool
    let onEnded: (HorizontalSwipeDirection?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onChanged: onChanged,
            onThresholdReached: onThresholdReached,
            onEnded: onEnded
        )
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.trackedView = view
        context.coordinator.startMonitoring()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.trackedView = nsView
        context.coordinator.onChanged = onChanged
        context.coordinator.onThresholdReached = onThresholdReached
        context.coordinator.onEnded = onEnded
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stopMonitoring()
    }

    @MainActor
    final class Coordinator {
        private enum GestureAxis {
            case undecided
            case horizontal
            case vertical
        }

        weak var trackedView: NSView?
        var onChanged: (CGFloat) -> Void
        var onThresholdReached: (HorizontalSwipeDirection) -> Bool
        var onEnded: (HorizontalSwipeDirection?) -> Void

        private var eventMonitor: Any?
        private var horizontalDistance: CGFloat = 0
        private var verticalDistance: CGFloat = 0
        private var axis = GestureAxis.undecided
        private var isTrackingGesture = false
        private var committedDirection: HorizontalSwipeDirection?

        init(
            onChanged: @escaping (CGFloat) -> Void,
            onThresholdReached: @escaping (HorizontalSwipeDirection) -> Bool,
            onEnded: @escaping (HorizontalSwipeDirection?) -> Void
        ) {
            self.onChanged = onChanged
            self.onThresholdReached = onThresholdReached
            self.onEnded = onEnded
        }

        func startMonitoring() {
            guard eventMonitor == nil else { return }
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handle(event) == true ? nil : event
            }
        }

        func stopMonitoring() {
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
            }
            eventMonitor = nil
            if axis == .horizontal {
                onEnded(nil)
            }
            resetGesture()
        }

        private func handle(_ event: NSEvent) -> Bool {
            guard event.hasPreciseScrollingDeltas,
                  event.momentumPhase.isEmpty,
                  event.phase.isEmpty == false else {
                return false
            }

            if event.phase.contains(.mayBegin) || event.phase.contains(.began) {
                resetGesture()
                guard isInsideTrackedView(event) else { return false }
                isTrackingGesture = true
            } else if isTrackingGesture == false {
                guard isInsideTrackedView(event) else { return false }
                isTrackingGesture = true
            }

            let deviceDirectionMultiplier: CGFloat = event.isDirectionInvertedFromDevice ? -1 : 1
            horizontalDistance += event.scrollingDeltaX * deviceDirectionMultiplier
            verticalDistance += event.scrollingDeltaY

            let horizontalMagnitude = abs(horizontalDistance)
            let verticalMagnitude = abs(verticalDistance)
            if axis == .undecided, max(horizontalMagnitude, verticalMagnitude) >= 8 {
                if horizontalMagnitude > verticalMagnitude * 1.2 {
                    axis = .horizontal
                } else if verticalMagnitude > horizontalMagnitude * 1.2 {
                    axis = .vertical
                }
            }

            if axis == .horizontal {
                onChanged(horizontalDistance)
                if committedDirection == nil, horizontalMagnitude >= 48 {
                    let direction: HorizontalSwipeDirection = horizontalDistance > 0
                        ? .next
                        : .previous
                    if onThresholdReached(direction) {
                        committedDirection = direction
                    }
                }
            }

            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                let wasHorizontal = axis == .horizontal
                if wasHorizontal {
                    onEnded(committedDirection)
                }
                resetGesture()
                return wasHorizontal
            }

            return axis == .horizontal
        }

        private func isInsideTrackedView(_ event: NSEvent) -> Bool {
            guard let trackedView,
                  event.window === trackedView.window else {
                return false
            }
            let location = trackedView.convert(event.locationInWindow, from: nil)
            return trackedView.bounds.contains(location)
        }

        private func resetGesture() {
            horizontalDistance = 0
            verticalDistance = 0
            axis = .undecided
            isTrackingGesture = false
            committedDirection = nil
        }
    }
}

struct SwipeCarousel<Item: Hashable, Page: View>: View {
    let items: [Item]
    let selection: Item
    let translation: CGFloat
    let retainedRadius: Int
    let page: (Item) -> Page

    init(
        items: [Item],
        selection: Item,
        translation: CGFloat,
        retainedRadius: Int = 1,
        @ViewBuilder page: @escaping (Item) -> Page
    ) {
        self.items = items
        self.selection = selection
        self.translation = translation
        self.retainedRadius = retainedRadius
        self.page = page
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let selectedIndex = items.firstIndex(of: selection) ?? 0

            HStack(spacing: 0) {
                ForEach(items.indices, id: \.self) { index in
                    Group {
                        if abs(index - selectedIndex) <= retainedRadius {
                            page(items[index])
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: width, height: proxy.size.height)
                    .allowsHitTesting(index == selectedIndex)
                }
            }
            .frame(width: width * CGFloat(items.count), alignment: .leading)
            .offset(x: -CGFloat(selectedIndex) * width + translation)
        }
        .clipped()
        .contentShape(Rectangle())
    }
}

@MainActor
enum NotchHaptics {
    static func wheelSelectionChanged(performPulse: (() -> Void)? = nil) {
        if let performPulse {
            performPulse()
            return
        }

        NSHapticFeedbackManager.defaultPerformer.perform(
            .alignment,
            performanceTime: .now
        )
    }

    static func selectionChanged() {
        performSelectionPulse()

        Task { @MainActor in
            for _ in 0..<2 {
                try? await Task.sleep(for: .milliseconds(22))
                performSelectionPulse()
            }
        }
    }

    private static func performSelectionPulse() {
        NSHapticFeedbackManager.defaultPerformer.perform(
            .generic,
            performanceTime: .now
        )
    }
}

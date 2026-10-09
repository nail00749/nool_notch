import AppKit
import SwiftUI

/// Bounded minute selection. Precise hours/seconds stay available in the panel.
struct TimerDurationRuler: View {
    @Binding var minutes: Int
    @State private var dragStart: Double?
    @State private var draggedValue: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let spacing: CGFloat = 14
    private var displayedValue: Double { draggedValue ?? Double(minutes) }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                ForEach((Int(displayedValue) - 18)...(Int(displayedValue) + 18), id: \.self) { value in
                    if (1...120).contains(value) {
                        let x = geometry.size.width / 2 + CGFloat(Double(value) - displayedValue) * spacing
                        let major = value.isMultiple(of: 5) || value == 1
                        Capsule()
                            .fill(Color.signalMint.opacity(value == minutes ? 1 : major ? 0.6 : 0.24))
                            .frame(width: major ? 3 : 2, height: major ? 24 : 16)
                            .position(x: x, y: 32)
                        if major {
                            Text("\(value)")
                                .font(.system(size: 9, weight: .medium, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(NotchPalette.secondary)
                                .position(x: x, y: 8)
                        }
                    }
                }
                Image(systemName: "triangle.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(Color.signalMint)
                    .position(x: geometry.size.width / 2, y: 51)
            }
            .clipped()
            .contentShape(Rectangle())
            .overlay {
                TimerRulerInput(
                    onScroll: { delta in
                        let previous = draggedValue ?? Double(minutes)
                        let bounded = min(120, max(1, previous - delta / Double(spacing)))
                        draggedValue = bounded
                        select(Int(bounded.rounded()))
                    },
                    onDrag: { translation in
                    if dragStart == nil { dragStart = Double(minutes) }
                    let candidate = (dragStart ?? Double(minutes)) - Double(translation / spacing)
                    let bounded = min(120, max(1, candidate))
                    draggedValue = bounded
                    select(Int(bounded.rounded()))
                    },
                    onEnd: {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
                        draggedValue = nil
                        dragStart = nil
                    }
                    }
                )
            }
        }
        .frame(height: 56)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Длительность в минутах")
        .accessibilityValue("\(minutes)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: select(min(120, minutes + 1))
            case .decrement: select(max(1, minutes - 1))
            @unknown default: break
            }
        }
    }

    private func select(_ value: Int) {
        guard minutes != value else { return }
        minutes = value
        NotchHaptics.wheelSelectionChanged()
    }
}

private struct TimerRulerInput: NSViewRepresentable {
    let onScroll: (Double) -> Void
    let onDrag: (CGFloat) -> Void
    let onEnd: () -> Void

    func makeNSView(context: Context) -> InputView { InputView() }

    func updateNSView(_ view: InputView, context: Context) {
        view.onScroll = onScroll
        view.onDrag = onDrag
        view.onEnd = onEnd
    }

    final class InputView: NSView, NotchScrollGestureConsumer {
        var onScroll: ((Double) -> Void)?
        var onDrag: ((CGFloat) -> Void)?
        var onEnd: (() -> Void)?
        private var dragOrigin: CGFloat?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func scrollWheel(with event: NSEvent) {
            // Consume momentum without letting the parent scroll or switch tabs.
            guard event.momentumPhase.isEmpty else { return }
            let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
                ? event.scrollingDeltaX : event.scrollingDeltaY
            onScroll?(Double(delta) * (event.hasPreciseScrollingDeltas ? 1 : 14))
            if event.phase.isEmpty || event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                onEnd?()
            }
        }

        override func mouseDown(with event: NSEvent) {
            onEnd?()
            dragOrigin = event.locationInWindow.x
        }

        override func mouseDragged(with event: NSEvent) {
            guard let dragOrigin else { return }
            onDrag?(event.locationInWindow.x - dragOrigin)
        }

        override func mouseUp(with event: NSEvent) {
            dragOrigin = nil
            onEnd?()
        }
    }
}

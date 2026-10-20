import SwiftUI

enum DisplayControlTheme {
    static let card = Color(white: 0.067)
    static let field = Color(white: 0.15)
    static let secondary = Color(white: 0.58)
}

struct DisplayMenuField: View {
    let title: String
    let value: String
    let icon: String
    var compact = false
    var compactHeight: CGFloat = 44

    var body: some View {
        HStack(spacing: compact ? 6 : 10) {
            if !compact {
                Image(systemName: icon).font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75)).frame(width: 18)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: compact ? 9 : 10)).foregroundStyle(DisplayControlTheme.secondary)
                Text(value).font(.system(size: compact ? 12 : 13, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.75)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, compact ? 10 : 12)
        .frame(maxWidth: .infinity, minHeight: compact ? compactHeight : 52)
        .background(DisplayControlTheme.field, in: RoundedRectangle(cornerRadius: compact ? 10 : 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}

extension View {
    func displayMenuStyle() -> some View {
        self.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
    }
}

struct DisplayActionStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(prominent ? .black : .white)
            .padding(.horizontal, 12).frame(minHeight: 40)
            .background(prominent ? Color.white : Color.white.opacity(configuration.isPressed ? 0.16 : 0.07),
                        in: RoundedRectangle(cornerRadius: 12))
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.35)
    }
}

/// Control Center-style filled slider, with keyboard and VoiceOver adjustment.
struct DisplayDimmingSlider: View {
    @Binding var value: Double
    let label: String
    var vertical = false
    var source: String? = nil
    var verticalTrackHeight: CGFloat = 120
    @FocusState private var isFocused: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 6)) : AnyLayout(HStackLayout(spacing: 12))
        layout {
            GeometryReader { proxy in
                ZStack(alignment: vertical ? .bottom : .leading) {
                    Capsule().fill(Color(white: 0.21))
                    if vertical {
                        Rectangle().fill(Color(white: 0.94))
                            .frame(height: proxy.size.height * value)
                    } else {
                        Capsule().fill(Color(white: 0.94))
                            .frame(width: max(36, proxy.size.width * value))
                    }
                    Image(systemName: "sun.max.fill")
                        .font(.system(size: vertical ? 15 : 17, weight: .medium))
                        .foregroundStyle(vertical && value < 0.25 ? Color.white.opacity(0.8) : .black.opacity(0.8))
                        .padding(.leading, vertical ? 0 : 12)
                        .padding(.bottom, vertical ? 12 : 0)
                }
                .clipShape(Capsule())
                .contentShape(Capsule())
                .gesture(DragGesture(minimumDistance: 0).onChanged { event in
                    guard isEnabled, proxy.size.width > 0, proxy.size.height > 0 else { return }
                    let fraction = vertical ? 1 - event.location.y / proxy.size.height : event.location.x / proxy.size.width
                    value = min(1, max(0.1, fraction))
                })
                .overlay(Capsule().strokeBorder(.white.opacity(isFocused ? 0.7 : 0), lineWidth: 2).padding(-3))
            }
            .frame(width: vertical ? 40 : nil, height: vertical ? verticalTrackHeight : 38)
            Text(value, format: .percent.precision(.fractionLength(0)))
                .font(.system(size: vertical ? 11 : 15, weight: .semibold)).monospacedDigit()
                .foregroundStyle(.white).frame(width: 44, alignment: vertical ? .center : .trailing)
            if vertical, let source {
                Text(source).font(.system(size: 8, weight: .medium))
                    .foregroundStyle(DisplayControlTheme.secondary)
            }
        }
        .frame(minHeight: 44)
        .frame(width: vertical ? 44 : nil)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value.formatted(.percent.precision(.fractionLength(0))))
        .accessibilityAdjustableAction { direction in
            guard isEnabled else { return }
            switch direction {
            case .increment: adjust(0.05)
            case .decrement: adjust(-0.05)
            @unknown default: break
            }
        }
        .focusable(isEnabled).focused($isFocused).focusEffectDisabled()
        .onKeyPress(.leftArrow) { guard isEnabled else { return .ignored }; adjust(-0.05); return .handled }
        .onKeyPress(.rightArrow) { guard isEnabled else { return .ignored }; adjust(0.05); return .handled }
        .onKeyPress(.downArrow) { guard isEnabled, vertical else { return .ignored }; adjust(-0.05); return .handled }
        .onKeyPress(.upArrow) { guard isEnabled, vertical else { return .ignored }; adjust(0.05); return .handled }
    }

    private func adjust(_ amount: Double) { value = min(1, max(0.1, value + amount)) }
}

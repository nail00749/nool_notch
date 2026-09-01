import SwiftUI
import NotchCore

struct LimitsPanel: View {
    @ObservedObject var model: NotchViewModel

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 10, alignment: .top),
                    GridItem(.flexible(), spacing: 10, alignment: .top)
                ],
                alignment: .leading,
                spacing: 10
            ) {
                ForEach(model.visibleQuotaProviders, id: \.id) { provider in
                    ProviderQuotaCard(
                        providerName: provider.displayName,
                        sourceURL: provider.sourceURL,
                        snapshot: model.snapshot(for: provider.id),
                        onConnect: { model.beginAuthentication(for: provider.id) }
                    )
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 4)
        }
    }
}

private struct ProviderQuotaCard: View {
    let providerName: String
    let sourceURL: URL?
    let snapshot: QuotaSnapshot?
    let onConnect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(providerName)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)

                Spacer()

                if let snapshot {
                    Text(snapshot.connection.label)
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .tracking(0.6)
                        .foregroundStyle(
                            snapshot.connection == .stale || snapshot.connection == .requiresAuthentication
                                ? Color.signalAmber
                                : Color.signalMint
                        )
                }
            }

            if let snapshot, snapshot.windows.isEmpty == false {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 8, alignment: .top),
                        GridItem(.flexible(), spacing: 8, alignment: .top)
                    ],
                    alignment: .leading,
                    spacing: 8
                ) {
                    ForEach(snapshot.windows) { window in
                        QuotaWindowRow(window: window)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                    Text(snapshot?.message ?? "Ожидаю подключение аккаунта…")
                }
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.52))
            }

            HStack(spacing: 8) {
                Text(snapshot?.message ?? "Нет данных")
                    .lineLimit(1)
                Spacer()
                if snapshot?.connection == .requiresAuthentication {
                    Button("Войти", action: onConnect)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.signalMint)
                        .frame(minWidth: 40, minHeight: 40)
                        .buttonStyle(NotchButtonStyle())
                        .accessibilityLabel("Войти в \(providerName)")
                } else if let url = snapshot?.sourceURL ?? sourceURL {
                    Link("Открыть", destination: url)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.signalMint)
                }
            }
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.34))
        }
        .padding(11)
    }
}

private struct QuotaWindowRow: View {
    let window: QuotaWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(window.label)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.76))
                    .lineLimit(1)

                Spacer(minLength: 2)

                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    if let remaining = window.remaining {
                        Text(formatQuotaValue(remaining))
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(.white)

                        if window.unit == .percentage {
                            Text("%")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.72))
                        } else if let limit = window.limit {
                            Text("/ \(formatQuotaValue(limit))")
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.34))
                        }
                    } else {
                        Text("—")
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.42))
                    }
                }
            }

            if let ratio = window.remainingRatio {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.09))
                        Capsule()
                            .fill(ratio < 0.2 ? Color.signalCoral : Color.signalMint)
                            .frame(width: proxy.size.width * ratio)
                    }
                }
                .frame(height: 4)
            }

            if let resetAt = window.resetAt {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.counterclockwise")
                    Text("сброс")
                    Text(resetAt, style: .relative)
                }
                .font(.system(size: 8, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.34))
                .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private func formatQuotaValue(_ value: Double) -> String {
    if value.rounded() == value {
        return String(Int(value))
    }
    return String(format: "%.1f", value)
}

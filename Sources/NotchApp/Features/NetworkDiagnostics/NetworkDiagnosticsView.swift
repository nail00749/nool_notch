import SwiftUI

struct NetworkDiagnosticsView: View {
    @ObservedObject var store: NetworkDiagnosticsStore

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                Text("Проверить доступность соединения")
                    .font(.system(size: 12)).foregroundStyle(NotchPalette.secondary)
                Spacer()
                if store.isRunning {
                    Button(store.isCancelling ? "Остановка…" : "Остановить", action: store.cancel)
                        .buttonStyle(.bordered).disabled(store.isCancelling)
                } else {
                    Button("Запустить проверку", action: store.start)
                        .buttonStyle(.borderedProminent)
                }
            }
            if store.isRunning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(store.isCancelling ? "Завершаем проверки…" : "Выполняем четыре проверки…")
                        .font(.system(size: 11)).foregroundStyle(NotchPalette.secondary)
                }
            }
            if let error = store.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(.orange)
            }

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(NetworkProbeKind.allCases) { kind in
                    card(kind: kind, result: store.report?.probe(kind))
                }
            }
            if let report = store.report {
                VStack(alignment: .leading, spacing: 7) {
                    Label("Итог проверки", systemImage: "info.circle")
                        .font(.system(size: 12, weight: .semibold))
                    Text(report.summary).font(.system(size: 11))
                    Text(report.measuredAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 10)).foregroundStyle(NotchPalette.secondary)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(NotchPalette.raised, in: RoundedRectangle(cornerRadius: 14))
                .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(NotchPalette.separator) }
            } else if !store.isRunning {
                Text("Проверка запускается только по кнопке. Результаты не сохраняются.")
                    .font(.system(size: 11)).foregroundStyle(NotchPalette.secondary)
            }
            Text("Шлюз определяется по активному IPv4-маршруту и может быть VPN-шлюзом. DNS-ответ может прийти из кэша. Пинг без ответа не доказывает, что интернет недоступен.")
                .font(.system(size: 10)).foregroundStyle(NotchPalette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(NotchPalette.text)
        .tint(NotchPalette.accent)
    }

    private func card(kind: NetworkProbeKind, result: NetworkProbeResult?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(kind.title, systemImage: kind.symbol)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if let result {
                    Image(systemName: statusSymbol(result.outcome))
                        .foregroundStyle(statusColor(result.outcome))
                        .accessibilityLabel(statusTitle(result.outcome))
                }
            }
            Text(result?.target ?? defaultTarget(kind))
                .font(.system(size: 10)).foregroundStyle(NotchPalette.secondary)
                .lineLimit(2)
            Text(result?.detail ?? "Проверка ещё не запускалась")
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
        .padding(14)
        .background(NotchPalette.raised, in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(NotchPalette.separator) }
    }

    private func defaultTarget(_ kind: NetworkProbeKind) -> String {
        switch kind {
        case .gatewayICMP: "Текущий IPv4-шлюз"
        case .externalICMP: "1.1.1.1 · ICMP"
        case .dns: "example.com · системный resolver"
        case .https: "https://example.com · TLS + HTTP"
        }
    }

    private func statusSymbol(_ outcome: NetworkProbeOutcome) -> String {
        switch outcome {
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.circle.fill"
        case .skipped: "minus.circle.fill"
        }
    }

    private func statusColor(_ outcome: NetworkProbeOutcome) -> Color {
        switch outcome {
        case .success: Color(nsColor: .systemGreen)
        case .warning: Color(nsColor: .systemOrange)
        case .skipped: NotchPalette.secondary
        }
    }

    private func statusTitle(_ outcome: NetworkProbeOutcome) -> String {
        switch outcome {
        case .success: "Проверка прошла"
        case .warning: "Требует внимания"
        case .skipped: "Проверка пропущена"
        }
    }
}

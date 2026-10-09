import Foundation

enum NetworkProbeKind: String, CaseIterable, Identifiable, Sendable {
    case gatewayICMP, externalICMP, dns, https

    var id: Self { self }

    var title: String {
        switch self {
        case .gatewayICMP: "Шлюз"
        case .externalICMP: "Внешний ICMP"
        case .dns: "DNS"
        case .https: "HTTPS"
        }
    }

    var symbol: String {
        switch self {
        case .gatewayICMP: "network"
        case .externalICMP: "dot.radiowaves.left.and.right"
        case .dns: "text.magnifyingglass"
        case .https: "lock.shield"
        }
    }
}

enum NetworkProbeOutcome: Equatable, Sendable {
    case success
    case warning
    case skipped
}

struct NetworkProbeResult: Equatable, Sendable, Identifiable {
    let kind: NetworkProbeKind
    let target: String
    let outcome: NetworkProbeOutcome
    let detail: String

    var id: NetworkProbeKind { kind }
}

struct NetworkDiagnosticsReport: Equatable, Sendable {
    let measuredAt: Date
    let probes: [NetworkProbeResult]

    func probe(_ kind: NetworkProbeKind) -> NetworkProbeResult? {
        probes.first { $0.kind == kind }
    }

    var summary: String {
        let https = probe(.https)?.outcome == .success
        let dns = probe(.dns)?.outcome == .success
        let gatewayPing = probe(.gatewayICMP)?.outcome == .success
        let externalPing = probe(.externalICMP)?.outcome == .success

        if https {
            if !gatewayPing || !externalPing {
                return "HTTPS доступен. Неполные ответы ICMP могут быть связаны с фильтрацией и сами по себе не означают потери интернета."
            }
            return "HTTPS доступен; проверенные DNS и ICMP показывают состояние только этих маршрутов и адресов."
        }
        if dns {
            return "DNS разрешил имя, но HTTPS до example.com не подтвердился. Проверьте доступность сайта или ограничения сети."
        }
        if gatewayPing || externalPing {
            return "Есть ответы ICMP, но DNS и HTTPS не подтвердили работу веб-доступа."
        }
        return "Проверки не подтвердили доступность сети. ICMP может быть заблокирован, а отсутствие IPv4-шлюза не исключает доступ через IPv6 или VPN."
    }
}

protocol NetworkDiagnosticsRunning: Sendable {
    func run() async throws -> NetworkDiagnosticsReport
}

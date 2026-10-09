import Darwin
import Foundation

struct SystemNetworkDiagnosticsRunner: NetworkDiagnosticsRunning {
    private let commands: any DiagnosticCommandRunning
    private let https: any NetworkHTTPSChecking

    init(commands: any DiagnosticCommandRunning = SystemDiagnosticCommandRunner(),
         https: any NetworkHTTPSChecking = SystemNetworkHTTPSChecker()) {
        self.commands = commands
        self.https = https
    }

    func run() async throws -> NetworkDiagnosticsReport {
        try Task.checkCancellation()
        let route = await commands.run(executable: "/sbin/route", arguments: ["-n", "get", "default"],
                                       timeoutSeconds: 2)
        try Task.checkCancellation()
        let gateway = route.stopReason == nil && route.exitCode == 0
            ? NetworkDiagnosticsParsing.gatewayAddress(in: route.output) : nil

        async let gatewayProbe = checkGateway(gateway, route: route)
        async let externalProbe = checkPing(kind: .externalICMP, address: "1.1.1.1")
        async let dnsProbe = checkDNS()
        async let httpsProbe = https.check()
        let probes = await [gatewayProbe, externalProbe, dnsProbe, httpsProbe]
        try Task.checkCancellation()
        return NetworkDiagnosticsReport(measuredAt: .now, probes: probes)
    }

    private func checkGateway(_ gateway: String?, route: DiagnosticCommandResult) async -> NetworkProbeResult {
        guard let gateway else {
            let reason = route.stopReason == .timedOut
                ? "Определение IPv4-шлюза заняло слишком много времени. Проверка пропущена."
                : "Активный IPv4-шлюз не найден. Проверка пропущена; доступ через IPv6 или VPN возможен."
            return NetworkProbeResult(kind: .gatewayICMP, target: "Шлюз текущего IPv4-маршрута",
                                      outcome: .skipped, detail: reason)
        }
        return await checkPing(kind: .gatewayICMP, address: gateway)
    }

    private func checkPing(kind: NetworkProbeKind, address: String) async -> NetworkProbeResult {
        let target = kind == .gatewayICMP ? "Текущий IPv4-шлюз · \(address)" : "1.1.1.1 · ICMP"
        let result = await commands.run(executable: "/sbin/ping",
                                        arguments: ["-n", "-q", "-c", "5", "-i", "0.5", "-W", "1000", "-t", "7", address],
                                        timeoutSeconds: 8)
        if result.stopReason == .timedOut {
            return NetworkProbeResult(kind: kind, target: target, outcome: .warning,
                                      detail: "Проверка ICMP не завершилась за 8 секунд.")
        }
        if result.stopReason != nil {
            return NetworkProbeResult(kind: kind, target: target, outcome: .warning,
                                      detail: "ICMP-проверку не удалось выполнить.")
        }
        guard let statistics = NetworkDiagnosticsParsing.pingStatistics(in: result.output) else {
            return NetworkProbeResult(kind: kind, target: target, outcome: .warning,
                                      detail: "Нет понятной статистики ICMP. Некоторые сети или системы ограничивают ping.")
        }
        let unanswered = statistics.sent - statistics.received
        let unansweredPercent = Int((Double(unanswered) / Double(statistics.sent) * 100).rounded())
        let base = "Ответы: \(statistics.received) из \(statistics.sent); без ответа: \(unanswered) (\(unansweredPercent)%)."
        let latency = statistics.averageMilliseconds.map { " Средняя задержка: \(formatted($0)) мс." } ?? ""
        if unanswered == 0 {
            return NetworkProbeResult(kind: kind, target: target, outcome: .success, detail: base + latency)
        }
        return NetworkProbeResult(kind: kind, target: target, outcome: .warning,
                                  detail: base + latency + " Это доля ICMP без ответа, а не измерение физической потери пакетов.")
    }

    private func checkDNS() async -> NetworkProbeResult {
        let target = "example.com · системный resolver (возможен кэш)"
        let result = await commands.run(executable: "/usr/bin/dscacheutil",
                                        arguments: ["-q", "host", "-a", "name", "example.com"],
                                        timeoutSeconds: 5)
        if result.stopReason == .timedOut {
            return NetworkProbeResult(kind: .dns, target: target, outcome: .warning,
                                      detail: "Системный resolver не ответил за 5 секунд.")
        }
        guard result.stopReason == nil, result.exitCode == 0 else {
            return NetworkProbeResult(kind: .dns, target: target, outcome: .warning,
                                      detail: "Системный resolver не завершил запрос.")
        }
        let addresses = NetworkDiagnosticsParsing.resolvedAddresses(in: result.output)
        guard !addresses.isEmpty else {
            return NetworkProbeResult(kind: .dns, target: target, outcome: .warning,
                                      detail: "Адрес не получен. Ответ мог прийти из кэша или запрос мог не пройти.")
        }
        return NetworkProbeResult(kind: .dns, target: target, outcome: .success,
                                  detail: "Получено адресов: \(addresses.count). Первый: \(addresses[0]). Кэш DNS возможен.")
    }

    private func formatted(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }
}

struct DiagnosticPingStatistics: Equatable {
    let sent: Int
    let received: Int
    let averageMilliseconds: Double?
}

enum NetworkDiagnosticsParsing {
    static func gatewayAddress(in output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            let pieces = line.split(separator: ":", maxSplits: 1)
            guard pieces.count == 2, pieces[0].trimmingCharacters(in: .whitespaces) == "gateway" else { continue }
            let address = pieces[1].trimmingCharacters(in: .whitespaces)
            if isValidIPv4(address), address != "0.0.0.0", address != "255.255.255.255" { return address }
        }
        return nil
    }

    static func isValidIPv4(_ address: String) -> Bool {
        let octets = address.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets.allSatisfy { octet in
            let numeric = (1...3).contains(octet.count) && octet.utf8.allSatisfy { (48...57).contains($0) }
            let canonical = octet == "0" || octet.first != "0"
            return numeric && canonical && (Int(octet) ?? 256) <= 255
        }
    }

    static func pingStatistics(in output: String) -> DiagnosticPingStatistics? {
        guard let line = output.split(whereSeparator: \.isNewline).first(where: {
            $0.contains("packets transmitted") && $0.contains("received")
        }) else { return nil }
        let components = line.split(separator: ",")
        guard components.count >= 2,
              let sent = firstInteger(in: components[0]), let received = firstInteger(in: components[1]),
              sent > 0, received >= 0, received <= sent else { return nil }
        let average = output.split(whereSeparator: \.isNewline)
            .first(where: { $0.contains("min/avg/max") })
            .flatMap { line -> Double? in
                guard let value = line.split(separator: "=", maxSplits: 1).last else { return nil }
                let pieces = value.trimmingCharacters(in: .whitespaces).split(separator: "/")
                guard pieces.count >= 2 else { return nil }
                return Double(pieces[1])
            }
        return DiagnosticPingStatistics(sent: sent, received: received,
                                        averageMilliseconds: average.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil })
    }

    static func resolvedAddresses(in output: String) -> [String] {
        var seen = Set<String>()
        return output.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let pieces = line.split(separator: ":", maxSplits: 1)
            guard pieces.count == 2 else { return nil }
            let field = pieces[0].trimmingCharacters(in: .whitespaces)
            guard field == "ip_address" || field == "ipv6_address" else { return nil }
            let address = pieces[1].trimmingCharacters(in: .whitespaces)
            var ipv4 = in_addr()
            var ipv6 = in6_addr()
            let valid = address.withCString {
                inet_pton(AF_INET, $0, &ipv4) == 1 || inet_pton(AF_INET6, $0, &ipv6) == 1
            }
            return valid && seen.insert(address).inserted ? address : nil
        }
    }

    private static func firstInteger(in text: Substring) -> Int? {
        text.split(whereSeparator: \.isWhitespace).first.flatMap { Int($0) }
    }
}

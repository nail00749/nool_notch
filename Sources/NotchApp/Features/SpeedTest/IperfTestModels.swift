import Darwin
import Foundation

enum IperfTestTransport: String, CaseIterable, Identifiable, Codable, Sendable {
    case tcp, udp
    var id: String { rawValue }
    var title: String { rawValue.uppercased() }
}

struct IperfTestConfiguration: Codable, Equatable, Sendable {
    var host = ""
    var port = 5201
    var durationSeconds = 5
    var udpMegabitsPerSecond = 50
    var transport: IperfTestTransport = .tcp

    var validationError: String? {
        guard validatedHost != nil else { return "Введите имя или IP-адрес сервера без URL, порта и пробелов." }
        guard (1...65535).contains(port) else { return "Порт должен быть от 1 до 65535." }
        guard (1...30).contains(durationSeconds) else { return "Длительность должна быть от 1 до 30 секунд на направление." }
        guard (1...10000).contains(udpMegabitsPerSecond) else { return "Скорость UDP должна быть от 1 до 10000 Мбит/с." }
        return nil
    }
    var isValid: Bool { validationError == nil }

    var validatedHost: String? {
        guard !host.isEmpty, host.utf8.count <= 253, !host.hasPrefix("-"),
              host.unicodeScalars.allSatisfy({ $0.isASCII && !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0) }),
              !host.contains("/"), !host.contains("\\"), !host.contains("@") else { return nil }
        let address = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        var ipv4 = in_addr()
        if inet_pton(AF_INET, address, &ipv4) == 1 { return address }
        let pieces = address.split(separator: "%", omittingEmptySubsequences: false)
        if pieces.count <= 2, let first = pieces.first {
            let scopeValid = pieces.count == 1 || (!pieces[1].isEmpty && pieces[1].utf8.count <= 32
                && pieces[1].utf8.allSatisfy { Self.isHostnameByte($0) || $0 == 95 })
            var ipv6 = in6_addr()
            if scopeValid, inet_pton(AF_INET6, String(first), &ipv6) == 1 { return address }
        }
        guard address == host, !host.contains(":"), !host.contains("%"),
              !host.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }) else { return nil }
        let name = host.hasSuffix(".") ? String(host.dropLast()) : host
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty, labels.allSatisfy({ label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
                && label.utf8.allSatisfy { Self.isHostnameByte($0) && $0 != 46 }
        }) else { return nil }
        return host
    }

    private static func isHostnameByte(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || byte == 45 || byte == 46
    }
}

struct IperfTestResult: Codable, Equatable, Sendable {
    let downloadMbps: Double
    let uploadMbps: Double
    /// UDP quality uses the worse receiver measurement across the two directions.
    let jitterMilliseconds: Double?
    let lossPercent: Double?
    let measuredAt: Date
    let transport: IperfTestTransport
    let host: String
}

enum IperfTestError: LocalizedError, Equatable, Sendable {
    case invalidConfiguration(String), binaryMissing, launchFailed, processFailed(Int32)
    case timedOut, outputLimited, invalidResponse, cancelled, server(String)
    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message): message
        case .binaryMissing: "iperf3 не найден. Установите его отдельно и повторите тест."
        case .launchFailed: "Не удалось запустить iperf3."
        case .processFailed(let code): "iperf3 завершился с ошибкой (код \(code)). Проверьте адрес, порт и доступность сервера."
        case .timedOut: "Сервер iperf3 не завершил тест вовремя."
        case .outputLimited: "Ответ iperf3 превысил допустимый объём."
        case .invalidResponse: "iperf3 вернул неполный или некорректный результат."
        case .cancelled: "Тест iperf3 отменён."
        case .server(let message): "Сервер iperf3: \(message)"
        }
    }
}

protocol IperfTestRunning: Sendable {
    func run(configuration: IperfTestConfiguration,
             onPhase: @escaping @Sendable (String) -> Void) async throws -> IperfTestResult
}

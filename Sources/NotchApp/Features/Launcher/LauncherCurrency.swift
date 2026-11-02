import Combine
import Foundation

enum LauncherCurrency: String, CaseIterable, Codable, Identifiable, Sendable {
    case RUB, USD, EUR, CNY, GBP, JPY, KZT, TRY, AED, CHF, INR, KRW

    var id: String { rawValue }

    var title: String {
        switch self {
        case .RUB: "Российский рубль"
        case .USD: "Доллар США"
        case .EUR: "Евро"
        case .CNY: "Китайский юань"
        case .GBP: "Фунт стерлингов"
        case .JPY: "Японская иена"
        case .KZT: "Казахстанский тенге"
        case .TRY: "Турецкая лира"
        case .AED: "Дирхам ОАЭ"
        case .CHF: "Швейцарский франк"
        case .INR: "Индийская рупия"
        case .KRW: "Южнокорейская вона"
        }
    }

    var symbol: String {
        switch self {
        case .RUB: "₽"
        case .USD: "$"
        case .EUR: "€"
        case .CNY: "¥"
        case .GBP: "£"
        case .JPY: "¥"
        case .KZT: "₸"
        case .TRY: "₺"
        case .AED: "د.إ"
        case .CHF: "CHF"
        case .INR: "₹"
        case .KRW: "₩"
        }
    }

    fileprivate var aliases: [String] {
        switch self {
        case .RUB: ["rub", "rur", "₽", "руб", "рубль", "рубля", "рублей", "рублях", "рубли"]
        case .USD: ["usd", "$", "доллар", "доллара", "долларов", "доллары", "долларах", "бакс", "бакса", "баксов"]
        case .EUR: ["eur", "€", "евро"]
        case .CNY: ["cny", "rmb", "юань", "юаня", "юаней", "юани", "юанях", "¥"]
        case .GBP: ["gbp", "£", "фунт", "фунта", "фунтов", "фунтах"]
        case .JPY: ["jpy", "иена", "иены", "иен", "иенах"]
        case .KZT: ["kzt", "₸", "тенге"]
        case .TRY: ["try", "₺", "лира", "лиры", "лир", "лирах"]
        case .AED: ["aed", "дирхам", "дирхама", "дирхамов", "дирхамах"]
        case .CHF: ["chf", "франк", "франка", "франков", "франках"]
        case .INR: ["inr", "₹", "рупия", "рупии", "рупий", "рупиях"]
        case .KRW: ["krw", "₩", "вона", "воны", "вон", "вонах"]
        }
    }

    static func parse(_ raw: String) -> Self? {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().replacingOccurrences(of: "ё", with: "е")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,"))
        return allCases.first { currency in
            currency.aliases.contains(token) || currency.rawValue.lowercased() == token
        }
    }
}

struct LauncherCurrencyQuery: Equatable, Sendable {
    let amount: Double
    let source: LauncherCurrency
    let target: LauncherCurrency

    static func parse(_ input: String, defaultTarget: LauncherCurrency) -> Self? {
        let normalized = input.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().replacingOccurrences(of: "ё", with: "е")
        guard !normalized.isEmpty, normalized.count <= 128 else { return nil }

        let pattern = #"^\s*([$€£₽¥₸₺₹₩])?\s*([0-9]+(?:[\s ][0-9]{3})*(?:[.,][0-9]+)?|[0-9]+(?:[.,][0-9]+)?)\s*([^\d]*?)\s*$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)),
              match.range == NSRange(normalized.startIndex..., in: normalized),
              let amountRange = Range(match.range(at: 2), in: normalized) else { return nil }

        let amountText = normalized[amountRange]
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ",", with: ".")
        guard let amount = Double(amountText), amount.isFinite, amount >= 0 else { return nil }

        let prefix = Range(match.range(at: 1), in: normalized).map { String(normalized[$0]) } ?? ""
        let suffix = Range(match.range(at: 3), in: normalized).map { String(normalized[$0]) } ?? ""
        let parts = suffix.components(separatedBy: try! NSRegularExpression(pattern: #"(?:^|\s+)(?:в|to)\s+|\s*(?:->|→|=)\s*"#))
        let sourceText = prefix.isEmpty ? (parts.first ?? "") : prefix
        guard let source = LauncherCurrency.parse(sourceText) else { return nil }
        let explicitTarget: LauncherCurrency?
        if parts.count > 1 {
            guard let parsed = LauncherCurrency.parse(parts.dropFirst().joined(separator: " ")) else { return nil }
            explicitTarget = parsed
        } else {
            explicitTarget = nil
        }
        return Self(amount: amount, source: source, target: explicitTarget ?? defaultTarget)
    }
}

private extension String {
    func components(separatedBy expression: NSRegularExpression) -> [String] {
        let range = NSRange(startIndex..., in: self)
        var result: [String] = []
        var cursor = startIndex
        for match in expression.matches(in: self, range: range) {
            guard let matchRange = Range(match.range, in: self) else { continue }
            result.append(String(self[cursor..<matchRange.lowerBound]).trimmingCharacters(in: .whitespaces))
            cursor = matchRange.upperBound
        }
        result.append(String(self[cursor...]).trimmingCharacters(in: .whitespaces))
        return result
    }
}

struct LauncherCurrencyRates: Codable, Equatable, Sendable {
    let date: Date
    /// Rubles for one unit of the keyed currency.
    let rublesPerUnit: [LauncherCurrency: Double]

    func convert(_ query: LauncherCurrencyQuery) -> Double? {
        let sourceRate = query.source == .RUB ? 1 : rublesPerUnit[query.source]
        let targetRate = query.target == .RUB ? 1 : rublesPerUnit[query.target]
        guard let sourceRate, let targetRate, sourceRate > 0, targetRate > 0 else { return nil }
        let value = query.amount * sourceRate / targetRate
        return value.isFinite ? value : nil
    }
}

protocol LauncherCurrencyRateLoading: Sendable {
    func loadRates() async throws -> LauncherCurrencyRates
}

struct BankOfRussiaCurrencyClient: LauncherCurrencyRateLoading, @unchecked Sendable {
    static let endpoint = URL(string: "https://www.cbr.ru/scripts/XML_daily.asp")!
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session { self.session = session; return }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 7
        configuration.timeoutIntervalForResource = 10
        self.session = URLSession(configuration: configuration)
    }

    func loadRates() async throws -> LauncherCurrencyRates {
        var request = URLRequest(url: Self.endpoint, cachePolicy: .reloadRevalidatingCacheData, timeoutInterval: 7)
        request.setValue("application/xml", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              data.count <= 1_000_000 else { throw LauncherCurrencyError.invalidResponse }
        return try Self.decode(data)
    }

    static func decode(_ data: Data) throws -> LauncherCurrencyRates {
        let delegate = BankOfRussiaXMLDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), delegate.rates.count >= 3 else { throw LauncherCurrencyError.invalidResponse }
        return LauncherCurrencyRates(date: delegate.date ?? Date(), rublesPerUnit: delegate.rates)
    }
}

private final class BankOfRussiaXMLDelegate: NSObject, XMLParserDelegate {
    var date: Date?
    var rates: [LauncherCurrency: Double] = [:]
    private var element = ""
    private var text = ""
    private var code: String?
    private var nominal: Double?
    private var value: Double?

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        element = elementName
        text = ""
        if elementName == "ValCurs", let rawDate = attributeDict["Date"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "dd.MM.yyyy"
            date = formatter.date(from: rawDate)
        } else if elementName == "Valute" {
            code = nil; nominal = nil; value = nil
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let valueText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "CharCode": code = valueText
        case "Nominal": nominal = Double(valueText)
        case "Value": value = Double(valueText.replacingOccurrences(of: ",", with: "."))
        case "Valute":
            if let code, let currency = LauncherCurrency(rawValue: code),
               let nominal, let value, nominal > 0, value > 0 {
                rates[currency] = value / nominal
            }
        default: break
        }
        element = ""
        text = ""
    }
}

enum LauncherCurrencyError: Error { case invalidResponse }

@MainActor
final class LauncherCurrencyStore: ObservableObject {
    @Published private(set) var result: LauncherResult?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let loader: any LauncherCurrencyRateLoading
    private let defaults: UserDefaults
    private var cached: LauncherCurrencyRates?
    private var cachedAt: Date?
    private var task: Task<Void, Never>?
    private var request: LauncherCurrencyQuery?
    private var generation = 0
    private static let cacheKey = "nool.launcher.currencyRates"
    private static let cacheDateKey = "nool.launcher.currencyRatesFetchedAt"
    private static let freshness: TimeInterval = 12 * 60 * 60

    init(loader: any LauncherCurrencyRateLoading = BankOfRussiaCurrencyClient(), defaults: UserDefaults = .standard) {
        self.loader = loader
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.cacheKey) {
            cached = try? JSONDecoder().decode(LauncherCurrencyRates.self, from: data)
        }
        cachedAt = defaults.object(forKey: Self.cacheDateKey) as? Date
    }

    func update(input: String, defaultTarget: LauncherCurrency) {
        let next = LauncherCurrencyQuery.parse(input, defaultTarget: defaultTarget)
        if next == request {
            if isLoading { return }
            if result != nil, let cachedAt, Date().timeIntervalSince(cachedAt) < Self.freshness { return }
        }
        generation += 1
        task?.cancel()
        request = next
        result = next.flatMap { query in
            cached.flatMap { rates in makeResult(query: query, rates: rates) }
        }
        errorMessage = nil
        guard let next else { isLoading = false; return }
        if let cached, let cachedAt, Date().timeIntervalSince(cachedAt) < Self.freshness,
           makeResult(query: next, rates: cached) != nil {
            isLoading = false
            return
        }

        isLoading = true
        let currentGeneration = generation
        task = Task { [weak self, loader] in
            do {
                let rates = try await loader.loadRates()
                guard !Task.isCancelled, let self, self.generation == currentGeneration, self.request == next else { return }
                self.cached = rates
                self.cachedAt = Date()
                if let data = try? JSONEncoder().encode(rates) { self.defaults.set(data, forKey: Self.cacheKey) }
                self.defaults.set(self.cachedAt, forKey: Self.cacheDateKey)
                self.result = self.makeResult(query: next, rates: rates)
                self.errorMessage = self.result == nil ? "Для этой валюты нет курса Банка России." : nil
                self.isLoading = false
                self.task = nil
            } catch {
                guard !Task.isCancelled, let self, self.generation == currentGeneration else { return }
                self.isLoading = false
                self.task = nil
                if self.result == nil { self.errorMessage = "Не удалось загрузить курсы валют." }
            }
        }
    }

    func stop() {
        generation += 1
        task?.cancel()
        task = nil
        request = nil
        isLoading = false
    }

    private func makeResult(query: LauncherCurrencyQuery, rates: LauncherCurrencyRates) -> LauncherResult? {
        guard let value = rates.convert(query) else { return nil }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = abs(value) < 1 ? 4 : 2
        formatter.usesGroupingSeparator = true
        guard let number = formatter.string(from: NSNumber(value: value)) else { return nil }
        let title = "\(number) \(query.target.symbol)"
        let date = rates.date.formatted(.dateTime.day().month(.twoDigits).year().locale(Locale(identifier: "ru_RU")))
        let source = Self.compact(query.amount)
        return LauncherResult(id: "currency", title: title,
                              subtitle: "\(source) \(query.source.rawValue) → \(query.target.rawValue) · ЦБ РФ, \(date) · Enter — скопировать",
                              payload: .calculation(title))
    }

    private static func compact(_ value: Double) -> String {
        value.rounded() == value && value <= Double(Int64.max) ? String(Int64(value)) : String(format: "%.8g", value)
    }
}

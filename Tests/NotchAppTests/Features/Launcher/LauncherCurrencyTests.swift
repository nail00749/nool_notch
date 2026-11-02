import Foundation
import XCTest
@testable import NotchApp

final class LauncherCurrencyTests: XCTestCase {
    func testLiveBankOfRussiaRatesWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["NOOL_CURRENCY_LIVE"] == "1" else {
            throw XCTSkip("Opt-in Bank of Russia integration test")
        }
        let rates = try await BankOfRussiaCurrencyClient().loadRates()
        XCTAssertGreaterThan(try XCTUnwrap(rates.rublesPerUnit[.USD]), 0)
        XCTAssertGreaterThan(try XCTUnwrap(rates.rublesPerUnit[.CNY]), 0)
    }

    func testParsesSymbolsWordsAndExplicitTargets() {
        XCTAssertEqual(LauncherCurrencyQuery.parse("250$", defaultTarget: .RUB),
                       .init(amount: 250, source: .USD, target: .RUB))
        XCTAssertEqual(LauncherCurrencyQuery.parse("$ 250 в юанях", defaultTarget: .RUB),
                       .init(amount: 250, source: .USD, target: .CNY))
        XCTAssertEqual(LauncherCurrencyQuery.parse("1 000 юаней", defaultTarget: .USD),
                       .init(amount: 1000, source: .CNY, target: .USD))
        XCTAssertEqual(LauncherCurrencyQuery.parse("50,5 € в доллары", defaultTarget: .RUB),
                       .init(amount: 50.5, source: .EUR, target: .USD))
        XCTAssertEqual(LauncherCurrencyQuery.parse("100 JPY to RUB", defaultTarget: .EUR),
                       .init(amount: 100, source: .JPY, target: .RUB))
    }

    func testRejectsOrdinarySearchAndMalformedValues() {
        XCTAssertNil(LauncherCurrencyQuery.parse("Safari", defaultTarget: .RUB))
        XCTAssertNil(LauncherCurrencyQuery.parse("250", defaultTarget: .RUB))
        XCTAssertNil(LauncherCurrencyQuery.parse("-5 USD", defaultTarget: .RUB))
        XCTAssertNil(LauncherCurrencyQuery.parse("250 неизвестных", defaultTarget: .RUB))
        XCTAssertNil(LauncherCurrencyQuery.parse("250 USD в неизвестных", defaultTarget: .RUB))
    }

    func testDecodesNominalsAndConvertsCrossRate() throws {
        let xml = """
        <?xml version="1.0" encoding="windows-1251"?>
        <ValCurs Date="30.10.2026" name="Foreign Currency Market">
          <Valute><CharCode>USD</CharCode><Nominal>1</Nominal><Value>80,0000</Value></Valute>
          <Valute><CharCode>EUR</CharCode><Nominal>1</Nominal><Value>100,0000</Value></Valute>
          <Valute><CharCode>CNY</CharCode><Nominal>10</Nominal><Value>120,0000</Value></Valute>
        </ValCurs>
        """
        let rates = try BankOfRussiaCurrencyClient.decode(Data(xml.utf8))
        XCTAssertEqual(rates.rublesPerUnit[.USD], 80)
        XCTAssertEqual(rates.rublesPerUnit[.CNY], 12)
        XCTAssertEqual(try XCTUnwrap(rates.convert(.init(amount: 10, source: .USD, target: .CNY))),
                       800 / 12, accuracy: 0.0001)
        XCTAssertEqual(rates.convert(.init(amount: 2, source: .EUR, target: .RUB)), 200)
    }

    @MainActor
    func testStorePublishesCopyableResultAndPersistsRates() async throws {
        let suite = "launcher-currency-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let rates = LauncherCurrencyRates(date: Date(), rublesPerUnit: [.USD: 80, .EUR: 100, .CNY: 12])
        let store = LauncherCurrencyStore(loader: FixedCurrencyLoader(rates: rates), defaults: defaults)
        store.update(input: "2$", defaultTarget: .RUB)
        for _ in 0..<100 where store.result == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(store.result?.title, "160 ₽")
        XCTAssertEqual(store.result?.payload, .calculation("160 ₽"))

        let restored = LauncherCurrencyStore(loader: FixedCurrencyLoader(rates: rates), defaults: defaults)
        restored.update(input: "1 EUR", defaultTarget: .RUB)
        XCTAssertEqual(restored.result?.title, "100 ₽")
        XCTAssertFalse(restored.isLoading)
    }

    @MainActor
    func testStoreRetriesSameQueryAfterFailureAndAfterStop() async throws {
        let suite = "launcher-currency-retry-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let rates = LauncherCurrencyRates(date: Date(), rublesPerUnit: [.USD: 80, .EUR: 100, .CNY: 12])
        let loader = RetryCurrencyLoader(rates: rates)
        let store = LauncherCurrencyStore(loader: loader, defaults: defaults)
        store.update(input: "2$", defaultTarget: .RUB)
        for _ in 0..<100 where store.errorMessage == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotNil(store.errorMessage)
        store.update(input: "2$", defaultTarget: .RUB)
        for _ in 0..<100 where store.result == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(store.result?.title, "160 ₽")

        store.stop()
        store.update(input: "3$", defaultTarget: .RUB)
        XCTAssertEqual(store.result?.title, "240 ₽")
    }

    @MainActor
    func testStoreRefreshesPersistedStaleRates() async throws {
        let suite = "launcher-currency-stale-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let stale = LauncherCurrencyRates(date: Date().addingTimeInterval(-86_400),
                                          rublesPerUnit: [.USD: 70, .EUR: 90, .CNY: 10])
        defaults.set(try JSONEncoder().encode(stale), forKey: "nool.launcher.currencyRates")
        defaults.set(Date().addingTimeInterval(-86_400), forKey: "nool.launcher.currencyRatesFetchedAt")
        let fresh = LauncherCurrencyRates(date: Date(), rublesPerUnit: [.USD: 80, .EUR: 100, .CNY: 12])
        let loader = CountingCurrencyLoader(rates: fresh)
        let store = LauncherCurrencyStore(loader: loader, defaults: defaults)
        store.update(input: "2$", defaultTarget: .RUB)
        XCTAssertEqual(store.result?.title, "140 ₽", "Stale value remains visible while refreshing")
        for _ in 0..<100 where store.result?.title != "160 ₽" { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(store.result?.title, "160 ₽")
        let loadCount = await loader.loadCount()
        XCTAssertEqual(loadCount, 1)
    }
}

private struct FixedCurrencyLoader: LauncherCurrencyRateLoading {
    let rates: LauncherCurrencyRates
    func loadRates() async throws -> LauncherCurrencyRates { rates }
}

private actor RetryCurrencyLoader: LauncherCurrencyRateLoading {
    let rates: LauncherCurrencyRates
    private var attempts = 0
    init(rates: LauncherCurrencyRates) { self.rates = rates }
    func loadRates() async throws -> LauncherCurrencyRates {
        attempts += 1
        if attempts == 1 { throw LauncherCurrencyError.invalidResponse }
        return rates
    }
}

private actor CountingCurrencyLoader: LauncherCurrencyRateLoading {
    let rates: LauncherCurrencyRates
    private var count = 0
    init(rates: LauncherCurrencyRates) { self.rates = rates }
    func loadRates() async throws -> LauncherCurrencyRates { count += 1; return rates }
    func loadCount() -> Int { count }
}

import Foundation
import XCTest
@testable import NotchApp

final class CodexResetForecastTests: XCTestCase {
    func testDecoderMapsCommunityForecastContract() throws {
        let data = Data(
            #"""
            {
              "mode": "model",
              "updated_at": "2026-09-08T06:01:19.210Z",
              "probabilities": {
                "raw_24h": 0.2915803600645666,
                "raw_48h": 0.4981416137537509,
                "rounded_24h": 30,
                "rounded_48h": 50,
                "commitment": null,
                "commitment_floor_percent": null,
                "signal_percent": null
              },
              "signal_score": null,
              "confidence": "low",
              "confidence_note": "Experimental forecast.",
              "last_reset_at": "2026-09-08T04:05:53.000Z",
              "age_days": 0.1,
              "official_signal": null,
              "teased_window": null,
              "time_window": {
                "start_hour": 23,
                "end_hour": 2,
                "label": "11 PM - 2 AM",
                "timezone": "UTC"
              },
              "cadence": {
                "recent_median_days": 2.1,
                "recent_sample": 5,
                "weighted_mean_days": 5,
                "accelerating": true
              },
              "milestone_watch": null,
              "evidence": [],
              "model": {
                "version": "rate-v3",
                "window_intervals": 8,
                "half_life_days": 60,
                "effective_sample_size": 28.5,
                "base_daily_rate": 0.292
              },
              "backtest": {
                "sample_size": 309,
                "brier": 0.109,
                "baseline_brier": 0.112,
                "rate_v2_brier": 0.109,
                "better_than_naive": true,
                "better_than_rate_v2": false,
                "status": "experimental"
              },
              "signal_tier": null,
              "alert_event_id": null,
              "latest_alert": {
                "id": "2097174560412246215",
                "kind": "reset",
                "state": "confirmed",
                "source_at": "2026-09-08T04:05:53.000Z",
                "summary": "All reset for everyone.",
                "url": "https://x.com/thsottiaux/status/2097174560412246215",
                "score": null,
                "window": null,
                "corrected": true
              }
            }
            """#.utf8
        )

        let forecast = try CodexResetForecastDecoder.decode(data)

        XCTAssertEqual(forecast.probability24Hours, 30)
        XCTAssertEqual(forecast.probability48Hours, 50)
        XCTAssertEqual(forecast.confidence, .low)
        XCTAssertEqual(forecast.confidenceNote, "Experimental forecast.")
        XCTAssertEqual(
            forecast.updatedAt.timeIntervalSince1970,
            1_788_847_279.210,
            accuracy: 0.001
        )
        XCTAssertEqual(
            try XCTUnwrap(forecast.lastResetAt).timeIntervalSince1970,
            1_788_840_353,
            accuracy: 0.001
        )
    }

    func testDecoderRejectsImpossibleProbability() {
        let data = Data(
            #"""
            {
              "mode": "model",
              "updated_at": "2026-09-08T06:01:19.210Z",
              "probabilities": {
                "rounded_24h": 130,
                "rounded_48h": 50
              },
              "confidence": "low",
              "last_reset_at": null
            }
            """#.utf8
        )

        XCTAssertThrowsError(try CodexResetForecastDecoder.decode(data))
    }

    func testVisibilityPolicyRejectsRetainedAdjacentPanel() {
        XCTAssertFalse(
            CodexResetForecastVisibility.shouldLoad(
                isExpanded: true,
                selectedPanel: .live,
                selectedAISection: .limits,
                isShowingSettings: false,
                isUtilityPresented: false,
                isChatGPTProviderVisible: true
            )
        )
        XCTAssertTrue(
            CodexResetForecastVisibility.shouldLoad(
                isExpanded: true,
                selectedPanel: .ai,
                selectedAISection: .limits,
                isShowingSettings: false,
                isUtilityPresented: false,
                isChatGPTProviderVisible: true
            )
        )
    }

    @MainActor
    func testProviderKeepsLastForecastWhenRefreshFails() async {
        let expected = CodexResetForecast(
            probability24Hours: 30,
            probability48Hours: 50,
            updatedAt: Date(timeIntervalSince1970: 1_788_847_279.210),
            lastResetAt: Date(timeIntervalSince1970: 1_788_840_353),
            confidence: .low,
            confidenceNote: "Experimental forecast."
        )
        let loader = ForecastSequenceLoader([
            .success(expected),
            .failure(ForecastStubError.offline)
        ])
        let provider = CodexResetForecastProvider(loader: loader)

        await provider.refresh()
        await provider.refresh()

        XCTAssertEqual(provider.forecast, expected)
        XCTAssertTrue(provider.isStale)
        XCTAssertEqual(provider.errorMessage, "Прогноз временно недоступен")
    }

    @MainActor
    func testProviderMarksOldServerForecastAsStale() async {
        let updatedAt = Date(timeIntervalSince1970: 946_684_800)
        let expected = CodexResetForecast(
            probability24Hours: 30,
            probability48Hours: 50,
            updatedAt: updatedAt,
            lastResetAt: nil,
            confidence: .low,
            confidenceNote: nil
        )
        let loader = ForecastSequenceLoader([.success(expected)])
        let provider = CodexResetForecastProvider(loader: loader)

        await provider.refresh()

        XCTAssertEqual(provider.forecast, expected)
        XCTAssertTrue(provider.isStale)
        XCTAssertNil(provider.errorMessage)
    }

    @MainActor
    func testCancelledRefreshDoesNotPublishForecast() async {
        let forecast = CodexResetForecast(
            probability24Hours: 30,
            probability48Hours: 50,
            updatedAt: .now,
            lastResetAt: nil,
            confidence: .low,
            confidenceNote: nil
        )
        let provider = CodexResetForecastProvider(
            loader: DelayedForecastLoader(forecast: forecast)
        )

        let refreshTask = Task { await provider.refresh() }
        await Task.yield()
        refreshTask.cancel()
        await refreshTask.value

        XCTAssertNil(provider.forecast)
        XCTAssertFalse(provider.isLoading)
        XCTAssertNil(provider.errorMessage)
    }
}

private actor ForecastSequenceLoader: CodexResetForecastLoading {
    private var results: [Result<CodexResetForecast, Error>]

    init(_ results: [Result<CodexResetForecast, Error>]) {
        self.results = results
    }

    func loadForecast() async throws -> CodexResetForecast {
        try results.removeFirst().get()
    }
}

private enum ForecastStubError: Error {
    case offline
}

private struct DelayedForecastLoader: CodexResetForecastLoading {
    let forecast: CodexResetForecast

    func loadForecast() async throws -> CodexResetForecast {
        try await Task<Never, Never>.sleep(nanoseconds: 30_000_000_000)
        return forecast
    }
}

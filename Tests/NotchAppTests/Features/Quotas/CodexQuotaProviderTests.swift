import XCTest
@testable import NotchApp

final class CodexQuotaProviderTests: XCTestCase {
    func testUnavailableMessageInterpolatesError() {
        struct StubError: LocalizedError {
            var errorDescription: String? { "test failure" }
        }

        XCTAssertEqual(
            CodexQuotaProvider.unavailableMessage(for: StubError()),
            "Codex app-server: test failure"
        )
    }

    func testGPT53CodexSparkLimitIsExcludedByIDOrDisplayName() {
        XCTAssertTrue(CodexQuotaSnapshotMapper.isGPT53SparkLimit(
            key: "codex_spark",
            limitID: nil,
            limitName: nil
        ))
        XCTAssertTrue(CodexQuotaSnapshotMapper.isGPT53SparkLimit(
            key: "another-key",
            limitID: "gpt-5.3-codex-spark",
            limitName: "GPT-5.3 Codex Spark"
        ))
    }

    func testOtherModelLimitsRemainVisible() {
        XCTAssertFalse(CodexQuotaSnapshotMapper.isGPT53SparkLimit(
            key: "gpt-5.3-codex",
            limitID: "codex",
            limitName: "GPT-5.3 Codex"
        ))
        XCTAssertFalse(CodexQuotaSnapshotMapper.isGPT53SparkLimit(
            key: "spark-standard",
            limitID: nil,
            limitName: "Spark Standard"
        ))
    }

    func testSnapshotMapperDropsLiveSparkBucketAndKeepsPrimaryCodexLimit() {
        let weekly = CodexRateLimitsResponse.Window(
            usedPercent: 23,
            windowDurationMins: 10_080,
            resetsAt: 1_789_805_411
        )
        let sparkSession = CodexRateLimitsResponse.Window(
            usedPercent: 0,
            windowDurationMins: 300,
            resetsAt: 1_789_393_331
        )
        let response = CodexRateLimitsResponse(
            rateLimits: .init(
                limitId: "codex",
                limitName: nil,
                primary: weekly,
                secondary: nil
            ),
            rateLimitsByLimitId: [
                "codex_bengalfox": .init(
                    limitId: "codex_bengalfox",
                    limitName: "GPT-5.3-Codex-Spark",
                    primary: sparkSession,
                    secondary: weekly
                )
            ]
        )

        let windows = CodexQuotaSnapshotMapper.windows(from: response, planType: "pro")

        XCTAssertEqual(windows.map(\.label), ["7d"])
    }
}

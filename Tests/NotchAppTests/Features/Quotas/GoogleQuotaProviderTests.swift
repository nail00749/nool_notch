import Foundation
import NotchCore
import XCTest
@testable import NotchApp

final class GoogleQuotaProviderTests: XCTestCase {
    func testParsesAntigravityLanguageServerProcessAndPorts() {
        let psOutput = """
          101 /usr/sbin/syslogd
          4251 /Applications/Antigravity.app/Contents/Resources/app/extensions/antigravity/bin/language_server_macos_arm --enable_lsp --csrf_token=tok_abc123 --extension_server_port=54321
        """
        let parsed = AntigravityLocalQuotaClient.parseServerProcess(from: psOutput)
        XCTAssertEqual(parsed?.pid, 4251)
        XCTAssertEqual(parsed?.csrfToken, "tok_abc123")
        XCTAssertEqual(parsed?.ports, [54321])

        let lsofOutput = """
        COMMAND    PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
        language_ 4251 user   12u  IPv4  0x123      0t0  TCP 127.0.0.1:54321 (LISTEN)
        language_ 4251 user   15u  IPv4  0x124      0t0  TCP 127.0.0.1:54322 (LISTEN)
        """
        let ports = AntigravityLocalQuotaClient.parseListeningPorts(from: lsofOutput)
        XCTAssertEqual(ports, [54321, 54322])
    }

    func testMapsLocalGetUserStatusIntoGroupedWindows() throws {
        let json = """
        {
          "userStatus": {
            "cascadeModelConfigData": {
              "clientModelConfigs": [
                {
                  "label": "Gemini 3 Pro (High)",
                  "modelOrAlias": { "model": "MODEL_GEMINI_3_PRO_HIGH" },
                  "quotaInfo": { "remainingFraction": 0.80, "resetTime": "2026-11-24T15:00:00Z" }
                },
                {
                  "label": "Gemini 3 Pro (Low)",
                  "modelOrAlias": { "model": "MODEL_GEMINI_3_PRO_LOW" },
                  "quotaInfo": { "remainingFraction": 0.65, "resetTime": "2026-11-24T14:30:00Z" }
                },
                {
                  "label": "Gemini 3 Flash",
                  "modelOrAlias": { "model": "MODEL_GEMINI_3_FLASH" },
                  "quotaInfo": { "remainingFraction": 0.92, "resetTime": "2026-11-24T16:00:00Z" }
                },
                {
                  "label": "Claude Sonnet 4.5",
                  "modelOrAlias": { "model": "MODEL_CLAUDE_4_5_SONNET" },
                  "quotaInfo": { "remainingFraction": 0.40, "resetTime": "2026-11-24T17:00:00Z" }
                }
              ]
            }
          }
        }
        """
        let windows = try GoogleQuotaMapper.windows(fromLocalUserStatusData: Data(json.utf8))
        XCTAssertEqual(windows.count, 3)

        XCTAssertEqual(windows[0].id, "google-gemini-pro")
        XCTAssertEqual(windows[0].label, "Pro")
        XCTAssertEqual(windows[0].remaining, 65)
        XCTAssertEqual(windows[0].resetAt, GoogleQuotaMapper.parseISO8601("2026-11-24T14:30:00Z"))

        XCTAssertEqual(windows[1].id, "google-gemini-flash")
        XCTAssertEqual(windows[1].label, "Flash")
        XCTAssertEqual(windows[1].remaining, 92)

        XCTAssertEqual(windows[2].id, "google-antigravity-partner")
        XCTAssertEqual(windows[2].label, "Partner")
        XCTAssertEqual(windows[2].remaining, 40)
    }

    func testParsesAgyUsageTUIScreenWithANSISequencesAndResetTimers() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let ansiOutput = """
        \u{1B}[2J\u{1B}[1;1HWelcome to the Antigravity CLI. You are currently not signed in.\r
        ⣷  Signing in...\u{1B}[1A\r\u{1B}[KAntigravity CLI 1.5.17\r
        ? for shortcuts\u{1B}[10X\u{1B}[10CGemini 4 Neon · high\r\u{1B}M
        \u{1B}[1mGEMINI MODELS\u{1B}[m\u{1B}[K\r
          \u{1B}[2mModels within this group: Gemini 4 Neon, Gemini 4 Carbon, Gemini 4 Argon, Gemini 4 Hydrogen, Orchestrator (Neon), Orchestrator (Carbon), O\u{1B}[m\r
        \u{1B}[K
          \u{1B}[1mWeekly Limit Remaining\u{1B}[m\u{1B}[K
        \u{1B}[20D[█████████████████████████████████████████\u{1B}[2m░░░░░░░░░\u{1B}[m]\u{1B}[2m 82.31%\u{1B}[m
        \u{1B}[59DRefreshes in 6d 0h 52m\r

          \u{1B}[1mFive Hour Limit Remaining\u{1B}[m
        \u{1B}[23D[█████████████████████████████████████████████████\u{1B}[2m░\u{1B}[m]\u{1B}[2m 98.04%\u{1B}[m
        \u{1B}[59DRefreshes in 4h 59m\r

        \u{1B}[1mCLAUDE AND GPT MODELS\u{1B}[m\r
          Models within this group: Claude Opus, Claude Sonnet, GPT-OSS\r
        \r
          Weekly Limit Remaining\r
            [\u{1B}[32m████████████████████████████████\u{1B}[0m] 100.00%\r
            Quota available\r
        GEMINI MODELS\r
          Weekly \r
         ░░░░░░░░░] 82.31\r
          Five Hour Limit Remaining\r
            [████████████████████████████████████████████████░░] 96.40%\r
            Refreshes in 4h 48m\r
        """

        let windows = try AgyUsageParser.parseWindows(from: ansiOutput, now: now)
        XCTAssertEqual(windows.map(\.id), ["google-5h", "google-7d"])
        XCTAssertEqual(windows.map(\.label), ["5h", "7d"])
        XCTAssertEqual(windows[0].remaining, 96.4)
        XCTAssertEqual(windows[0].resetAt, now.addingTimeInterval(4 * 3600 + 48 * 60))
        XCTAssertEqual(windows[1].remaining, 82.3)
        XCTAssertEqual(windows[1].resetAt, now.addingTimeInterval(6 * 86_400 + 52 * 60))
    }

    func testGoogleQuotaGateThrottlesAndRetainsStaleSnapshot() async {
        let gate = GoogleQuotaGate()
        let start = Date(timeIntervalSince1970: 1_000_000)

        let firstNil = await gate.cachedSnapshot(at: start)
        XCTAssertNil(firstNil)

        let live = QuotaSnapshot(
            providerID: "google-antigravity",
            providerName: "Google Antigravity",
            windows: [
                QuotaWindow(id: "google-5h", label: "5h", limit: 100, remaining: 80, resetAt: nil, unit: .percentage)
            ],
            connection: .live,
            updatedAt: start,
            sourceURL: nil,
            message: nil
        )
        await gate.recordSuccess(live, at: start)

        let cached = await gate.cachedSnapshot(at: start.addingTimeInterval(60))
        XCTAssertEqual(cached, live)

        let expiredCache = await gate.cachedSnapshot(at: start.addingTimeInterval(181))
        XCTAssertNil(expiredCache)

        let stale = await gate.staleSnapshot(for: .serviceUnavailable)
        XCTAssertEqual(stale?.connection, .stale)
        XCTAssertEqual(stale?.windows, live.windows)
    }
}

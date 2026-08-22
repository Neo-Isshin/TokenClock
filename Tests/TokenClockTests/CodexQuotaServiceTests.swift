import Foundation
import XCTest
@testable import TokenClock

final class CodexQuotaServiceTests: XCTestCase {
    func testDecodesAppServerRateLimitsAndCredits() throws {
        let response = #"""
        {
          "id": 2,
          "result": {
            "rateLimits": {
              "limitId": "codex",
              "limitName": "Codex",
              "planType": "pro",
              "primary": {
                "usedPercent": 25,
                "windowDurationMins": 300,
                "resetsAt": 2000000000
              },
              "secondary": {
                "usedPercent": "70",
                "windowDurationMins": 10080,
                "resetsAt": 2000003600
              },
              "credits": {
                "balance": "12.5",
                "unlimited": false
              }
            },
            "rateLimitResetCredits": {
              "availableCount": 2
            }
          }
        }
        """#
        let refreshedAt = Date(timeIntervalSince1970: 1_900_000_000)

        let snapshot = try XCTUnwrap(CodexQuotaService.decodeAppServerResponse(
            Data(response.utf8),
            now: refreshedAt
        ))

        XCTAssertEqual(snapshot.status, .available)
        XCTAssertEqual(snapshot.source, .appServer)
        XCTAssertEqual(snapshot.planType, "pro")
        XCTAssertEqual(snapshot.creditBalance, "12.5")
        XCTAssertEqual(snapshot.resetCreditCount, 2)
        XCTAssertEqual(snapshot.refreshedAt, refreshedAt)
        XCTAssertEqual(snapshot.buckets.map(\.windowMinutes), [10_080, 300])
        XCTAssertEqual(snapshot.buckets.map(\.remainingPercent), [30, 75])
    }

    func testDecodesBoundedSessionLogFallbackShape() throws {
        let line = #"""
        {
          "timestamp": "2026-08-06T10:30:00Z",
          "payload": {
            "rate_limits": {
              "plan_type": "team",
              "primary": {
                "used_percent": 110,
                "window_minutes": 300,
                "resets_at": 2000000000
              },
              "secondary": {
                "used_percent": 35,
                "window_minutes": 10080,
                "resets_at": 2000003600
              },
              "credits": {
                "balance": "4",
                "unlimited": true
              }
            }
          }
        }
        """#

        let snapshot = try XCTUnwrap(CodexQuotaService.decodeSessionLogLine(Data(line.utf8)))

        XCTAssertEqual(snapshot.status, .available)
        XCTAssertEqual(snapshot.source, .sessionLog)
        XCTAssertEqual(snapshot.planType, "team")
        XCTAssertEqual(snapshot.creditBalance, "4")
        XCTAssertTrue(snapshot.hasUnlimitedCredits)
        XCTAssertEqual(snapshot.buckets.map(\.windowMinutes), [10_080, 300])
        XCTAssertEqual(snapshot.buckets.map(\.remainingPercent), [65, 0])
    }

    func testRejectsAppServerErrorsAndLogsWithoutRateLimits() {
        XCTAssertNil(CodexQuotaService.decodeAppServerResponse(Data(#"{"id":2,"error":{"message":"no"}}"#.utf8)))
        XCTAssertNil(CodexQuotaService.decodeSessionLogLine(Data(#"{"payload":{}}"#.utf8)))
    }

    func testDecodesAndOrdersMultipleAppServerLimitGroups() throws {
        let response = #"""
        {
          "id": 2,
          "result": {
            "rateLimitsByLimitId": {
              "spark": {
                "limitName": "Spark",
                "primary": { "usedPercent": 10, "windowDurationMins": 1440 }
              },
              "codex": {
                "limitName": "Codex",
                "primary": { "usedPercent": "15", "windowDurationMins": "300" },
                "secondary": { "usedPercent": 40, "windowDurationMins": 10080 }
              }
            }
          }
        }
        """#

        let snapshot = try XCTUnwrap(CodexQuotaService.decodeAppServerResponse(Data(response.utf8)))

        XCTAssertEqual(snapshot.buckets.map(\.id), ["codex:secondary", "codex:primary"])
        XCTAssertEqual(snapshot.buckets.map(\.remainingPercent), [60, 85])
        XCTAssertFalse(snapshot.buckets.contains { $0.name.localizedCaseInsensitiveContains("spark") })
    }

    func testBuildsPlatformSpecificCodexExecutableCandidates() {
        let windows = CodexQuotaService.executableCandidatePaths(
            environment: [
                "CODEX_BINARY": "D:\\Portable\\codex.exe",
                "LOCALAPPDATA": "C:\\Users\\neo\\AppData\\Local",
                "APPDATA": "C:\\Users\\neo\\AppData\\Roaming",
                "Path": "C:\\Tools;D:\\Bin",
            ],
            platform: .windows,
            homeDirectory: "C:\\Users\\neo"
        )
        XCTAssertEqual(windows.first, "D:\\Portable\\codex.exe")
        XCTAssertTrue(windows.contains("C:\\Users\\neo\\AppData\\Local\\Programs\\OpenAI\\Codex\\bin\\codex.exe"))
        XCTAssertTrue(windows.contains("C:\\Users\\neo\\AppData\\Local\\OpenAI\\Codex\\bin\\codex.exe"))
        XCTAssertTrue(windows.contains("C:\\Tools\\codex.exe"))
        XCTAssertTrue(windows.contains("D:\\Bin\\codex.exe"))
        XCTAssertFalse(windows.contains { $0.contains(":\\Tools;D:") })

        let linux = CodexQuotaService.executableCandidatePaths(
            environment: ["PATH": "/custom/bin:/usr/bin"],
            platform: .unix,
            homeDirectory: "/home/neo"
        )
        XCTAssertTrue(linux.contains("/home/neo/.local/bin/codex"))
        XCTAssertTrue(linux.contains("/custom/bin/codex"))
        XCTAssertTrue(linux.contains("/usr/bin/codex"))
    }
}

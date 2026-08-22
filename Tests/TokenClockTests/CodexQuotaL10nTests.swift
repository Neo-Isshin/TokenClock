import XCTest
@testable import TokenClock

final class CodexQuotaL10nTests: XCTestCase {
    func testQuotaLabelsExistInEverySupportedLanguage() {
        let l10n = L10n.shared
        let originalLanguage = l10n.language
        defer { l10n.language = originalLanguage }

        let keys = [
            "detail.codexQuota", "detail.subscriptionQuotaLine1", "detail.subscriptionQuotaLine2",
            "quota.loading", "quota.unavailable", "quota.retry",
            "quota.weekly", "quota.liveSource", "quota.logSource",
        ]
        for language in AppLanguage.allCases {
            l10n.language = language
            for key in keys {
                XCTAssertNotEqual(l10n.tr(key), key, "\(key) fell back to its raw key for \(language.rawValue)")
            }
        }
    }
}

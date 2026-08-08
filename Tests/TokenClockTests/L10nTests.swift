import XCTest
@testable import TokenClock

final class L10nTests: XCTestCase {
    func testCustomEditorStyleLabelsAreLocalizedInEverySupportedLanguage() {
        let l10n = L10n.shared
        let originalLanguage = l10n.language
        defer { l10n.language = originalLanguage }

        let expected: [AppLanguage: [String: String]] = [
            .zhHans: [
                "editor.handStyle": "指针样式",
                "editor.numberStyle": "数字样式",
                "editor.numberFont": "数字字体",
            ],
            .zhHant: [
                "editor.handStyle": "指針樣式",
                "editor.numberStyle": "數字樣式",
                "editor.numberFont": "數字字體",
            ],
            .en: [
                "editor.handStyle": "Hand Style",
                "editor.numberStyle": "Number Style",
                "editor.numberFont": "Number Font",
            ],
        ]

        for language in AppLanguage.allCases {
            l10n.language = language
            for (key, value) in expected[language] ?? [:] {
                XCTAssertEqual(l10n.tr(key), value)
                XCTAssertNotEqual(l10n.tr(key), key, "\(key) fell back to its raw key for \(language.rawValue)")
            }
        }
    }
}

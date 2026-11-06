import XCTest
@testable import TokenClock

final class L10nTests: XCTestCase {
    func testContextMenuCategoryLabelsAreLocalizedInEverySupportedLanguage() {
        let l10n = L10n.shared
        let originalLanguage = l10n.language
        defer { l10n.language = originalLanguage }

        let keys = ["menu.appearance", "menu.weatherTime", "menu.general"]
        for language in AppLanguage.allCases {
            l10n.language = language
            for key in keys {
                XCTAssertNotEqual(l10n.tr(key), key, "\(key) fell back for \(language.rawValue)")
            }
        }
    }

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

    func testCatalogHasEveryLanguageAndMatchingFormatArguments() throws {
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source=try String(contentsOf:root.appendingPathComponent("Sources/TokenClock/L10n.swift"),encoding:.utf8)
        let ns=source as NSString
        let entries=try NSRegularExpression(pattern:#"^\s*"([^"\\]+)"\s*:\s*\["#,options:.anchorsMatchLines)
        let starts=entries.matches(in:source,range:NSRange(location:0,length:ns.length))
        let fields=try NSRegularExpression(pattern:#"\.(zhHans|zhHant|en):\s*"((?:\\.|[^"\\])*)""#)
        let formats=try NSRegularExpression(pattern:#"(?<!%)%(?!%)(?:[0-9]+\$)?[-+#0]*(?:[0-9]+|\*)?(?:\.[0-9]+)?(?:hh|h|ll|l|z)?[@a-zA-Z]"#)
        let han=try NSRegularExpression(pattern:"[\u{4e00}-\u{9fff}]")
        let l10n=L10n.shared,original=l10n.language
        defer {l10n.language=original}
        XCTAssertGreaterThanOrEqual(starts.count,500)
        for (index,entry) in starts.enumerated() {
            let key=ns.substring(with:entry.range(at:1))
            let end=index+1<starts.count ? starts[index+1].range.location:ns.length
            let block=ns.substring(with:NSRange(location:entry.range.location,length:end-entry.range.location)) as NSString
            var values:[String:String]=[:]
            for field in fields.matches(in:block as String,range:NSRange(location:0,length:block.length)) {
                values[block.substring(with:field.range(at:1))]=block.substring(with:field.range(at:2))
            }
            XCTAssertEqual(values.count,3,key)
            for language in AppLanguage.allCases {
                l10n.language=language
                XCTAssertNotEqual(l10n.tr(key),key,key)
                XCTAssertFalse(l10n.tr(key).isEmpty,key)
            }
            if let english=values["en"] { XCTAssertNil(han.firstMatch(in:english,range:NSRange(english.startIndex...,in:english)),key) }
            func arguments(_ value:String)->[String] {
                formats.matches(in:value,range:NSRange(value.startIndex...,in:value)).map { (value as NSString).substring(with:$0.range).suffix(1).description }.sorted()
            }
            for language in ["en","zhHant"] {XCTAssertEqual(arguments(values["zhHans"] ?? ""),arguments(values[language] ?? ""),key)}
        }
    }

    func testLocalToolboxResultsTranslateWithoutChangingStoredFindings() {
#if os(macOS)
        let l10n=L10n.shared,original=l10n.language
        defer {l10n.language=original}
        let finding=LocalFinding(title:"疑似密钥 · 第 42 行",detail:"匹配内容已隐藏，仅保留文件与行号",path:"/private/session.jsonl")
        l10n.language = .en
        XCTAssertEqual(finding.localizedTitle,"Suspected key · line 42")
        XCTAssertFalse(finding.localizedDetail.contains("隐藏"))
        XCTAssertEqual(finding.title,"疑似密钥 · 第 42 行")
        XCTAssertEqual(finding.path,"/private/session.jsonl")
        l10n.language = .zhHans
        XCTAssertEqual(LocalToolboxResultText.status("✅ Accepted"),"✅ 接口可用")
        XCTAssertEqual(LocalToolboxResultText.localized("1 MB · 8 files"),"1 MB · 8 个文件")
#endif
    }

}

import XCTest
@testable import TokenClock

final class BrandIconCatalogTests: XCTestCase {
    func testAllMappedBrandsHaveBundledPNGAssets() throws {
        let keys = Set(BrandIconCatalog.tools.values).union(BrandIconCatalog.modelFamilies.map(\.1))
        for key in keys {
            let url = try XCTUnwrap(BrandIconCatalog.url(forKey: key), "Missing \(key)")
            let bytes = try Data(contentsOf: url)
            XCTAssertEqual(Array(bytes.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10], key)
        }
        XCTAssertNil(BrandIconCatalog.url(forKey: "../outside"))
    }

    func testEmojiModePreservesLegacyLabelsAndUnknownPreferencesUseOfficial() {
        XCTAssertEqual(BrandIconStyle.resolved(nil), .official)
        XCTAssertEqual(BrandIconStyle.resolved("future-mode"), .official)
        XCTAssertEqual(BrandIconStyle.resolved("emoji"), .emoji)
        XCTAssertEqual(BrandIconCatalog.token(for: "Codex", fallback: "⚛️", style: .emoji), "⚛️")
        XCTAssertEqual(BrandIconCatalog.token(for: "Codex", fallback: "⚛️", style: .official), "[[brand:codex]]")
        XCTAssertEqual(BrandIconCatalog.nativeLabel("▾ 😶 Grok Bot", style: .emoji), "▾ 😶 Grok Bot")
    }

    func testToolAndModelIdentitiesRemainDistinct() {
        XCTAssertEqual(BrandIconCatalog.key(for: "Codex"), "codex")
        XCTAssertEqual(BrandIconCatalog.key(for: "openai/gpt-6-astra"), "openai")
        XCTAssertEqual(BrandIconCatalog.key(for: "Grok Bot"), "grok-bot")
        XCTAssertEqual(BrandIconCatalog.key(for: "grok-bot-default"), "grok")
        XCTAssertEqual(BrandIconCatalog.key(for: "Qwen Code"), "qwen-code")
        XCTAssertEqual(BrandIconCatalog.key(for: "qwen3-coder"), "qwen")
        XCTAssertNil(BrandIconCatalog.key(for: "Unknown"))
        XCTAssertEqual(BrandIconCatalog.token(for: "Unknown", fallback: "🧠"), "🧠")
    }

    func testNativeLabelPreservesDisclosureAndName() {
        let parts = BrandIconCatalog.labelParts("▾ ⚛️ Codex")
        XCTAssertEqual(parts?.key, "codex")
        XCTAssertEqual(parts?.prefix, "▾ ")
        XCTAssertEqual(parts?.text, "Codex")
        XCTAssertEqual(BrandIconCatalog.nativeLabel("😶 Grok Bot", style: .official), "[[brand:grok-bot]] Grok Bot")
        XCTAssertNil(BrandIconCatalog.labelParts("☀️ Los Angeles"))
    }
}

import XCTest
@testable import TokenClock

final class EmojiMappingTests: XCTestCase {
    func testDenseModelRowsUseDistinctReadableEmoji() {
        XCTAssertEqual(ModelEmoji.emoji(for: "gpt-5.6-sol"), "💫")
        XCTAssertEqual(ModelEmoji.emoji(for: "gpt-6-astra"), "💫")
        XCTAssertEqual(ModelEmoji.emoji(for: "gemini-3.7-flash"), "❇️")
        XCTAssertEqual(ModelEmoji.emoji(for: "grok-4"), "🪐")
        XCTAssertEqual(ModelEmoji.emoji(for: "grok-bot-default"), "😶")
        XCTAssertEqual(ModelEmoji.emoji(for: "MiniMax-M3"), "〽️")
        XCTAssertEqual(ModelEmoji.emoji(for: "qwen3-coder"), "♻️")
    }

    func testSelectedToolEmojiStayVisuallyDistinct() {
        let tools = Dictionary(uniqueKeysWithValues: MockUsageService.generateInitialData().map { ($0.name, $0.emoji) })
        XCTAssertEqual(tools["Gemini CLI"], "❇️")
        XCTAssertEqual(tools["Codex"], "⚛️")
        XCTAssertEqual(tools["OpenCode"], "🖱️")
        XCTAssertEqual(tools["Qwen Code"], "♻️")
        XCTAssertEqual(tools["Grok"], "🪐")
        XCTAssertEqual(tools["Antigravity"], "🔃")
        XCTAssertEqual(tools["Cline"], "🧰")
        XCTAssertEqual(tools["Cursor Agent"], "💎")
        XCTAssertEqual(tools["Grok Bot"], "😶")
    }
}

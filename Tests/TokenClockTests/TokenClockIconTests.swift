import XCTest
@testable import TokenClock

final class TokenClockIconTests: XCTestCase {
    func testToolAndModelNamesResolveToDistinctSemanticIcons() {
        XCTAssertEqual(TokenClockIcon.resolve(displayName: "Codex"), .toolCodex)
        XCTAssertEqual(TokenClockIcon.resolve(displayName: "Cursor Agent"), .toolCursorAgent)
        XCTAssertEqual(TokenClockIcon.resolve(displayName: "Antigravity"), .toolAntigravity)
        XCTAssertEqual(TokenClockIcon.resolve(displayName: "Qwen Code"), .toolQwenCode)
        XCTAssertEqual(TokenClockIcon.resolve(displayName: "Grok"), .toolGrokCLI)
        XCTAssertEqual(TokenClockIcon.resolve(displayName: "Grok Bot"), .toolGrokBot)
        XCTAssertEqual(TokenClockIcon.resolve(displayName: "Cline"), .toolCline)
        XCTAssertEqual(TokenClockIcon.resolve(displayName: "gpt-5.6-sol"), .modelOpenAIChatGPT)
        XCTAssertEqual(TokenClockIcon.resolve(displayName: "grok-bot-default"), .modelGrok)
        XCTAssertEqual(TokenClockIcon.resolve(displayName: "MiniMax-M3"), .modelMiniMax)
        XCTAssertEqual(TokenClockIcon.resolve(displayName: "qwen3-coder"), .modelQwen)
        XCTAssertNil(TokenClockIcon.resolve(displayName: "OpenCode"))
    }

    func testEverySemanticIconHasBundledSVG() {
        for icon in TokenClockIcon.allCases {
            let url = Bundle.module.url(
                forResource: icon.resourceName,
                withExtension: "svg",
                subdirectory: "TokenClockIcons"
            ) ?? Bundle.module.url(forResource: icon.resourceName, withExtension: "svg")
            XCTAssertNotNil(url, "Missing SVG for \(icon.rawValue)")
        }
    }
}

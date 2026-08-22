#if os(Windows)
import XCTest
@testable import TokenClock

final class WindowsEmojiSupportTests: XCTestCase {
    func testEveryWindowsProviderHasAColoredIcon() {
        for provider in WindowsProviderCatalog.orderedEntries {
            XCTAssertTrue(
                WindowsEmojiSupport.hasColorIcon(for: provider.emoji),
                "Missing colored icon for \(provider.displayName): \(provider.emoji)"
            )
        }
    }

    func testEveryModelCategoryAndUnknownBucketHasAColoredIcon() {
        let models = [
            "claude-sonnet", "gpt-5", "o3", "gemini-pro", "minimax-m2",
            "glm-5", "kimi-k2", "moonshot-v1", "qwen3", "doubao-pro",
            "deepseek-v3", "llama-4", "grok-4", "mistral-large", "unknown-model",
        ]
        for model in models {
            XCTAssertTrue(
                WindowsEmojiSupport.hasColorIcon(for: ModelEmoji.emoji(for: model)),
                "Missing colored icon for model category \(model)"
            )
        }
        XCTAssertTrue(WindowsEmojiSupport.hasColorIcon(for: "❓ Unknown"))
    }

    func testWeatherAndRateIconsHaveColoredReplacements() {
        let semanticIcons = [
            "☀️", "⛅", "☁️", "🌫️", "🌦️", "🌨️", "⛈️", "❄️", "🌧️",
            "💥", "🔥", "🏃‍♂️", "☕", "🛌",
        ]
        for icon in semanticIcons {
            XCTAssertTrue(WindowsEmojiSupport.hasColorIcon(for: icon), "Missing colored icon for \(icon)")
        }
    }

    func testUncataloguedEmojiUsesFontFallback() {
        XCTAssertFalse(WindowsEmojiSupport.hasColorIcon(for: "🪿"))
    }
}
#endif

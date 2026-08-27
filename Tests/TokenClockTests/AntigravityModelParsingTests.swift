import Foundation
import XCTest
@testable import TokenClock

final class AntigravityModelParsingTests: XCTestCase {
    func testDecodesSelectedModelFromExecutorMetadata() {
        let config = field(28, bytes: Data("gemini-3.7-flash-high".utf8))
        let runtime = field(1, bytes: config)
        let root = field(10, bytes: runtime)

        XCTAssertEqual(
            AntigravityUsageService().decodeModelFromExecutorMetadata(root),
            "gemini-3.7-flash"
        )
    }

    func testNormalizesGeminiThinkingLevelsAsOneOfficialModel() {
        for level in ["low", "medium", "high", "xhigh"] {
            XCTAssertEqual(
                ModelNormalizer.normalize("gemini-3.7-flash-\(level)"),
                "gemini-3.7-flash"
            )
        }
        XCTAssertEqual(ModelNormalizer.normalize("claude-opus-5-high-thinking"), "claude-opus-5")
        XCTAssertEqual(ModelNormalizer.normalize("gpt-5.6-sol-max"), "gpt-5.6-sol")
        XCTAssertEqual(ModelNormalizer.normalize("gemini-3.6-flash-max-thinking"), "gemini-3.6-flash")
    }

    func testPreservesOfficialNamesThatOnlyLookLikeEffortSuffixes() {
        XCTAssertEqual(ModelNormalizer.normalize("qwen3.8-max"), "qwen3.8-max")
        XCTAssertEqual(ModelNormalizer.normalize("MiniMax-M2.7-highspeed"), "MiniMax-M2.7-highspeed")
        XCTAssertEqual(ModelNormalizer.normalize("my-medium-model"), "my-medium-model")
    }

    func testIgnoresModelLookingTextOutsideExecutorConfigPath() {
        let decoy = field(2, bytes: Data("gemini-3.7-flash-high".utf8))
        XCTAssertNil(AntigravityUsageService().decodeModelFromExecutorMetadata(decoy))
    }

    func testRealLocalSessionsExposeConcreteModelsWhenEnabled() throws {
        guard ProcessInfo.processInfo.environment["TOKENCLOCK_RUN_REAL_ANTIGRAVITY_TESTS"] == "1" else {
            throw XCTSkip("Set TOKENCLOCK_RUN_REAL_ANTIGRAVITY_TESTS=1 to scan local Antigravity data")
        }
        let service = AntigravityUsageService()
        service.fullScan()
        let sessions = service.todaySessions()
        guard !sessions.isEmpty else { throw XCTSkip("No Antigravity sessions found for today") }
        let models = sessions.compactMap(\.model)
        XCTAssertEqual(models.count, sessions.count)
        XCTAssertTrue(models.allSatisfy { $0.hasPrefix("gemini-") }, "Decoded models: \(models)")
        XCTAssertFalse(
            models.contains { $0.hasSuffix("-low") || $0.hasSuffix("-medium") || $0.hasSuffix("-high") },
            "Thinking levels must not appear as model versions: \(models)"
        )
        XCTAssertTrue(sessions.allSatisfy { $0.todayCost.available }, "Session costs: \(sessions.map(\.todayCost))")
        XCTAssertTrue(service.todayCost().available)
    }

    private func field(_ number: UInt64, bytes: Data) -> Data {
        var result = varint((number << 3) | 2)
        result.append(varint(UInt64(bytes.count)))
        result.append(bytes)
        return result
    }

    private func varint(_ value: UInt64) -> Data {
        var value = value
        var bytes: [UInt8] = []
        repeat {
            var byte = UInt8(value & 0x7f)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while value != 0
        return Data(bytes)
    }
}

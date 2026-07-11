import XCTest
@testable import TokenClock

/// CustomThemeConfig 宽容解码测试 —— 验证旧 schema（缺字段）能解码且缺失字段回默认，
/// 而非整体失败/静默清空（#7 修复的核心保证）。
final class CustomThemeConfigTests: XCTestCase {

    func testDecodes_partialJSON_missingFieldsFallbackToDefaults() {
        // 仅 dialColor + showNumbers；其余字段缺失 → 应回默认，不抛错
        let json = """
        {"dialColor":{"red":0.1,"green":0.2,"blue":0.3},"showNumbers":false}
        """.data(using: .utf8)!
        let cfg = try! JSONDecoder().decode(CustomThemeConfig.self, from: json)
        XCTAssertEqual(cfg.dialColor.red, 0.1)
        XCTAssertEqual(cfg.dialColor.green, 0.2)
        XCTAssertEqual(cfg.dialColor.blue, 0.3)
        XCTAssertEqual(cfg.dialColor.opacity, 1.0, "缺 opacity 通道 → 默认 1.0")
        XCTAssertEqual(cfg.showNumbers, false, "显式 false 覆盖默认 true")
        // 缺失字段回默认
        XCTAssertEqual(cfg.hourHandWidth, 4.5)
        XCTAssertEqual(cfg.handStyleRaw, "round")
        XCTAssertEqual(cfg.numberStyleRaw, "arabic")
        XCTAssertNil(cfg.glassTint, "可选字段缺失 → nil")
    }

    func testDecodes_emptyJSON_allDefaults() {
        let cfg = try! JSONDecoder().decode(CustomThemeConfig.self, from: "{}".data(using: .utf8)!)
        XCTAssertEqual(cfg, CustomThemeConfig(), "空 JSON 应等价于全新默认实例")
    }

    func testCodableColor_missingOpacity_defaultsToOne() {
        let json = "{\"red\":0.5,\"green\":0.5,\"blue\":0.5}".data(using: .utf8)!
        let c = try! JSONDecoder().decode(CodableColor.self, from: json)
        XCTAssertEqual(c.opacity, 1.0, "缺 opacity 通道 → 默认 1.0")
    }

    func testRoundTrip_preservesCustomValues() {
        var original = CustomThemeConfig()
        original.dialRimWidth = 9
        original.handStyleRaw = "lance"
        original.showNumbers = false
        let data = try! JSONEncoder().encode(original)
        let decoded = try! JSONDecoder().decode(CustomThemeConfig.self, from: data)
        XCTAssertEqual(decoded, original, "编码→解码应保持字段一致（向后兼容靠解码兜底，不影响正常往返）")
    }
}

import Foundation

/// AI 模型名归一化：去掉厂商在 model 名尾部附加的日期/快照后缀，只保留稳定的官方模型名。
///
/// 用于「按模型」分组视图，避免同一模型因日期不同（如 `claude-sonnet-4-5-20250929`
/// 与 `claude-sonnet-4-5-20251027`）被拆成多行。
///
/// 例：
/// - `claude-sonnet-4-5-20250929` → `claude-sonnet-4-5`
/// - `gpt-5-codex-2025-09-29`     → `gpt-5-codex`
/// - `gemini-2.5-pro`             → `gemini-2.5-pro`（无日期后缀，原样返回）
enum ModelNormalizer {
    /// 尾部日期后缀：`-20250929` / `-2025-09-29` 等固定在串末的 8 位日期（可带连字符）。
    private static let dateSuffixPattern = #"-\d{4}-?\d{2}-?\d{2}$"#

    /// 已知别名兜底表（手动维护）。键 = 工具日志里的展示别名，值 = 官方模型名。
    /// Antigravity 把思考强度附加在 Gemini 3.7 Flash 后面；low / medium / high
    /// 是推理设置而不是不同模型，分组、显示和计费均应归入同一个官方模型。
    private static let aliases: [String: String] = [
        "gemini-3.7-flash-low": "gemini-3.7-flash",
        "gemini-3.7-flash-medium": "gemini-3.7-flash",
        "gemini-3.7-flash-high": "gemini-3.7-flash",
    ]

    /// 把原始 model 名归一成官方模型名。
    /// - Parameters:
    ///   - raw: 工具日志里读到的原始 model 字符串（可能为 nil / 空 / 带日期后缀）。
    /// - Returns: 归一化后的官方名；输入为 nil / 空白时返回 nil（交由上层归入「未知」桶）。
    static func normalize(_ raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            return nil
        }
        s = s.replacingOccurrences(of: dateSuffixPattern, with: "", options: .regularExpression)
        if let mapped = aliases[s] { s = mapped }
        return s
    }
}

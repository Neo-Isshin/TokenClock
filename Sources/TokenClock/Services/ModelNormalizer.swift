import Foundation

/// AI 模型名归一化：去掉日期/快照后缀和路由器附加的推理等级，只保留稳定的官方模型名。
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

    /// Cursor / Antigravity 等路由器在模型 ID 尾部附加的推理等级。
    /// `highspeed` 等单词不会命中；只有完整的末尾段才移除。
    private static let effortSuffixPattern = #"-(?:low|medium|high|xhigh)(?:-thinking)?$"#
    private static let maxThinkingSuffixPattern = #"-max-thinking$"#

    /// `max` 也是部分厂商正式模型名（如 qwen3.8-max），不能全局移除。
    /// 仅在已知会把 max 当作推理档位的模型族中处理裸 `-max`。
    private static let maxEffortFamilies = [
        "gpt-", "claude-", "gemini-", "grok-", "composer-", "o1-", "o3-", "o4-",
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
        s = s.replacingOccurrences(of: effortSuffixPattern, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: maxThinkingSuffixPattern, with: "", options: .regularExpression)
        if s.hasSuffix("-max"), maxEffortFamilies.contains(where: { s.lowercased().hasPrefix($0) }) {
            s.removeLast(4)
        }
        return s
    }
}

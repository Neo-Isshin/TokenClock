import Foundation

/// 「按模型」视图里给常见模型配一个 emoji 前缀（纯通用符号，非品牌 logo）。
///
/// 按归一化后的模型名前缀（大小写不敏感）顺序匹配，第一个命中即返回；无命中 → 🧠。
/// 大厂系（Claude / GPT / Gemini / Qwen / Grok）刻意复用对应工具在 TokenClock 里的 emoji，
/// 让「工具行」与「模型行」视觉上能对上号；其余按厂商特征配通用符号。
enum ModelEmoji {
    /// (前缀, emoji) —— 顺序敏感；更具体的放前面。前缀匹配均对模型名 lowercased。
    private static let rules: [(prefix: String, emoji: String)] = [
        // Anthropic —— 同 Claude Code 工具
        ("claude",   "✳️"),
        // OpenAI —— 同 Codex 工具（含 o 系列推理模型）
        ("gpt",      "🤖"),
        ("o1",       "🤖"),
        ("o3",       "🤖"),
        ("o4",       "🤖"),
        // Google —— 同 Gemini CLI 工具
        ("gemini",   "✨"),
        // MiniMax —— 声波
        ("minimax",  "🔊"),
        // 智谱 GLM —— 字母 Z
        ("glm",      "🅉"),
        // Moonshot Kimi —— 字母 K
        ("kimi",     "🅚"),
        ("moonshot", "🅚"),
        // 通义千问 —— 同 Qwen Code 工具
        ("qwen",     "🟣"),
        // 字节豆包 —— 豆
        ("doubao",   "🫘"),
        // DeepSeek —— 鲸
        ("deepseek", "🐋"),
        // Meta Llama
        ("llama",    "🦙"),
        // xAI Grok —— 同 Grok 工具
        ("grok",     "⚡"),
        // Mistral
        ("mistral",  "🌪️"),
    ]

    /// 取模型名对应的 emoji；匹配不到返回 🧠。
    static func emoji(for modelName: String) -> String {
        let lower = modelName.lowercased()
        for rule in rules where lower.hasPrefix(rule.prefix) {
            return rule.emoji
        }
        return "🧠"
    }
}

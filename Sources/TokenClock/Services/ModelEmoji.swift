import Foundation

/// 「按模型」视图里给常见模型配一个 emoji 前缀（纯通用符号，非品牌 logo）。
///
/// 按归一化后的模型名前缀（大小写不敏感）顺序匹配，第一个命中即返回；无命中 → 🧠。
/// 大厂系（Claude / GPT / Gemini / Grok）刻意复用对应工具在 TokenClock 里的 emoji，
/// 让「工具行」与「模型行」视觉上能对上号；其余按厂商特征配通用符号。
enum ModelEmoji {
    /// (前缀, emoji) —— 顺序敏感；更具体的放前面。前缀匹配均对模型名 lowercased。
    private static let rules: [(prefix: String, emoji: String)] = [
        // OpenAI / ChatGPT models share the user-selected shooting-star mark.
        ("gpt-6-astra", "💫"),
        ("gpt-5.6-sol", "💫"),
        ("gpt-5.6-luna", "💫"),
        ("gpt-5.6-terra", "💫"),
        ("gpt-5.4-mini", "💫"),
        ("chatgpt", "💫"),
        ("gpt", "💫"),
        ("o1", "💫"),
        ("o3", "💫"),
        ("o4", "💫"),

        // Anthropic model names are literary forms.
        ("claude-opus", "🎼"),
        ("claude-sonnet", "📝"),
        ("claude-haiku", "🍃"),
        ("claude-fable", "📖"),
        ("claude", "✳️"),

        // Gemini CLI and every Gemini model share the same sparkle mark.
        ("gemini-3.7-flash", "❇️"),
        ("gemini-3.6-flash", "❇️"),
        ("gemini-3.5-flash", "❇️"),
        ("gemini", "❇️"),

        ("minimax", "〽️"),
        ("glm", "🧮"),
        ("kimi", "🌙"),
        ("moonshot", "🌙"),
        ("qwen", "♻️"),
        ("doubao", "🫘"),
        ("deepseek", "🐋"),
        ("llama", "🦙"),
        ("grok-bot", "🪐"),
        ("grok", "🪐"),
        ("mistral", "🌪️"),
        ("command", "🧭"),
        ("nova", "🌠"),
        ("phi", "🔷"),
        ("yi", "☯️"),
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

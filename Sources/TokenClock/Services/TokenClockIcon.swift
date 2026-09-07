import Foundation

/// Stable semantic IDs for TokenClock's original provider/model glyphs.
///
/// Tool names are matched before model families so `Grok` and `Grok Bot` keep
/// their surface-specific badges, while every concrete `grok-*` model shares
/// the same black-hole mark.
enum TokenClockIcon: String, CaseIterable, Sendable {
    case toolCodex = "tool-codex"
    case toolCursorAgent = "tool-cursor-agent"
    case toolAntigravity = "tool-antigravity"
    case toolQwenCode = "tool-qwen-code"
    case toolGrokCLI = "tool-grok-cli"
    case toolGrokBot = "tool-grok-bot"
    case toolCline = "tool-cline"
    case modelOpenAIChatGPT = "model-openai-chatgpt"
    case modelGrok = "model-grok"
    case modelMiniMax = "model-minimax"
    case modelQwen = "model-qwen"

    var resourceName: String { rawValue }

    static func resolve(displayName rawName: String) -> TokenClockIcon? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name.lowercased() {
        case "codex": return .toolCodex
        case "cursor agent": return .toolCursorAgent
        case "antigravity": return .toolAntigravity
        case "qwen code": return .toolQwenCode
        case "grok", "grok cli": return .toolGrokCLI
        case "grok bot": return .toolGrokBot
        case "cline": return .toolCline
        default: break
        }

        let model = name.lowercased()
        if model.hasPrefix("grok") { return .modelGrok }
        if model.hasPrefix("minimax") { return .modelMiniMax }
        if model.hasPrefix("qwen") { return .modelQwen }
        if model.hasPrefix("chatgpt") || model.hasPrefix("gpt-")
            || model.hasPrefix("o1") || model.hasPrefix("o3") || model.hasPrefix("o4") {
            return .modelOpenAIChatGPT
        }
        return nil
    }
}

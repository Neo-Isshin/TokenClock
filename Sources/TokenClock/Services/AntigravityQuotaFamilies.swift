import Foundation

enum AntigravityQuotaFamilies {
    enum Family { case gemini, claudeGPT, argon }

    static func matches(_ family: Family, group: String, bucket: CodexQuotaBucket) -> Bool {
        let name = group.lowercased()
        let argon = name.contains("argon") || bucket.id.lowercased().contains("argon") || bucket.name.lowercased().contains("argon")
        switch family {
        case .argon: return argon
        case .gemini: return !argon && name.contains("gemini")
        case .claudeGPT: return !argon && (name.contains("claude") || name.contains("gpt"))
        }
    }
}

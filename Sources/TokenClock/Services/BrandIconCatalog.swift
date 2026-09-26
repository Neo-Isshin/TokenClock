import Foundation

/// A presentation-only preference: persisted usage and API responses keep their emoji.
enum BrandIconStyle: String, CaseIterable {
    case official, emoji
    static let defaultsKey = "TC_brandIconStyle"
    static var current: Self {
        get { resolved(UserDefaults.standard.string(forKey: defaultsKey)) }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }
    static func resolved(_ value: String?) -> Self { value.flatMap(Self.init(rawValue:)) ?? .official }
    static var menuTitle: String {
        switch L10n.shared.language {
        case .en: return "Tool & Model Icons"
        case .zhHans: return "工具与模型图标"
        case .zhHant: return "工具與模型圖示"
        }
    }
    var title: String {
        if self == .emoji { return "Emoji" }
        switch L10n.shared.language {
        case .en: return "Official Icons"
        case .zhHans: return "官方图标"
        case .zhHant: return "官方圖示"
        }
    }
}

/// Bundled vendor artwork. Usage records retain their text/emoji fallback;
/// branding is resolved only at presentation time, including historical rows.
enum BrandIconCatalog {
    /// Unplated monochrome marks follow foreground contrast; colored brands stay original.
    static let monochromeKeys: Set<String> = ["codex", "copilot", "grok", "zcode"]
    static let tools: [String: String] = [
        "codex": "codex", "claude code": "claude", "claude": "claude",
        "cursor": "cursor", "cursor agent": "cursor", "gemini cli": "gemini",
        "antigravity": "antigravity", "antigravity ide": "antigravity",
        "antigravity cli": "antigravity", "qwen code": "qwen-code",
        "grok": "grok", "grok cli": "grok", "grok bot": "grok-bot",
        "openclaw": "openclaw", "hermes": "hermes", "opencode": "opencode",
        "copilot": "copilot", "github copilot cli": "copilot", "aider": "aider",
        "cline": "cline", "continue": "continue", "zcode": "zcode",
        "z.ai": "zai", "kiro": "kiro", "kiro cli": "kiro",
        "codebuddy": "codebuddy", "codebuddy cli": "codebuddy",
    ]
    static let modelFamilies: [(String, String)] = [
        ("grok", "grok"), ("chatgpt", "openai"), ("gpt", "openai"),
        ("o1", "openai"), ("o3", "openai"), ("o4", "openai"),
        ("claude", "claude"), ("gemini", "gemini"), ("composer", "cursor"),
        ("minimax", "minimax"), ("glm", "zai"), ("kimi", "kimi"),
        ("moonshot", "kimi"), ("qwen", "qwen"), ("doubao", "doubao"),
        ("deepseek", "deepseek"), ("llama", "meta"), ("mistral", "mistral"),
        ("codestral", "mistral"), ("command", "cohere"), ("nova", "amazon"),
        ("phi", "microsoft"), ("yi-", "yi"),
    ]

    static func key(for name: String) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let tool = tools[name] { return tool }
        let model = name.split(separator: "/").last.map(String.init) ?? name
        return modelFamilies.first { model.hasPrefix($0.0) }?.1
    }

    static var directory: URL? {
        Bundle.module.resourceURL?.appendingPathComponent("BrandIcons", isDirectory: true)
    }

    private static let urls: [String: URL] = {
        let keys = Set(tools.values).union(modelFamilies.map(\.1))
        return Dictionary(uniqueKeysWithValues: keys.compactMap { key in
            guard let url = directory?.appendingPathComponent(key + ".png"),
                  FileManager.default.fileExists(atPath: url.path) else { return nil }
            return (key, url)
        })
    }()

    static func url(forKey key: String) -> URL? { urls[key] }

    static func token(for name: String, fallback: String, style: BrandIconStyle = .current) -> String {
        guard style == .official else { return fallback }
        guard let key = key(for: name), url(forKey: key) != nil else { return fallback }
        return "[[brand:\(key)]]"
    }

    /// Upgrade legacy presenter labels without changing stored usage or API data.
    static func labelParts(_ label: String) -> (prefix: String, key: String, text: String)? {
        let pattern = #"^(\s*[▸▾]?\s*)[^\p{L}\p{N}\s]+\s+(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: label, range: NSRange(label.startIndex..., in: label)),
              let prefixRange = Range(match.range(at: 1), in: label),
              let nameRange = Range(match.range(at: 2), in: label) else { return nil }
        let text = String(label[nameRange])
        let name = text.components(separatedBy: " · ").first ?? text
        guard let key = key(for: name), url(forKey: key) != nil else { return nil }
        return (String(label[prefixRange]), key, text)
    }

    static func nativeLabel(_ label: String, style: BrandIconStyle = .current) -> String {
        guard style == .official else { return label }
        guard let parts = labelParts(label) else { return label }
        return "\(parts.prefix)[[brand:\(parts.key)]] \(parts.text)"
    }
}

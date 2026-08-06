import Foundation
#if os(Windows)
import Win32Shim     // win_user_locale (GetUserDefaultLocaleName)
#endif

enum AppLanguage: String, CaseIterable, Identifiable {
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case en = "en"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .zhHans: return "简体中文"
        case .zhHant: return "繁體中文"
        case .en:     return "English"
        }
    }
}

final class L10n: @unchecked Sendable {
    static let shared = L10n()

    var language: AppLanguage {
        didSet { UserDefaults.standard.setString(language.rawValue, for: .language) }
    }

    private init() {
        let defaults = UserDefaults.standard
        if let saved = defaults.string(for: .language),
           let lang = AppLanguage(rawValue: saved) {
            // 已有记录（用户手动选择过，或上次自动探测过）→ 沿用
            self.language = lang
        } else {
            // 首次启动：未记录过语言 → 按系统语言自动探测并落盘（之后以用户手动选择为准）
            let detected = Self.detectSystemLanguage()
            self.language = detected
            defaults.setString(detected.rawValue, for: .language)
        }
    }

    /// 探测系统语言并映射到 AppLanguage：简/繁中文 → 对应中文，其余（含英文及一切非中文）→ 英文。
    private static func detectSystemLanguage() -> AppLanguage {
        #if os(Linux)
        // Linux：依次读 LC_ALL / LC_MESSAGES / LANG（形如 zh_CN.UTF-8、zh_TW.UTF-8、en_US.UTF-8）
        let env = ProcessInfo.processInfo.environment
        let tag = env["LC_ALL"] ?? env["LC_MESSAGES"] ?? env["LANG"] ?? ""
        #elseif os(Windows)
        // Windows：读用户默认 locale（GetUserDefaultLocaleName，形如 zh-CN、zh-TW、en-US）。
        // 比 Locale.preferredLanguages（corelibs 上常为空）更可靠。
        let buf = UnsafeMutablePointer<CChar>.allocate(capacity: 86)
        defer { buf.deallocate() }
        let tag = (win_user_locale(buf, 86) > 0) ? String(cString: buf) : ""
        #else
        // macOS / 其他 Apple 平台：取用户首选语言列表第一项（形如 zh-Hans-CN、zh-Hant、en-US）
        let tag = Locale.preferredLanguages.first ?? ""
        #endif
        return matchLanguage(tag)
    }

    /// 把任意语言标签归一化为 AppLanguage：以 zh 开头 → 按繁/简判定，否则一律英文。
    private static func matchLanguage(_ tag: String) -> AppLanguage {
        let lower = tag.lowercased()
        guard lower.hasPrefix("zh") else { return .en }
        // 繁体标识：zh-Hant / zh-TW / zh-HK / zh-MO
        if lower.contains("hant") || lower.contains("tw") || lower.contains("hk") || lower.contains("mo") {
            return .zhHant
        }
        return .zhHans
    }

    func tr(_ key: String) -> String {
        table[key]?[language] ?? table[key]?[.zhHans] ?? key
    }

    func tr(_ key: String, _ args: CVarArg...) -> String {
        let format = tr(key)
        return String(format: format, arguments: args)
    }

    // MARK: - String Table

    private let table: [String: [AppLanguage: String]] = [
        // MARK: Menu
        "menu.clockFace":        [.zhHans: "🎨 表盘",               .zhHant: "🎨 錶盤",              .en: "🎨 Clock Face"],
        "menu.size":             [.zhHans: "表盘大小",              .zhHant: "錶盤大小",            .en: "Clock Size"],
        "menu.myClockFaces":     [.zhHans: "✏️ 我的表盘",            .zhHant: "✏️ 我的錶盤",           .en: "✏️ My Clock Faces"],
        "menu.api":              [.zhHans: "🔌 API: localhost:%d/api/usage", .zhHant: "🔌 API: localhost:%d/api/usage", .en: "🔌 API: localhost:%d/api/usage"],
        "menu.opacity":          [.zhHans: "透明度",                .zhHant: "透明度",              .en: "Opacity"],
        "menu.alwaysOnTop":      [.zhHans: "始终置于顶层",           .zhHant: "始終置於頂層",          .en: "Always on Top"],
        "menu.temperature":      [.zhHans: "🌡️ 温度",              .zhHant: "🌡️ 溫度",             .en: "🌡️ Temperature"],
        "menu.celsius":          [.zhHans: "摄氏度 °C",            .zhHant: "攝氏度 °C",            .en: "Celsius °C"],
        "menu.fahrenheit":       [.zhHans: "华氏度 °F",            .zhHant: "華氏度 °F",            .en: "Fahrenheit °F"],
        "menu.city":             [.zhHans: "🌤️ 城市",             .zhHant: "🌤️ 城市",             .en: "🌤️ City"],
        "menu.cityAuto":         [.zhHans: "自动(%@)",             .zhHant: "自動(%@)",             .en: "Auto (%@)"],
        "menu.cityAutoLocating": [.zhHans: "自动(定位中...)",       .zhHant: "自動(定位中...)",       .en: "Auto (locating...)"],
        "menu.timezone":         [.zhHans: "🕐 时区",              .zhHant: "🕐 時區",              .en: "🕐 Timezone"],
        "menu.language":         [.zhHans: "🌐 语言",              .zhHant: "🌐 語言",              .en: "🌐 Language"],
        "menu.settings":         [.zhHans: "⚙️ 设置",              .zhHant: "⚙️ 設定",              .en: "⚙️ Settings"],
        "menu.launchAtLogin":    [.zhHans: "开机自启",              .zhHant: "開機自啟",              .en: "Launch at Login"],
        "menu.dialAppearance":   [.zhHans: "🪟 表盘外观",           .zhHant: "🪟 錶盤外觀",           .en: "🪟 Dial Appearance"],
        "menu.dialTextColor":    [.zhHans: "文字颜色",             .zhHant: "文字顏色",              .en: "Text Color"],
        "menu.dialTextTheme":    [.zhHans: "跟随主题",             .zhHant: "跟隨主題",              .en: "Follow Theme"],
        "menu.dialTextWhite":    [.zhHans: "白色",                 .zhHant: "白色",                  .en: "White"],
        "menu.dialTextBlack":    [.zhHans: "黑色",                 .zhHant: "黑色",                  .en: "Black"],
        "menu.dialTextCustom":   [.zhHans: "自定义…",              .zhHant: "自訂…",                 .en: "Custom…"],
        "menu.dialMaterial":     [.zhHans: "玻璃材质",             .zhHant: "玻璃材質",              .en: "Glass Material"],
        "menu.materialClear":    [.zhHans: "清透",                 .zhHant: "清透",                  .en: "Clear"],
        "menu.materialStandard": [.zhHans: "标准",                 .zhHant: "標準",                  .en: "Standard"],
        "menu.materialFrosted":  [.zhHans: "磨砂",                 .zhHant: "磨砂",                  .en: "Frosted"],
        "menu.glassBacking":     [.zhHans: "毛玻璃底板",           .zhHant: "毛玻璃底板",            .en: "Frosted Backing"],
        "menu.dialTint":         [.zhHans: "玻璃底色",             .zhHant: "玻璃底色",              .en: "Glass Tint"],
        "menu.tintNone":         [.zhHans: "无",                   .zhHant: "無",                    .en: "None"],
        "menu.tintCustom":       [.zhHans: "自定义…",              .zhHant: "自訂…",                 .en: "Custom…"],
        "menu.panelTextColor":   [.zhHans: "📋 详情面板文字色",     .zhHant: "📋 詳情面板文字色",     .en: "📋 Detail Panel Text"],
        "menu.panelTextTheme":   [.zhHans: "跟随主题",             .zhHant: "跟隨主題",              .en: "Follow Theme"],
        "menu.panelTextCustom":  [.zhHans: "自定义…",              .zhHant: "自訂…",                 .en: "Custom…"],
        "menu.panelTextWhite":   [.zhHans: "白色",                 .zhHant: "白色",                  .en: "White"],
        "menu.panelTextBlack":   [.zhHans: "黑色",                 .zhHant: "黑色",                  .en: "Black"],
        "menu.dialResetDefaults":[.zhHans: "↩️ 恢复默认",           .zhHant: "↩️ 還原預設",            .en: "↩️ Reset to Defaults"],
        "menu.glassRefraction":  [.zhHans: "✨ 液态玻璃折射",        .zhHant: "✨ 液態玻璃折射",         .en: "✨ Liquid Glass Refraction"],
        "menu.quit":             [.zhHans: "关闭 TokenClock",       .zhHant: "關閉 TokenClock",       .en: "Quit TokenClock"],
        "menu.about":            [.zhHans: "关于 TokenClock",       .zhHant: "關於 TokenClock",       .en: "About TokenClock"],

        // MARK: About
        "about.license":         [.zhHans: "许可证：MIT",           .zhHant: "許可證：MIT",            .en: "License: MIT"],
        "about.contact":         [.zhHans: "联系方式",              .zhHant: "聯絡方式",              .en: "Contact"],
        "about.close":           [.zhHans: "关闭",                  .zhHant: "關閉",                  .en: "Close"],

        // MARK: Timezone
        "tz.auto":       [.zhHans: "自动",      .zhHant: "自動",      .en: "Auto"],
        "tz.hongKong":   [.zhHans: "香港 HKT",  .zhHant: "香港 HKT",  .en: "Hong Kong HKT"],
        "tz.shanghai":   [.zhHans: "上海 CST",  .zhHant: "上海 CST",  .en: "Shanghai CST"],
        "tz.tokyo":      [.zhHans: "东京 JST",  .zhHant: "東京 JST",  .en: "Tokyo JST"],
        "tz.singapore":  [.zhHans: "新加坡 SGT", .zhHant: "新加坡 SGT", .en: "Singapore SGT"],
        "tz.newYork":    [.zhHans: "纽约 EST",  .zhHant: "紐約 EST",  .en: "New York EST"],
        "tz.london":     [.zhHans: "伦敦 GMT",  .zhHant: "倫敦 GMT",  .en: "London GMT"],
        "tz.losAngeles": [.zhHans: "洛杉矶 PST", .zhHant: "洛杉磯 PST", .en: "Los Angeles PST"],

        // MARK: Clock overlay
        "clock.todayTokens":   [.zhHans: "今日Tokens",    .zhHant: "今日Tokens",    .en: "Today's Tokens"],
        "clock.messagesCount": [.zhHans: "消息数：%d条",   .zhHant: "消息數：%d條",   .en: "Messages: %d"],

        // MARK: Accessibility (VoiceOver) —— 表盘是纯视觉，VoiceOver 读不出指针/emoji，
        // 故把表盘收拢成单一元素并朗读「时间 + 用量」摘要。
        // %1$@=日期  %2$@=时间(HH:MM)  %3$@=今日token  %4$@=消息数串
        "a11y.clockSummary": [.zhHans: "时钟。%@，%@。今日 %@。%@。",
                              .zhHant: "時鐘。%@，%@。今日 %@。%@。",
                              .en:     "Clock. %@, %@. Today %@. %@."],
        "a11y.clockHint":    [.zhHans: "点按展开或收起详情",
                              .zhHant: "點按展開或收起詳情",
                              .en:     "Tap to expand or collapse details"],

        // MARK: Detail dropdown
        "detail.instance":  [.zhHans: "实例",     .zhHant: "實例",     .en: "Instance"],
        "detail.todayUsage":[.zhHans: "今日消耗",  .zhHant: "今日消耗",  .en: "Usage"],
        "detail.messages":  [.zhHans: "消息数",    .zhHant: "消息數",    .en: "Msgs"],
        "detail.cacheRate": [.zhHans: "缓存率",    .zhHant: "緩存率",    .en: "Cache"],
        "detail.forecast":  [.zhHans: "未来趋势",  .zhHant: "未來趨勢",  .en: "Forecast"],
        "detail.loading":   [.zhHans: "正在读取数据…", .zhHant: "正在讀取資料…", .en: "Reading data…"],
        "detail.groupBySession": [.zhHans: "按会话", .zhHant: "按工作階段", .en: "By Session"],
        "detail.groupByModel":   [.zhHans: "按模型", .zhHant: "按模型",   .en: "By Model"],
        "detail.unknownModel":   [.zhHans: "未知",   .zhHant: "未知",    .en: "Unknown"],
        "detail.model":          [.zhHans: "模型",   .zhHant: "模型",    .en: "Model"],
        "detail.percent":        [.zhHans: "按百分比", .zhHant: "按百分比", .en: "By Percent"],
        "detail.share":          [.zhHans: "占比",   .zhHant: "佔比",    .en: "Share"],

        // MARK: Theme picker
        "themePicker.title": [.zhHans: "选择表盘", .zhHant: "選擇錶盤", .en: "Select Clock Face"],

        // MARK: Clock size
        "size.title":      [.zhHans: "📐 表盘大小", .zhHant: "📐 錶盤大小", .en: "📐 Clock Size"],
        "size.small":      [.zhHans: "小",   .zhHant: "小",   .en: "Small"],
        "size.medium":     [.zhHans: "中",   .zhHant: "中",   .en: "Medium"],
        "size.large":      [.zhHans: "大",   .zhHant: "大",   .en: "Large"],
        "size.extraLarge": [.zhHans: "特大", .zhHant: "特大", .en: "X-Large"],
        "size.hint":       [.zhHans: "首次启动按屏幕分辨率自动选择；手动选择后将不再自动调整。",
                            .zhHant: "首次啟動依螢幕解析度自動選擇；手動選擇後將不再自動調整。",
                            .en: "Auto-selected by screen resolution on first launch; a manual choice disables auto-adjustment."],

        // MARK: Settings
        "settings.title":           [.zhHans: "TokenClock 设置",          .zhHant: "TokenClock 設定",          .en: "TokenClock Settings"],
        "settings.done":            [.zhHans: "完成",                     .zhHant: "完成",                     .en: "Done"],
        "settings.autoDetect":      [.zhHans: "🔍 自动探测",              .zhHant: "🔍 自動探測",              .en: "🔍 Auto Detect"],
        "settings.redetect":        [.zhHans: "重新探测",                 .zhHant: "重新探測",                 .en: "Re-detect"],
        "settings.detectAllFound":  [.zhHans: "✅ 已探测到全部 %d 个数据源（%@）", .zhHant: "✅ 已探測到全部 %d 個數據源（%@）", .en: "✅ All %d data sources detected (%@)"],
        "settings.detectPartial":   [.zhHans: "⚠️ 已探测到 %d/%d 个数据源（%@）",  .zhHant: "⚠️ 已探測到 %d/%d 個數據源（%@）",  .en: "⚠️ Detected %d/%d data sources (%@)"],
        "settings.detectUpdated":   [.zhHans: "✅ %@ %@ 路径已更新（%@）",        .zhHant: "✅ %@ %@ 路徑已更新（%@）",        .en: "✅ %@ %@ path updated (%@)"],
        "settings.detectNotFound":  [.zhHans: "❌ %@ %@ 未找到有效数据目录",       .zhHant: "❌ %@ %@ 未找到有效數據目錄",       .en: "❌ %@ %@ valid data directory not found"],
        "settings.dataPaths":       [.zhHans: "📁 数据源路径",              .zhHant: "📁 數據源路徑",             .en: "📁 Data Source Paths"],
        "settings.defaultPath":     [.zhHans: "默认路径",                   .zhHant: "預設路徑",                 .en: "Default path"],
        "settings.search":          [.zhHans: "检索",                      .zhHant: "檢索",                     .en: "Detect"],
        "settings.browse":          [.zhHans: "浏览",                      .zhHant: "瀏覽",                     .en: "Browse"],
        "settings.hint.emptyPath":  [.zhHans: "留空则使用默认路径。修改路径后需重启应用生效。", .zhHant: "留空則使用預設路徑。修改路徑後需重啟應用生效。", .en: "Leave empty for default path. Restart app after changing."],
        "settings.hint.envVars":    [.zhHans: "支持环境变量覆盖：OPENCLAW_HOME、CLAUDE_CONFIG_DIR、GEMINI_CLI_HOME、CODEX_HOME、HERMES_HOME、OPENCODE_HOME、QWEN_HOME、QWEN_RUNTIME_DIR、COPILOT_HOME、GROK_HOME、AIDER_ANALYTICS_LOG、ANTIGRAVITY_HOME、CLINE_HOME、CONTINUE_HOME、CURSOR_AGENT_HOME", .zhHant: "支持環境變量覆蓋：OPENCLAW_HOME、CLAUDE_CONFIG_DIR、GEMINI_CLI_HOME、CODEX_HOME、HERMES_HOME、OPENCODE_HOME、QWEN_HOME、QWEN_RUNTIME_DIR、COPILOT_HOME、GROK_HOME、AIDER_ANALYTICS_LOG、ANTIGRAVITY_HOME、CLINE_HOME、CONTINUE_HOME、CURSOR_AGENT_HOME", .en: "Env vars: OPENCLAW_HOME, CLAUDE_CONFIG_DIR, GEMINI_CLI_HOME, CODEX_HOME, HERMES_HOME, OPENCODE_HOME, QWEN_HOME, QWEN_RUNTIME_DIR, COPILOT_HOME, GROK_HOME, AIDER_ANALYTICS_LOG, ANTIGRAVITY_HOME, CLINE_HOME, CONTINUE_HOME, CURSOR_AGENT_HOME"],
        "settings.browseOpenClaw":  [.zhHans: "选择 OpenClaw 目录",        .zhHant: "選擇 OpenClaw 目錄",       .en: "Select OpenClaw Directory"],
        "settings.browseClaudeCode":[.zhHans: "选择 Claude Code 目录",      .zhHant: "選擇 Claude Code 目錄",    .en: "Select Claude Code Directory"],
        "settings.browseGemini":    [.zhHans: "选择 Gemini CLI 目录",       .zhHant: "選擇 Gemini CLI 目錄",     .en: "Select Gemini CLI Directory"],
        "settings.browseCodex":     [.zhHans: "选择 Codex 目录",            .zhHant: "選擇 Codex 目錄",          .en: "Select Codex Directory"],
        "settings.browseHermes":    [.zhHans: "选择 Hermes 目录",           .zhHant: "選擇 Hermes 目錄",         .en: "Select Hermes Directory"],
        "settings.browseOpenCode":  [.zhHans: "选择 OpenCode 目录",         .zhHant: "選擇 OpenCode 目錄",       .en: "Select OpenCode Directory"],
        "settings.browseQwen":     [.zhHans: "选择 Qwen Code 目录",        .zhHant: "選擇 Qwen Code 目錄",     .en: "Select Qwen Code Directory"],
        "settings.browseCopilot":  [.zhHans: "选择 Copilot 目录",          .zhHant: "選擇 Copilot 目錄",        .en: "Select Copilot Directory"],
        "settings.browseGrok":     [.zhHans: "选择 Grok 目录",             .zhHant: "選擇 Grok 目錄",           .en: "Select Grok Directory"],
        "settings.browseAider":    [.zhHans: "选择 Aider 目录",            .zhHant: "選擇 Aider 目錄",          .en: "Select Aider Directory"],
        "settings.browseAntigravity": [.zhHans: "选择 Antigravity 目录",     .zhHant: "選擇 Antigravity 目錄",    .en: "Select Antigravity Directory"],
        "settings.browseCline":     [.zhHans: "选择 Cline 目录",            .zhHant: "選擇 Cline 目錄",           .en: "Select Cline Directory"],
        "settings.browseContinue":  [.zhHans: "选择 Continue 目录",         .zhHant: "選擇 Continue 目錄",        .en: "Select Continue Directory"],
        "settings.browseCursorAgent": [.zhHans: "选择 Cursor Agent 目录",   .zhHant: "選擇 Cursor Agent 目錄",   .en: "Select Cursor Agent Directory"],
        "settings.toolSelection":   [.zhHans: "🔧 工具选择",                 .zhHant: "🔧 工具選擇",               .en: "🔧 Tool Selection"],
        "settings.pathValid":       [.zhHans: "用户自定义路径有效",          .zhHant: "用戶自訂路徑有效",          .en: "Custom path is valid"],
        "settings.pathInvalid":     [.zhHans: "所选路径未找到有效日志文件",    .zhHant: "所選路徑未找到有效日誌文件",  .en: "No valid log files found in selected path"],

        // MARK: Rate threshold
        "rate.title":     [.zhHans: "🔥 热力图标阈值",   .zhHant: "🔥 熱力圖標閾值",   .en: "🔥 Heat Thresholds"],
        "rate.save":      [.zhHans: "保存",               .zhHant: "儲存",               .en: "Save"],
        "dataFetch.cursorCloud":     [.zhHans: "Cursor 用量从云端获取", .zhHant: "Cursor 用量從雲端獲取", .en: "Fetch Cursor usage from cloud"],
        "dataFetch.cursorCloudHint": [.zhHans: "会用 Cursor 登录凭证请求 cursor.com（默认开启；关闭后 Cursor 不显示用量）", .zhHant: "會用 Cursor 登入憑證請求 cursor.com（預設開啟；關閉後 Cursor 不顯示用量）", .en: "Sends Cursor credentials to cursor.com (on by default; Cursor shows no usage if off)"],
        "rate.period":    [.zhHans: "统计周期",           .zhHant: "統計週期",           .en: "Period"],
        "rate.10min":     [.zhHans: "10分钟",             .zhHant: "10分鐘",             .en: "10 min"],
        "rate.30min":     [.zhHans: "30分钟",             .zhHant: "30分鐘",             .en: "30 min"],
        "rate.1hour":     [.zhHans: "1小时",              .zhHant: "1小時",              .en: "1 hour"],
        "rate.burst":     [.zhHans: "爆发",               .zhHant: "爆發",               .en: "Burst"],
        "rate.hot":       [.zhHans: "火热",               .zhHant: "火熱",               .en: "Hot"],
        "rate.active":    [.zhHans: "活跃",               .zhHant: "活躍",               .en: "Active"],
        "rate.calm":      [.zhHans: "悠闲",               .zhHant: "悠閒",               .en: "Calm"],
        "rate.rest":      [.zhHans: "🛌 休息：低于悠闲阈值", .zhHant: "🛌 休息：低於悠閒閾值", .en: "🛌 Idle: below calm threshold"],
        "rate.adjusted":  [.zhHans: "阈值已自动调整为递减顺序", .zhHant: "閾值已自動調整為遞減順序", .en: "Thresholds auto-adjusted to descending order"],
        "rate.value":     [.zhHans: "数值",               .zhHant: "數值",               .en: "Value"],
        "rate.above":     [.zhHans: "以上",               .zhHant: "以上",               .en: "above"],

        // MARK: Custom theme
        "theme.title":        [.zhHans: "🎨 自定义表盘",     .zhHant: "🎨 自訂錶盤",       .en: "🎨 Custom Clock Face"],
        "theme.saved":        [.zhHans: "已保存的表盘",       .zhHant: "已儲存的錶盤",      .en: "Saved Clock Faces"],
        "theme.apply":        [.zhHans: "应用",              .zhHant: "套用",              .en: "Apply"],
        "theme.delete":       [.zhHans: "删除",              .zhHant: "刪除",              .en: "Delete"],
        "theme.new":          [.zhHans: "新建自定义表盘",     .zhHant: "新建自訂錶盤",      .en: "New Custom Face"],
        "theme.editing":      [.zhHans: "编辑中 — 表盘实时预览", .zhHant: "編輯中 — 錶盤即時預覽", .en: "Editing — Live Preview"],
        "theme.cancel":       [.zhHans: "取消",              .zhHant: "取消",              .en: "Cancel"],
        "theme.save":         [.zhHans: "保存",              .zhHant: "儲存",              .en: "Save"],
        "theme.nameHint":     [.zhHans: "输入表盘名称",       .zhHant: "輸入錶盤名稱",      .en: "Enter face name"],

        // MARK: Theme editor
        "editor.dialBg":        [.zhHans: "表盘底色",    .zhHant: "錶盤底色",    .en: "Dial Background"],
        "editor.dialBorder":    [.zhHans: "表盘边框",    .zhHant: "錶盤邊框",    .en: "Dial Border"],
        "editor.borderWidth":   [.zhHans: "边框宽度",    .zhHant: "邊框寬度",    .en: "Border Width"],
        "editor.handHour":      [.zhHans: "时针颜色",    .zhHant: "時針顏色",    .en: "Hour Hand"],
        "editor.handMinute":    [.zhHans: "分针颜色",    .zhHant: "分針顏色",    .en: "Minute Hand"],
        "editor.handSecond":    [.zhHans: "秒针颜色",    .zhHant: "秒針顏色",    .en: "Second Hand"],
        "editor.handWidthHour": [.zhHans: "时针宽度",    .zhHant: "時針寬度",    .en: "Hour Width"],
        "editor.handWidthMin":  [.zhHans: "分针宽度",    .zhHant: "分針寬度",    .en: "Minute Width"],
        "editor.handWidthSec":  [.zhHans: "秒针宽度",    .zhHant: "秒針寬度",    .en: "Second Width"],
        "editor.centerOuter":   [.zhHans: "中心外圈",    .zhHant: "中心外圈",    .en: "Center Outer"],
        "editor.centerInner":   [.zhHans: "中心内圈",    .zhHant: "中心內圈",    .en: "Center Inner"],
        "editor.showTicks":     [.zhHans: "显示刻度",    .zhHant: "顯示刻度",    .en: "Show Tick Marks"],
        "editor.showNumbers":   [.zhHans: "显示数字",    .zhHant: "顯示數字",    .en: "Show Numbers"],
        "editor.showDeco":      [.zhHans: "表盘装饰",    .zhHant: "錶盤裝飾",    .en: "Dial Decoration"],
        "editor.tickColor":     [.zhHans: "刻度颜色",    .zhHant: "刻度顏色",    .en: "Tick Color"],
        "editor.majorTickColor":[.zhHans: "主刻度颜色",   .zhHant: "主刻度顏色",   .en: "Major Tick Color"],
        "editor.numberColor":   [.zhHans: "数字颜色",    .zhHant: "數字顏色",    .en: "Number Color"],
        "editor.numArabic":     [.zhHans: "阿拉伯数字",   .zhHant: "阿拉伯數字",   .en: "Arabic"],
        "editor.numChinese":    [.zhHans: "中文数字",     .zhHant: "中文數字",     .en: "Chinese"],
        "editor.fontDefault":   [.zhHans: "默认",        .zhHant: "預設",         .en: "Default"],
        "editor.fontRounded":   [.zhHans: "圆体",        .zhHant: "圓體",         .en: "Rounded"],
        "editor.fontSerif":     [.zhHans: "衬线",        .zhHant: "襯線",         .en: "Serif"],
        "editor.fontMono":      [.zhHans: "等宽",        .zhHant: "等寬",         .en: "Monospaced"],
        "editor.dropBg":        [.zhHans: "面板背景",    .zhHant: "面板背景",     .en: "Panel Background"],
        "editor.dropText":      [.zhHans: "面板文字",    .zhHant: "面板文字",     .en: "Panel Text"],
        "editor.dropSubtext":   [.zhHans: "面板副文字",  .zhHant: "面板副文字",   .en: "Panel Subtext"],
        "editor.dropBorder":    [.zhHans: "面板边框",    .zhHant: "面板邊框",     .en: "Panel Border"],
        "editor.dropDivider":   [.zhHans: "面板分割线",  .zhHant: "面板分割線",   .en: "Panel Divider"],
        "editor.overlayPrimary":  [.zhHans: "主文字颜色", .zhHant: "主文字顏色",  .en: "Primary Text"],
        "editor.overlaySecondary":[.zhHans: "副文字颜色", .zhHant: "副文字顏色",  .en: "Secondary Text"],

        // MARK: Hand style
        "handStyle.round":   [.zhHans: "圆形",  .zhHant: "圓形",  .en: "Round"],
        "handStyle.tapered": [.zhHans: "锥形",  .zhHant: "錐形",  .en: "Tapered"],
        "handStyle.lance":   [.zhHans: "枪尖",  .zhHant: "槍尖",  .en: "Lance"],
        "handStyle.sword":   [.zhHans: "剑形",  .zhHant: "劍形",  .en: "Sword"],

        // MARK: Clock face themes
        "themeName.classic":    [.zhHans: "经典",   .zhHant: "經典",   .en: "Classic"],
        "themeName.midnight":   [.zhHans: "深夜",   .zhHant: "深夜",   .en: "Midnight"],
        "themeName.luxe":       [.zhHans: "暗金",   .zhHant: "暗金",   .en: "Luxe"],
        "themeName.gufeng":     [.zhHans: "古风",   .zhHant: "古風",   .en: "Antique"],
        "themeName.railgun":    [.zhHans: "超電磁砲", .zhHant: "超電磁砲", .en: "Railgun"],
        "themeName.sky":        [.zhHans: "天空",   .zhHant: "天空",   .en: "Sky"],
        "themeName.glass":      [.zhHans: "玻璃",   .zhHant: "玻璃",   .en: "Glass"],
        "themeName.glacier":    [.zhHans: "冰川",   .zhHant: "冰川",   .en: "Glacier"],
        "themeName.custom":     [.zhHans: "自定义", .zhHant: "自訂",   .en: "Custom"],

        "themeDesc.classic":    [.zhHans: "浅灰表盘 · 红色层次指针", .zhHant: "淺灰錶盤 · 紅色層次指針", .en: "Light gray dial · Red layered hands"],
        "themeDesc.midnight":   [.zhHans: "深蓝表盘 · 青色锥形指针", .zhHant: "深藍錶盤 · 青色錐形指針", .en: "Deep blue dial · Cyan tapered hands"],
        "themeDesc.luxe":       [.zhHans: "暗色表盘 · 金色菱形指针", .zhHant: "暗色錶盤 · 金色菱形指針", .en: "Dark dial · Gold diamond hands"],
        "themeDesc.gufeng":     [.zhHans: "宣纸底色 · 墨色剑形指针", .zhHant: "宣紙底色 · 墨色劍形指針", .en: "Rice paper dial · Ink sword hands"],
        "themeDesc.railgun":    [.zhHans: "米白表盘 · 电弧蓝秒针",   .zhHant: "米白錶盤 · 電弧藍秒針",   .en: "Off-white dial · Arc blue second hand"],
        "themeDesc.sky":        [.zhHans: "蓝天白云 · 阳光金色指针", .zhHant: "藍天白雲 · 陽光金色指針", .en: "Blue sky · Sunlit gold hands"],
        "themeDesc.glass":      [.zhHans: "玻璃质感底 · 琥珀秒针",     .zhHant: "玻璃質感底 · 琥珀秒針",     .en: "Glass-textured backdrop · Amber second hand"],
        "themeDesc.glacier":    [.zhHans: "清澈透亮的液态玻璃 · 冰青 tint", .zhHant: "清澈透亮的液態玻璃 · 冰青 tint", .en: "Crystal-clear liquid glass · icy cyan"],
        "themeDesc.custom":     [.zhHans: "用户自定义配色与样式",     .zhHant: "用戶自訂配色與樣式",     .en: "User-defined colors and style"],

        // MARK: Path detector
        "pathSource.userDefaults":  [.zhHans: "用户自定义",   .zhHant: "用戶自訂",    .en: "User Custom"],
        "pathSource.envVar":        [.zhHans: "环境变量",     .zhHant: "環境變數",    .en: "Env Variable"],
        "pathSource.official":      [.zhHans: "官方默认",     .zhHant: "官方預設",    .en: "Official Default"],
        "pathSource.alternate":     [.zhHans: "备选路径",     .zhHant: "備選路徑",    .en: "Alternate Path"],
        "pathSource.notFound":      [.zhHans: "未找到",       .zhHant: "未找到",      .en: "Not Found"],
        "pathDetail.userCustom":    [.zhHans: "使用用户自定义路径",     .zhHant: "使用用戶自訂路徑",         .en: "Using custom path"],
        "pathDetail.envDetected":   [.zhHans: "从环境变量探测到",       .zhHant: "從環境變數探測到",         .en: "Detected from env variable"],
        "pathDetail.official":      [.zhHans: "使用官方默认路径",       .zhHant: "使用官方預設路徑",         .en: "Using official default path"],
        "pathDetail.alternate":     [.zhHans: "从备选路径探测到",       .zhHant: "從備選路徑探測到",         .en: "Detected from alternate path"],
        "pathDetail.notFound":      [.zhHans: "未找到",                 .zhHant: "未找到",                   .en: "Not found"],
        "pathDetail.notFoundDefault":[.zhHans: "未找到有效日志文件，将使用默认路径", .zhHant: "未找到有效日誌文件，將使用預設路徑", .en: "No valid log files found, using default path"],
    ]
}

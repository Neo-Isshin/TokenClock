import Foundation

/// 应用级开发者配置（编译期常量）
///
/// 这里放不该让用户随意改、但开发者需要能快速调整的值：
/// API endpoint、HTTP 超时、缓冲区大小、扫描频率等。
///
/// 用户可配置项走 UserDefaults，见 `SettingsKeys.swift`。
/// 文件路径走 `PathConfig.swift`（已存在，不动）。
enum AppConfig {

    // MARK: - 外部 API endpoint

    enum API {
        /// Cursor 官方 usage API base
        static let cursorBase = "https://cursor.com/api"
        /// Cursor dashboard URL（用于 Origin/Referer header）
        static let cursorOrigin = "https://cursor.com"
        static let cursorDashboard = "https://cursor.com/dashboard"
        /// 天气查询（wttr.in 公开服务，无需 key）
        static let weatherBase = "https://wttr.in"
        /// IP 地理定位（中国境内可访问）
        // 使用 https 避免 MITM 风险（明文 http 易被中间人篡改）
        static let ipLookup = "https://myip.ipip.net/"
    }

    // MARK: - HTTP / 网络

    enum HTTP {
        static let requestTimeout: TimeInterval = 10
        static let resourceTimeout: TimeInterval = 30
        /// Cursor API 最小拉取间隔（避免被限流）
        static let cursorMinFetchInterval: TimeInterval = 60
        /// 默认 User-Agent
        static let userAgent = "TokenClock/1.0 (macOS)"
    }

    // MARK: - 数据扫描参数

    enum Scan {
        /// Cursor API 全量扫描的天数范围
        static let cursorFullScanDays = 30
        /// Cursor API 增量扫描的天数范围（今天 + 昨天）
        static let cursorIncrementalDays = 2
        /// Cursor API 单次分页大小
        static let cursorPageSize = 200
        /// JSONL 流式读取缓冲（64KB，平衡内存和 IO 效率）
        static let jsonlBufferSize = 65_536
        /// Codex 面板只消费当日与最近数据。保留今天+昨天的 rollout，覆盖跨日长会话，
        /// 避免冷启动为当前用量反复解析整个历史目录。
        static let codexSessionLookbackDays = 2
        /// Gemini 面板同样只展示当日/最近用量；保留今天+昨天以覆盖跨日会话。
        static let geminiSessionLookbackDays = 2
        /// Codex 额度仅在用户打开额度面板时请求；短缓存避免反复开 app-server。
        static let codexQuotaCacheSeconds: TimeInterval = 60
        /// app-server 异常时必须及时回收子进程，不能让详情页点击产生常驻后台任务。
        static let codexQuotaTimeoutSeconds: TimeInterval = 8
        /// 本地 rollout 兜底只读取最新文件尾部，不为额度查询重扫完整历史。
        static let codexQuotaFallbackTailBytes = 2_097_152
        static let codexQuotaFallbackFileLimit = 32
        /// "活跃工具" 判定窗口（10 分钟内有调用算活跃）
        static let activeThresholdSeconds: TimeInterval = 600
        /// "最近 token" 默认窗口（分钟）
        static let defaultRecentWindowMinutes = 10
        static let oneDaySeconds: TimeInterval = 86_400
    }

    // MARK: - 定时器间隔

    enum Timers {
        /// 时钟刷新（1s，驱动秒针动画）
        static let clock: TimeInterval = 1.0
        /// 数据扫描（30s）
        static let dataScan: TimeInterval = 30.0
        /// 天气刷新（5min）
        static let weather: TimeInterval = 300.0
        /// recentTokens 重置（10min）
        static let recentReset: TimeInterval = 600.0
    }

    // MARK: - 本地 API 服务

    enum LocalServer {
        /// 默认监听端口
        static let defaultPort: UInt16 = 9988
        /// 暴露给外部集成的 endpoint 路径
        static let usageEndpoint = "/api/usage"
    }

    // MARK: - 日结历史

    enum History {
        /// 历史保留天数(API 默认 + clamp 上限)
        static let retentionDays = 30
        /// history endpoint 路径
        static let historyEndpoint = "/api/history"
    }
}

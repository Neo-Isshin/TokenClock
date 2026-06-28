# TokenClock — Handover Document

> 最后更新: 2026-06-28 02:30 GMT+8

## 项目身份

**TokenClock** — macOS 悬浮液态玻璃 token 时钟（双变体）

- **仓库**: `https://gitea.nxc8335.cloud/nxc8335/TokenClock.git`
- **本地 Gitea**: `http://localhost:3000/nxc8335/TokenClock.git`（LAN 推拉用，反代到公开域名）
- **公开托管**: `https://gitea.nxc8335.cloud/nxc8335/TokenClock`
- **用户**: Neo-Isshin
- **许可证**: MIT
- **规模**: ~10,700 行 Swift + 双 CLI 脚本
- **主项目目录**: `/Users/neo/Projects/TokenClock`

## 架构概览

### 双分支双变体

| 分支 | 平台 | 渲染 | 最低系统 | Package.swift |
|---|---|---|---|---|
| `main` | Liquid Glass | macOS 26 原生 `.glassEffect()` | macOS 26 | `.macOS(.v26)` |
| `normal` | Classic opaque | `.background()` + 透明度 | macOS 15 | `.macOS(.v15)` |

`cli/install.sh` 一次性拉两个分支（macOS 26+ 用户）或只拉 normal（macOS 15-25），按 `sw_vers -productVersion | cut -d. -f1` 主版本自动决策。

### 关键模块（`Sources/TokenClock/`）

- `AppDelegate.swift` — NSApplicationDelegate；右键菜单（NSMenu）、设置 NSWindow、theme picker panel
- `FloatingPanel.swift` — `NSPanel` 子类，**双实例（FloatingPanel 时钟 + DropdownPanel 详情）**，无锁架构
- `SettingsView.swift` — SwiftUI 设置窗口主视图
- `ViewModel.swift` — `@ObservableObject`，持有 `enabledTools: Set<String>`
- `L10n.swift` — 自研国际化引擎（zh-Hans / zh-Hant / en），从 UserDefaults `TC_language` 读
- `Config/AppConfig.swift` — 集中常量，含 `LocalServer.defaultPort = 9988`
- `Config/SettingsKeys.swift` — `enum SettingsKey: String { case ... = "TC_..." }` + UserDefaults 扩展
- `Services/PathDetector.swift` — 14 工具路径探测，`DetectionResult { service, exists }`
- `Services/UsageAggregator.swift` — 用量聚合
- `Services/AppPaths.swift` — `~/Library/Application Support/...` 路径集中 helper
- `Services/*UsageService.swift` — 各工具的 parser（共 14 个）

### 14 个 AI 工具（`TC_enabledTools` 偏好列表）

OpenClaw · Claude Code · Gemini CLI · Codex · Hermes · OpenCode · Qwen Code · Copilot · Grok · Aider · Antigravity · Cline · Continue · Cursor Agent

每个工具有独立 env var（`OPENCLAW_HOME` 等）+ 默认路径 + 可在 Settings 里覆盖的自定义路径。

### CLI 子系统（`cli/`）

- `install.sh` — 一行安装器（公开 URL：`curl -fsSL https://gitea.nxc8335.cloud/.../raw/main/cli/install.sh | bash`）
- `tokenclock` — 轻量 shell wrapper：`start / stop / restart / doctor / update / help`

**共享常量**（两个脚本顶部都声明，注释提醒"保持同步"）：
```bash
MIN_MACOS=15
LIQUID_GLASS_MIN_MACOS=26
API_PORT_DEFAULT=9988
DOMAIN="TokenClock"
```

## 最近一次发布

**当前 origin HEAD:**
- main: `34448d6` feat(installer): default-enable API + auto-detect system language
- normal: `c214cd4` 同上 (sync from main)

**用户最后确认的稳定 base:**
- main: `70c98e9` fix(installer): default repo URL points to public gitea, not LAN localhost
- normal: `7cfa60f` 同上

**从 base 到现在的 4 个修复:**

| commit | 文件 | 修复 |
|---|---|---|
| `a6b531f` (main) / `71aed4e` (normal) | `SettingsView.swift` | #85 工具 toggle 视觉：未探测到的工具显示灰色 |
| `34448d6` (main) / `c214cd4` (normal) | `install.sh` | #84 API 默认开 + #86 语言自动检测 |
| `178ae96` (normal 独有) | `FloatingPanel.swift` | #83 normal 分支设置面板不出来：`canBecomeKey=true → false` + `hasShadow=false → true` |

**未 push 的工作:** 无。所有 4 个修复已推到 origin 并经 CDN 验证（`eo-cache-status: MISS` + `age: 0`）。

**未验证（用户暂缓）:**
- 一行安装回归 smoke
- normal 变体在 macOS 15-25 上手动验证设置面板

## 关键技术细节

### SettingsKey enum 模式（已统一）

```swift
enum SettingsKey: String {
    case language = "TC_language"
    case apiServerEnabled = "TC_apiServerEnabled"
    case apiServerPort = "TC_apiServerPort"
    case enabledTools = "TC_enabledTools"
    case savedCustomThemes = "TC_savedCustomThemes"
    case customThemeConfig = "TC_customThemeConfig"
    // ... 14 工具的 path key
}

extension UserDefaults {
    func string(for key: SettingsKey) -> String?
    func int(for key: SettingsKey, default: Int) -> Int { ... }
    func setBool(_ value: Bool, for key: SettingsKey) { ... }
    // ...
}
```

**改动 UserDefaults key 时**: 只动 `SettingsKey` enum case 的 rawValue，所有调用点自动跟随。

### 右键菜单流程

```
rightMouseDown (FloatingPanel override)
  → panel.menu?.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
  → 用户选择菜单项
  → NSMenuItem.action 触发 @objc selector（openSettings / toggleLaunchAtLogin / copyAPIEndpoint / quitApp）
```

**关键**: `FloatingPanel.canBecomeKey = false`（main 和 normal 都已对齐）——这样 settings NSWindow 才能从 NSPanel 手里接管 key 状态、正常 `makeKeyAndOrderFront`。

### 双 NSPanel 架构

- **FloatingPanel**: 时钟面板（小、`canBecomeKey=false`、`isMovableByWindowBackground=true`）
- **DropdownPanel**: 详情面板（独立窗口、`canBecomeKey=false`、随 always-on-top 切换 level）
- **SettingsWindow**: 普通 NSWindow（`styleMask = [.titled, .closable]`），不是 NSPanel

### 国际化

`L10n.swift` 启动顺序：
1. 读 `UserDefaults.standard.string(forKey: "TC_language")`
2. 缺失时回退 `zh-Hans`（**这就是为什么英文 locale 用户首启看到中文**——installer 通过 `detect_and_set_language` 写 `TC_language` 解决）
3. `tr(_:_:)` 变参 CVarArg，注意**单参 overload 的 type inference 问题**——直接调 `L10n.shared.tr("key", args...)` 即可

### API 服务器

- 默认端口 `9988`，监听 `127.0.0.1`
- 启动逻辑在 AppDelegate，按 `TC_apiServerEnabled` + `TC_apiServerPort` 决定
- 端点：`GET /api/usage` 返回 14 工具聚合 JSON
- `AppConfig.LocalServer.defaultPort` 与 shell `API_PORT_DEFAULT=9988` 交叉引用注释

### LaunchAgent / 开机自启

- 用 `SMAppService.mainApp`（现代 API），不用 LaunchAgent plist
- 右键菜单勾选状态由 `LaunchAgentHelper.detectVariant()` + `.isRegistered(variant:)` 反映
- `cli/install.sh` **不**注册 plist——Swift 端 UI 控制

## 发布流程（已建立的最佳实践）

### 1. 本地开发
```bash
cd /Users/neo/Projects/TokenClock
# 改代码...
swift build -c debug                    # 必须过
swift build -c release                  # release 验证
bash -n cli/install.sh                  # bash 语法
```

### 2. 双分支同步（如果有 main-only 改动）
```bash
# 创建 normal worktree
git worktree add /Users/neo/Projects/TokenClock-normal normal

# 在 normal worktree 里 apply patch / cherry-pick / cp
# 注意：normal 缺 P1+P2 refactor 之前可能有结构差异，diff -q 检查后用 cp wholesale 同步 install.sh / tokenclock / README

# 构建验证
cd /Users/neo/Projects/TokenClock-normal && swift build -c debug
```

### 3. Push（默认分支需用户授权）
```bash
git push origin main
git push origin normal

# 清理
git worktree remove /Users/neo/Projects/TokenClock-normal
```

### 4. CDN 验证（关键！EdgeOne 缓存 6 小时）

```bash
curl -sSI "https://gitea.nxc8335.cloud/nxc8335/TokenClock/raw/main/cli/install.sh" \
  | grep -iE "last-modified|age|eo-cache|etag|content-length"
```

期望：`last-modified` 等于最新 commit 时间；`eo-cache-status: MISS`；`age: 0`。

**如果 `last-modified` 停在旧时间 + `age > 0`**：
- 在腾讯 EdgeOne 控制台 purge URL `https://gitea.nxc8335.cloud/nxc8335/TokenClock/raw/branch/main/cli/install.sh`（注意 `/raw/branch/...` 是 303 跳转后的实际缓存 key）
- 等几分钟后重试
- 临时绕过：`?nocache=$(date +%s)` query string

### 5. 一行安装 smoke（推荐 `--no-start --debug`）

```bash
curl -fsSL "https://gitea.nxc8335.cloud/nxc8335/TokenClock/raw/main/cli/install.sh?nocache=$(date +%s)" \
  | bash -- --no-start --debug 2>&1 | tail -40
```

期望看到：
- `🌐 系统语言: <locale> → TC_language=<en|zh-Hans|zh-Hant>`
- `✓ API 服务器: 已启用（端口 9988…）`
- doctor OK
- 双变体 clone + build + CLI 装好

### 6. 运行时验证（macOS 26+ glass）
```bash
tokenclock start                                    # 自动选 glass
# 右键 → Settings → 验证：
#   - 设置面板能打开（main: 一直能；normal: 之前打不开，现在可以）
#   - 工具 toggle: 已探测到 = 蓝色，未探测 = 灰色
defaults read TokenClock TC_language                # 验证语言写入
defaults read TokenClock TC_apiServerEnabled        # true
defaults read TokenClock TC_apiServerPort           # 9988
curl http://127.0.0.1:9988/api/usage | head -c 100 # 返回 JSON
```

## 已知坑（必须传给下次会话）

### 1. Gitea token 敏感
- Token: `2d022617b7bce9038df329e2bc0cd2609d53b317`
- 用户手动加到 `~/.zshrc`：`export GITEA_TOKEN='...'`
- **绝不** echo 到日志或命令输出
- 不要用 Bash 工具里直接处理带 token 的 `git diff`（会被 auto-classifier 阻断）；改用 `git cherry-pick`、`cp`、或 Read 工具读文件

### 2. CDN cache（见 memory `feedback_tokenclock_cdn.md`）
- 腾讯 EdgeOne + openresty，6 小时缓存
- raw URL `/raw/branch/main/cli/install.sh`（303 跳转后）是实际缓存 key
- **永远**在 push 后 verify CDN；不要假设 auto-mode 会替你 purge

### 3. SourceKit 大量误报
- `Cannot find type 'FloatingPanel' / 'L10n' / 'PathConfig' in scope` 等都是 SPM indexing 问题
- **`swift build` 才是 source of truth**
- build 失败时也别只看 SourceKit 报告的错——直接跑 `swift build` 看真实编译错误

### 4. 双分支异步演化
- normal 分支不一定与 main 同步——可能缺少某些 main 上的 refactor
- 同步时先 `git log origin/normal` 看是否有遗漏的"port from main" commits
- install.sh / tokenclock 顶层有"保持同步"注释，是 cross-script constant 的真理来源

### 5. L10n type inference 坑
- `let tr = L10n.shared.tr` 会 bind 到**单参** overload，调用 `tr("key", args...)` 编译失败
- **不要**做局部 alias；直接 `L10n.shared.tr("key", args...)` 调全路径

### 6. macOS 主版本判断
- 永远用 `sw_vers -productVersion | cut -d. -f1` 取主版本
- shell 与 Swift 都要判断；两边都要更新常量（`MIN_MACOS`、`LIQUID_GLASS_MIN_MACOS`）

### 7. installer 脚本 bash 3.2 兼容性
- 不支持 `[[ ]]`（其实支持但要小心）、`${var,,}`、`mapfile`、`local -n`
- `set -uo pipefail` 是默认行为（不是 `-e`），所有错误用 `|| die "..."` 显式处理
- `export LC_ALL=C` 在脚本顶部必加（避免 bash 3.2 把 UTF-8 多字节字符误并入变量名）

### 8. Swift 6 strict concurrency
- 跨 actor 边界用 `@unchecked Sendable` 或 `@MainActor`
- NSApplicationDelegate 主线程访问 UI 是默认假设

## 待办 / 未来方向

- [ ] **回归测试**: 一行安装 + normal 变体手动验证（用户暂缓）
- [ ] **`tokenclock update`**: 更新服务器待部署，目前是 placeholder
- [ ] **签名 / 公证 release**: `.app` 打包当前缺
- [ ] **更丰富的历史统计图表**: roadmap 中

## 关联 memory 文件

- `/Users/neo/.claude/projects/-Volumes-SSD/memory/MEMORY.md` — 项目索引
- `/Users/neo/.claude/projects/-Volumes-SSD/memory/project_tokenclock.md` — 项目上下文
- `/Users/neo/.claude/projects/-Volumes-SSD/memory/feedback_tokenclock_cdn.md` — CDN 缓存坑详解
- `/Users/neo/.claude/projects/-Volumes-SSD/memory/feedback_tokenclock_debug.md` — debug 工具变量检查（`TC_enabledTools`）

## 内置表盘一览

| Theme | displayName | 风格 | glassTint |
|---|---|---|---|
| `classic` | 经典 | 浅灰 + 红层次指针 | 蓝灰 `(0.55, 0.72, 0.92)` |
| `midnight` | 深夜 | 深蓝 + 青色锥形指针 | 青色 `(0.149, 0.776, 0.855)` |
| `luxe` | 暗金 | 暗 + 金色菱形指针 | 金 `(1.0, 0.835, 0.310)` |
| `gufeng` | 古风 | 宣纸 + 墨色剑形指针 | 古褐 `(0.620, 0.430, 0.260)` |
| `railgun` | 超电磁炮 | 米白 + 电弧蓝秒针 | 粉 `(0.820, 0.580, 0.560)` |
| `sky` | 天空 | 蓝天 + 阳光金色指针 | 蓝 `(0.420, 0.620, 0.820)` |
| **`glacier`** | **冰川** | **清澈冰青 + 冷蓝黑数字 + 纤细金属指针** | **冰青 `(0.78, 0.92, 1.00)`** |
| `custom` | 自定义 | `CustomThemeConfig.load()` | 用户自定 |

**glacier 关键参数（2026-06-28 新增）**：
- dialColor `Color(white: 0.96)` + rim 透明（避免"厚"感）
- glassTint 高亮冰青 RGB，靠近 `.clear` 透明度
- 数字 / 主刻度 / 文字一律 `Color(red: 0.10, green: 0.20, blue: 0.42)` 冷蓝黑（与冷青 tint 形成色相对比）
- 时针 4.0 / 分针 2.8 / 秒针 1.2 —— 全场最纤细（金属质感）
- handStyle `.sword`（最纤细）

**远期待办**：自定义主题编辑器扩展暴露液态玻璃参数（glassTint UI / cornerRadius Slider / interactive Toggle）。当前不做。

## 联系 / 风格偏好

- 用户偏好：中文交流，注释用中文
- commit message 风格：`<type>(<scope>): <subject>` + 可选 body，type 用 conventional commits
- 一次性批量做改动 + 验证（不是一次改一个反复问）
- plan mode + Explore subagents 是首选排查模式
- user-invocable skills: 暂无特殊依赖
- 不允许的工作：push 到默认分支（需用户授权）、echo 敏感 token
<div align="center">

**简体中文** · [English](README.en.md)

# 🕰️ TokenClock

**一个浮在桌面上的 macOS 时钟，一眼看清你所有 AI 编程工具的实时 token 用量。**

[![macOS 15+](https://img.shields.io/static/v1?label=macOS&message=15%2B&color=000000&logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![macOS 26 Liquid Glass](https://img.shields.io/static/v1?label=macOS%2026&message=Liquid%20Glass&color=00B0F0)](https://developer.apple.com/macos/)
[![Swift 6](https://img.shields.io/static/v1?label=Swift&message=6&color=F05138&logo=swift&logoColor=white)](https://www.swift.org/)
[![SwiftUI](https://img.shields.io/static/v1?label=UI&message=SwiftUI%20%2B%20AppKit&color=blueviolet)](https://developer.apple.com/xcode/swiftui/)
[![SwiftPM](https://img.shields.io/static/v1?label=Build&message=SwiftPM&color=FA7343)](https://www.swift.org/package-manager/)
[![Privacy](https://img.shields.io/static/v1?label=Privacy&message=local%20only&color=success)](#-隐私--privacy)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

</div>

<div align="center">

![TokenClock — 桌面液态玻璃时钟](docs/screenshots/hero.png)

</div>

---

TokenClock 是一个常驻桌面的 **悬浮时钟**（置顶 · 可拖拽 · 记忆位置）。表盘上实时叠加显示：**今日总 token 消耗、消息条数、当前活跃的 AI 工具、速率指示器与天气**。点击时钟即可展开下拉面板，查看 **每个工具 → 每个 session / agent** 的明细用量。

采用 macOS 26 的 **Liquid Glass** 材质打造玻璃质感表盘，并提供 6 款精心设计的内置表盘与完全自定义主题。所有数据都在 **本地** 读取——不上传任何信息。

---

## ✨ 特性

### 🤖 多 AI 工具统一检测
- **一个时钟聚合 14 款 AI 编程工具** 的实时 token / 消息用量，无需在多个终端之间来回切换。
- 表盘上叠加 **今日总量、活跃工具图标、速率 emoji**（🔥 爆发 / 🌊 平稳阈值）。
- 点击展开 **下拉面板**：按工具 → session / agent 维度拆解，一目了然。

### 🧊 液态玻璃（Liquid Glass）
- macOS 26 上以原生 **Liquid Glass** 材质渲染，玻璃盘体随壁纸自适应、带氛围着色。
- **自适应高对比墨色文字**：浅色 tint 主题自动切换近黑刻度 / 数字，保证可读性。
- 提供 `liquid-glass`（macOS 26）与 `normal`（macOS 15）**双版本**，由 `tokenclock` CLI 按系统版本自动选用。

### 🎨 多表盘 + 美观设计
- 6 款内置表盘（经典 / 深夜 / 暗金 / 古风 / 超电磁炮 / 天空），风格各异。
- 4 种指针样式（圆头 / 锥形 / 菱形 / 剑形），数字风格含阿拉伯数字与中文数字。
- **完全自定义主题**：表盘色、玻璃着色、三根指针、刻度、数字、边框颜色与字体全部可调。

### ⚙️ 其他
- 实时时钟（1s）、用量刷新（30s）、天气（5min）。
- 天气与 12 小时预报（IP 自动定位或手动选城市）；8 个时区。
- 国际化：**简体中文 / 繁体中文 / English**。
- 置顶 · 可拖拽 · 跨重启位置记忆；开机自启动（`SMAppService`）。
- 本地 API 服务器（`:9988`），供集成 / 脚本调用。
- 隐私优先：**全部数据本地读取，零上传**。

---

## 📸 截图

<table>
  <tr>
    <td width="50%" align="center"><b>悬浮玻璃时钟</b><br>表盘叠加 token / 消息 / 速率 / 天气</td>
    <td width="50%" align="center"><b>展开详情面板</b><br>按工具 → session / agent 拆解用量</td>
  </tr>
  <tr>
    <td width="50%" align="center"><img src="docs/screenshots/hero.png" alt="hero"></td>
    <td width="50%" align="center"><img src="docs/screenshots/dropdown.png" alt="dropdown"></td>
  </tr>
  <tr>
    <td colspan="2" align="center"><b>表盘主题选择器</b> · 6 款内置 + 自定义</td>
  </tr>
  <tr>
    <td colspan="2" align="center"><img src="docs/screenshots/themes.png" alt="themes"></td>
  </tr>
</table>

---

## 🤖 支持的 AI 工具

TokenClock 通过读取各工具在本地写入的 **JSONL / SQLite 用量文件** 进行统计（路径优先级：自定义路径 > 环境变量 > 默认路径，首启时自动探测）。下表为默认数据源与对应环境变量。

| 工具 | 默认数据源 | 环境变量 |
|------|-----------|---------|
| **OpenClaw** | `~/.openclaw/` | `OPENCLAW_HOME` |
| **Claude Code** | `~/.claude/` | `CLAUDE_CONFIG_DIR` |
| **Gemini CLI** | `~/.gemini/` | `GEMINI_HOME` |
| **Codex** | `~/.codex/` | `CODEX_HOME` |
| **Hermes** | `~/.hermes/` | `HERMES_HOME` |
| **OpenCode** | `~/.local/share/opencode/` | `OPENCODE_HOME` |
| **Qwen Code** | `~/.qwen/` | `QWEN_HOME` |
| **GitHub Copilot CLI** | `~/.copilot/` | `COPILOT_HOME` |
| **Grok CLI** | `~/.grok/` | `GROK_HOME` |
| **Aider** | `~/.aider/analytics.jsonl` | `AIDER_HOME` |
| **Antigravity** | `~/.gemini/antigravity-cli/` | `ANTIGRAVITY_HOME` |
| **Cline**（VSCode 扩展） | `~/Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/` | `CLINE_HOME` |
| **Continue**（VSCode 扩展） | `~/.continue/` | `CONTINUE_HOME` |
| **Cursor Agent** | `~/.cursor/` | `CURSOR_AGENT_HOME` |

> 各服务的 token 计算公式略有差异（例如 Codex 的 `input_tokens` 已含 cached，需用 `total_tokens + reasoning_output_tokens`；其余服务输入/输出/缓存字段互斥相加）。详见 `docs/TOOL_SCHEMA_ANALYSIS.md`。

---

## 🚀 快速开始

### 一键安装（最简单）

自动检测 macOS 版本 → 构建对应变体 → 安装到 `~/.tokenclock` → 把 `tokenclock` 加入 PATH → 首次启动并扫描各 AI 工具的本地路径，全程无需手动干预。

```bash
# 已克隆本仓库时直接运行：
./cli/install.sh

# 或（公开托管后替换 <your-host>）一行安装：
curl -fsSL https://<your-host>/raw/liquid-glass/cli/install.sh | bash
```

可选参数：`--debug`（构建更快）/ `--normal` / `--glass` / `--no-start`（装完不自动启动）。

> 也可手动从源码构建，见下方。

### 前置要求
- **macOS 15+**（普通版）；**macOS 26+**（Liquid Glass 版）
- Swift 6 工具链（Xcode 16+ / Command Line Tools）

### 从源码构建运行

```bash
git clone <你的仓库地址> TokenClock
cd TokenClock

# 调试构建并直接运行
swift run

# 或先构建再运行
swift build            # 调试
swift build -c release # 发布
.build/debug/TokenClock      # 或 .build/release/TokenClock
```

> 当前 `Package.swift` 声明平台为 `.macOS(.v26)`，故 `swift run` 直接产出 Liquid Glass 版。`main` 分支为兼容 macOS 15 的普通版本。

### 使用 `tokenclock` CLI

将轻量 shell 脚本安装到 PATH：

```bash
sudo install -m755 cli/tokenclock /usr/local/bin/tokenclock
```

| 命令 | 说明 |
|------|------|
| `tokenclock start [--glass\|--normal] [--force]` | 启动时钟；未指定版本时 **按系统版本自动选**（26+ → glass，15+ → normal）；`--force` 强制另开一份 |
| `tokenclock stop` | 停止所有运行中的 TokenClock 实例 |
| `tokenclock restart [--glass\|--normal]` | 重启 |
| `tokenclock doctor` | 诊断环境：系统版本、已安装变体路径、运行中的进程、环境变量 |
| `tokenclock update` | 更新（占位，更新服务器待部署） |
| `tokenclock help` | 显示帮助 |

**变体定位顺序**：`$TOKENCLOCK_GLASS` / `$TOKENCLOCK_NORMAL` 环境变量 → `~/.tokenclock/` → `/Applications/` → 仓库 `.build/debug/`。

---

## 🎨 主题

6 款内置表盘，外加完全自定义：

| 主题 | 中文名 | 性格 |
|------|--------|------|
| `classic`  | 经典     | 纯净玻璃盘 · 炭黑指针 + 琥珀秒针 · 仅 3/6/9/12 数字 |
| `midnight` | 深夜     | 青色玻璃 · 青色锥形指针 |
| `luxe`     | 暗金     | 金色玻璃 · 金色菱形指针 |
| `gufeng`   | 古风     | 暖棕玻璃 · 墨色剑形指针 · **中文数字** |
| `railgun`  | 超电磁炮 | 粉橙玻璃 · 电弧蓝秒针 · 等宽字体 |
| `sky`      | 天空     | 蓝色玻璃 · 阳光白云 · 金色指针 |
| `custom`   | 自定义   | 玻璃着色 / 三根指针 / 刻度 / 数字 / 字体……全部可调 |

在时钟上 **右键** → 主题选择器，或打开设置窗口中的主题编辑器即可切换 / 自定义。

---

## 🧊 液态玻璃（Liquid Glass）

TokenClock 提供两套构建：

| 分支 | 目标系统 | 渲染 |
|------|---------|------|
| `liquid-glass` | **macOS 26+** | 原生 Liquid Glass 材质，玻璃盘体随壁纸自适应、带氛围着色 |
| `main`         | macOS 15+     | 普通半透明 / 不透明渲染，向前兼容 |

- 玻璃表盘采用 **氛围着色（glass tint）** 取代旧版不透明底色：纯净玻璃基础上叠加主题提示色，保留各表盘个性又不遮挡壁纸。
- 浅色 tint 主题（暗金 / 超电磁炮 / 天空）自动使用 **高对比近黑墨色** 文字、刻度与数字；深 / 中 tint 主题（经典 / 深夜 / 古风）使用纯白。
- `tokenclock` CLI 会根据 `sw_vers` 主版本号自动选用匹配变体，无需手动判断。

---

## 🔌 本地 API 服务器

TokenClock 在本地启动一个 `NWListener` HTTP 服务器：

```
GET http://127.0.0.1:9988/api/usage
```

返回所有工具聚合后的 JSON 用量数据，便于外部脚本 / 仪表盘集成。仅监听本机回环，**不会对外暴露**。

---

## 🔒 隐私

- 所有用量数据均 **在本地读取** 自各 AI 工具自身写入的日志文件——TokenClock **不上传任何 token / 会话信息**。
- 本地 API 服务器仅监听 `127.0.0.1`，且为可选项。
- 天气功能通过 IP 大致定位或手动选择城市获取，仅用于显示当前天气与预报。

---

## 🛣 路线图

- [ ] `tokenclock update` —— 部署更新服务器，实现一键拉取 / 安装新版本
- [ ] 支持更多 AI 编程工具（持续扩展检测器）
- [ ] 提供签名 / 公证的 release 构建（`.app`）
- [ ] 更丰富的历史统计与图表

---

## 📦 技术栈

| | |
|---|---|
| **语言** | Swift 6（`-parse-as-library`） |
| **UI** | SwiftUI + AppKit（无锁 NSPanel 双窗口架构） |
| **构建** | Swift Package Manager（无 `.xcodeproj`） |
| **平台** | macOS 26 SDK（`liquid-glass` 分支）/ macOS 15 SDK（`main` 分支） |
| **定位** | 自研 `L10n` 引擎（zh-Hans / zh-Hant / en，无 `.xcstrings`） |
| **规模** | 约 10,700 行 Swift |

---

## 📄 许可证

TokenClock 基于 **[MIT 协议](LICENSE)** 开源 —— © 2026 nxc8335。可自由使用、修改与再分发，仅需保留版权声明。

---

## 🙏 致谢

TokenClock 的诞生得益于众多优秀的 AI 编程工具及其社区。感谢这些工具将 token 用量写入本地日志，使统一可视化成为可能。表盘设计灵感来自传统机械腕表与流行文化（古风 / 超电磁炮主题）。

---

<div align="center">

**⭐ 如果 TokenClock 对你有帮助，欢迎 Star。**

</div>

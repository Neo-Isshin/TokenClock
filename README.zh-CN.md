<div align="center">

**简体中文** · [English](README.md)

# 🕰️ TokenClock

**原生液态玻璃（Liquid Glass）token 时钟 · 一屏掌握你所有 Agent 的消耗**

[![macOS 12+](https://img.shields.io/badge/macOS-12%2B-000000?style=for-the-badge&logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![macOS 26+](https://img.shields.io/badge/macOS%2026-Liquid%20Glass-00B0F0?style=for-the-badge)](https://developer.apple.com/macos/)
[![Linux normal](https://img.shields.io/badge/Linux-normal-FCC624?style=for-the-badge&logo=linux&logoColor=black)](#linux-normal-版)

[![Swift 6](https://img.shields.io/static/v1?label=Swift&message=6&color=F05138&logo=swift&logoColor=white)](https://www.swift.org/)
[![SwiftUI](https://img.shields.io/static/v1?label=UI&message=SwiftUI%20%2B%20AppKit&color=blueviolet)](https://developer.apple.com/xcode/swiftui/)
[![SwiftPM](https://img.shields.io/static/v1?label=Build&message=SwiftPM&color=FA7343)](https://www.swift.org/package-manager/)
[![Privacy](https://img.shields.io/static/v1?label=Privacy&message=local%20only&color=success)](#-隐私)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![Releases](https://img.shields.io/badge/releases-GitHub-181717?logo=github&logoColor=white)](https://github.com/Neo-Isshin/TokenClock/releases)

</div>

<div align="center">

<table>
  <tr>
    <td width="50%" align="center"><img src="docs/screenshots/glass_zh.png" alt="Liquid Glass 版" width="300"><br><sub><b>Liquid Glass版</b> · macOS 26+</sub></td>
    <td width="30%" align="center"><img src="docs/screenshots/normal_zh.png" alt="Normal 版" width="300"><br><sub><b>Normal版</b> · macOS 12+</sub></td>
  </tr>
</table>

</div>

---

TokenClock 是一个常驻桌面的 **悬浮时钟**（置顶 · 可拖拽 · 记忆位置）。表盘上实时叠加显示：**今日总 token 消耗、消息条数、当前活跃的 AI 工具、速率指示器与天气**。点击时钟即可展开下拉面板，查看 **每个工具 → 每个 session / agent** 的明细用量。

重复读取的提示词缓存不会抬高主数字；新输入、缓存创建、输出和推理仍会正常计入。

采用 macOS 26 的 **Liquid Glass** 材质打造玻璃质感表盘，并提供 7 款精心设计的内置表盘与完全自定义主题。所有数据都在 **本地** 读取——不上传任何信息。

> [!NOTE]
> Liquid Glass 版已支持 macOS 27 beta 3，但可能随 beta 版本更新而失效。
---

## 📑 目录

- [🌟 核心优势](#-核心优势)
- [✨ 特性](#-特性)
- [📸 截图](#-截图)
- [🤖 支持的 AI 工具](#-支持的-ai-工具)
- [🚀 快速开始](#-快速开始) —— [一行安装](#一键安装最简单) · [`tokenclock` CLI](#使用-tokenclock-cli)
- [🎨 主题](#-主题)
- [🧊 液态玻璃（Liquid Glass）](#-液态玻璃liquid-glass)
- [🔌 本地 API 服务器](#-本地-api-服务器)
- [🔒 隐私](#-隐私)
- [🛣 未来支持计划](#-未来支持计划)
- [📦 技术栈](#-技术栈)
- [📄 许可证](#-许可证)
- [🙏 致谢](#-致谢)

---

## 🌟 核心优势

<table>
  <tr>
    <td width="50%" valign="top"><b>🤖 多工具总览，一屏尽览</b><br><sub>把 <b>14 款</b> AI 编程工具的 token / 消息用量汇聚到同一只表盘，告别多终端、多后台来回切换。</sub></td>
    <td width="50%" valign="top"><b>🔍 分 session / agent 下钻</b><br><sub>从工具级总览一路深入到每条 session / agent 明细，立刻看清消耗花在哪、是哪段对话烧的。</sub></td>
  </tr>
  <tr>
    <td valign="top"><b>🌤️ 常驻桌面，零打扰</b><br><sub>悬浮置顶的半透明液态玻璃表盘，余光即知实时消耗与速率（🔥 爆发 / 🌊 平稳），不打断编码节奏。</sub></td>
    <td valign="top"><b>📈 多维实时洞察</b><br><sub>今日总量、缓存率、未来趋势预测、活跃工具一图打尽。</sub></td>
  </tr>
  <tr>
    <td valign="top"><b>🎨 丰富的自定义选项</b><br><sub>6 款表盘 + 完全自定义：毛玻璃底板透明度、玻璃着色、文字 / 指针 / 刻度 / 数字 / 字体 / 尺寸 / 窗口透明度全可调。</sub></td>
    <td valign="top"><b>📜 历史用量可回溯</b><br><sub>每日快照存入本地 SQLite（保留 30 天），经本地 API 暴露，可回溯过往、对接你自己的图表。</sub></td>
  </tr>
  <tr>
    <td valign="top"><b>⚡ 性能占用极低</b><br><sub>原生 Swift + 高效轮询（时钟 1s / 用量 30s / 天气 5min）+ 流式 JSONL，常驻后台几乎无感。</sub></td>
    <td valign="top"><b>🔒 纯本地，零上传</b><br><sub>只读各工具本地日志，不上传任何数据；API 仅监听 <code>127.0.0.1</code> 回环。</sub></td>
  </tr>
  <tr>
    <td colspan="2" valign="top"><b>🔌 零配置，开箱即用</b><br><sub>首次启动自动探测本机已安装的 14 款 AI 编程工具。对于无历史数据的全新工具，在使用产生日志后亦能被后台动态感知开启，无需手动配置。</sub></td>
  </tr>
</table>

---

## ✨ 特性

### 🤖 多 AI 工具统一实时检测
- 自动探测并读取 **14 款 AI 编程工具** 写入本地的 token / 消息用量日志并统一聚合。
- 表盘上叠加 **今日总量、活跃工具图标、速率 emoji**（🔥 爆发 / 🌊 平稳阈值）。
- 点击展开 **下拉面板** 查看明细（工具 → session / agent 两级下钻，详见[核心优势](#-核心优势)）。

### 🧊 液态玻璃（Liquid Glass）& 精心设计
- macOS 26 上以原生 **Liquid Glass** 材质渲染，玻璃盘体随壁纸自适应、带氛围着色、折射与流动。
- **自适应高对比墨色文字**：浅色 tint 主题自动切换近黑刻度 / 数字，保证可读性。
- 提供 `main`（macOS 26）与 `normal`（macOS 12）**双版本**，由 `tokenclock` CLI 按系统版本自动选用。

### 📦 一行安装 & CLI
- `normal` 适用于 **macOS 12+ 与 Linux**，液态玻璃仅适用于 **macOS 26+**。`tokenclock` CLI 可在两个平台启动 / 停止 / 诊断。

### 🎨 多表盘 + 美观设计 + 支持深度自定义
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

### 🧊 Liquid Glass 版预览（macOS 26+）

<table>
  <tr>
    <td width="50%" align="center"><b>悬浮液态玻璃时钟</b><br><sub>玻璃盘体随壁纸折射 · 叠加 token / 消息 / 速率 / 天气</sub></td>
    <td width="50%" align="center"><b>总览</b><br><sub>玻璃时钟与展开面板同框</sub></td>
  </tr>
  <tr>
    <td width="50%" align="center"><img src="docs/screenshots/glass_zh.png" alt="liquid glass clock" width="75%"></td>
    <td width="50%" align="center"><img src="docs/screenshots/glass_full_zh.png" alt="liquid glass overview" width="75%"></td>
  </tr>
</table>

### ⬜ Normal 版预览（macOS 12+）

<table>
  <tr>
    <td width="50%" align="center"><b>悬浮时钟</b><br><sub>经典不透明表盘 · 叠加 token / 消息 / 速率 / 天气</sub></td>
    <td width="50%" align="center"><b>总览</b><br><sub>不透明时钟与展开面板同框</sub></td>
  </tr>
  <tr>
    <td width="50%" align="center"><img src="docs/screenshots/normal_zh.png" alt="normal clock" width="75%"></td>
    <td width="50%" align="center"><img src="docs/screenshots/normal_full_zh.png" alt="normal overview" width="75%"></td>
  </tr>
</table>

### ⚙️ 功能设置预览

<table>
  <tr>
    <td width="44%" align="center"><b>功能设置面板</b><br><sub>自动探测工具路径与详细参数配置</sub></td>
    <td width="34%" align="center"><b>表盘主题选择器</b><br><sub>6 款内置表盘与完全自定义配置</sub></td>
    <td width="22%" align="center"><b>右键快捷菜单</b><br><sub>快速调整表盘、尺寸与常用设置</sub></td>
  </tr>
  <tr>
    <td align="center"><img src="docs/screenshots/settings_zh.png" alt="settings panel upper" width="100%"></td>
    <td align="center" rowspan="2" valign="middle"><img src="docs/screenshots/themes_zh.png" alt="theme picker" width="300"></td>
    <td align="center" rowspan="2" valign="middle"><img src="docs/screenshots/menu_zh.png" alt="context menu" width="220"></td>
  </tr>
  <tr>
    <td align="center"><img src="docs/screenshots/settings_zh_bottom.png" alt="settings panel lower" width="83%"></td>
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

> 各服务的 token 计算公式略有差异：**Codex、Gemini/Qwen** 的 `input`（`promptTokenCount`）已含 cached，不能再加 cached（否则双计），用 `input + output + (thought)`；其余服务（Claude/OpenClaw 等）的输入/输出/缓存字段互斥相加。详见 `docs/TOOL_SCHEMA_ANALYSIS.md`。

---

## 🚀 快速开始

### 一键安装（最简单）

自动检测系统平台与版本（**Linux / macOS 12+ / macOS 26+**）→ 安装对应变体：macOS 下**下载预编译** universal 二进制（SHA256 校验 + 去隔离）—— 26+ 装 Liquid Glass + normal，12–25 仅 normal；Linux 下**从源码编译 normal GTK3 版**。随后安装到 `~/.tokenclock` → 把 `tokenclock` 加入 PATH → 首次启动并扫描各 AI 工具的本地路径。macOS 下仅当下载失败或加 `--build-from-source` 才回退本地编译。

> 💡 **下载即用** —— 无需 Xcode、无需 $99/年公证：自动下载预编译 universal 二进制（SHA256 校验 + 去隔离），普通用户开箱即用。

```bash
# 一行安装（推荐）：
curl -fsSL https://raw.githubusercontent.com/Neo-Isshin/TokenClock/main/cli/install.sh | bash

# 已克隆本仓库时也可直接运行：
./cli/install.sh
```

### Linux normal 版

Linux 使用 GTK3/Cairo 还原 **normal 表盘体验**：主窗口是透明的圆形小组件，盘面信息布局与 macOS normal 一致，并完整提供玻璃、经典、冰川、深夜、暗金、古风、超电磁炮、天空 8 套内置表盘及其指针形状、数字、刻度和装饰。左键展开与主题配套的详情面板，可按会话/模型分组、显示占比、展开来源并查看天气趋势；右键提供图形化表盘选择器、尺寸、透明度、置顶、温标、城市、时区、语言、设置、XDG 开机自启、复制 API 和关于。GTK 设置窗口包含自动探测、14 种工具开关与数据路径、API 即时配置、速率阈值和可保存的自定义表盘。Linux 自动天气使用 wttr.in 的 IP 定位回退，手选城市行为与 macOS normal 一致。

Linux 详情面板还在 **By Percent 左侧**加入 **Codex Quota**：在有数据时展示周额度/短周期额度的剩余量、重置时间、套餐、余额和 reset credits。额度只在用户打开该视图时按需获取，并使用短缓存和有界回退；不会常驻 `app-server` 子进程，也没有额度轮询循环。normal 对齐还包括紧凑的 3×3 基础表盘选择器（已保存自定义表盘排列在其后）、自定义表盘保存/应用/删除/重置与持久化、520×548 的概览式折叠设置窗口，以及 Linux 专属 About 信息。这些是对 normal 工作流与视觉气质的 GTK/Cairo 适配，不代表与 AppKit 像素级完全相同。

#### Linux provider catalog

Linux 使用独立的路径 catalog，不会导入 macOS 的 `~/Library/Application Support`，也不会导入 Windows 的 `%APPDATA%`/`%LOCALAPPDATA%`。解析顺序为：已保存的自定义路径、下表所列环境变量候选、Linux 默认路径、Linux 专属备选路径。只有 provider 或宿主应用遵循 XDG Base Directory 时才使用 XDG；XDG 变量未设置（或错误地设置成相对路径）时使用 `:-` 后的回退路径。

| 工具 | Linux 默认路径 / 解析器输入 | 环境变量候选（按优先级） |
|------|-----------------------------|--------------------------|
| **OpenClaw** | `~/.openclaw/agents/*/sessions/*.jsonl` | `OPENCLAW_STATE_DIR`；`${OPENCLAW_HOME}/.openclaw` |
| **Claude Code** | `~/.claude/projects/**/*.jsonl` | `CLAUDE_CONFIG_DIR` |
| **Gemini CLI** | `~/.gemini/tmp/*/chats/session-*.(jsonl\|json)` | `${GEMINI_CLI_HOME}/.gemini`；`GEMINI_HOME`† |
| **Codex** | `~/.codex/sessions/**/rollout-*.jsonl` | `CODEX_HOME` |
| **Hermes** | `~/.hermes/state.db`（`sessions` 表） | `HERMES_HOME` |
| **OpenCode** | `${XDG_DATA_HOME:-~/.local/share}/opencode/opencode.db` | `OPENCODE_DB`（文件）；`OPENCODE_HOME`†；`XDG_DATA_HOME` |
| **Qwen Code** | `~/.qwen/projects/*/chats/*.jsonl` | `QWEN_RUNTIME_DIR`；`QWEN_HOME` |
| **GitHub Copilot CLI** | `~/.copilot/session-state/*/events.jsonl` 与可选的 OTel JSONL | `COPILOT_HOME`；`COPILOT_OTEL_FILE_EXPORTER_PATH`（文件） |
| **Grok CLI** | `~/.grok/sessions/*/*/updates.jsonl` | `GROK_HOME`† |
| **Aider** | `${XDG_STATE_HOME:-~/.local/state}/aider/analytics.jsonl`（TokenClock 约定） | `AIDER_ANALYTICS_LOG`（文件）；`AIDER_HOME`†；`XDG_STATE_HOME` |
| **Antigravity** | `~/.gemini/{antigravity-cli,antigravity-ide,antigravity}/conversations/*.db` | `ANTIGRAVITY_HOME`† |
| **Cline** | `${XDG_CONFIG_HOME:-~/.config}/Code/User/globalStorage/saoudrizwan.claude-dev/tasks/*/api_conversation.json` | `CLINE_HOME`†；`XDG_CONFIG_HOME` |
| **Continue** | `~/.continue/{dev_data,sessions}/*.jsonl` | `CONTINUE_HOME`† |
| **Cursor Agent** | `${XDG_CONFIG_HOME:-~/.config}/Cursor/User/globalStorage/state.vscdb`，随后请求已认证的 Cursor usage API | `CURSOR_AGENT_HOME`†；`XDG_CONFIG_HOME` |

† TokenClock 兼容覆盖变量，不是 provider 官方公布的环境变量契约。自定义路径和环境变量路径支持展开 `~`、`$VAR`、`${VAR}`。Cline 还会探测 Linux 用户数据目录下的 VSCodium、Code OSS、Cursor、VS Code Remote 和 Cursor Remote global storage。

自动探测在内部区分三个状态：catalog 已声明、候选路径存在、解析器可读取。只有 TokenClock 能读取有效 JSON/JSONL，或能打开所需 SQLite 表及字段时，才计为探测成功。

已知限制：

- 当前 OpenClaw 可以把 transcript 迁移到每个 agent 的 SQLite 数据库；TokenClock 的 OpenClaw 解析器目前仍要求旧版 JSONL transcript。
- Aider 默认不会创建 analytics 日志，必须通过 `--analytics-log <file>` 或 `AIDER_ANALYTICS_LOG` 开启；上面的 XDG state 路径只是 TokenClock 的 Linux 约定。
- Copilot 的 session event 可能只包含有限的 token 明细；完整明细需要 Copilot OTel 文件，`COPILOT_OTEL_FILE_EXPORTER_PATH` 会被直接读取。
- Cursor 用量并非来自本地 token 日志：TokenClock 读取本地 Cursor 凭据数据库，并在启用云端获取时调用 Cursor 的已认证 usage API。

**x86_64 —— 预编译 AppImage（默认）：** 通用一键命令会下载一个自带 GTK3 的 AppImage（仅要求 glibc ≥ 2.35），无需 Swift、无需编译、无需开发头文件：

```bash
# 同一条通用安装命令 —— 在 x86_64 Linux 上自动下载预编译 AppImage
curl -fsSL https://raw.githubusercontent.com/Neo-Isshin/TokenClock/main/cli/install.sh | bash
```

AppImage 运行期需要 `libfuse2`（多数桌面发行版自带；缺失时：`sudo apt install libfuse2`，Ubuntu 24.04+ 为 `libfuse2t64`）。

**其它架构 / `--build-from-source`** —— 从源码编译（需要 Swift 6 + GTK3/SQLite3 开发头文件）：

```bash
sudo apt install git pkg-config libcurl4 libgtk-3-dev libsqlite3-dev   # Ubuntu/Debian 构建依赖
curl -fsSL https://raw.githubusercontent.com/Neo-Isshin/TokenClock/main/cli/install.sh | bash -s -- --build-from-source
```

也可以使用可复现的容器构建：

```bash
docker build -f Dockerfile.linux -t tokenclock-linux .
```

可选参数：`--normal` / `--glass`（指定变体）/ `--no-start`（装完不自动启动）/ `--build-from-source`（强制本地源码编译）/ `--check`（仅检查不安装）/ `--debug`（debug 构建）。

> 注：在较新 glibc 的发行版上，AppImage 启动时终端可能打印一行无害的 `libgvfs … undefined symbol / Failed to load module` —— TokenClock 不使用 gvfs，可忽略（从桌面菜单启动时看不到）。

### 前置要求
- **macOS 12+**（普通版）；**macOS 26+**（Liquid Glass 版）
- 预编译安装**无需任何工具链**；仅 `--build-from-source` 本地编译时需要 Swift 6（Xcode 16+ / Command Line Tools）
- **Linux normal**：x86_64 走预编译 AppImage（仅需 `libfuse2` + glibc ≥ 2.35，桌面发行版均自带）；其它架构 / `--build-from-source` 需 Swift 6、GTK3/SQLite3 开发头文件、`libcurl4` 与 `pkg-config`

### 从源码构建运行

```bash
git clone https://github.com/Neo-Isshin/TokenClock.git TokenClock
cd TokenClock

# 调试构建并直接运行
swift run

# 或先构建再运行
swift build            # 调试
swift build -c release # 发布
.build/debug/TokenClock      # 或 .build/release/TokenClock
```

> `main` 分支的 `Package.swift` 声明为 `.macOS(.v26)`，`swift run` 直接产出 Liquid Glass 版；兼容 macOS 12 的经典（不透明）版本位于 `normal` 分支。

> Linux 上请克隆或切换到 `normal` 分支再运行 `swift build`；SwiftPM 会自动选择 GTK3 目标。

> 小坑：在 **macOS 27 且只装了 Command Line Tools**（无完整 Xcode）的机器上，`main` 分支裸 `swift build` 会因 27 SDK 把 `@State` 宏化而失败；指定 `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk swift build` 即可（26 SDK 里 `@State` 仍是普通属性包装器）。`normal` 分支不受影响。

### 使用 `tokenclock` CLI

将轻量 shell 脚本安装到 PATH：

```bash
sudo install -m755 cli/tokenclock /usr/local/bin/tokenclock
```

| 命令 | 说明 |
|------|------|
| `tokenclock start [--glass\|--normal] [--force]` | 启动时钟；自动选择（macOS 26+ → glass，macOS 12–25/Linux → normal）；`--force` 强制另开一份 |
| `tokenclock stop` | 停止所有运行中的 TokenClock 实例 |
| `tokenclock restart [--glass\|--normal]` | 重启 |
| `tokenclock doctor` | 诊断环境：系统版本、已安装变体路径、运行中的进程、环境变量 |
| `tokenclock update [--check] [--force]` | 更新到最新版：拉取最新 install.sh → SHA256 校验 → 装新二进制 → 重启（无变更则不动）；`--check` 仅检查，`--force` 强制 |
| `tokenclock help` | 显示帮助 |

**变体定位顺序**：`$TOKENCLOCK_GLASS` / `$TOKENCLOCK_NORMAL` 环境变量 → `~/.tokenclock/` → `/Applications/` → 仓库 `.build/debug/`。

---

## 🎨 主题

7 款内置表盘，外加完全自定义：

| 主题 | 中文名 | 性格 |
|------|--------|------|
| `classic`  | 经典     | 纯净玻璃盘 · 炭黑指针 + 琥珀秒针 · 仅 3/6/9/12 数字 |
| `glacier`  | 冰川     | 清透冰蓝玻璃 · 墨色剑形指针 + 樱粉秒针 · 冰蓝色刻度与数字 |
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
| `main`   | **macOS 26+** | 原生 Liquid Glass 材质，玻璃盘体随壁纸自适应、带氛围着色 |
| `normal` | macOS 12+     | 经典不透明主题表盘，向前兼容 |

- 玻璃表盘采用 **氛围着色（glass tint）** 取代旧版不透明底色：纯净玻璃基础上叠加主题提示色，保留各表盘个性又不遮挡壁纸。
- **可调毛玻璃底板**：清透折射玻璃下层叠加一层公开毛玻璃底板，透明度 0–100% 五档可调（0 = 纯净玻璃通透，100 = 实心底板），在通透与实心之间自由拿捏（仅 macOS 26 液态玻璃版）。
- 浅色 tint 主题（暗金 / 超电磁炮 / 天空）自动使用 **高对比近黑墨色** 文字、刻度与数字；深 / 中 tint 主题（经典 / 深夜 / 古风）使用纯白。
- `tokenclock` CLI 会根据 `sw_vers` 主版本号自动选用匹配变体，无需手动判断。

---

## 🔌 本地 API 服务器

TokenClock 在本地启动一个 `NWListener` HTTP 服务器：

```
GET http://127.0.0.1:9988/api/usage          # 实时聚合用量（今日总量 / 各工具 / session 明细）
GET http://127.0.0.1:9988/api/history?days=30 # 过去 N 天的日结快照（最多 30 天，便于画趋势）
```

返回 JSON 用量数据，便于外部脚本 / 仪表盘集成。仅监听本机回环，**不会对外暴露**。

---

## 🔒 隐私

- 所有用量数据均 **在本地读取** 自各 AI 工具自身写入的日志文件——TokenClock **不上传任何 token / 会话信息**。
- 本地 API 服务器仅监听 `127.0.0.1`，且为可选项。
- 天气功能通过 IP 大致定位或手动选择城市获取，仅用于显示当前天气与预报。

---

## 🛣 未来支持计划

- [ ] 支持更多 AI 编程工具（持续扩展检测器）
- [ ] 提供签名 / 公证的 release 构建（`.app`）—— 当前走未签名 GitHub 分发，此项需 Apple Developer 账号（$99/年），暂不计划，欢迎赞助 / 认领
- [ ] 更丰富的历史统计与图表

---

## 📦 技术栈

| | |
|---|---|
| **语言** | Swift 6（`-parse-as-library`） |
| **UI** | macOS：SwiftUI + AppKit；Linux normal：GTK3 + Cairo |
| **构建** | Swift Package Manager（无 `.xcodeproj`） |
| **平台** | macOS 26 SDK（`main`）/ macOS 12 与 Linux GTK3（`normal`） |
| **定位** | 自研 `L10n` 引擎（zh-Hans / zh-Hant / en，无 `.xcstrings`） |
| **规模** | 约 12,400 行 Swift |

---

## 📄 许可证

TokenClock 基于 **[GPL v3 协议](LICENSE)** 开源 —— © 2026 Neo-Isshin。您可以自由使用、分发与修改，但任何分发或修改后的衍生版本也必须以 GPL v3 协议开源。

---

## 🙏 致谢

- TokenClock 的诞生得益于众多优秀的 AI 编程工具及其社区。感谢这些工具将 token 用量写入本地日志，使统一可视化成为可能。  

- 本项目的液态玻璃折射效果（macOS 26+）得益于对 macOS 私有 API `NSGlassEffectView` 的逆向研究，特别致谢首创探索该私有 API 的开源项目 **[electron-liquid-glass](https://github.com/Meridius-Labs/electron-liquid-glass)**（由 Meridius-Labs 维护）。

- 表盘设计灵感来自传统机械腕表与流行文化（古风 / 超电磁炮主题）。
---

<div align="center">

<h3>⭐ 觉得 TokenClock 好用？</h3>

**欢迎给项目一个 Star —— 你的支持是持续迭代的动力 🚀**

[![Star](https://img.shields.io/badge/⭐-Star%20on%20GitHub-181717?style=for-the-badge&logo=github&logoColor=white)](https://github.com/Neo-Isshin/TokenClock)

</div>

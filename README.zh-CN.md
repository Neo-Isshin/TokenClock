<div align="center">

**简体中文** · [English](README.md)

# 🕰️ TokenClock

**原生液态玻璃（Liquid Glass）token 时钟 · 一屏掌握你所有 Agent 的消耗**

[![macOS 12+](https://img.shields.io/badge/macOS-12%2B-000000?style=for-the-badge&logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![macOS 26+](https://img.shields.io/badge/macOS%2026-Liquid%20Glass-00B0F0?style=for-the-badge)](https://developer.apple.com/macos/)
[![Linux normal](https://img.shields.io/badge/Linux-normal-FCC624?style=for-the-badge&logo=linux&logoColor=black)](#linux-normal-版)
[![Windows normal](https://img.shields.io/badge/Windows-normal-0078D4?style=for-the-badge&logo=windows&logoColor=white)](#windows-normalwindows-port)

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

### Windows provider catalog（`windows-port`）

Windows 的路径探测与 macOS、Linux 分开维护。支持展开 `%NAME%`、`$env:NAME`、`${NAME}`、`$NAME` 和 `~`，探测优先级为：**设置中的自定义路径 → 环境变量 → Windows 默认路径 → 兼容备选路径**。

| 工具 | Windows 默认数据源 | 环境变量 |
|------|--------------------|---------|
| **OpenClaw** | `%USERPROFILE%\.openclaw\` | `OPENCLAW_STATE_DIR`（直接目录）；`OPENCLAW_HOME`（用户主目录） |
| **Claude Code** | `%USERPROFILE%\.claude\` | `CLAUDE_CONFIG_DIR` |
| **Gemini CLI** | `%USERPROFILE%\.gemini\` | `GEMINI_CLI_HOME`（父目录）；`GEMINI_HOME`（TokenClock 兼容覆盖） |
| **Codex** | `%USERPROFILE%\.codex\` | `CODEX_HOME` |
| **Hermes** | `%LOCALAPPDATA%\hermes\state.db` | `HERMES_HOME` |
| **OpenCode** | `%USERPROFILE%\.local\share\opencode\opencode.db` | `OPENCODE_DB`（直接数据库）；`XDG_DATA_HOME`（父目录）；`OPENCODE_HOME`（TokenClock 兼容覆盖） |
| **Qwen Code** | `%USERPROFILE%\.qwen\` | `QWEN_RUNTIME_DIR`、`QWEN_HOME` |
| **GitHub Copilot CLI** | `%USERPROFILE%\.copilot\` 会话状态 | `COPILOT_OTEL_FILE_EXPORTER_PATH`（直接 JSONL 文件）；`COPILOT_HOME` |
| **Grok CLI** | `%USERPROFILE%\.grok\` | `GROK_HOME`（TokenClock 兼容覆盖） |
| **Aider** | `%USERPROFILE%\.aider\analytics.jsonl` | `AIDER_ANALYTICS_LOG`；`AIDER_HOME`（TokenClock 兼容覆盖） |
| **Antigravity** | `%USERPROFILE%\.gemini\antigravity-cli\` | `ANTIGRAVITY_HOME`（TokenClock 兼容覆盖） |
| **Cline** | `%APPDATA%\Code\User\globalStorage\saoudrizwan.claude-dev\` | `CLINE_HOME`（TokenClock 兼容覆盖） |
| **Continue** | `%USERPROFILE%\.continue\` | `CONTINUE_HOME`（TokenClock 兼容覆盖） |
| **Cursor Agent** | `%APPDATA%\Cursor\User\globalStorage\state.vscdb` | `CURSOR_AGENT_HOME`（TokenClock 兼容覆盖） |

探测报告会分别记录三件事：catalog 中是否有声明、选中的路径是否存在、对应 JSONL/JSON/SQLite 输入是否真的可由解析器读取。因此，仅有空目录不会被误报为“可用”。Hermes 也会兼容探测旧路径 `%USERPROFILE%\.hermes`；OpenCode 另行兼容探测 `%LOCALAPPDATA%\opencode` 和 `%USERPROFILE%\.opencode`；Cline 也会探测 Cursor 的扩展数据目录。

上表中的“官方”表示该变量或路径契约有 provider 官方文档/源码依据（例如 OpenClaw 的 `OPENCLAW_STATE_DIR`、Qwen 运行目录或平台标准 `XDG_DATA_HOME`）。“TokenClock 兼容覆盖”仅表示 TokenClock 为方便配置而接受该变量名；目前未找到稳定的上游官方契约，不能把它当作 provider 官方设置。

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

### Windows normal（`windows-port`）

Windows normal 当前由长期分支 `windows-port` 独立维护，不反向合并进 macOS/Linux 产品分支。安装器仅写入当前用户目录，无需管理员权限；下载 release ZIP 后会校验配套 SHA-256，默认安装到 `%LOCALAPPDATA%\Programs\TokenClock`。

该渠道按 macOS normal 的工作流对齐：完整提供玻璃、经典、冰川、深夜、暗金、古风、超电磁炮、天空 8 套内置表盘，紧凑 3×3 表盘选择器与已保存自定义表盘、四档尺寸，以及固定 320×547 的详情卡（会话/模型分组、百分比、可展开行、天气趋势）；**Codex Quota** 位于 **By Percent** 左侧。右键菜单、概览式分组设置、自定义表盘保存/应用/删除流程和品牌 About 均采用 Windows 原生实现对齐同一套 normal 功能。provider 路径仍保持 Windows 专属，不引入 macOS 或 Linux catalog 路径。

```powershell
# 安装最新 x86_64 Windows 版并启动。
irm https://raw.githubusercontent.com/Neo-Isshin/TokenClock/windows-port/cli/install.ps1 | iex

# 显式传参示例：安装后不启动，并创建开始菜单快捷方式。
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/Neo-Isshin/TokenClock/windows-port/cli/install.ps1))) -NoStart -StartMenuShortcut
```

默认安装**不会**创建快捷方式，也不会修改登录自启动。主要操作与参数：

- `-Action Install|Update|Check|Uninstall`，可配合 `-Version <tag>` 安装指定版本。
- `-NoStart`、`-StartMenuShortcut`、`-DesktopShortcut`、`-EnableAutostart` 均为显式选项。
- `-InstallDir <路径>` 可更改当前用户安装目录；安装器会拒绝用户目录、AppData 根目录等过宽目标。
- 若正在运行的 TokenClock 无法正常关闭，必须显式使用 `-Force`。
- 卸载默认保留 `%LOCALAPPDATA%\TokenClock` 设置；仅 `-RemoveUserData` 会一并删除。
- release 缺少校验文件时默认中止；`-AllowUnsigned` 仅用于用户明确确认可信的本地/自定义包。

Windows release 包通过 `pwsh scripts/build-windows.ps1 -Zip` 生成，包含 `TokenClock.exe`、Swift/VC++ 运行时 DLL 和资源。发布时使用指向 `windows-port` 的独立 tag：共享 release `v1.3.8` 已存在后，把对应 Windows 提交标记为 `windows-v1.3.8` 并推送。这样 workflow 定义和源码都存在于不可变的 Windows tag 中；workflow 会把 `windows-v1.3.8` 映射回已存在的 `v1.3.8` release，只附加 ZIP 和校验文件。它不会创建 Windows-only release，也不需要把 Windows 源码合并进 main。

```bash
gh release view v1.3.8 --repo Neo-Isshin/TokenClock
git switch windows-port
git pull --ff-only origin windows-port
git tag -a windows-v1.3.8 -m "Windows assets for v1.3.8"
git push origin windows-v1.3.8
```

使用 `-Version latest` 时，安装器会选择最新且已同时包含 Windows ZIP 和 SHA-256 的稳定 release；若更新的 macOS/Linux release 仍在等待 Windows 资产，会先跳过它。显式 `-Version` 则严格解析共享 tag（例如 `v1.3.8`，而不是 `windows-v1.3.8`）。当前发行包仅提供 x86_64。由于尚非 Microsoft Store/MSIX 包且可能未签名，Windows 信誉保护可能弹出提示。也可直接使用便携 ZIP，但快捷方式、更新与卸载需自行管理。

### Linux normal 版

Linux 在 [`normal` 分支](https://github.com/Neo-Isshin/TokenClock/tree/normal)独立维护，使用 GTK3/Cairo 还原 **normal 表盘体验**。当前完整提供 8 套 normal 内置表盘、3×3 表盘选择器、可保存的自定义表盘、会话/模型详情、百分比、基于 IP 定位或手选城市的天气趋势、Codex Quota、分组设置、XDG 开机自启，以及 `127.0.0.1:9988` 回环 API。其 14-provider catalog 与路径解析保持 Linux/XDG 专属；目标是对齐 macOS normal 的工作流和视觉气质，而不是宣称与 AppKit 像素级一致。

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
| **UI** | macOS：SwiftUI + AppKit；Linux normal：GTK3 + Cairo；Windows normal：Win32 + GDI+ 分层渲染 |
| **构建** | Swift Package Manager（无 `.xcodeproj`）；Windows 另含 Win32 C/C++ shim 与 PE 资源 |
| **平台** | macOS 26 SDK（`main`）/ macOS 12 与 Linux GTK3（`normal`）/ Windows 11 x86_64（`windows-port`） |
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

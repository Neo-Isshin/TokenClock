<div align="center">

[简体中文](README.zh-CN.md) · **English**

# 🕰️ TokenClock

**A native Liquid Glass desktop clock for your AI coding usage**

Track Claude Code, Codex, Gemini CLI, OpenCode, and 10 more tools on one living glass dial — **entirely on your Mac**.

[![macOS 12+](https://img.shields.io/badge/macOS-12%2B-000000?style=for-the-badge&logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![macOS 26+](https://img.shields.io/badge/macOS%2026-Liquid%20Glass-00B0F0?style=for-the-badge)](https://developer.apple.com/macos/)

[![Privacy](https://img.shields.io/static/v1?label=Privacy&message=local%20only&color=success)](#-privacy)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![Releases](https://img.shields.io/badge/releases-GitHub-181717?logo=github&logoColor=white)](https://github.com/Neo-Isshin/TokenClock/releases)

</div>

<div align="center">

<img src="docs/screenshots/glass_en.png" alt="TokenClock native Liquid Glass clock showing local AI coding token usage" width="520">

<sub><b>Native Liquid Glass on macOS 26+</b> · wallpaper-aware refraction · ambient tint · adaptive contrast · always-on-top</sub>

</div>

---

## 🧊 Liquid Glass is the interface, not a skin

TokenClock turns macOS 26's native **Liquid Glass** into a useful, glanceable instrument. The clock disc refracts the desktop behind it, picks up a subtle theme tint, and automatically switches its ink contrast to stay readable as the wallpaper changes. An adjustable frosted backing lets you move from clean, transparent glass to a denser dial without losing the native material.

The result is not a dashboard hidden in another window. It is an **always-on-top glass object** that belongs on the desktop: draggable, position-aware, and calm enough to live beside your work all day.

<div align="center">

**7 glass faces** · **adjustable translucency** · **full theme editor** · **macOS-native rendering**

</div>

## ⚡ Install in one line

The installer automatically selects the native Liquid Glass build on macOS 26+ and the classic compatible build on macOS 12–15.

```bash
curl -fsSL https://raw.githubusercontent.com/Neo-Isshin/TokenClock/main/cli/install.sh | bash
```

TokenClock overlays live data on the dial: **today's token consumption, message count, active AI tools, usage rate, and weather**. Click it to drill down from **tool → session / agent** and see exactly where the tokens went.

It reads the logs your AI coding tools already keep on your Mac. **Nothing is uploaded.**

> [!NOTE]
> Liquid Glass build has supported macOS 27 beta 3, but may break with beta version updates.

---

## 📑 Contents

- [🌟 Core advantages](#-core-advantages)
- [✨ Features](#-features)
- [📸 Screenshots](#-screenshots)
- [🤖 Supported AI tools](#-supported-ai-tools)
- [🚀 Quick start](#-quick-start) — [One-line install](#one-line-install-easiest) · [`tokenclock` CLI](#use-the-tokenclock-cli)
- [🎨 Themes](#-themes)
- [🧊 Liquid Glass](#-liquid-glass)
- [🔌 Local API server](#-local-api-server)
- [🔒 Privacy](#-privacy)
- [🛣 Roadmap](#-roadmap)
- [📦 Tech stack](#-tech-stack)
- [📄 License](#-license)
- [🙏 Acknowledgments](#-acknowledgments)

---

## 🌟 Core advantages

<table>
  <tr>
    <td width="50%" valign="top"><b>🧊 Native Liquid Glass</b><br><sub>A refractive glass disc that responds to the wallpaper behind it, with ambient tint and adaptive high-contrast ink.</sub></td>
    <td width="50%" valign="top"><b>🎨 Glass you can make your own</b><br><sub>7 built-in faces, adjustable frosted backing, glass tint, hands, ticks, numerals, fonts, dial size, and window opacity.</sub></td>
  </tr>
  <tr>
    <td valign="top"><b>🤖 All your tools, one dial</b><br><sub>Token / message usage from <b>14 AI coding tools</b> flows into a single clock face — no more hopping between terminals and web dashboards.</sub></td>
    <td valign="top"><b>🔍 Drill down per session / agent</b><br><sub>From a per-tool overview all the way down to every session / agent — see exactly where the tokens went and which conversation burned them.</sub></td>
  </tr>
  <tr>
    <td valign="top"><b>🌤️ Always visible, never disruptive</b><br><sub>A floating, always-on-top instrument; a glance gives you the live consumption and rate (🔥 burst / 🌊 calm) without breaking focus.</sub></td>
    <td valign="top"><b>📜 Usage history you can revisit</b><br><sub>Each day's usage is auto-settled into a local SQLite store (30 days) and exposed via the local API — feed your own charts.</sub></td>
  </tr>
  <tr>
    <td valign="top"><b>⚡ Tiny footprint</b><br><sub>Native Swift + efficient polling (clock 1s / usage 30s / weather 5min) + streaming JSONL; sits in the background almost unnoticed.</sub></td>
    <td valign="top"><b>🔒 Purely local, zero upload</b><br><sub>Reads only local logs each tool writes; nothing leaves your machine, and the API listens on <code>127.0.0.1</code> only.</sub></td>
  </tr>
  <tr>
    <td colspan="2" valign="top"><b>🔌 Zero config, ready out of the box</b><br><sub>Auto-detects 14 AI coding tools' log paths on first launch. New tools without history are auto-discovered by background workers on their first session, requiring no manual setup.</sub></td>
  </tr>
</table>

---

## ✨ Features

### 🤖 Unified multi-AI-tool detection
- Auto-detects and reads the local token / message usage logs written by **14 AI coding tools** and aggregates them.
- The dial overlays **today's totals, active-tool labels, and a rate emoji** (🔥 burst / 🌊 calm thresholds).
- Click to expand the **dropdown panel** for the breakdown (tool → session / agent; see [Core advantages](#-core-advantages)).

### 🧊 Liquid Glass
- On macOS 26 the disc renders with the native **Liquid Glass** material — it adapts to your wallpaper and carries a subtle theme tint.
- **Adaptive high-contrast ink**: lighter-tinted themes automatically switch to near-black ticks / numerals for legibility.
- Ships in **two variants** — `main` (macOS 26) and `normal` (macOS 12) — and the `tokenclock` CLI picks the right one for your OS automatically.

### 📦 One-line install & CLI
- The normal build runs on **macOS 12+**, the Liquid Glass build on **macOS 26+**. The one-liner picks the right variant for your OS automatically, and the lightweight `tokenclock` CLI handles start / stop / switch / diagnose. See the [install guide](https://github.com/Neo-Isshin/TokenClock).

### 🎨 Multiple faces & thoughtful design
- 7 built-in faces (Classic / Glacier / Midnight / Luxe / Gu Feng / Railgun / Sky), each with its own personality.
- 4 hand styles (round / tapered / lance / sword); numerals in Arabic or Chinese.
- **Fully custom themes**: dial color, glass tint, all three hands, ticks, numerals, borders, and fonts are all adjustable.

### ⚙️ More
- Live clock (1s), usage refresh (30s), weather (5min).
- Weather + 12-hour forecast (auto-located by IP or pick a city); 8 time zones.
- Internationalization: **Simplified Chinese / Traditional Chinese / English**.
- Always-on-top · draggable · position remembered across relaunch; launch-at-login via `SMAppService`.
- Local API server (`:9988`) for integration / scripting.
- Privacy-first: **all data read locally, zero upload**.

---

## 📸 Screenshots

### 🧊 Liquid Glass build preview (macOS 26+)

<table>
  <tr>
    <td width="50%" align="center"><b>Floating Liquid Glass clock</b><br><sub>disc refracts the wallpaper · tokens / messages / rate / weather on the dial</sub></td>
    <td width="50%" align="center"><b>Overview</b><br><sub>glass clock + expanded panel together</sub></td>
  </tr>
  <tr>
    <td width="50%" align="center"><img src="docs/screenshots/glass_en.png" alt="liquid glass clock" width="75%"></td>
    <td width="50%" align="center"><img src="docs/screenshots/glass_full_en.png" alt="liquid glass overview" width="75%"></td>
  </tr>
</table>

### ⬜ Normal build preview (macOS 12+)

<table>
  <tr>
    <td width="50%" align="center"><b>Floating clock</b><br><sub>classic opaque dial · tokens / messages / rate / weather on the dial</sub></td>
    <td width="50%" align="center"><b>Overview</b><br><sub>opaque clock + expanded panel together</sub></td>
  </tr>
  <tr>
    <td width="50%" align="center"><img src="docs/screenshots/normal_en.png" alt="normal clock" width="75%"></td>
    <td width="50%" align="center"><img src="docs/screenshots/normal_full_en.png" alt="normal overview" width="75%"></td>
  </tr>
</table>

### ⚙️ Settings preview

<table>
  <tr>
    <td width="44%" align="center"><b>Settings panel</b><br><sub>Auto-detected tool paths & parameters configuration</sub></td>
    <td width="34%" align="center"><b>Theme picker</b><br><sub>7 built-in faces & fully custom theme editing</sub></td>
    <td width="22%" align="center"><b>Context menu</b><br><sub>Quick access to dial themes, sizes & preferences</sub></td>
  </tr>
  <tr>
    <td align="center"><img src="docs/screenshots/settings_en.png" alt="settings panel upper" width="83%"></td>
    <td align="center" rowspan="2" valign="middle"><img src="docs/screenshots/themes_en.png" alt="theme picker" width="300"></td>
    <td align="center" rowspan="2" valign="middle"><img src="docs/screenshots/menu_en.png" alt="context menu" width="220"></td>
  </tr>
  <tr>
    <td align="center"><img src="docs/screenshots/settings_en_bottom.png" alt="settings panel lower" width="83%"></td>
  </tr>
</table>

---

## 🤖 Supported AI tools

TokenClock reads the **JSONL / SQLite usage files** that each tool writes locally (path priority: custom path > env var > default path; auto-detected on first launch). Defaults and env vars below.

| Tool | Default data source | Env var |
|------|---------------------|--------|
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
| **Cline** (VSCode extension) | `~/Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/` | `CLINE_HOME` |
| **Continue** (VSCode extension) | `~/.continue/` | `CONTINUE_HOME` |
| **Cursor Agent** | `~/.cursor/` | `CURSOR_AGENT_HOME` |

> Token-counting formulas differ slightly per service: **Codex** and **Gemini/Qwen** have `input` (`promptTokenCount`) already including cached tokens, so cached must not be added again (it would double-count) — they use `input + output + (thought)`; other services (Claude/OpenClaw, etc.) sum input/output/cache fields that are mutually exclusive. See `docs/TOOL_SCHEMA_ANALYSIS.md`.

---

## 🚀 Quick start

### One-line install (easiest)

Auto-detects the macOS version → **downloads the precompiled** matching variant (universal, SHA256-checked + de-quarantined) → installs to `~/.tokenclock` → puts `tokenclock` on your PATH → launches and scans each AI tool's local paths — no manual steps. Falls back to a local build only on download failure or with `--build-from-source`.

> 💡 **Download & run** — no Xcode, no $99/yr notarization: it fetches precompiled universal binaries (SHA256-checked + de-quarantined) and just works.

```bash
# one-line install (recommended):
curl -fsSL https://raw.githubusercontent.com/Neo-Isshin/TokenClock/main/cli/install.sh | bash

# or, if you've cloned this repo:
./cli/install.sh
```

Options: `--normal` / `--glass` (pick the variant) / `--no-start` (don't auto-launch) / `--build-from-source` (force a local build) / `--check` (check only, don't install) / `--debug` (debug build).

> Or build manually from source below.

### Prerequisites
- **macOS 12+** (normal build); **macOS 26+** (Liquid Glass build)
- The precompiled install needs **no toolchain at all**; Swift 6 (Xcode 16+ / Command Line Tools) is only required for `--build-from-source` local builds

### Build & run from source

```bash
git clone https://github.com/Neo-Isshin/TokenClock.git TokenClock
cd TokenClock

# debug build and run directly
swift run

# or build first, then run
swift build            # debug
swift build -c release # release
.build/debug/TokenClock      # or .build/release/TokenClock
```

> The `main` branch's `Package.swift` declares `.macOS(.v26)`, so `swift run` produces the Liquid Glass build; the classic (opaque) macOS 12-compatible build lives on the `normal` branch.

> Gotcha: on **macOS 27 with only Command Line Tools** installed (no full Xcode), a bare `swift build` on the `main` branch fails because the 27 SDK macro-expands `@State`; pass `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk swift build` to fix it (in the 26 SDK `@State` is still a plain property wrapper). The `normal` branch is unaffected.

### Use the `tokenclock` CLI

Install the lightweight shell script onto your PATH:

```bash
sudo install -m755 cli/tokenclock /usr/local/bin/tokenclock
```

| Command | Description |
|---------|-------------|
| `tokenclock start [--glass\|--normal] [--force]` | Start the clock; auto-picks by OS (26+ → glass, 12+ → normal); `--force` opens another instance |
| `tokenclock stop` | Stop all running TokenClock instances |
| `tokenclock restart [--glass\|--normal]` | Restart |
| `tokenclock doctor` | Diagnose: OS version, installed variant paths, running processes, env vars |
| `tokenclock update [--check] [--force]` | Update to the latest release: pulls the latest install.sh → SHA256-checks → installs new binaries → restarts (no-op if unchanged); `--check` checks only, `--force` forces |
| `tokenclock help` | Show help |

**Variant discovery order**: `$TOKENCLOCK_GLASS` / `$TOKENCLOCK_NORMAL` env vars → `~/.tokenclock/` → `/Applications/` → repo `.build/debug/`.

---

## 🎨 Themes

7 built-in faces, plus full custom:

| Theme | Name | Personality |
|-------|------|-------------|
| `classic`  | Classic    | Clear glass disc · charcoal hands + amber second hand · 3/6/9/12 only |
| `glacier`  | Glacier    | Crystal ice-blue glass · ink sword hands + cherry-blossom pink second hand · ice-blue numerals & ticks |
| `midnight` | Midnight   | Cyan glass · cyan tapered hands |
| `luxe`     | Luxe       | Gold glass · gold lance hands |
| `gufeng`   | Gu Feng    | Warm-brown glass · ink sword hands · **Chinese numerals** |
| `railgun`  | Railgun    | Pink-orange glass · electric-blue second hand · monospaced |
| `sky`      | Sky        | Blue glass · sun & clouds · gold hands |
| `custom`   | Custom     | Glass tint / hands / ticks / numerals / fonts… fully customizable |

**Right-click** the clock → theme picker, or open the theme editor in the settings window to switch or customize.

---

## 🧊 Liquid Glass

TokenClock ships in two builds:

| Branch | Target | Rendering |
|--------|--------|-----------|
| `main`   | **macOS 26+** | Native Liquid Glass material; the disc adapts to the wallpaper and carries a subtle tint |
| `normal` | macOS 12+     | Classic opaque themed dial, for backward compatibility |

- The glass disc uses an **ambient tint (glass tint)** instead of the old opaque dial fill: a clean glass base plus a theme hint color, preserving each face's character without hiding your wallpaper.
- **Adjustable frosted backing** — a public frosted-glass plate sits beneath the clear refractive glass, with opacity adjustable across 5 steps (0 = clean see-through glass, 100 = solid plate), letting you dial translucency to taste (macOS 26 Liquid Glass build only).
- Lighter-tinted themes (Luxe / Railgun / Sky) automatically use **high-contrast near-black ink** for text, ticks, and numerals; darker/mid tints (Classic / Midnight / Gu Feng) use pure white.
- The `tokenclock` CLI selects the matching variant from the `sw_vers` major version — no manual guessing.

---

## 🔌 Local API server

TokenClock starts a local `NWListener` HTTP server:

```
GET http://127.0.0.1:9988/api/usage          # live aggregated usage (today's totals / per-tool / session detail)
GET http://127.0.0.1:9988/api/history?days=30 # daily snapshots for the last N days (max 30, for trend charts)
```

It returns JSON usage data, handy for external scripts / dashboards. It listens on loopback only and is **never exposed externally**.

---

## 🔒 Privacy

- All usage data is **read locally** from the log files each AI tool writes itself — TokenClock **uploads no token / session data**.
- The local API server listens only on `127.0.0.1` and is opt-in.
- Weather uses approximate IP geolocation or a city you pick, solely to show current conditions and a forecast.

---

## 🛣 Roadmap

- [ ] Support more AI coding tools (keep extending the detector)
- [ ] Signed / notarized release builds (`.app`) — currently shipping unsigned via GitHub; this needs an Apple Developer account ($99/yr) and isn't currently planned — open to sponsorship / volunteers
- [ ] Richer history stats and charts

---

## 📦 Tech stack

| | |
|---|---|
| **Language** | Swift 6 (`-parse-as-library`) |
| **UI** | SwiftUI + AppKit (lock-free dual-`NSPanel` architecture) |
| **Build** | Swift Package Manager (no `.xcodeproj`) |
| **Platforms** | macOS 26 SDK (`main` branch) / macOS 12 SDK (`normal` branch) |
| **i18n** | Custom `L10n` engine (zh-Hans / zh-Hant / en, no `.xcstrings`) |
| **Size** | ~12,400 lines of Swift |

---

## 📄 License

TokenClock is open-sourced under the **[GPL v3 License](LICENSE)** — © 2026 Neo-Isshin. You are free to use, distribute, and modify it, but any distributed or modified derivative works must also be open-sourced under the GPL v3 License.

---

## 🙏 Acknowledgments

- TokenClock exists thanks to the many excellent AI coding tools and their communities. Thanks to these tools for writing token usage to local logs, making unified visualization possible..

- The Liquid Glass refraction effect (macOS 26+) is powered by reverse-engineered macOS private API `NSGlassEffectView`. Special thanks to the pioneering open-source project **[electron-liquid-glass](https://github.com/Meridius-Labs/electron-liquid-glass)** (maintained by Meridius-Labs).

- The dial designs draw inspiration from traditional mechanical watches and pop culture (the Gu Feng / Railgun themes).
---

<div align="center">

<h3>⭐ Finding TokenClock useful?</h3>

**A Star means a lot — it's what keeps the project going 🚀**

[![Star](https://img.shields.io/badge/⭐-Star%20on%20GitHub-181717?style=for-the-badge&logo=github&logoColor=white)](https://github.com/Neo-Isshin/TokenClock)

</div>

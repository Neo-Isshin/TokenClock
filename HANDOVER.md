# TokenClock - Handover Document

> Last updated: 2026-06-24

## Project Overview

TokenClock is a macOS floating desktop clock that displays real-time AI coding tool token usage. It runs as a borderless panel in the corner of the screen, showing a clock face with today's total token consumption overlaid. Clicking the clock expands a detail panel with per-tool breakdowns, session lists, and weather forecast.

**Tech stack**: Swift 6, SwiftUI + AppKit, SwiftPM (no Xcode project), macOS 15+
**Repository**: `http://localhost:3000/nxc8335/TokenClock.git` (gitea)
**Build**: `swift build` / `swift build -c release`
**Run**: `.build/debug/TokenClock` or `.build/release/TokenClock`

## Architecture

```
TokenClockApp (main.swift) → @NSApplicationDelegateAdator → AppDelegate
  ├── FloatingPanel (NSPanel, borderless, clock face)
  │     └── ClockContentView (SwiftUI: clock + overlays)
  │           └── ClockFaceView (Canvas-drawn analog clock)
  ├── DropdownPanel (NSPanel, detail view, appears below clock)
  │     └── DetailDropdownView (tool breakdown + weather forecast)
  ├── ViewModel (ObservableObject, all state)
  │     ├── 14x UsageService instances (one per AI tool)
  │     ├── WeatherService
  │     └── Timers (clock 1s, data 30s, weather 5min)
  ├── SettingsView (separate NSWindow)
  └── UsageAPIServer (NWListener on :9988, JSON endpoint)
```

### Key Design Decisions

- **Dual NSPanel architecture**: Clock and dropdown are separate `NSPanel` windows (not one resizable window). The dropdown is positioned below the clock frame. This avoids layout jumps during expand/collapse.
- **Service pattern**: Each AI tool has its own `*UsageService` class with `fullScan()`, `incrementalScan()`, `todayUsage()`, `todaySessions()` methods. All services are non-sendable classes used from the main actor via ViewModel.
- **JSONL streaming parser**: Services read JSONL log files with `InputStream` (64KB buffer), parsing line-by-line. Parsed results are cached in memory with file size tracking for change detection.
- **Local-only API**: `UsageAPIServer` exposes `GET /api/usage` on port 9988 for external integrations.
- **No .lproj/.xcstrings**: Localization uses a custom `L10n` singleton with inline string dictionaries (3 languages: zh-Hans, zh-Hant, en). No Xcode localization files.

## Supported AI Tools

14 tools total — original 5 (committed `6b48803`, 2026-05-28) plus 9 new (committed `4145b30`, 2026-06-24). All services follow the same protocol (`fullScan`, `incrementalScan`, `todayUsage`, `currentHourTokens`, `recentUsage`, `isActive`). See `docs/TOOL_SCHEMA_ANALYSIS.md` for JSONL field-level details per tool.

| Tool | Service | Data Source (default) | Env Var |
|------|---------|----------------------|---------|
| OpenClaw | `OpenClawUsageService` | `~/.openclaw/` | `OPENCLAW_HOME` |
| Claude Code | `ClaudeCodeUsageService` | `~/.claude/` | `CLAUDE_CONFIG_DIR` |
| Gemini CLI | `GeminiUsageService` | `~/.gemini/` | `GEMINI_HOME` |
| Codex | `CodexUsageService` | `~/.codex/` | `CODEX_HOME` |
| Hermes | `HermesUsageService` | `~/.hermes/` | `HERMES_HOME` |
| **OpenCode** | `OpenCodeUsageService` | `~/.local/share/opencode/` | `OPENCODE_HOME` |
| **Qwen Code** | `QwenCodeUsageService` | `~/.qwen/` | `QWEN_HOME` |
| **Copilot** | `CopilotUsageService` | `~/.copilot/` | `COPILOT_HOME` |
| **Grok** | `GrokUsageService` | `~/.grok/` | `GROK_HOME` |
| **Aider** | `AiderUsageService` | `~/.aider/analytics.jsonl` | `AIDER_HOME` |
| **Antigravity** | `AntigravityUsageService` | `~/.gemini/antigravity-cli/` | `ANTIGRAVITY_HOME` |
| **Cline** | `ClineUsageService` | `~/Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/` | `CLINE_HOME` |
| **Continue** | `ContinueUsageService` | `~/.continue/` | `CONTINUE_HOME` |
| **Cursor Agent** | `CursorAgentUsageService` | `~/.cursor/` | `CURSOR_AGENT_HOME` |

**Path resolution priority** (in `PathConfig`): UserDefaults custom path > env var > default path. `PathDetector` runs on first launch (`TC_hasRunInitialDetection` flag) to auto-pick the right candidate when the default doesn't exist.

> **Note**: New tools (rows marked in bold) have not yet been runtime-verified against real log files on this machine. Schema analysis was done from documentation; token formulas may need adjustment after first real-world test (especially for tools with unusual formats like Cline's VSCode globalStorage path and Aider's analytics-mode opt-in).

### Codex Token Counting Algorithm (critical, rewritten multiple times)

Codex JSONL files contain `token_count` events wrapped in `event_msg` payloads:

```json
{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":...,"cached_input_tokens":...,"output_tokens":...,"reasoning_output_tokens":...,"total_tokens":12345},"last_token_usage":{...}}}}
```

**Key difference from other services**: Codex's `input_tokens` ALREADY includes `cached_input_tokens`. Other services (Claude Code, OpenClaw, etc.) keep these as separate, mutually exclusive fields.

**Token formula by service**:

| Service | Formula | Notes |
|---------|---------|-------|
| Codex | `(total_tokens + reasoning_output_tokens)` delta per event | `input_tokens` already includes cached |
| OpenClaw | `input + output + cacheRead` per event | Fields are mutually exclusive |
| Claude Code | `inputTokens + outputTokens + cacheRead` per event | Fields are mutually exclusive |
| Gemini | `input + output + cached` per event | Only one cache field |
| Hermes | `inputTokens + outputTokens + cacheRead` per session | Fields are mutually exclusive |

**cacheWrite / cache_creation is excluded** from all services because it's already counted as part of the original input tokens (infrastructure overhead, not model processing).

**Per-event date attribution**: Codex sessions can span multiple days (a single JSONL file with events across May 24-26). Each delta must be attributed to the date of that specific event's timestamp, NOT all to the last event's date. Other services already do per-event attribution natively since each event has its own independent token count.

**Session tokens**: Codex session display tokens come from JSONL parsing (via `sessionTokensByDate`), NOT from SQLite `threads.tokens_used` (which includes cached tokens and uses a different counting method).

**File growth detection**: Codex appends to existing JSONL files. The `jsonlCache` stores file sizes; `incrementalScan()` triggers `fullScan()` if any cached file has grown.

## Source File Map

```
Sources/TokenClock/
├── main.swift                          # App entry point (SwiftUI @main)
├── AppDelegate.swift                   # NSApplicationDelegate, panels, menus, settings window
├── ViewModel.swift                     # Central state: tools, timers, data refresh, themes
├── L10n.swift                          # Localization engine (3 languages)
├── FloatingPanel.swift                 # NSPanel subclass for clock window
├── Models/
│   ├── TokenUsage.swift                # ToolUsage, SessionInfo, WeatherInfo, DateHelper
│   ├── ClockFaceTheme.swift            # Theme enum with visual properties + custom themes
│   └── CustomThemeConfig.swift         # Persisted custom theme configuration
├── Views/
│   ├── ClockFaceView.swift             # Canvas-drawn analog clock (multiple hand styles)
│   ├── ClockContentView.swift          # Clock + overlaid token/date/weather info
│   ├── DetailDropdownView.swift        # Expanded detail panel (tool list, sessions, forecast)
│   ├── SettingsView.swift              # Settings window (paths, theme editor, options)
│   └── ThemePickerView.swift           # Clock face theme selector
└── Services/
    ├── UsageServiceProtocol.swift      # Shared types: DayUsage, HourlyUsage, RecentEntry
    ├── UsageAggregator.swift           # Aggregation helpers (totals, top tools, rate emoji)
    ├── MockUsageService.swift          # Initial placeholder data generator
    ├── OpenClawUsageService.swift      # OpenClaw JSONL parser
    ├── ClaudeCodeUsageService.swift    # Claude Code JSONL + SQLite parser
    ├── GeminiUsageService.swift        # Gemini CLI JSONL parser
    ├── CodexUsageService.swift         # Codex JSONL + SQLite parser (see algorithm notes above)
    ├── HermesUsageService.swift        # Hermes JSONL parser
    ├── OpenCodeUsageService.swift      # OpenCode JSONL parser (NEW)
    ├── QwenCodeUsageService.swift      # Qwen Code JSONL parser (NEW)
    ├── CopilotUsageService.swift       # GitHub Copilot CLI JSONL parser (NEW)
    ├── GrokUsageService.swift          # Grok CLI JSONL parser (NEW)
    ├── AiderUsageService.swift         # Aider analytics JSONL parser (NEW, requires --analytics-log)
    ├── AntigravityUsageService.swift   # Antigravity CLI JSONL parser (NEW)
    ├── ClineUsageService.swift         # Cline (VSCode ext.) globalStorage parser (NEW)
    ├── ContinueUsageService.swift      # Continue (VSCode ext.) JSONL parser (NEW)
    ├── CursorAgentUsageService.swift   # Cursor agent JSONL parser (NEW)
    ├── PathConfig.swift                # Tool log path configuration (UserDefaults + env vars)
    ├── PathDetector.swift              # Auto-detect tool log paths on first launch
    ├── WeatherService.swift            # Weather API (ip-based location or city selection)
    └── UsageAPIServer.swift            # Local HTTP server (:9988)
```

Total: ~10300 lines of Swift (was ~9000 before the 9-tool expansion).

## Recent Work History

| Commit | Description |
|--------|-------------|
| `4145b30` | Expand tool coverage to 14 monitors (add 9 new services, path config, settings UI, schema doc) |
| `6b48803` | Use last_token_usage for Codex token counting |
| `9003eb3` | Update HANDOVER.md with token formula table and multi-day session notes |
| `96887b4` | Fix token counting: exclude cacheWrite, Codex per-event date attribution, resize grip visibility |
| `dffa356` | Fix Codex: use total_token_usage deltas instead of last_token_usage sums |
| `4a52993` | Split dropdown into separate NSPanel for resize stability |
| `6a34569` | Improve expanded panel resizing |
| `b584b7e` | Stabilize clock expansion layout |
| `09451bf` | Fix tap reliability (contentShape), expansion jump (opacity transition), always-on-top persistence |
| `33f8dd0` | Rewrite Codex service to use JSONL incremental data |
| `3d8da5f` | Localize date format and city name |
| `ded1cfc` | Add multi-language support (zh-Hans/zh-Hant/en) |

## Known Issues & Gotchas

1. **Dual instance risk**: Using `SMAppService.mainApp.register()` for launch-at-login creates a launchd service with `OnDemand=false`. Running `.build/debug/TokenClock &` from CLI creates a second instance. Always `killall TokenClock` first, then let launchd restart it.
2. **Codex JSONL format**: Codex wraps events in `{"type":"event_msg","payload":{...}}`. The filter `"type":"token_count","info"` must match the inner payload, not the outer wrapper. If Codex changes its format, this filter will break silently.
3. **Codex `input_tokens` includes cached**: Unlike other services where fields are mutually exclusive, Codex's `input_tokens` already contains `cached_input_tokens`. The formula must be `total_tokens + reasoning_output_tokens` (not `total_tokens - cached_input_tokens`). Getting this wrong causes either 10x overcount or 10x undercount.
4. **Codex multi-day sessions**: A single Codex JSONL file can span multiple days. Token deltas must be attributed per-event by timestamp. Attributing all to `lastDateKey` causes ~3x overcount on the last day.
5. **SwiftUI + NSPanel animation conflict**: SwiftUI `.animation()` competes with NSPanel's `NSAnimationContext` frame animation. The current approach uses `.transition(.opacity)` (not `.move`) to avoid layout shifts. Do NOT add `.animation()` to the ZStack containing the clock + dropdown.
6. **Tap gesture**: The tap gesture is on the ZStack in `ClockContentView` with `.contentShape(Rectangle())`. Individual overlay Text/Canvas views must NOT have their own gestures, or they'll intercept taps.
7. **Localization**: `L10n.swift` is a singleton. Language changes propagate through `@Published var language` on ViewModel. The right-click menu is rebuilt manually via `setupRightClickMenu()` on language change (not reactive).

## Configuration Storage

All settings use `UserDefaults` with `TC_` prefix:
- `TC_alwaysOnTop` (Bool, default true)
- `TC_selectedTheme` (String, ClockFaceTheme rawValue)
- `TC_rateWindow` (Int, minutes for recent activity window, default 10)
- `TC_activeCustomThemeId` (String, UUID)
- `TC_language` (String, managed by L10n)
- Tool paths: `TC_openclawPath`, `TC_claudeCodePath`, `TC_geminiPath`, `TC_codexPath`, `TC_hermesPath`
- Window position: `TokenClockWindowPositionX/Y`
- `TC_hasRunInitialDetection` (Bool, first-launch path auto-detection)

## Features

- Analog clock face with 4 hand styles (round, tapered, lance, sword)
- 6 built-in themes + custom theme editor with color picker
- 5 AI tool monitors with real-time token tracking
- Per-tool session breakdown with SQLite integration
- Weather display (auto IP geolocation or manual city)
- 8 timezone options
- 3 languages (zh-Hans, zh-Hant, en)
- Right-click context menu for all settings
- Launch at login (SMAppService)
- Local API server (port 9988)
- Expandable detail panel with resize grip

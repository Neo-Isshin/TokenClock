# TokenClock - Handover Document

> Last updated: 2026-05-23

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
  │     ├── 5x UsageService instances (one per tool)
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

| Tool | Service | Data Source | Key File |
|------|---------|------------|----------|
| OpenClaw | `OpenClawUsageService` | JSONL session files | `~/.openclaw/sessions/` |
| Claude Code | `ClaudeCodeUsageService` | JSONL + SQLite | `~/.claude/projects/` |
| Gemini CLI | `GeminiUsageService` | JSONL session files | `~/.gemini/` |
| Codex | `CodexUsageService` | JSONL + SQLite threads | `~/.codex/` |
| Hermes | `HermesUsageService` | JSONL session files | `~/.hermes/` |

### Codex Token Counting Algorithm (critical, rewritten 3 times)

Codex JSONL files contain `token_count` events wrapped in `event_msg` payloads:

```json
{"type":"event_msg","payload":{"type":"token_count","info":{...},"last_token_usage":{...},"total_token_usage":{"total_tokens":12345,...}}}
```

**Correct approach** (current):
1. Filter: match lines containing `"type":"token_count","info"`
2. Extract `total_token_usage.total_tokens` from each event
3. Compute **delta** = `current_total - previous_total` (running accumulator per file)
4. Sum only positive deltas as real token usage
5. Extract `cached_input_tokens` from `last_token_usage` for cache rate calculation

**Why this works**: `total_token_usage.total_tokens` is a monotonically increasing counter per session. `last_token_usage` is NOT a reliable incremental — it overcounts by ~105% due to including cached tokens and duplicate events.

**File growth detection**: Codex appends to existing JSONL files. The `jsonlCache` stores file sizes; `incrementalScan()` triggers `fullScan()` if any cached file has grown.

## Source File Map

```
Sources/TokenClock/
├── main.swift                          # App entry point (SwiftUI @main)
├── AppDelegate.swift                   # NSApplicationDelegate, panels, menus, settings window
├── ViewModel.swift                     # Central state: tools, timers, data refresh, themes
├── L10n.swift                          # Localization engine (122 strings, 3 languages)
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
    ├── PathConfig.swift                # Tool log path configuration (UserDefaults)
    ├── PathDetector.swift              # Auto-detect tool log paths on first launch
    ├── WeatherService.swift            # Weather API (ip-based location or city selection)
    └── UsageAPIServer.swift            # Local HTTP server (:9988)
```

Total: ~9000 lines of Swift.

## Recent Work History

| Commit | Description |
|--------|-------------|
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
3. **SwiftUI + NSPanel animation conflict**: SwiftUI `.animation()` competes with NSPanel's `NSAnimationContext` frame animation. The current approach uses `.transition(.opacity)` (not `.move`) to avoid layout shifts. Do NOT add `.animation()` to the ZStack containing the clock + dropdown.
4. **Tap gesture**: The tap gesture is on the ZStack in `ClockContentView` with `.contentShape(Rectangle())`. Individual overlay Text/Canvas views must NOT have their own gestures, or they'll intercept taps.
5. **Localization**: `L10n.swift` is a singleton. Language changes propagate through `@Published var language` on ViewModel. The right-click menu is rebuilt manually via `setupRightClickMenu()` on language change (not reactive).

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

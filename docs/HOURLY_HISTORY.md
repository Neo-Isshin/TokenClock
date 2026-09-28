# Single-day hourly historical usage

- Only Custom ranges whose normalized start/end dates match use hourly buckets.
- The view always has 24 local wall-clock buckets, 00–23. Repeated daylight-saving hours combine; a nonexistent spring-forward hour stays empty.
- Default, line, and stacked views use the same hourly data. Hover/click selects an hour; Overview returns to the day summary.
- Hourly events are persisted separately in hourly-history.sqlite. Daily history, share images, and reports retain their existing date-based behavior.
- Existing parser accounting/deduplication is reused. Metadata is added only when the source supplies an event timestamp; current-time/session-summary fallbacks are not assigned to invented hours.
- Captured providers: Codex, Claude Code, Gemini CLI, OpenClaw, Antigravity (timestamped records), Cursor Agent and Grok Bot API events, OpenCode, Qwen Code, Copilot, Continue, Grok, and ZCode where that platform supports it.
- Missing hour history, deleted source logs, unsupported session-only records (for example Hermes), or unavailable cache fields are marked partial. A larger saved daily total stays visible; it is never divided evenly over the hours.
- Parsers populate/backfill the new store during normal scans/API refreshes. No extra remote request is made by switching chart dates. Unchanged local tools are persisted at most once per minute (full scans bypass throttling).
- Existing model and cache fields are retained when available. Unknown models/prices/cache counts remain explicitly unknown.
- SQL writes replace a tool's covered days atomically rather than incrementing counters; rescanning cannot double-count. Empty/failed input cannot wipe an earlier successful capture.

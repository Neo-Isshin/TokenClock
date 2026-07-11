# TokenClock — Tool Schema Analysis

> Last updated: 2026-07-10
>
> **实现状态对账（2026-07-10）：** 下表原为可行性分析。如今 **所有 P0–P3 工具 + Cline + Continue 都已落地为 `Sources/TokenClock/Services/*UsageService.swift`**（共 14 个，~4000 行）。测试覆盖刚起步——目前仅 Claude Code 有解析器单测（`Tests/TokenClockTests/ClaudeCodeUsageServiceTests.swift`，确立 fixture 模式），其余 13 个待按同模式补单测。下表的 "Priority / Ready / Needs verification" 列保留作历史，实际状态见新增的 **Impl** 列。

## Schema Standardization Template

Each tool analysis follows this structure:

| Field | Description |
|-------|-------------|
| **Tool** | Tool name and version |
| **Data Source** | File path / DB location |
| **Format** | JSONL / SQLite / Protobuf / Mixed |
| **Scan Pattern** | fullScan / incremental strategy |
| **Token Fields** | Available token fields and their semantics |
| **Token Formula** | How to compute effective tokens |
| **Date Attribution** | Per-event or per-session |
| **Cache Semantics** | Whether input_tokens includes cached |
| **Session Source** | Where session list data comes from |
| **Feasibility** | Can TokenClock support this tool? |

---

## Supported Tools

### OpenClaw

| Field | Value |
|-------|-------|
| **Tool** | OpenClaw |
| **Data Source** | `~/.openclaw/sessions/` JSONL files |
| **Format** | JSONL (streaming) |
| **Scan Pattern** | fileCache + modDate incremental |
| **Token Fields** | `input`, `output`, `cacheRead`, `cacheWrite` |
| **Token Formula** | `input + output + cacheRead` |
| **Date Attribution** | Per-event via timestamp field |
| **Cache Semantics** | `input` EXCLUDES cached (mutually exclusive) |
| **Session Source** | JSONL session files |
| **Feasibility** | ✅ Fully supported |

### Claude Code

| Field | Value |
|-------|-------|
| **Tool** | Claude Code |
| **Data Source** | `~/.claude/projects/*/<sessionId>.jsonl` |
| **Format** | JSONL (streaming) |
| **Scan Pattern** | fileCache + modDate incremental |
| **Token Fields** | `input_tokens`, `output_tokens`, `cache_read_input_tokens`, `cache_creation_input_tokens` |
| **Token Formula** | `inputTokens + outputTokens + cacheRead` |
| **Date Attribution** | Per-event via timestamp field |
| **Cache Semantics** | `input_tokens` EXCLUDES cached (mutually exclusive) |
| **Session Source** | `~/.claude/sessions/*.json` + find matching JSONL |
| **Feasibility** | ✅ Fully supported |

### Gemini CLI

| Field | Value |
|-------|-------|
| **Tool** | Gemini CLI |
| **Data Source** | `~/.gemini/tmp/*/chats/session-*.json` or `.jsonl` |
| **Format** | JSON (legacy) + JSONL (current, preferred) |
| **Scan Pattern** | fileCache + modDate incremental |
| **Token Fields** | `tokens.input`, `tokens.output`, `tokens.cached`, `tokens.thought` (API `usageMetadata`: `promptTokenCount` / `candidatesTokenCount` / `cachedContentTokenCount` / `thoughtsTokenCount`) |
| **Token Formula** | `input + output + thought` (do NOT add `cached` — already included in `input`/`promptTokenCount`) |
| **Date Attribution** | Per-event via timestamp field |
| **Cache Semantics** | `input` INCLUDES `cached` (mutually inclusive, like Codex — adding `cached` double-counts) |
| **Session Source** | JSONL/JSON session files |
| **Feasibility** | ✅ Fully supported |

### Codex

| Field | Value |
|-------|-------|
| **Tool** | Codex CLI |
| **Data Source** | `~/.codex/sessions/*/rollout-*.jsonl` |
| **Format** | JSONL (streaming) + SQLite (`state_5.sqlite`) |
| **Scan Pattern** | jsonlCache + fileSize change detection → fullScan |
| **Token Fields** | `last_token_usage.total_tokens`, `reasoning_output_tokens`, `cached_input_tokens` |
| **Token Formula** | `total_tokens + reasoning_output_tokens` per event |
| **Date Attribution** | Per-event via timestamp (sessions can span multiple days) |
| **Cache Semantics** | `input_tokens` INCLUDES `cached_input_tokens` |
| **Session Source** | SQLite `threads` table + JSONL token data |
| **Feasibility** | ✅ Fully supported |

### Hermes

| Field | Value |
|-------|-------|
| **Tool** | Hermes Agent |
| **Data Source** | `~/.hermes/state.db` |
| **Format** | SQLite |
| **Scan Pattern** | modTime-based full rescan (WAL-aware) |
| **Token Fields** | `input_tokens`, `output_tokens`, `cache_read_tokens`, `cache_write_tokens` |
| **Token Formula** | `inputTokens + outputTokens + cacheRead` |
| **Date Attribution** | Per-session via `started_at` |
| **Cache Semantics** | `input_tokens` EXCLUDES cached (mutually exclusive) |
| **Session Source** | SQLite `sessions` table |
| **Feasibility** | ✅ Fully supported |

---

## New Tools Under Analysis

### OpenCode (sst/opencode)

| Field | Value |
|-------|-------|
| **Tool** | OpenCode v1.17.3 |
| **Data Source** | `~/.local/share/opencode/opencode.db` (SQLite) |
| **Format** | SQLite |
| **Scan Pattern** | TBD (likely modTime rescan like Hermes) |
| **Token Fields** | `tokens_input`, `tokens_output`, `tokens_reasoning`, `tokens_cache_read`, `tokens_cache_write`, `cost` |
| **Token Formula** | `tokens_input + tokens_output + tokens_cache_read` |
| **Date Attribution** | Per-session via `time_created` / `time_updated` (epoch ms) |
| **Cache Semantics** | TBD (fields named identically to Hermes) |
| **Session Source** | SQLite `session` table |
| **Feasibility** | ✅ **Ready to implement** — schema is clean and complete |

**Key schema details:**

```sql
-- session table token columns
tokens_input      INTEGER DEFAULT 0
tokens_output     INTEGER DEFAULT 0
tokens_reasoning  INTEGER DEFAULT 0
tokens_cache_read INTEGER DEFAULT 0
tokens_cache_write INTEGER DEFAULT 0
cost              REAL DEFAULT 0
time_created      INTEGER  -- epoch ms
time_updated      INTEGER  -- epoch ms
model             TEXT     -- JSON: {"id":"big-pickle","providerID":"opencode"}
```

### Cursor Agent

| Field | Value |
|-------|-------|
| **Tool** | Cursor IDE + Cursor Agent CLI (same account system) |
| **Data Source** | Cursor official usage API + IDE's `state.vscdb` for auth token |
| **Format** | HTTPS POST to `https://cursor.com/api/dashboard/get-filtered-usage-events` |
| **Scan Pattern** | Poll every 60s+ (throttled), full rescan on `fullScan`, partial on `incrementalScan` |
| **Token Fields** | Per-event `tokenUsage`: `inputTokens`, `outputTokens`, `cacheReadTokens`, `cacheWriteTokens`, `totalCents` |
| **Token Formula** | `input + output + cache_read + cache_write` (per-event; cost tracked separately in cents) |
| **Date Attribution** | Per-event via `timestamp` (Unix ms, from API response) |
| **Cache Semantics** | All four fields distinct, all added (cache_write is billable on Cursor) |
| **Session Source** | API doesn't expose sessions; events grouped by model |
| **Feasibility** | ✅ **Fully supported** (zero user configuration) |

**Auth flow (automatic):**

1. Read `cursorAuth/accessToken` from Cursor IDE's local SQLite:
   `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`
2. Extract userId from token:
   - If format is `user_XXXXX::JWT`, split on `::`
   - If pure JWT (3 dot-separated parts), base64-decode payload and regex `user_[A-Za-z0-9]+` from `sub`
3. Build cookie: `WorkosCursorSessionToken=user_XXXXX%3A%3A<jwt>` (URL-encode `::` as `%3A%3A`)

**API request:**

```http
POST /api/dashboard/get-filtered-usage-events HTTP/1.1
Host: cursor.com
Content-Type: application/json
Cookie: WorkosCursorSessionToken=user_XXX%3A%3A<jwt>

{"teamId": 0, "startDate": "<ms>", "endDate": "<ms>", "page": 1, "pageSize": 200}
```

**API response shape:**

```json
{
  "usageEventsDisplay": [{
    "timestamp": "1781258399219",
    "model": "composer-2.5-fast",
    "kind": "USAGE_EVENT_KIND_CUSTOM_SUBSCRIPTION",
    "customSubscriptionName": "free",
    "isTokenBasedCall": true,
    "tokenUsage": {
      "inputTokens": 12069,
      "outputTokens": 83,
      "cacheReadTokens": 544,
      "totalCents": 3.77
    },
    "requestsCosts": 0.9,
    "usageBasedCosts": "-"
  }]
}
```

**Verified** (2026-06-25 against real account): returns full per-event token + cost breakdown, works for any time range.

**Why cursor's local files alone don't work:**

- `state.vscdb`: `tokenCount` field exists but always `{"inputTokens": 0, "outputTokens": 0}`
- `chats/*/store.db`: protobuf blobs contain **input prompt token budget estimates** (not actual API usage)
- `agent-transcripts/*.jsonl`: role + message text only, no usage fields
- `ai-tracking/ai-code-tracking.db`: file-level AI attribution, not token counts

The API is the only authoritative source. Token is auto-refreshed by Cursor IDE; if our request returns 401/403 we re-read state.vscdb on next scan.

**Previous approach (deprecated):** Hook script at `~/.cursor/hooks/log-token-usage.sh` captured `afterAgentResponse` events. Removed in favor of API polling which gives historical data + cost + model name without user setup.

### Antigravity IDE

| Field | Value |
|-------|-------|
| **Tool** | Antigravity IDE (Electron, Cursor-like) + antigravity-claude-proxy 2.8.0 |
| **Data Source** | `~/.gemini/antigravity/conversations/*.pb` (encrypted) |
| **Format** | Encrypted protobuf (Shannon entropy 8.00 = fully random) |
| **Scan Pattern** | N/A |
| **Token Fields** | None accessible (encrypted) |
| **Token Formula** | N/A |
| **Date Attribution** | N/A |
| **Cache Semantics** | N/A |
| **Session Source** | None accessible |
| **Feasibility** | ❌ **Not feasible** — session files are encrypted, no public API |

**Investigation findings (verified 2026-06-25):**

- `~/.gemini/antigravity/conversations/*.pb` files: 3 files, 132-364KB each
- Shannon entropy: 8.00 bits/byte (max — confirmed fully encrypted, not plaintext protobuf)
- ASCII printable ratio: 36.9% (random noise, not structured data)
- Compare: Antigravity **CLI** .db files start with `53514c697465...` ("SQLite format 3") — plaintext

**Why encryption:**

Antigravity IDE is a closed commercial product. Encrypting sessions prevents:
- IP extraction (prompt templates, model behavior)
- Subscription metering bypass
- Reverse engineering

**Paths explored (none viable):**
- `~/Library/Application Support/Antigravity/User/globalStorage/state.vscdb`: empty token fields
- `~/.gemini/antigravity-browser-profile/`: browser cache only
- No public usage API documented

> **Conclusion**: Antigravity IDE is genuinely unsupported without an official API. Use Antigravity CLI (separate product) which works fine via SQLite parsing.

### Antigravity CLI (agy)

| Field | Value |
|-------|-------|
| **Tool** | Antigravity CLI (agy) v1.0.6 (Go binary) |
| **Data Source** | `~/.gemini/antigravity-cli/conversations/*.db` (SQLite) |
| **Format** | SQLite + nested protobuf blobs in two columns |
| **Scan Pattern** | per-DB modTime, dedup by telemetry `field 11` (tracking_id) |
| **Token Fields** | Telemetry protobuf: `field 1`=input, `field 2`=output, `field 3`=cache_read, `field 9`=thoughts, `field 10`=tool, `field 11`=tracking_id |
| **Token Formula** | `field 1 + field 2 + field 3 + field 9 + field 10` (do NOT include `field 5` — it's cumulative total_prompt that double-counts input) |
| **Date Attribution** | Per-row, from `metadata` protobuf column: `outer.field 1 → inner.field 1` (Unix seconds) |
| **Cache Semantics** | `field 3` is cache_read (discounted); no separate cache_write field observed |
| **Session Source** | One SQLite DB per session, filename is session UUID |
| **Feasibility** | ✅ **Supported** (service implemented, verified against real data) |

**Database schema (per-session .db file):**

```
steps table:
  idx INTEGER
  step_type INTEGER
  status INTEGER
  metadata BLOB          ← protobuf with timestamp
  step_payload BLOB      ← protobuf with telemetry
  ...
```

**protobuf structure:**

- `metadata` column (timestamp):
  - `outer.field 1` (length-delimited, 12B) — timestamp wrapper
    - `inner.field 1` (varint) — Unix seconds
    - `inner.field 2` (varint) — nanoseconds
- `step_payload` column (telemetry):
  - `outer.field 5` — step wrapper
    - `inner.field 9` — telemetry block
      - `field 1`: input tokens (new, non-cached, typically ~1020)
      - `field 2`: output tokens (highly variable, 29–200K+)
      - `field 3`: cache_read tokens (typically <1K)
      - `field 5`: cumulative total_prompt (DO NOT add — includes history + fields 1 & 3)
      - `field 6`: constant 24 (unknown meaning, possibly model version)
      - `field 9`: thoughts/reasoning tokens
      - `field 10`: tool tokens
      - `field 11`: tracking_id string (for dedup)

**Verification (3 local .db files, 141 telemetry blocks):**

| Algorithm | Total tokens | Today's tokens |
|-----------|-------------|----------------|
| Original (wrong fields 2/3/5/9/10) | 12,008,670 | 12,008,670 (all attributed to today) |
| Corrected (fields 1/2/3/9/10 + metadata ts) | 1,572,822 | 0 (correctly distributed across Jun 12–22) |

Original algorithm over-counted by **7.64×** due to adding cumulative field 5.

### Trae CLI (trae-agent)

| Field | Value |
|-------|-------|
| **Tool** | Trae Agent (bytedance/trae-agent) |
| **Data Source** | N/A (uninstalled) |
| **Format** | N/A |
| **Scan Pattern** | N/A |
| **Token Fields** | N/A — research project, proxies to external LLMs |
| **Token Formula** | N/A |
| **Date Attribution** | N/A |
| **Cache Semantics** | N/A |
| **Session Source** | N/A |
| **Feasibility** | ❌ **Not feasible** — no local token logging |

**Note:** Trae CLI (open-source agent) ≠ Trae IDE (commercial product). Trae IDE may store token data locally, but Trae CLI does not.

### Trae CLI (trae-agent)

| Field | Value |
|-------|-------|
| **Tool** | Trae Agent (bytedance/trae-agent) |
| **Data Source** | N/A (uninstalled) |
| **Format** | N/A |
| **Scan Pattern** | N/A |
| **Token Fields** | N/A — research project, proxies to external LLMs |
| **Token Formula** | N/A |
| **Date Attribution** | N/A |
| **Cache Semantics** | N/A |
| **Session Source** | N/A |
| **Feasibility** | ❌ **Not feasible** — no local token logging |

**Note:** Trae CLI (open-source agent) ≠ Trae IDE (commercial product). Trae IDE may store token data locally, but Trae CLI does not.

---

## Summary Matrix

Impl = 实现状态（`*UsageService.swift` 行数；✓tested = 有解析器单测）。

| Tool | Local Token Data | TokenClock Feasibility | Impl | 原 Priority |
|------|-----------------|----------------------|------|-------------|
| OpenClaw | ✅ JSONL | ✅ Supported | ✅ 442 | — |
| Claude Code | ✅ JSONL | ✅ Supported | ✅ 340 ✓tested | — |
| Gemini CLI | ✅ JSONL | ✅ Supported | ✅ 404 | — |
| Codex | ✅ JSONL + SQLite | ✅ Supported | ✅ 319 | — |
| Hermes | ✅ SQLite | ✅ Supported | ✅ 223 | — |
| **OpenCode** | ✅ **SQLite (complete)** | ✅ **Supported** | ✅ 214 | ~~P0~~ done |
| **Cursor Agent** | ✅ **Official usage API** | ✅ **Supported** (zero config) | ✅ 313 | — |
| **Antigravity CLI (agy)** | ✅ **SQLite + protobuf telemetry** | ✅ **Supported** | ✅ 343 | — |
| **Cline** | ✅ VSCode globalStorage | ✅ Supported | ✅ 188 | (新) |
| **Continue** | ✅ ~/.continue JSONL/SQLite | ✅ Supported | ✅ 255 | (新) |
| **Qwen Code** | ✅ Gemini fork | ✅ Supported | ✅ 301 | ~~P1~~ done |
| **Grok Build** | ✅ | ✅ Supported | ✅ 212 | ~~P2~~ done |
| **Copilot CLI** | ✅ | ✅ Supported | ✅ 294 | ~~P2~~ done |
| **Aider** | ✅ | ✅ Supported | ✅ 129 | ~~P3~~ done |
| Antigravity IDE | ❌ Not persisted | ❌ Not feasible | — | — |
| Trae CLI | ❌ Not persisted | ❌ Not feasible | — | — |

> **下一步（测试）：** 对 Cline / Continue / OpenCode / Qwen / Grok / Copilot / Aider / Antigravity 等 13 个 service 按 `ClaudeCodeUsageServiceTests` 的模式补解析器单测（fixture + PathConfig.setXxxPath 重定向 + token 公式断言）。

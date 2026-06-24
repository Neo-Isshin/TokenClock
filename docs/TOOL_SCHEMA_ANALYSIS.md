# TokenClock — Tool Schema Analysis

> Last updated: 2026-06-24

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
| **Token Fields** | `tokens.input`, `tokens.output`, `tokens.cached` |
| **Token Formula** | `input + output + cached` |
| **Date Attribution** | Per-event via timestamp field |
| **Cache Semantics** | `input` EXCLUDES cached (mutually exclusive) |
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
| **Tool** | Cursor Agent CLI 2026.06.04 + Cursor IDE |
| **Data Source** | `~/.cursor/token-usage.jsonl` (written by user-installed hook) |
| **Format** | JSONL (custom, written by hook script) |
| **Scan Pattern** | fileCache + modDate incremental, dedup by `(timestamp, session_id)` |
| **Token Fields** | `input_tokens`, `output_tokens`, `cache_read_tokens`, `cache_write_tokens` (hook script tries multiple field-name variants from Cursor's payload) |
| **Token Formula** | `input + output + cache_read + cache_write` |
| **Date Attribution** | Per-event via `timestamp` field (Unix seconds, written by hook) |
| **Cache Semantics** | Distinct fields, all four are added (cache_write included because Cursor bills for it) |
| **Session Source** | Same JSONL file, grouped by `session_id` field |
| **Feasibility** | ⚠️ **Feasible with user setup** — requires installing hook script |

**Architecture (workaround for cloud-only billing):**

Cursor's `TokenUsage` protobuf flows through in-memory hooks (`afterAgentResponse`, `stop`) but is never persisted to disk by Cursor itself. TokenClock solves this by shipping a hook script that the user installs:

1. Place `log-token-usage.sh` at `~/.cursor/hooks/log-token-usage.sh` (reads stdin JSON, extracts `tokenUsage`, appends to JSONL)
2. Register in `~/.cursor/hooks.json` for `afterAgentResponse` and `stop` events
3. TokenClock reads `~/.cursor/token-usage.jsonl`

Without the hook installed, `token-usage.jsonl` stays empty and the service reports 0 tokens (graceful degradation).

**Why cursor's own files don't have tokens:**

- `state.vscdb`: `tokenCount` field exists but always `{"inputTokens": 0, "outputTokens": 0}`
- `state.vscdb`: `usageData` field exists but always `{}`
- `chats/*/store.db`: protobuf blobs contain **input prompt token budget estimates** (not actual API usage)
- `agent-transcripts/*.jsonl`: role + message text only, no usage fields
- `ai-tracking/ai-code-tracking.db`: file-level AI attribution, not token counts
- No accessible API endpoint for usage history

### Antigravity IDE

| Field | Value |
|-------|-------|
| **Tool** | Antigravity IDE (Electron, Cursor-like) + antigravity-claude-proxy 2.8.0 |
| **Data Source** | `~/Library/Application Support/Antigravity/User/globalStorage/state.vscdb` |
| **Format** | SQLite (ItemTable, VS Code compatible) |
| **Scan Pattern** | N/A |
| **Token Fields** | None found |
| **Token Formula** | N/A |
| **Date Attribution** | N/A |
| **Cache Semantics** | N/A |
| **Session Source** | None found |
| **Feasibility** | ❌ **Not feasible** — same architecture as Cursor IDE, no token data persisted locally |

**Investigation findings:**

- `state.vscdb` (ItemTable): Has `antigravityUnifiedStateSync.*` keys but none contain token usage
- `modelCredits`: key exists but value is empty
- `trajectorySummaries`: key exists but value is empty

> **Note**: The CLI version of Antigravity (below) IS supported via SQLite parsing. The IDE version would need a similar hook-based workaround as Cursor Agent, but no such hook has been written yet.

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

| Tool | Local Token Data | TokenClock Feasibility | Priority |
|------|-----------------|----------------------|----------|
| OpenClaw | ✅ JSONL | ✅ Supported | — |
| Claude Code | ✅ JSONL | ✅ Supported | — |
| Gemini CLI | ✅ JSONL | ✅ Supported | — |
| Codex | ✅ JSONL + SQLite | ✅ Supported | — |
| Hermes | ✅ SQLite | ✅ Supported | — |
| **OpenCode** | ✅ **SQLite (complete)** | ✅ **Ready to implement** | **P0** |
| **Cursor Agent** | ⚠️ **Via user-installed hook** | ⚠️ **Supported (hook required)** | — |
| **Antigravity CLI (agy)** | ✅ **SQLite + protobuf telemetry** | ✅ **Supported** (verified) | — |
| Antigravity IDE | ❌ Not persisted | ❌ Not feasible | — |
| Trae CLI | ❌ Not persisted | ❌ Not feasible | — |
| Qwen Code | ❓ (Gemini fork, likely similar) | ❓ Needs verification | P1 |
| Grok Build | ❓ Unknown | ❓ Needs verification | P2 |
| Copilot CLI | ❓ Unknown | ❓ Needs verification | P2 |
| Aider | ❓ Unknown | ❓ Needs verification | P3 |

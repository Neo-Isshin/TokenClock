# TokenClock — Tool Schema Analysis

> Last updated: 2026-06-11

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
| **Data Source** | N/A |
| **Format** | N/A |
| **Scan Pattern** | N/A |
| **Token Fields** | TokenUsage protobuf: `inputTokens`, `outputTokens`, `cacheWriteTokens`, `cacheReadTokens`, `totalCents` |
| **Token Formula** | N/A — data not persisted locally |
| **Date Attribution** | N/A |
| **Cache Semantics** | From protobuf schema (not verifiable from data) |
| **Session Source** | Agent transcripts at `~/.cursor/projects/*/agent-transcripts/*.jsonl` (role+message only, no tokens) |
| **Feasibility** | ❌ **Not feasible** — token data is server-side only, never written to local disk |

**Investigation findings:**

- `state.vscdb`: `tokenCount` field exists but always `{"inputTokens": 0, "outputTokens": 0}`
- `state.vscdb`: `usageData` field exists but always `{}`
- `chats/*/store.db`: protobuf blobs contain **input prompt token budget estimates** (not actual API usage)
- `agent-transcripts/*.jsonl`: role + message text only, no usage fields
- `ai-tracking/ai-code-tracking.db`: file-level AI attribution, not token counts
- TokenUsage data flows through in-memory hooks (`afterAgentResponse`) but is never persisted
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
| **Feasibility** | ❌ **Not feasible** — same architecture as Cursor, no token data persisted locally |

**Investigation findings:**

- `state.vscdb` (ItemTable): Has `antigravityUnifiedStateSync.*` keys but none contain token usage
- `modelCredits`: key exists but value is empty
- `trajectorySummaries`: key exists but value is empty

### Antigravity CLI (agy)

| Field | Value |
|-------|-------|
| **Tool** | Antigravity CLI (agy) v1.0.6 (Go binary) |
| **Data Source** | `~/.gemini/antigravity-cli/` |
| **Format** | Protobuf (.pb) conversations + JSONL transcripts |
| **Scan Pattern** | N/A |
| **Token Fields** | None found |
| **Token Formula** | N/A |
| **Date Attribution** | N/A |
| **Cache Semantics** | N/A |
| **Session Source** | `~/.gemini/antigravity-cli/conversations/*.pb` (protobuf, no token data) |
| **Feasibility** | ❌ **Not feasible** — no token usage data stored locally |

**Investigation findings:**

- `conversations/*.pb`: Protobuf-encoded dialogues, no usage_metadata/token_count fields
- `brain/*/.system_generated/logs/transcript.jsonl`: Step-level logs (step_index, source, type, content), no token fields
- `history.jsonl`: Command history only (display, timestamp, conversationId)
- Log files: "token" references are OAuth auth tokens, not usage tokens
- No chat/session database with token fields
- `~/.antigravity/`: Only has `argv.json` and `extensions/` — no session data
- `antigravity-claude-proxy`: npm package, acts as a proxy to Claude API — no local token logging

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
| Cursor Agent | ❌ Server-side only | ❌ Not feasible | — |
| Antigravity IDE | ❌ Not persisted | ❌ Not feasible | — |
| Antigravity CLI (agy) | ❌ Not persisted | ❌ Not feasible | — |
| Trae CLI | ❌ Not persisted | ❌ Not feasible | — |
| Qwen Code | ❓ (Gemini fork, likely similar) | ❓ Needs verification | P1 |
| Grok Build | ❓ Unknown | ❓ Needs verification | P2 |
| Copilot CLI | ❓ Unknown | ❓ Needs verification | P2 |
| Aider | ❓ Unknown | ❓ Needs verification | P3 |

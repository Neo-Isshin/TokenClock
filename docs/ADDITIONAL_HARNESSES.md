# Additional local harnesses

TokenClock reads these sources without launching an agent, modifying its data,
reading credentials, or requesting Keychain access. Enable tools and choose a
custom source directory in Settings. Existing users get a one-time migration
that enables only newly detected tools; later disabled selections are retained.

Pi and OMP share `PI_CODING_AGENT_DIR`. Recognizable `.pi`/`.omp` layouts are
attributed automatically; arbitrary shared-override directories must be assigned
explicitly to one tool in Settings rather than counted under both harnesses.

| Harness | Local source | Measurement |
| --- | --- | --- |
| Kilo Code | XDG data `kilo/kilo.db`; VS Code-compatible `kilocode.kilo-code/tasks/*/ui_messages.json` | Per-message tokens (CLI), completed API receipt tokens (legacy extension) |
| Pi | `~/.pi/agent/sessions/**/*.jsonl`; `PI_CODING_AGENT_DIR` | Native assistant/usage/summary receipts |
| OMP (Oh My Pi) | `~/.omp/agent`, named profiles, existing XDG `omp` roots | File-backed JSONL receipts; not remote Redis/SQL storage |
| Command Code | `~/.commandcode/projects/<project>/<session>.jsonl`, title `.meta.json` sidecars | Native entry-level usage; input is cache-inclusive |
| Freebuff | `~/.config/manicode/projects/*/chats/*/chat-messages.json`; `FREEBUFF_CONFIG_DIR` | **Completed local replies only**, not token usage or credits |

Freebuff's native transcript does not persist per-request token receipts. Its
`runState.contextTokenCount` is context occupancy, not accumulated usage;
`credits` is not tokens. Freebuff therefore uses a separate `requests` measurement
with the visible label “responses” and an explicit limitation in Settings/session
details. It is excluded from token totals, heat, model grouping, API-equivalent
cost, daily token reports and token-history import. No cloud-account aggregation
or subscription-quota support is claimed for this integration.

Accounting excludes cache reads from the default primary token value, preserves
cache writes and generation/reasoning, and supplies cache reads separately.
Current Kilo SQLite records separate visible output from reasoning; Pi output
already includes reasoning. Command Code input already includes cache read/write,
so those buckets are split before aggregation/pricing.

Only genuine event timestamps determine dates/hours: never file mtime or a
cumulative session-total counter. Stable entry IDs and canonical source paths
deduplicate replayed/forked records and overlapping roots. Malformed numeric
fields are rejected. Changed-file snapshots replace prior contributions and
deleted files are evicted. SQLite is opened read-only with a short busy timeout;
schema/read failures preserve the last complete snapshot. Token-based providers
import the retained local daily history once and maintain hourly history.

Hermes uses the bundled black-and-white portrait in all current presenters,
including when other tools use Emoji; no artwork is generated or redrawn.

## Upstream evidence

- Pi: https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/src/core/session-manager.ts
- OMP: https://github.com/can1357/oh-my-pi/blob/main/docs/session.md
- OMP paths: https://github.com/can1357/oh-my-pi/blob/main/packages/utils/src/dirs.ts
- Kilo paths: https://github.com/Kilo-Org/kilocode/blob/main/packages/core/src/global.ts
- Kilo message tokens: https://github.com/Kilo-Org/kilocode/blob/main/packages/core/src/session/runner/publish-llm-event.ts
- Command Code sessions: https://commandcode.ai/docs/sessions
- Command Code field-level check: published `command-code@1.79.2`, `dist/cli.mjs`, `toSessionUsage` and AI SDK finish handling. Downloaded for inspection, not installed/executed.
- Freebuff persistence: https://github.com/CodebuffAI/freebuff/blob/main/cli/src/utils/run-state-storage.ts
- Freebuff paths: https://github.com/CodebuffAI/freebuff/blob/main/cli/src/utils/config-dir.ts
- Freebuff context semantics: https://github.com/CodebuffAI/freebuff/blob/main/common/src/types/session-state.ts
- Hermes artwork: https://github.com/NousResearch/hermes-agent/blob/main/assets/icon-master.svg

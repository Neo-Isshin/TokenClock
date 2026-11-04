# Glass: DoH, native results, latency and new harnesses

Network results now use DOM textContent rather than layout-dependent innerText.
The hidden WebKit probe is a sibling of the native hosting view, not an unsupported
child of NSHostingView. The native regression test checks every displayed card's
text (not only hidden page values), plus the overall issue/unknown summary.

DoH checks send binary DNS-over-HTTPS POST queries to Cloudflare and Google with
per-run d0/d1 names. Their authority observations remain separate from ordinary
p0/p1/p2 DNS probes and never contaminate the system/browser resolver results.
HTTP 200 alone does not count: MIME, DNS header, ID and echoed question are checked.
Cloudflare's CHAOS whoami query additionally returns the client address of that
DoH request. Google resolver addresses / EDNS prefixes are not client-IP evidence.
URLSession HTTP proxy observations are presented separately; lack of an HTTP proxy
observation does not prove VPN bypass. Readable Chrome-family/Firefox preferences
are static configuration snapshots, not proof of a running browser's DoH mode.
Private URI paths/query values are excluded from the configuration display.

The overall summary distinguishes risk evidence, items needing review and
unconfirmed checks. A successful DoH response never becomes a blanket leak-free
verdict for other endpoints, browser extensions or VPN routing.

Model view columns:
- Token mode: Usage / Msgs / Share.
- Cost mode: API estimate / TTFT / t/s.
- The separate session view retains its Cache column.

TTFT is aggregated only from recorded request start and first-token timestamps.
ZCode supplies both fields for the same latest completed logical request. The
existing SQL request ranking and read-only access remain unchanged. Codex's
assistant-item spans and Pi's final messages do not establish these timestamps;
unknown latency is a dash, not zero or a value inferred from output speed.
The t/s denominator, concurrency attribution, ten-minute sample policy and
three-minute refresh interval are unchanged. Hover text shows measurable coverage.

Pi already had usage support; its explicit PI_CODING_AGENT_SESSION_DIR override
is now recognized without claiming OMP's selected namespace. PiG is registered
at ~/.pig/agent with the existing Pi receipt contract. DSH is registered at
$DSH_HOME/sessions (default ~/.dsh/sessions), with a settings path override.
DSH reads the latest canonical v0-v4 physical generation, supports plain JSONL
and concatenated Zstandard streams, and skips inherited fork seed events.
Assistant top-level usage wins over embedded stream usage. Same-attempt updates
replace earlier samples; retry boundaries retain separate paid attempts. DSH's
input/cache counters are disjoint. Unknown formats, corrupt or incomplete
compressed frames do not replace a good cached snapshot. Source logs are never
upgraded, repaired, rewritten or passed to an installed harness/CLI.

The macOS decoder is a bundled, locally signed arm64/x86_64 decoder-only Zstd
library; no Homebrew/CLI is required by the client. Windows/Linux compressed
packaging is outside this Glass rollout; the shared plain-reader code is portable.

Primary source contracts:
- https://www.rfc-editor.org/rfc/rfc8484.html
- https://pi.dev/docs/latest/session-format
- https://pi-in-go.dev/docs/latest/session-format/
- https://github.com/deepseek-ai/deepseek-harness/tree/master/packages/session/session-persistence-jsonl
- https://github.com/deepseek-ai/deepseek-harness/blob/master/packages/llm/token-meter/src/usage-projection.ts

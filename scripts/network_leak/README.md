# TokenClock network check

The macOS Glass launcher creates an ephemeral WebKit window only after a click.
The embedded page runs one check; subsequent checks require another click.
An external-browser page opens idle and tests that browser's own environment.
Closing the native window tears down WebKit, fetches, and ICE connections.

## Service

- Public HTTPS page/API: `https://www.ailyre.com/tokenclock/network-check/`.
- Anonymous API listener: `127.0.0.1:8798`, behind the supplied nginx location.
- Authoritative DNS: `38.64.59.9:53`, UDP and TCP, only for `probe.tokenclock.ailyre.com`.
- STUN Binding: `38.64.59.9:3478/UDP`. No TURN, forwarding, media, or recursive DNS.
- DNS records: DNS-only A `ns.tokenclock.ailyre.com → 38.64.59.9`; NS delegation
  `probe.tokenclock.ailyre.com → ns.tokenclock.ailyre.com`.
- Installation: `/opt/tokenclock-network-check`, managed by
  `tokenclock-network-check.service`. The two narrowly scoped firewall accepts
  are also present in `/etc/nftables.conf`.

Each explicit check creates a random 128-bit observation token and three unique
probe names. The authority records incoming resolver IPs in memory and returns
NXDOMAIN with zero negative-cache TTL, so probes do not open HTTPS connections.
API rows expire at 120 seconds and are purged every 15 seconds. Application
request/IP/token logs are disabled; there is no measurement database.
Cloudflare's own proxy source ranges are taken from its published `ips-v4` and
`ips-v6` lists. Only trusted proxy peers can supply `CF-Connecting-IP`; nginx
overwrites both source headers before forwarding to the loopback API.

## Result interpretation

- DNS resolver sources can be upstream resolvers, rather than the resolver IP
  configured locally. Without optional expected resolver IPs, show observations
  for review. Do not infer a leak from location or an HTTP/DNS IP difference.
- Public ICE candidates differing from the HTTPS source within the same address
  family are risk evidence, not proof of VPN failure. An unmatched address family
  needs review; no public candidate is inconclusive. mDNS/private/relay addresses
  are listed separately and do not count as a public-IP match.
- No device/media permissions, persistent browser storage, or automatic refresh.
  The client stops after at most 25 seconds, after completion, or on cancellation.

## Verification

```sh
python3 scripts/network_leak/test_server.py
node scripts/network_leak/test_probe.cjs
swift test --filter NetworkLeakEndpointTests
TOKENCLOCK_NETWORK_LIVE_TEST=1 swift test --filter NetworkLeakLiveTests
```

The opt-in live test uses real WebKit, DNS, and STUN; it also closes the window
during a second run. Use the project's documented local Xcode/SDK configuration
when building on the development Mac. `nginx -t` must pass before a reload.
Only add/modify this module's DNS names, location, service, and firewall rules;
do not reload the complete nftables ruleset or alter other site services.

## Extended Glass checks

On the same explicit Start action, the native WebKit bridge runs a fixed allowlist
of HTTPS requests through macOS URLSession's system proxy/PAC and VPN settings.
Its ephemeral session has no shared cookies, credentials or cache, refuses
redirects, and caps response bodies at 16 KiB. Cancellation/window teardown
invalidates the per-check session and rejects late callbacks by run ID. WebKit
messages are accepted only from the main frame of the check page's HTTPS origin.

- Exit consistency compares Ailyre, Cloudflare and ipify's observed client IPs.
- Country consistency compares data for the same explicit IP from IPWhois,
  Country.is and available Cloudflare traces. Multiple Cloudflare trace sites
  count as one geographic source; `colo` is not used as client geolocation.
- IPv6 uses IPv6-only ipify plus public IPv6 ICE candidates. No response means
  only "not observed". The optional IPv4-only policy flags unexpected IPv6;
  otherwise IPv6 availability alone is not classified as a leak.
- AI targets: chatgpt.com, claude.ai, gemini.google.com, api.openai.com,
  api.anthropic.com and api.x.ai. Client IP evidence comes from public trace
  responses when available. Gemini's unauthenticated HEAD request verifies only
  HTTP reachability. 200/401/403 or a blocked trace never proves routing or
  account/model availability. No model/completion endpoints are called.

The external-browser page uses CORS-readable IP/location probes and explicitly
asks users to use TokenClock for AI routing when cross-origin policies prevent
reliable checks. The browser result is not replaced with VPS-side probes.

Additional unit checks: `NetworkDiagnosticsTests` and
`node scripts/network_leak/test_probe.cjs`. The opt-in native live test covers
all six AI rows, IP/country rows, IPv6 state and cancellation during a second run.

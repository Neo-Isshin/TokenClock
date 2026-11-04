# Glass toolboxes and sharing

The Glass dropdown and status summary share an adaptive shortcut grid. Users can
hide/reorder actions and restore defaults. Compact summaries use icons with
immediate, pointer-transparent hints. The summary keeps its tools accessible
outside the scrolling quota/usage area; quotas use two columns (2×2, 2×3, …).

Network Toolbox now uses the same native SwiftUI header, controls and cards as
the quota window. Its ephemeral WebKit view remains only a probe engine, with
native presentation events validated against the page origin and current view.
The original DNS/STUN/IPv6/AI checks remain explicitly initiated and cancellable.

Local Toolbox runs only on request:

- Environment: scalar shell assignments, harness JSON/TOML configuration,
  current process values and read-only `launchctl getenv`. Shell files are
  never sourced; differing scopes are reported as candidates rather than a
  universal claim about which value a separately launched harness will use.
  Key values are replaced by variant numbers; URL credentials/query are hidden.
- Disk: logical log/database file sizes under configured PathConfig locations.
  Cleanup requires individual selection plus confirmation. Only unchanged
  JSONL/LOG files older than 30 days qualify. Configs/databases/symlinks are not
  removed; filesystem identity/size/date are checked again, then files move to
  Trash. Nothing is automatically deleted.
- Log secrets: built-in API/AWS key patterns plus an optional custom regex.
  Reports contain file/line only, without secret snippets. Scans are bounded
  and cancellable, do not upload logs, and do not write provider files.
- Clock: one bounded, read-only SNTP request. The reply must echo the request
  timestamp and have a valid server mode/stratum. An unavailable reply is not a
  clock-error verdict. No system clock adjustment is performed.
- API keys: collect explicit keys from readable JSON/TOML/YAML/.env settings and
  process env. OAuth/Keychain/browser credentials are excluded. Provider and
  endpoint stay paired; equivalent entries are deduplicated. Up to three checks
  run concurrently, using ephemeral sessions with no shared cookies, credentials
  or redirects. Keys are held only in memory and are masked in results. Listing
  endpoints are preferred; a 404/405 permits one output-token fallback only when
  a model is explicitly configured. Invalid credentials do not trigger inference.
  A successful model list proves only that endpoint accepted the request, not
  available balance or every model permission. Billing, region, permissions,
  rate limiting and transport failures remain distinct.

Sharing keeps the existing date/cache controls and aggregation. It adds Ailyre's
actual emblem and website, four offline landscape backgrounds, shuffle, and
custom image selection with bounded image decoding. Preview and PNG export use
the same selected background. Sources/licenses accompany the bundled artwork.

Focused checks cover credential routing/masking, header and one-token request
construction, auth failure behavior, local secret redaction, changed-file cleanup
refusal, NTP validation, native layout at small screen sizes and PNG rendering.

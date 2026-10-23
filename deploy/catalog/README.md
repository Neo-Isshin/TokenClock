# TokenClock catalog endpoint

Clients read `https://www.ailyre.com/tokenclock/pricing-catalog.json` without Git credentials. Their existing daily refresh policy and cached/bundled fallback remain unchanged.

The VPS runs `tokenclock-catalog.timer` daily at 03:17 UTC, preserving the former publication schedule. Its dedicated unprivileged user can write only `/var/lib/tokenclock-catalog`; scripts live in `/opt/tokenclock-catalog`. The Nginx snippet exposes one JSON file, not the state directory or repository.

Deploy `scripts/publish-pricing-catalog.py` beside `scripts/update-pricing-snapshot.py`, seed the state file from the reviewed repository snapshot, and install the provided systemd units and Nginx snippet. Run `nginx -t` before reloading Nginx. Use `systemctl start tokenclock-catalog.service` for a manual update and `systemctl list-timers tokenclock-catalog.timer` to inspect the schedule.

The publisher reuses the existing LiteLLM public feed and catalog validation. No PR, Gitea login, or app build is needed for routine new-model/price updates. Unchanged data does not rewrite the file; failed downloads/validation preserve the last good file, and publication uses atomic replacement. This moves client distribution off GitHub; it does not change the third-party upstream data source.

Offline checks:

```sh
python3 -B scripts/test_pricing_snapshot.py
python3 -B scripts/test_publish_pricing_catalog.py
```

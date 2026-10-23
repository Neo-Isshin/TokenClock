# Public installation and release distribution

Gitea stores source history; `https://www.ailyre.com/tokenclock/` serves public installers,
release metadata, SHA-256 checked assets, and committed source archives. Gitea access
permissions are unchanged. No GitHub credentials, Actions, PRs, or release API are used.

Endpoints: `install.sh`, `install.ps1`, `tokenclock`, `releases/latest.json`,
`releases/latest-windows.json`, `releases/vX.Y.Z.json`,
`releases/download/vX.Y.Z/<asset>`, and `sources/<channel>.tar.gz` with checksum sidecars.
Release JSON retains the existing tag/assets/digest schema. Windows has an independent
latest pointer. Published assets must not be silently replaced with different bytes.

After reviewing/pushing commits and tags, run `scripts/release.sh vX.Y.Z --assets-dir DIR
--publish`. It validates packages and source pins, stages tracked source only, uploads
to `vps-1T`, activates assets before latest pointers, and re-downloads all six assets
to verify their hashes. The SSH host can be overridden with `TOKENCLOCK_PUBLISH_HOST`.
Public source exports allow source installation without exposing a Gitea login.

Install the Nginx snippet beside the existing catalog snippet; back up the server
configuration and run `nginx -t` before reloading. Never publish a whole worktree,
build directory, credentials, or the pricing publisher's state directory.

Existing v1.5.12 packages are migrated byte-for-byte, not represented as newer builds.
Previously installed clients cannot learn a new update URL from an unreachable old
endpoint: they need a one-time installer/CLI update or a newly built client. Source
changes to client update URLs take effect when that platform is rebuilt.

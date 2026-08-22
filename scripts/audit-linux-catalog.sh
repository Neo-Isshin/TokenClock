#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_root="$(mktemp -d)"
trap 'rm -rf "$build_root"' EXIT

swiftc \
  -module-cache-path "$build_root/module-cache" \
  -I "$repo_root/Sources/CSQLite" \
  "$repo_root/Sources/TokenClock/Config/SettingsKeys.swift" \
  "$repo_root/Sources/TokenClock/L10n.swift" \
  "$repo_root/Sources/TokenClock/Linux/LinuxProviderCatalog.swift" \
  "$repo_root/Sources/TokenClock/Linux/LinuxPathConfig.swift" \
  "$repo_root/Sources/TokenClock/Linux/LinuxPathDetector.swift" \
  "$repo_root/scripts/linux-catalog-audit.swift" \
  -lsqlite3 \
  -o "$build_root/linux-catalog-audit"

"$build_root/linux-catalog-audit"

#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

export HOME="$test_root/home"
export XDG_CONFIG_HOME="$test_root/xdg-config"
export XDG_DATA_HOME="$test_root/xdg-data"
export XDG_STATE_HOME="$test_root/xdg-state"
export TOKENCLOCK_CATALOG_TEST_ROOT="$test_root/fixtures"
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME"

swiftc \
  -module-cache-path "$test_root/module-cache" \
  -I "$repo_root/Sources/CSQLite" \
  "$repo_root/Sources/TokenClock/Config/SettingsKeys.swift" \
  "$repo_root/Sources/TokenClock/L10n.swift" \
  "$repo_root/Sources/TokenClock/Linux/LinuxProviderCatalog.swift" \
  "$repo_root/Sources/TokenClock/Linux/LinuxPathConfig.swift" \
  "$repo_root/Sources/TokenClock/Linux/LinuxPathDetector.swift" \
  "$repo_root/scripts/linux-catalog-smoke.swift" \
  -lsqlite3 \
  -o "$test_root/linux-catalog-smoke"

"$test_root/linux-catalog-smoke"

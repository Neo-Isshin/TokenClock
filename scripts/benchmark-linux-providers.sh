#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_root="$(mktemp -d)"
trap 'rm -rf "$build_root"' EXIT

sources=(
  "$repo_root/Sources/TokenClock/Config/AppConfig.swift"
  "$repo_root/Sources/TokenClock/Config/SettingsKeys.swift"
  "$repo_root/Sources/TokenClock/Models/TokenUsage.swift"
  "$repo_root/Sources/TokenClock/Services/UsageServiceProtocol.swift"
  "$repo_root/Sources/TokenClock/Linux/LinuxProviderCatalog.swift"
  "$repo_root/Sources/TokenClock/Linux/LinuxPathConfig.swift"
  "$repo_root/Sources/TokenClock/Services/CodexUsageService.swift"
  "$repo_root/Sources/TokenClock/Services/ClaudeCodeUsageService.swift"
  "$repo_root/Sources/TokenClock/Services/ContinueUsageService.swift"
  "$repo_root/Sources/TokenClock/Services/CopilotUsageService.swift"
  "$repo_root/Sources/TokenClock/Services/GeminiUsageService.swift"
  "$repo_root/Sources/TokenClock/Services/GrokUsageService.swift"
  "$repo_root/Sources/TokenClock/Services/OpenClawUsageService.swift"
  "$repo_root/Sources/TokenClock/Services/QwenCodeUsageService.swift"
  "$repo_root/Sources/TokenClock/Services/AiderUsageService.swift"
)
if [[ -f "$repo_root/Sources/TokenClock/Services/JSONLLineReader.swift" ]]; then
  sources+=("$repo_root/Sources/TokenClock/Services/JSONLLineReader.swift")
fi

swiftc \
  -O \
  -module-cache-path "$build_root/module-cache" \
  -I "$repo_root/Sources/CSQLite" \
  "${sources[@]}" \
  "$repo_root/scripts/linux-provider-benchmark.swift" \
  -lsqlite3 \
  -o "$build_root/linux-provider-benchmark"

"$build_root/linux-provider-benchmark"

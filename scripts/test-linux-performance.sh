#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

swift test --filter UsageServicePerformanceTests

if [[ "${1:-}" == "--benchmark" ]]; then
    TOKENCLOCK_RUN_BENCHMARKS=1 swift test \
        --filter UsageServicePerformanceTests
fi

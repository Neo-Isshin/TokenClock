#!/usr/bin/env bash
#
# ci.sh —— TokenClock 本地 CI 冒烟（push 前自检）
#
# 项目现以 GitHub 为主仓（GitHub Actions 可作云端 CI；此处是 push 前本地等价自检）：
# 两个分支都能编 + 测试过。
#
# 环境（与本机验证一致）：
#   * DEVELOPER_DIR=Xcode-beta  —— 提供 XCTest（测试必需）+ universal 回退库
#   * SDKROOT=CLT26             —— 26 SDK 里 @State 是属性包装器，CLT 能编
#   单架构 debug 构建，快；universal 走 release.sh。
#
# 用法：scripts/ci.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
XCODE_BETA="${XCODE_BETA:-$(xcode-select -p)}"
CLT26_SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk"
export DEVELOPER_DIR="$XCODE_BETA" SDKROOT="$CLT26_SDK"

C_RED=$'\033[1;31m'; C_GREEN=$'\033[1;32m'; C_CYAN=$'\033[1;36m'; C_RESET=$'\033[0m'
[ -t 1 ] || { C_RED=''; C_GREEN=''; C_CYAN=''; C_RESET=''; }
step() { printf '\n%s━━ %s ━━%s\n' "$C_CYAN" "$*" "$C_RESET"; }
ok()   { printf '  %s✓ %s%s\n' "$C_GREEN" "$*" "$C_RESET"; }
die()  { printf '%s✗ %s%s\n' "$C_RED" "$*" "$C_RESET" >&2; exit 1; }

cd "$REPO_ROOT" || die "进不了 $REPO_ROOT"
[ -d "$XCODE_BETA" ] || die "Xcode-beta 不在 $XCODE_BETA"
[ -d "$CLT26_SDK" ] || die "CLT26 SDK 不在 $CLT26_SDK"

ORIG="$(git -C "$REPO_ROOT" branch --show-current)"
[ -n "$ORIG" ] || die "detached HEAD"
trap 'git -C "$REPO_ROOT" checkout "$ORIG" --quiet 2>/dev/null || true' EXIT

FAIL=0
build_branch() {
  local b="$1"
  step "构建 $b"
  git -C "$REPO_ROOT" checkout "$b" --quiet || die "checkout $b 失败"
  if swift build 2>&1 | tail -3; then
    ok "$b 编译通过"
  else
    printf '%s✗ %s 编译失败%s\n' "$C_RED" "$b" "$C_RESET"; FAIL=1
  fi
}

build_branch main
build_branch normal

step "测试（main 分支）"
git -C "$REPO_ROOT" checkout main --quiet
if swift test 2>&1 | grep -E "Executed [0-9]+ tests"; then
  ok "测试通过"
else
  printf '%s✗ 测试失败%s\n' "$C_RED" "$C_RESET"; FAIL=1
fi

step "结果"
[ "$FAIL" = 0 ] && { printf '%s✓ 全部通过%s\n' "$C_GREEN" "$C_RESET"; exit 0; } \
                || { printf '%s✗ 有失败，见上%s\n' "$C_RED" "$C_RESET"; exit 1; }

#!/usr/bin/env bash
#
# install.sh — TokenClock one-shot installer
#
# Automatically: check the environment → select the supported variant
#      (macOS 26+: Liquid Glass + normal / macOS 12+: normal / Linux: normal)
#      → install to ~/.tokenclock → install the tokenclock CLI → launch.
#
# Usage:
#   ./cli/install.sh              # auto-detect variant · download prebuilt binary by default · launch when done
#   ./cli/install.sh --debug      # debug build (faster, good for trying out; implies --build-from-source)
#   ./cli/install.sh --normal     # force the normal variant
#   ./cli/install.sh --glass      # force the liquid-glass variant
#   ./cli/install.sh --no-start       # do not auto-launch when done
#   ./cli/install.sh --build-from-source  # skip the prebuilt download, force a local swift build
#
# One-liner:
#   curl -fsSL https://raw.githubusercontent.com/Neo-Isshin/TokenClock/main/cli/install.sh | bash
#
# Environment variables to override defaults:
#   TOKENCLOCK_REPO     git repository URL            (default: repo origin)
#   TOKENCLOCK_HOME     install root directory        (default: ~/.tokenclock)
#   TOKENCLOCK_BIN_DIR  CLI install directory         (default: ~/.local/bin)
#   TOKENCLOCK_BUILD    clone + build directory       (default: $TOKENCLOCK_HOME/src)
#
set -uo pipefail
export LC_ALL=C      # kept for portability: bash 3.2 in a UTF-8 locale can fold a multibyte character directly after $var into the variable name; the C locale parses by byte and avoids that. ASCII-only strings are unaffected either way.

DEFAULT_REPO="https://github.com/Neo-Isshin/TokenClock.git"
REPO_URL="${TOKENCLOCK_REPO:-$DEFAULT_REPO}"
HOME_DIR="${TOKENCLOCK_HOME:-$HOME/.tokenclock}"
BIN_DIR="${TOKENCLOCK_BIN_DIR:-$HOME/.local/bin}"
BUILD_DIR="${TOKENCLOCK_BUILD:-$HOME_DIR/src}"
# Update source (cmd_update fetches this URL; the tokenclock wrapper defaults to the same value)
INSTALL_URL="${TOKENCLOCK_INSTALL_URL:-https://raw.githubusercontent.com/Neo-Isshin/TokenClock/main/cli/install.sh}"

CONFIG="release"
VARIANT=""          # "" = auto-select by platform / macOS version
NO_START=0
FORCE=0             # --force: bypass the "no change" short-circuit and redeploy the binary
DEPLOYED_ANYTHING=0 # whether anything was actually deployed this run (reported to tokenclock update to decide whether to restart)
BUILT_BINS=()       # collected build-artifact paths, as path:variant
BUILD_FROM_SOURCE=0 # --build-from-source: skip the prebuilt download and force a local swift build
LINUX_APPIMAGE=0    # Linux x86_64 默认走预编译 AppImage（置 1 后由 download_appimage 处理）

say()  { printf '%s\n' "$*"; }
step() { printf '\n🛠  %s\n' "$*"; }
sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# Color output: only colorize on a TTY (curl|bash and other pipes strip it, avoiding escape codes polluting logs).
if [ -t 1 ]; then
  C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'; C_RED=$'\033[1;31m'; C_CYAN=$'\033[1;36m'; C_RESET=$'\033[0m'
else
  C_GREEN=''; C_YELLOW=''; C_RED=''; C_CYAN=''; C_RESET=''
fi
warn() { printf '\n%b⚠ %s%b\n' "$C_YELLOW" "$*" "$C_RESET"; }
die()  { printf '\n%b❌ %s%b\n' "$C_RED" "$*" "$C_RESET" >&2; exit 1; }

# Invoked by tokenclock update? (it sets TOKENCLOCK_STATUS_FILE) → skip the long summary at the end;
# the wrapper prints a one-line conclusion itself. Distinguishes "fresh install" from "upgrade".
UPDATE_MODE=0; [ -n "${TOKENCLOCK_STATUS_FILE:-}" ] && UPDATE_MODE=1

usage() {
  sed -n '3,22p' "$0" 2>/dev/null || true
  exit 0
}

# ── Arguments ──
while [ $# -gt 0 ]; do
  case "$1" in
    --glass)     VARIANT=glass ;;
    --normal)    VARIANT=normal ;;
    --debug)     CONFIG=debug; BUILD_FROM_SOURCE=1 ;;   # debug has no prebuilt, build from source
    --release)   CONFIG=release ;;
    --no-start)     NO_START=1 ;;
    --force)        FORCE=1 ;;
    --build-from-source) BUILD_FROM_SOURCE=1 ;;
    -h|--help)      usage ;;
    *)              die "Unknown argument: $1 (use --glass / --normal / --debug / --release / --no-start / --force / --build-from-source)" ;;
  esac
  shift
done

# ── 1. Preflight checks ──
step "Checking environment"
KERNEL="$(uname -s 2>/dev/null || echo unknown)"
case "$KERNEL" in
  Darwin)
    PLATFORM=macos
    OS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
    command -v git   >/dev/null 2>&1 || say "  ⚠ git not found (only needed for --build-from-source; the default download path is unaffected)"
    command -v swift >/dev/null 2>&1 || say "  ⚠ swift not found (only needed for --build-from-source; the default download path is unaffected)"
    ;;
  Linux)
    PLATFORM=linux
    OS_MAJOR=0
    [ "$VARIANT" != glass ] || die "Linux supports the normal variant only; remove --glass."
    if [ "$(uname -m)" = x86_64 ] && [ "$BUILD_FROM_SOURCE" -eq 0 ]; then
      # x86_64 默认走预编译 AppImage：无需 Swift/GTK 工具链，下载即用。
      # 缺少 FUSE 2 时，CLI 与自启动项会自动使用 AppImage 的解包运行模式。
      LINUX_APPIMAGE=1
      if [ ! -e /dev/fuse ] || ! ldconfig -p 2>/dev/null | grep -q 'libfuse.so.2'; then
        say "  ℹ 未检测到可用的 FUSE 2；将自动使用 AppImage 解包运行模式（无需 sudo 安装依赖）"
      fi
      say "  Linux $(uname -m) · 预编译 AppImage（--build-from-source 可改走源码编译）"
    else
      # 其它架构（如 aarch64）或 --build-from-source：源码编译，需 Swift6 + GTK/SQLite 开发头文件。
      BUILD_FROM_SOURCE=1
      command -v git >/dev/null 2>&1 || die "git is required on Linux."
      command -v swift >/dev/null 2>&1 || die "Swift 6 is required on Linux (https://www.swift.org/install/linux/)."
      command -v pkg-config >/dev/null 2>&1 || die "pkg-config is required on Linux."
      pkg-config --exists gtk+-3.0 || die "GTK3 development files are required (Ubuntu/Debian: sudo apt install libgtk-3-dev)."
      pkg-config --exists sqlite3 || die "SQLite development files are required (Ubuntu/Debian: sudo apt install libsqlite3-dev)."
      say "  Linux $(uname -r) · normal GTK3 build · source build"
    fi
    [ "$INSTALL_URL" != "https://raw.githubusercontent.com/Neo-Isshin/TokenClock/main/cli/install.sh" ] \
      || INSTALL_URL="https://raw.githubusercontent.com/Neo-Isshin/TokenClock/normal/cli/install.sh"
    ;;
  *)
    die "Unsupported platform: $KERNEL (TokenClock supports macOS and Linux)."
    ;;
esac

if command -v swift >/dev/null 2>&1; then
  TC_TOOLCHAIN="$(swift --version 2>&1 | head -1)"
else
  TC_TOOLCHAIN=""
fi
case "$TC_TOOLCHAIN" in
  *Xcode\ license*|*not\ agreed*|*agreeing*|*同意*)
    say "  macOS $(sw_vers -productVersion) · major version $OS_MAJOR"
    say "  ⚠ Xcode license not accepted → git/swift are temporarily locked. The default prebuilt-download path is unaffected."
    say "    To use --build-from-source, resolve one of these first:"
    say "      sudo xcodebuild -license          # accept the license (recommended)"
    say "      sudo xcode-select -s /Library/Developer/CommandLineTools   # switch back to CLT"
    ;;
  *)
    if [ "$PLATFORM" = macos ]; then
      [ -n "$TC_TOOLCHAIN" ] \
        && say "  macOS $(sw_vers -productVersion) · major version $OS_MAJOR · toolchain $TC_TOOLCHAIN" \
        || say "  macOS $(sw_vers -productVersion) · major version $OS_MAJOR · toolchain (swift not installed)"
    else
      say "  Toolchain: $TC_TOOLCHAIN"
    fi
    ;;
esac

# ── 2. Select variant ──
# v1.4.7 and older CLIs did not forward --glass/--normal to install.sh during an
# update. Preserve those users' installed channel instead of interpreting an
# empty variant as a request to add both macOS builds.
if [ "$PLATFORM" = macos ] && [ "$UPDATE_MODE" -eq 1 ] && [ -z "$VARIANT" ]; then
  has_glass=0
  has_normal=0
  [ ! -x "$HOME_DIR/glass/TokenClock" ] || has_glass=1
  [ ! -x "$HOME_DIR/normal/TokenClock" ] || has_normal=1
  if [ "$has_glass" -eq 1 ] && [ "$has_normal" -eq 0 ]; then
    VARIANT=glass
  elif [ "$has_normal" -eq 1 ] && [ "$has_glass" -eq 0 ]; then
    VARIANT=normal
  fi
fi

if [ "$PLATFORM" = linux ]; then
  VARIANTS=(normal)
  BRANCHES=(normal)
  PRIMARY_VARIANT=normal
elif [ -z "$VARIANT" ]; then
  if [ "$OS_MAJOR" -ge 26 ]; then
    # macOS 26+: pull both variants (Liquid Glass + normal)
    VARIANTS=(glass normal)
    BRANCHES=(main normal)
    PRIMARY_VARIANT=glass    # default / first-launch variant
  elif [ "$OS_MAJOR" -ge 12 ]; then
    # macOS 12-25: normal only (classic opaque build, Monterey+)
    VARIANTS=(normal)
    BRANCHES=(normal)
    PRIMARY_VARIANT=normal
  else
    die "macOS 12 or later is required (current major version $OS_MAJOR)."
  fi
else
  # When --glass / --normal is given explicitly, install only that one
  case "$VARIANT" in
    glass)  VARIANTS=(glass);  BRANCHES=(main);   PRIMARY_VARIANT=glass ;;
    normal) VARIANTS=(normal); BRANCHES=(normal); PRIMARY_VARIANT=normal ;;
  esac
fi
VARIANT_LABELS=""
for i in "${!VARIANTS[@]}"; do
  if [ -z "$VARIANT_LABELS" ]; then
    VARIANT_LABELS="${VARIANTS[$i]} (${BRANCHES[$i]})"
  else
    VARIANT_LABELS="$VARIANT_LABELS + ${VARIANTS[$i]} (${BRANCHES[$i]})"
  fi
done
say "  Variants: $VARIANT_LABELS · build: $CONFIG"

# ── 3. Fetch source (lazy: only invoked for build-from-source / download fallback) ──
# The prebuilt-download path (default) never clones, avoiding a hard dependency on git / the Xcode license.
ensure_source() {
  local variant="$1" branch="$2" subdir="$BUILD_DIR/$branch"
  step "Fetching source [$variant] ($REPO_URL · $branch)"
  if [ -d "$subdir/.git" ]; then
    git -C "$subdir" fetch --depth 1 origin "$branch" >/dev/null 2>&1 || die "git fetch [$variant] failed (check your network or TOKENCLOCK_REPO)"
    git -C "$subdir" checkout "$branch" >/dev/null 2>&1 || die "failed to switch to branch $branch ([$variant])"
    git -C "$subdir" reset --hard "origin/$branch" >/dev/null 2>&1
    say "  Updated: $subdir"
  else
    mkdir -p "$subdir"
    git clone --depth 1 --branch "$branch" "$REPO_URL" "$subdir" >/dev/null 2>&1 \
      || die "git clone [$variant] failed (check TOKENCLOCK_REPO=$REPO_URL / network / Xcode license. The default download path needs no clone — retry without --build-from-source)"
    say "  Cloned: $subdir"
  fi
}

# ── 4. Obtain the binary (prefer the prebuilt download; fall back to building from source on failure / --build-from-source) ──
# Prebuilt assets come from the GitHub release (universal: arm64+x86_64); no Xcode, no compilation.
# Each independently maintained channel may publish a patch without relabelling the unchanged
# binaries from the other platforms. TOKENCLOCK_RELEASE_TAG remains a global testing override.
release_tag_for_variant() {
  if [ -n "${TOKENCLOCK_RELEASE_TAG:-}" ]; then
    echo "$TOKENCLOCK_RELEASE_TAG"
    return
  fi
  case "$1" in
    glass)  echo "v1.5.0" ;;
    normal) echo "v1.5.0" ;;
    linux)  echo "v1.5.0" ;;
  esac
}
release_base_for_tag() {
  local tag="$1"
  echo "${TOKENCLOCK_RELEASE_BASE:-https://github.com/Neo-Isshin/TokenClock/releases/download/$tag}"
}

# variant → tarball filename / expected SHA256 (bash 3.2 has no associative arrays, so use case)
tarball_name() {
  case "$1" in
    glass)  echo "TokenClock-glass-universal.tar.gz" ;;
    normal) echo "TokenClock-normal-universal.tar.gz" ;;
  esac
}
tarball_sha256() {
  case "$1" in
    glass)  echo "faf71d43419bbc0a2420ebd634a9c23dff56302fe64d2a9f1802f63ca539194f" ;;
    normal) echo "b3c5427e08076d7ec04bd1713747c6fa5fa2aaa244c6d1a129d4ea24e444f415" ;;
  esac
}

# Download + SHA256-verify + extract [$variant]. On success the extracted dir is written to the global
# $DL_DIR and 0 is returned; on failure 1 is returned (caller falls back to building from source).
# Temp dirs are tracked in DOWNLOAD_TMPDIRS and cleaned up on exit.
DL_DIR=""
DOWNLOAD_TMPDIRS=()
trap '[ "${#DOWNLOAD_TMPDIRS[@]}" -gt 0 ] && rm -rf "${DOWNLOAD_TMPDIRS[@]}" 2>/dev/null; [ -n "${WRAPPER_TMP:-}" ] && rm -f "$WRAPPER_TMP" 2>/dev/null; true' EXIT
download_variant() {
  local variant="$1" name expect tag base url tmp got
  name="$(tarball_name "$variant")"
  expect="$(tarball_sha256 "$variant")"
  tag="$(release_tag_for_variant "$variant")"
  base="$(release_base_for_tag "$tag")"
  [ -n "$name" ] && [ -n "$expect" ] || return 1
  url="$base/$name"
  step "Downloading prebuilt binary [$variant] ($tag)"
  tmp="$(mktemp -d 2>/dev/null)" || return 1
  if ! curl -fL --retry 6 --retry-delay 2 --retry-all-errors --connect-timeout 15 -o "$tmp/$name" "$url" 2>/dev/null; then
    say "  ⚠ [$variant] prebuilt download failed ($url) → falling back to source build"
    rm -rf "$tmp"; return 1
  fi
  got="$(sha256_file "$tmp/$name")"
  if [ "$got" != "$expect" ]; then
    say "  ⚠ [$variant] SHA256 mismatch (expected ${expect:0:12}… got ${got:0:12}…) → falling back to source build"
    rm -rf "$tmp"; return 1
  fi
  if ! tar xzf "$tmp/$name" -C "$tmp" 2>/dev/null || [ ! -f "$tmp/TokenClock" ]; then
    say "  ⚠ [$variant] extraction failed or no TokenClock inside the archive → falling back to source build"
    rm -rf "$tmp"; return 1
  fi
  chmod +x "$tmp/TokenClock"
  say "  ✓ [$variant] prebuilt binary ready (SHA256 ${got:0:12}…)"
  DL_DIR="$tmp"
  DOWNLOAD_TMPDIRS+=("$tmp")
  return 0
}

# Linux x86_64: 下载预编译 AppImage + sidecar SHA256（随本地验收后的发布资产提供，故不写死在脚本里），
# 校验通过则把 AppImage 路径写入全局 APPIMAGE_PATH 并返回 0；失败返回 1（调用方回退源码编译）。
APPIMAGE_PATH=""
download_appimage() {
  local name="TokenClock-x86_64.AppImage" sha_name tag base url tmp got expect
  sha_name="$name.sha256"
  tag="$(release_tag_for_variant linux)"
  base="$(release_base_for_tag "$tag")"
  url="$base/$name"
  step "Downloading prebuilt AppImage (Linux x86_64 · $tag)"
  tmp="$(mktemp -d 2>/dev/null)" || return 1
  if ! curl -fL --retry 6 --retry-delay 2 --retry-all-errors --connect-timeout 15 -o "$tmp/$name" "$url" 2>/dev/null; then
    say "  ⚠ AppImage 下载失败（$url，可能 CI 尚未构建完成）→ 回退源码编译"
    rm -rf "$tmp"; return 1
  fi
  if ! curl -fL --retry 6 --retry-delay 2 --retry-all-errors --connect-timeout 15 -o "$tmp/$sha_name" "$base/$sha_name" 2>/dev/null; then
    say "  ⚠ AppImage 的 SHA256 sidecar 下载失败 → 回退源码编译"
    rm -rf "$tmp"; return 1
  fi
  expect="$(awk '{print $1}' "$tmp/$sha_name" 2>/dev/null)"
  [ -n "$expect" ] || { say "  ⚠ SHA256 sidecar 为空 → 回退源码编译"; rm -rf "$tmp"; return 1; }
  got="$(sha256_file "$tmp/$name")"
  if [ "$got" != "$expect" ]; then
    say "  ⚠ AppImage SHA256 不符（expected ${expect:0:12}… got ${got:0:12}…）→ 回退源码编译"
    rm -rf "$tmp"; return 1
  fi
  chmod +x "$tmp/$name"
  say "  ✓ AppImage 就绪（SHA256 ${got:0:12}…）"
  APPIMAGE_PATH="$tmp/$name"
  DOWNLOAD_TMPDIRS+=("$tmp")
  return 0
}

# Local source build: on macOS 27 with only CLT, automatically pin to the 26 SDK (works around missing SwiftUIMacros).
swift_build_fallback() {
  local subdir="$1"
  local sdk26="/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk"
  if [ "${OS_MAJOR:-0}" -ge 27 ] && [ -d "$sdk26" ] \
     && [ "$(xcode-select -p 2>/dev/null)" = "/Library/Developer/CommandLineTools" ]; then
    say "  · Detected macOS $OS_MAJOR + CLT only → auto SDKROOT=$sdk26 to work around missing SwiftUIMacros"
    ( cd "$subdir" && SDKROOT="$sdk26" swift build -c "$CONFIG" )
  else
    ( cd "$subdir" && swift build -c "$CONFIG" )
  fi
}

for i in "${!VARIANTS[@]}"; do
  variant="${VARIANTS[$i]}"
  branch="${BRANCHES[$i]}"
  subdir="$BUILD_DIR/$branch"

  # 4a. Linux x86_64: 优先下载预编译 AppImage
  if [ "${LINUX_APPIMAGE:-0}" = 1 ] && download_appimage; then
    BUILT_BINS+=("$APPIMAGE_PATH:$variant")
    continue
  fi

  # 4b. macOS: 优先下载预编译 universal 二进制（Linux 上不下载 macOS tarball）
  if [ "$PLATFORM" != linux ] && [ "$BUILD_FROM_SOURCE" -eq 0 ] && download_variant "$variant"; then
    BUILT_BINS+=("$DL_DIR/TokenClock:$variant")
    continue
  fi

  # 4c. Fallback: build from source locally (this is the only path that needs a clone)
  ensure_source "$variant" "$branch"
  step "Building [$variant] (swift build -c $CONFIG · first run may take a few minutes)"
  swift_build_fallback "$subdir" \
    || die "[$variant] build failed. On Linux, verify Swift 6 + libgtk-3-dev + libsqlite3-dev; on macOS 27, install Xcode or the macOS 26 SDK."
  BIN_PATH="$subdir/.build/$CONFIG/TokenClock"
  [ -f "$BIN_PATH" ] || BIN_PATH="$subdir/.build/out/Products/$([ "$CONFIG" = release ] && echo Release || echo Debug)/TokenClock"
  [ -f "$BIN_PATH" ] || die "Build artifact not found: $BIN_PATH"
  BUILT_BINS+=("$BIN_PATH:$variant")
done

# ── 5. Stage the binary + resource bundle (update only on change; --force forces it) ──
for entry in "${BUILT_BINS[@]}"; do
  bin_path="${entry%:*}"
  variant="${entry##*:}"
  dest_bin="$HOME_DIR/$variant/TokenClock"
  mkdir -p "$HOME_DIR/$variant"
  step "Installing clock [$variant] to $HOME_DIR/$variant"

  # Binary: overwrite based on a hash comparison (--force / first deploy / hash differs → overwrite)
  bin_changed=0
  if [ "$FORCE" -eq 1 ] || [ ! -f "$dest_bin" ]; then
    bin_changed=1
  elif [ "$(sha256_file "$bin_path")" != "$(sha256_file "$dest_bin")" ]; then
    bin_changed=1
  fi
  if [ "$bin_changed" -eq 1 ]; then
    # Deploy through a sibling inode and atomically rename it into place. Linux returns
    # ETXTBSY when cp truncates a running AppImage; rename keeps the old process on its
    # existing inode while the next launch sees the complete, verified replacement.
    dest_tmp="$HOME_DIR/$variant/.TokenClock.new.$$"
    cp "$bin_path" "$dest_tmp" || { rm -f "$dest_tmp"; die "Failed to stage [$variant] binary"; }
    chmod +x "$dest_tmp" || { rm -f "$dest_tmp"; die "Failed to make [$variant] binary executable"; }
    # Ad-hoc re-sign safety net: prebuilt downloads or source-fallback artifacts may still be
    # linker-signed adhoc (flags=0x20002), which taskgated kills on macOS 27. `--force --sign -`
    # produces a proper adhoc (0x2). release.sh already signs before packaging; this re-signs
    # $dest_bin to cover the source-fallback path and self-heal any signing damage from transfer/extraction.
    if [ "$PLATFORM" = macos ]; then
      codesign --force --sign - "$dest_tmp" >/dev/null 2>&1 || warn "[$variant] ad-hoc re-sign failed: $dest_tmp (may crash on launch under macOS 27)"
    fi
    mv -f "$dest_tmp" "$dest_bin" || { rm -f "$dest_tmp"; die "Failed to activate [$variant] binary"; }
    say "  ✓ $dest_bin"
    DEPLOYED_ANYTHING=1
  else
    say "  · [$variant] binary unchanged, skipping"
  fi

  # Resource bundle: if present next to the build artifact, deploy it beside the binary (so the
  # runtime Bundle.module mainPath resolves; otherwise switching to the .glass theme on a non-dev
  # machine fatalError's because the bundle is missing). Count as deployed when missing → triggers restart.
  bundle_src="$(dirname "$bin_path")/TokenClock_TokenClock.bundle"
  if [ -d "$bundle_src" ]; then
    dest_bundle="$HOME_DIR/$variant/TokenClock_TokenClock.bundle"
    bundle_missing=0; [ -d "$dest_bundle" ] || bundle_missing=1
    rm -rf "$dest_bundle"
    cp -R "$bundle_src" "$dest_bundle"
    say "  ✓ $dest_bundle (resources)"
    [ "$bundle_missing" -eq 1 ] && DEPLOYED_ANYTHING=1
  fi
done

# ── 6. Install the tokenclock CLI ──
step "Installing tokenclock CLI"
mkdir -p "$BIN_DIR"
# CLI wrapper source: prefer an already-cloned source tree (build path), otherwise curl it from raw
# (download path, no git dependency). Both branches ship an identical cli/tokenclock, so raw pulls from main.
# Record the old wrapper SHA, compare after deploy → WRAPPER_CHANGED (only used to report "CLI updated"
# from update; it does not trigger an app restart — the wrapper and the running clock binary are independent).
WRAPPER_OLD_SHA=""
[ -f "$BIN_DIR/tokenclock" ] && WRAPPER_OLD_SHA="$(sha256_file "$BIN_DIR/tokenclock" 2>/dev/null)"
# Atomic deploy: write to a temp file first, then mv into place. tokenclock update invokes this script
# via the wrapper, so the "running wrapper" IS $BIN_DIR/tokenclock; an in-place cp/curl would make bash
# keep reading the new file from the wrong offset → executing comments/fragments ("command not found" +
# syntax errors). mv swaps the inode; the old process keeps reading the old inode undisturbed.
WRAPPER_TMP="$BIN_DIR/.tokenclock.new.$$"
WRAPPER_OK=0
for b in "${BRANCHES[@]}"; do
  if [ -f "$BUILD_DIR/$b/cli/tokenclock" ]; then
    cp "$BUILD_DIR/$b/cli/tokenclock" "$WRAPPER_TMP"
    WRAPPER_OK=1
    say "  ✓ $BIN_DIR/tokenclock (source: $b/cli)"
    break
  fi
done
if [ "$WRAPPER_OK" -eq 0 ]; then
  WRAPPER_URL="${INSTALL_URL%/*}/tokenclock"   # .../raw/main/cli/tokenclock
  if curl -fL --retry 6 --retry-delay 2 --retry-all-errors --connect-timeout 15 \
        -o "$WRAPPER_TMP" "$WRAPPER_URL" 2>/dev/null \
     && [ -s "$WRAPPER_TMP" ]; then
    say "  ✓ $BIN_DIR/tokenclock (source: raw)"
  else
    rm -f "$WRAPPER_TMP"
    die "cli/tokenclock not found (not cloned locally, and downloading $WRAPPER_URL failed)"
  fi
fi
chmod +x "$WRAPPER_TMP"
mv -f "$WRAPPER_TMP" "$BIN_DIR/tokenclock"
# Compare new vs old wrapper (on first install the old SHA is empty → treated as changed, but first
# install does not go through the update path, so no side effects)
WRAPPER_CHANGED=0
WRAPPER_NEW_SHA="$(sha256_file "$BIN_DIR/tokenclock" 2>/dev/null)"
[ "$WRAPPER_NEW_SHA" != "$WRAPPER_OLD_SHA" ] && WRAPPER_CHANGED=1
export PATH="$BIN_DIR:$PATH"   # let later commands in this script use tokenclock directly

# Report deploy status back to the caller (tokenclock update decides restart / just-notify / no-op from this):
#   DEPLOYED     clock binary changed → the running clock needs a restart
#   CLI_UPDATED  only the wrapper changed → no clock restart needed, but give the user a "CLI updated" notice
if [ -n "${TOKENCLOCK_STATUS_FILE:-}" ]; then
  {
    echo "DEPLOYED=$DEPLOYED_ANYTHING"
    echo "CLI_UPDATED=${WRAPPER_CHANGED:-0}"
  } > "$TOKENCLOCK_STATUS_FILE"
fi

# ── 7. Launch at login (LaunchAgent) ──
# Write a plist in the same format as the Swift-side LaunchAgentHelper: label / ProgramArguments /
# RunAtLoad=true / ProcessType=Interactive. The Swift-side cleanupLegacy() "adopts" this plist as a
# user-chosen auto-start, keeping the right-click menu toggle state correct.
# When the user turns it off from the clock's right-click menu, the Swift-side enable/disable overwrites this plist.
# Pick a free port: try $1 first, then walk forward N times
find_free_port() {
  local start="$1" tries="$2" p
  for p in $(seq "$start" $((start + tries))); do
    if ! lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1; then
      echo "$p"; return 0
    fi
  done
  return 1
}

# Register the LaunchAgent plist for PRIMARY_VARIANT. The Swift-side LaunchAgentHelper
# enable() writes its plist using ProcessInfo.arguments[0] as binaryPath — which in this script's
# context is $HOME_DIR/$PRIMARY_VARIANT/TokenClock, equivalent.
enable_launch_agent() {
  local variant="$1" binary_path="$2"
  local plist_dir="$HOME/Library/LaunchAgents"
  local plist_path="$plist_dir/com.tokenclock.app.${variant}.plist"
  local label="com.tokenclock.app.${variant}"

  mkdir -p "$plist_dir" || die "Failed to create $plist_dir"

  # Idempotent: plist already exists with RunAtLoad=true → skip, avoiding launchd churn from a reload
  if [ -f "$plist_path" ] && /usr/libexec/PlistBuddy -c "Print :RunAtLoad" "$plist_path" 2>/dev/null | grep -q "true"; then
    say "  ⏭ LaunchAgent already registered: $plist_path"
    return 0
  fi

  # Write the plist: same fields / same order as the Swift-side LaunchAgentHelper.renderPlist
  cat > "$plist_path" <<EOF || die "Failed to write $plist_path"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$label</string>
    <key>ProgramArguments</key>
    <array>
        <string>$binary_path</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardOutPath</key>
    <string>/dev/null</string>
    <key>StandardErrorPath</key>
    <string>/dev/null</string>
    <key>KeepAlive</key>
    <dict>
        <key>Crashed</key>
        <true/>
    </dict>
</dict>
</plist>
EOF

  # launchctl load -w: load and mark "enabled across reboots" (i.e. RunAtLoad is persisted)
  if launchctl load -w "$plist_path" 2>/dev/null; then
    say "  ✓ LaunchAgent registered: $plist_path"
  else
    say "  ⚠ launchctl load failed ($plist_path was written; the Swift right-click menu can recover it)"
  fi
}

enable_linux_autostart() {
  local binary_path="$1"
  local autostart_dir="${XDG_CONFIG_HOME:-$HOME/.config}/autostart"
  local desktop_path="$autostart_dir/tokenclock.desktop"
  local exec_line="$binary_path"
  if [ ! -e /dev/fuse ] || ! ldconfig -p 2>/dev/null | grep -q 'libfuse\.so\.2'; then
    exec_line="env APPIMAGE_EXTRACT_AND_RUN=1 $binary_path"
  fi
  mkdir -p "$autostart_dir" || die "Failed to create $autostart_dir"
  cat > "$desktop_path" <<EOF || die "Failed to write $desktop_path"
[Desktop Entry]
Type=Application
Name=TokenClock
Comment=Local AI coding usage clock
Exec=$exec_line
Terminal=false
X-GNOME-Autostart-enabled=true
EOF
  say "  ✓ XDG autostart registered: $desktop_path"
}

# y/N prompt; defaults to N (least surprise). Skipped when non-interactive (curl | bash).
prompt_api_server() {
  local API_PORT_DEFAULT=9988
  local API_PORT_TRIES=5
  local API_PORT_FALLBACK_MSG=" (launch may fail)"
  local API_PORT_RANGE_END=$((API_PORT_DEFAULT + API_PORT_TRIES))   # 9993

  if [ "$PLATFORM" = linux ]; then
    API_ENABLED=1
    API_CHOSEN_PORT="$API_PORT_DEFAULT"
    say "  ✓ API server: enabled on loopback port $API_PORT_DEFAULT"
    return 0
  fi

  # Non-interactive mode (curl|bash, heredoc): enable by default, quietly probe for a free port
  if [ ! -t 0 ]; then
    local chosen_port
    if chosen_port="$(find_free_port "$API_PORT_DEFAULT" "$API_PORT_TRIES")"; then
      if [ "$chosen_port" != "$API_PORT_DEFAULT" ]; then
        say "  ⚠ $API_PORT_DEFAULT in use → using $chosen_port instead"
      fi
    else
      chosen_port="$API_PORT_DEFAULT"
      say "  ⚠ ${API_PORT_DEFAULT}–${API_PORT_RANGE_END} all in use, still using $chosen_port$API_PORT_FALLBACK_MSG"
    fi
    defaults write TokenClock TC_apiServerEnabled -bool true \
      || die "defaults write TC_apiServerEnabled failed"
    defaults write TokenClock TC_apiServerPort -int "$chosen_port" \
      || die "defaults write TC_apiServerPort failed"
    API_ENABLED=1
    API_CHOSEN_PORT="$chosen_port"
    say "  ✓ API server: enabled (auto-enabled in non-interactive mode, port $chosen_port)"
    return 0
  fi

  local ans
  printf '  Enable the local API server (listening on 127.0.0.1:%d)? [y/N] ' "$API_PORT_DEFAULT"
  IFS= read -r ans || ans=""
  ans="$(printf '%s' "$ans" | tr 'A-Z' 'a-z')"
  case "$ans" in
    y|yes)
      local chosen_port
      if chosen_port="$(find_free_port "$API_PORT_DEFAULT" "$API_PORT_TRIES")"; then
        if [ "$chosen_port" != "$API_PORT_DEFAULT" ]; then
          say "  ⚠ $API_PORT_DEFAULT in use → using $chosen_port instead"
        fi
      else
        chosen_port="$API_PORT_DEFAULT"
        say "  ⚠ ${API_PORT_DEFAULT}–${API_PORT_RANGE_END} all in use, still using $chosen_port$API_PORT_FALLBACK_MSG"
      fi

      defaults write TokenClock TC_apiServerEnabled -bool true \
        || die "defaults write TC_apiServerEnabled failed"
      defaults write TokenClock TC_apiServerPort -int "$chosen_port" \
        || die "defaults write TC_apiServerPort failed"

      API_ENABLED=1
      API_CHOSEN_PORT="$chosen_port"
      say "  ✓ API server: enabled (port $chosen_port; takes effect once $HOME_DIR/$PRIMARY_VARIANT/TokenClock starts)"
      ;;
    *)
      defaults delete TokenClock TC_apiServerEnabled 2>/dev/null || true
      say "  ⏭ API server: not enabled (default)"
      ;;
  esac
}

# ── 7b. Ask whether to enable the local API server ──
API_ENABLED=0
API_CHOSEN_PORT=9988
if [ "$NO_START" -eq 1 ]; then
  say "  ⏭ API server: skipped (--no-start, app not launched)"
else
  step "Configuring the local API server (optional)"
  prompt_api_server
fi

# ── 8. Ensure PATH (write to the shell rc, idempotent) ──
ensure_in_path() {
  case ":$PATH:" in *":$BIN_DIR:"*) return 0 ;; esac      # already on PATH in the current shell
  local rc
  for rc in "$HOME/.zshrc" "$HOME/.bash_profile" "$HOME/.bashrc"; do
    [ -f "$rc" ] && grep -qF "$BIN_DIR" "$rc" && return 0  # some rc already configures it
  done
  local target_rc="$HOME/.zshrc"
  [ "$PLATFORM" = linux ] && target_rc="$HOME/.bashrc"
  printf '\n# Added by tokenclock installer\nexport PATH="%s:$PATH"\n' "$BIN_DIR" >> "$target_rc"
  say "  Added $BIN_DIR to $target_rc (takes effect in a new terminal)"
}
ensure_in_path

# ── 8b. Register the launch-at-login LaunchAgent ──
# Explicitly register the plist so install.sh's "auto-start on by default" promise lands on disk.
# The Swift-side LaunchAgentHelper.cleanupLegacy() "adopts" this plist, avoiding an inconsistent right-click menu toggle state.
LAUNCH_AGENT_OK=0
if [ "$PLATFORM" = linux ]; then
  LAUNCH_AGENT_PATH="${XDG_CONFIG_HOME:-$HOME/.config}/autostart/tokenclock.desktop"
else
  LAUNCH_AGENT_PATH="$HOME/Library/LaunchAgents/com.tokenclock.app.${PRIMARY_VARIANT}.plist"
fi
if [ "$NO_START" -eq 1 ]; then
  say "  ⏭ Login autostart: skipped (--no-start)"
elif [ "$PLATFORM" = linux ]; then
  step "Registering XDG login autostart (normal)"
  enable_linux_autostart "$HOME_DIR/normal/TokenClock"
  LAUNCH_AGENT_OK=1
else
  step "Registering login LaunchAgent ($PRIMARY_VARIANT)"
  enable_launch_agent "$PRIMARY_VARIANT" "$HOME_DIR/$PRIMARY_VARIANT/TokenClock"
  LAUNCH_AGENT_OK=1
fi

# ── 8c. Clean up leftover "classic" Login Items ──
# Older menus (SMAppService), or running from .build during development, may have registered a "classic"
# Login Item pointing at the bare executable — macOS opens it with Terminal, causing a terminal window to
# pop up on every login showing launch stdout, and closing the terminal kills the process. Auto-start is
# now exclusively handled by the LaunchAgent above (launchd launches directly, no terminal); here we make a
# best-effort attempt to delete any classic login item named TokenClock (needs "Automation" permission,
# failures are silently ignored).
if [ "$NO_START" -eq 0 ] && [ "$PLATFORM" = macos ]; then
  if osascript -e 'tell application "System Events" to delete (every login item whose name is "TokenClock")' >/dev/null 2>&1; then
    say "  ✓ Cleaned up leftover classic Login Item (if any)"
  else
    # osascript non-zero exit (common: Automation permission denied). Best-effort, do not abort the install;
    # prompt the user to handle it manually: grant Automation or remove the leftover login item in System Settings.
    say "  ⚠ Could not auto-clean the classic Login Item (Automation permission may be missing)."
    say "    Grant your terminal access to System Events under System Settings → Privacy & Security → Automation,"
    say "    or manually remove the item named TokenClock under System Settings → General → Login Items."
  fi
fi

# ── 9. First launch (= initialization: first scan of each AI tool's local paths) ──
if [ "$NO_START" -eq 1 ]; then
  say "  ⏭  Skipping auto-launch (--no-start)"
else
  step "Launching $PRIMARY_VARIANT for the first time and scanning AI tool paths"
  tokenclock stop >/dev/null 2>&1 || true                    # stop old instances to ensure the new binary is used
  tokenclock start --"$PRIMARY_VARIANT" >/dev/null 2>&1 || die "Launch failed"
  say "  Started the $PRIMARY_VARIANT build"
  sleep 3                                                    # wait for the first scan
  enabled=""
  if [ "$PLATFORM" = macos ]; then
    enabled="$(defaults read TokenClock TC_enabledTools 2>/dev/null \
               | tr -d '()"' | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' | paste -sd ',' - | sed 's/,/, /g')"
  fi
  if [ -n "$enabled" ]; then
    say "  🔍 Detected enabled tools: $enabled"
  else
    say "  🔍 First scan complete (if no tools are listed, enable them / set their paths via the clock's right-click → Settings)"
  fi

  # API server smoke test (if enabled). The port only listens after TokenClock starts.
  if [ "${API_ENABLED:-0}" -eq 1 ] && [ -n "${API_CHOSEN_PORT:-}" ]; then
    # FUSE-less AppImage startup includes a one-time extraction and can take longer than
    # the ordinary launch. Poll rather than reporting a false failure after a fixed delay.
    api_ready=0
    api_attempt=0
    out=""
    while [ "$api_attempt" -lt 30 ]; do
      if out="$(curl -fsS --connect-timeout 1 --max-time 2 "http://127.0.0.1:${API_CHOSEN_PORT}/api/usage" 2>/dev/null | head -c 80)"; then
        api_ready=1
        break
      fi
      api_attempt=$((api_attempt + 1))
      sleep 1
    done
    if [ "$api_ready" -eq 1 ]; then
      say "  ✓ API smoke test: http://127.0.0.1:${API_CHOSEN_PORT}/api/usage → ${out}…"
    else
      say "  ⚠ API smoke test failed (port ${API_CHOSEN_PORT} did not become ready within 30 seconds; retry later)"
    fi
  fi
fi

# ── 10. Done ──
# Update path (invoked by tokenclock update): skip the "🎉 Installed!" banner + doctor summary;
# the wrapper prints a one-line conclusion (deployed+restart / CLI updated / already up to date). Only a fresh install gets the full summary.
if [ "$UPDATE_MODE" -eq 1 ]; then
  exit 0
fi
step "Install complete · generating summary"

# 1. Collect doctor output (PATH was exported in step 6, so tokenclock is callable directly)
DOCTOR_OUT=""
if command -v tokenclock >/dev/null 2>&1; then
  DOCTOR_OUT="$(tokenclock doctor 2>&1 || true)"
else
  DOCTOR_OUT="(tokenclock is not on PATH; skipping doctor)"
fi

# 2. API status line
if [ "${API_ENABLED:-0}" -eq 1 ]; then
  API_LINE="✓ Enabled · port ${API_CHOSEN_PORT}"
  API_URL="http://127.0.0.1:${API_CHOSEN_PORT}/api/usage"
else
  API_LINE="⏭ Not enabled (default)"
  API_URL=""
fi

cat <<EOF

🎉 TokenClock installed!

  Variants: $VARIANT_LABELS
  Clock:    $HOME_DIR/${VARIANTS[0]}/TokenClock
EOF
# When multiple variants: list each path (a single variant is already covered by the line above)
if [ "${#VARIANTS[@]}" -gt 1 ]; then
  for v in "${VARIANTS[@]:1}"; do
    printf '         + %s\n' "$HOME_DIR/$v/TokenClock"
  done
fi

cat <<EOF
  CLI:    $BIN_DIR/tokenclock
EOF
# Source: one line per cloned branch subdir (only when something was actually cloned — the download path may have no src)
for branch in "${BRANCHES[@]}"; do
  [ -d "$BUILD_DIR/$branch" ] && printf '  Source:  %s/%s\n' "$BUILD_DIR" "$branch"
done

cat <<EOF

  API server: $API_LINE
EOF

[ -n "$API_URL" ] && printf '  API endpoint: %s\n' "$API_URL"

# Launch-at-login banner: reflect the real state
if [ "$LAUNCH_AGENT_OK" -eq 1 ] && [ -f "$LAUNCH_AGENT_PATH" ]; then
  printf '  Launch at login: ✓ enabled (%s)\n' "$LAUNCH_AGENT_PATH"
  if [ "$PLATFORM" = macos ]; then
    printf '                    toggle via the clock right-click → Settings\n'
  else
    printf '                    remove this .desktop file to disable\n'
  fi
else
  printf '  Launch at login: ⏭ not enabled\n'
fi

cat <<EOF

Common commands (available after opening a new terminal):
  tokenclock start [--glass|--normal]   start (auto-selects by platform/version)
  tokenclock stop                       stop
  tokenclock restart [--glass|--normal] restart
  tokenclock doctor                     diagnose environment and installed versions
  tokenclock update [--glass|--normal]  pull the latest install.sh, upgrade and restart
  tokenclock update --check             only download the latest script, do not upgrade

── tokenclock doctor ──
EOF
printf '%s\n' "$DOCTOR_OUT"

cat <<EOF

One-liner install:
  curl -fsSL $INSTALL_URL | bash
EOF

#!/usr/bin/env bash
# Validate and optionally publish a TokenClock release made entirely on the project's own machines.
# This script never compiles in GitHub Actions and never commits, tags, or pushes source code.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="${TOKENCLOCK_GH_REPO:-Neo-Isshin/TokenClock}"
VERSION=""
ASSETS_DIR=""
PUBLISH=0

say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'
  fi
}

usage() {
  cat <<'EOF'
Usage: scripts/release.sh vX.Y.Z --assets-dir DIR [--publish]

Without --publish, validates the six locally built release assets and source pins.
With --publish, uploads those exact files to an existing or new GitHub release, then
downloads them again and verifies every byte. Source commits and tags remain manual.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --assets-dir) shift; [ "$#" -gt 0 ] || die "--assets-dir needs a directory"; ASSETS_DIR="$1" ;;
    --publish) PUBLISH=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *) [ -z "$VERSION" ] || die "only one version may be supplied"; VERSION="$1" ;;
  esac
  shift
done

[ -n "$VERSION" ] || { usage; die "missing version"; }
case "$VERSION" in v[0-9]*.[0-9]*.[0-9]*) ;; *) die "version must look like v1.4.8" ;; esac
[ -n "$ASSETS_DIR" ] || die "--assets-dir is required"
ASSETS_DIR="$(cd "$ASSETS_DIR" 2>/dev/null && pwd)" || die "asset directory does not exist"

FILES="
TokenClock-glass-universal.tar.gz
TokenClock-normal-universal.tar.gz
TokenClock-windows-x86_64.zip
TokenClock-windows-x86_64.zip.sha256
TokenClock-x86_64.AppImage
TokenClock-x86_64.AppImage.sha256
"

say "Validating local assets for $VERSION"
for name in $FILES; do
  [ -s "$ASSETS_DIR/$name" ] || die "missing or empty asset: $ASSETS_DIR/$name"
done

verify_sidecar() {
  local payload="$1" sidecar="$2" expected actual
  expected="$(awk 'NF { print tolower($1); exit }' "$sidecar")"
  actual="$(sha256_file "$payload")"
  [ "$expected" = "$actual" ] || die "sidecar mismatch: $(basename "$payload")"
}
verify_sidecar "$ASSETS_DIR/TokenClock-windows-x86_64.zip" "$ASSETS_DIR/TokenClock-windows-x86_64.zip.sha256"
verify_sidecar "$ASSETS_DIR/TokenClock-x86_64.AppImage" "$ASSETS_DIR/TokenClock-x86_64.AppImage.sha256"

command -v tar >/dev/null 2>&1 || die "tar is required"
command -v unzip >/dev/null 2>&1 || die "unzip is required"
unzip -tq "$ASSETS_DIR/TokenClock-windows-x86_64.zip" >/dev/null || die "Windows zip integrity check failed"
unzip -Z1 "$ASSETS_DIR/TokenClock-windows-x86_64.zip" | grep -Eq '(^|/)TokenClock\.exe$' \
  || die "Windows zip does not contain TokenClock.exe"

TMP_DIR="$(mktemp -d -t tokenclock-release.XXXXXX)" || die "cannot create validation directory"
trap 'rm -rf "$TMP_DIR"' EXIT
for variant in glass normal; do
  out="$TMP_DIR/$variant"
  mkdir -p "$out"
  tar -xzf "$ASSETS_DIR/TokenClock-$variant-universal.tar.gz" -C "$out" \
    || die "$variant tarball cannot be extracted"
  [ -x "$out/TokenClock" ] || die "$variant tarball has no executable TokenClock"
  if command -v lipo >/dev/null 2>&1; then
    archs="$(lipo -archs "$out/TokenClock" 2>/dev/null || true)"
    echo "$archs" | grep -qw arm64 || die "$variant binary is missing arm64"
    echo "$archs" | grep -qw x86_64 || die "$variant binary is missing x86_64"
  fi
  if command -v codesign >/dev/null 2>&1; then
    codesign --verify "$out/TokenClock" 2>/dev/null || die "$variant binary signature is invalid"
  fi
done

[ -x "$ASSETS_DIR/TokenClock-x86_64.AppImage" ] \
  || die "Linux AppImage is not executable"

plain="${VERSION#v}"
grep -q "CLI_VERSION=\"$plain\"" "$ROOT/cli/tokenclock" || die "CLI version is not $plain"
grep -q "glass)  echo \"$VERSION\"" "$ROOT/cli/install.sh" || die "Glass installer tag is not $VERSION"
grep -q "normal) echo \"$VERSION\"" "$ROOT/cli/install.sh" || die "Normal installer tag is not $VERSION"
grep -q "linux)  echo \"$VERSION\"" "$ROOT/cli/install.sh" || die "Linux installer tag is not $VERSION"
grep -q "private let version = \"$VERSION\"" "$ROOT/Sources/TokenClock/Views/AboutView.swift" \
  || die "macOS About version is not $VERSION"
grep -q "\"$VERSION\"" "$ROOT/Sources/TokenClock/Windows/WindowsApp.swift" \
  || die "Windows About version is not $VERSION"
grep -q "\"$VERSION\"" "$ROOT/Sources/TokenClock/Linux/LinuxApp.swift" \
  || die "Linux About version is not $VERSION"
bash -n "$ROOT/cli/install.sh"
bash -n "$ROOT/cli/tokenclock"

glass_sha="$(sha256_file "$ASSETS_DIR/TokenClock-glass-universal.tar.gz")"
normal_sha="$(sha256_file "$ASSETS_DIR/TokenClock-normal-universal.tar.gz")"
grep -q "glass)  echo \"$glass_sha\"" "$ROOT/cli/install.sh" \
  || die "Glass tarball SHA is not pinned in cli/install.sh"
grep -q "normal) echo \"$normal_sha\"" "$ROOT/cli/install.sh" \
  || die "Normal tarball SHA is not pinned in cli/install.sh"

say "Local validation passed: six assets, checksums, architectures, signatures, and source pins"
[ "$PUBLISH" -eq 1 ] || { say "Validation only; add --publish after source and tag are pushed."; exit 0; }

command -v gh >/dev/null 2>&1 || die "GitHub CLI is required for --publish"
gh auth status >/dev/null 2>&1 || die "GitHub CLI is not signed in"
git -C "$ROOT" rev-parse -q --verify "refs/tags/$VERSION" >/dev/null \
  || die "local tag $VERSION does not exist; create and review it first"
git -C "$ROOT" ls-remote --exit-code origin "refs/tags/$VERSION" >/dev/null \
  || die "remote tag $VERSION does not exist; push the reviewed tag first"

if ! gh release view "$VERSION" --repo "$REPO" >/dev/null 2>&1; then
  gh release create "$VERSION" --repo "$REPO" --title "$VERSION" --generate-notes
fi
upload_args=()
for name in $FILES; do upload_args+=("$ASSETS_DIR/$name"); done
gh release upload "$VERSION" --repo "$REPO" --clobber "${upload_args[@]}"

VERIFY_DIR="$TMP_DIR/downloaded"
mkdir -p "$VERIFY_DIR"
for name in $FILES; do
  gh release download "$VERSION" --repo "$REPO" --dir "$VERIFY_DIR" --pattern "$name" --clobber
  [ "$(sha256_file "$ASSETS_DIR/$name")" = "$(sha256_file "$VERIFY_DIR/$name")" ] \
    || die "uploaded asset differs after download: $name"
done
say "Published and re-downloaded successfully: $VERSION"

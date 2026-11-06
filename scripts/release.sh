#!/usr/bin/env bash
# Validate and optionally publish a TokenClock release made entirely on the project's own machines.
# This script never uses GitHub and never commits, tags, or pushes source code.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PUBLISH_HOST="${TOKENCLOCK_PUBLISH_HOST:-vps-1T}"
VERSION=""
ASSETS_DIR=""
PUBLISH=0
WITHOUT_WINDOWS=0
LEGACY_ADHOC=0
ONLY_GLASS=0

say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'
  fi
}

usage() {
  cat <<'EOF'
Usage: scripts/release.sh vX.Y.Z --assets-dir DIR [--publish] [--without-windows] [--legacy-adhoc] [--only-glass]

Without --publish, validates the six locally built release assets and source pins.
With --publish, uploads those exact files to the public VPS release directory, then
downloads them again and verifies every byte. Source commits and tags remain manual.
--without-windows publishes macOS/Linux only, preserving the existing Windows channel.
--only-glass publishes only macOS Glass; other editions and source archives stay unchanged.
--legacy-adhoc explicitly validates the historical precompiled macOS format; no Apple notarization or permission-continuity claim.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --assets-dir) shift; [ "$#" -gt 0 ] || die "--assets-dir needs a directory"; ASSETS_DIR="$1" ;;
    --publish) PUBLISH=1 ;;
    --without-windows) WITHOUT_WINDOWS=1 ;;
    --only-glass) ONLY_GLASS=1; WITHOUT_WINDOWS=1 ;;
    --legacy-adhoc) LEGACY_ADHOC=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *) [ -z "$VERSION" ] || die "only one version may be supplied"; VERSION="$1" ;;
  esac
  shift
done

[ -n "$VERSION" ] || { usage; die "missing version"; }
case "$VERSION" in v[0-9]*.[0-9]*.[0-9]*) ;; *) die "version must look like v1.5.1" ;; esac
[ -n "$ASSETS_DIR" ] || die "--assets-dir is required"
ASSETS_DIR="$(cd "$ASSETS_DIR" 2>/dev/null && pwd)" || die "asset directory does not exist"

FILES="
TokenClock-glass-universal.tar.gz
TokenClock-normal-universal.tar.gz
TokenClock-x86_64.AppImage
TokenClock-x86_64.AppImage.sha256
"
if [ "$WITHOUT_WINDOWS" -eq 0 ]; then
  FILES="$FILES
TokenClock-windows-x86_64.zip
TokenClock-windows-x86_64.zip.sha256
"
fi

if [ "$ONLY_GLASS" -eq 1 ]; then FILES="TokenClock-glass-universal.tar.gz"; fi
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
if [ "$WITHOUT_WINDOWS" -eq 0 ]; then
  verify_sidecar "$ASSETS_DIR/TokenClock-windows-x86_64.zip" "$ASSETS_DIR/TokenClock-windows-x86_64.zip.sha256"
fi
if [ "$ONLY_GLASS" -eq 0 ]; then verify_sidecar "$ASSETS_DIR/TokenClock-x86_64.AppImage" "$ASSETS_DIR/TokenClock-x86_64.AppImage.sha256"; fi

command -v tar >/dev/null 2>&1 || die "tar is required"
if [ "$WITHOUT_WINDOWS" -eq 0 ]; then
  command -v unzip >/dev/null 2>&1 || die "unzip is required"
  unzip -tq "$ASSETS_DIR/TokenClock-windows-x86_64.zip" >/dev/null || die "Windows zip integrity check failed"
  unzip -Z1 "$ASSETS_DIR/TokenClock-windows-x86_64.zip" | grep -E '(^|/)TokenClock\.exe$' >/dev/null \
    || die "Windows zip does not contain TokenClock.exe"
fi

TMP_DIR="$(mktemp -d -t tokenclock-release.XXXXXX)" || die "cannot create validation directory"
trap 'rm -rf "$TMP_DIR"' EXIT
variants="glass normal"
[ "$ONLY_GLASS" -eq 0 ] || variants="glass"
for variant in $variants; do
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
    if [ "$LEGACY_ADHOC" -eq 1 ]; then
      codesign --verify --strict "$out/TokenClock" || die "$variant binary signature is invalid"
      signature_details="$(codesign -dv --verbose=2 "$out/TokenClock" 2>&1)"
      case "$signature_details" in
        *Signature=adhoc*) ;;
        *) die "legacy distribution requires ad-hoc artifacts; a local signing identity must not be published" ;;
      esac
    else
      python3 "$ROOT/scripts/macos-signing.py" verify-release --binary "$out/TokenClock" --variant "$variant" >/dev/null \
        || die "$variant requires Apple Developer ID signing (historical ad-hoc packages require explicit --legacy-adhoc)"
    fi
  fi
done

if [ "$ONLY_GLASS" -eq 0 ]; then
  [ -x "$ASSETS_DIR/TokenClock-x86_64.AppImage" ] || die "Linux AppImage is not executable"
fi

plain="${VERSION#v}"
grep -q "static let version = \"$plain\"" "$ROOT/Sources/TokenClock/Config/AppConfig.swift" \
  || die "Release notification version is not $plain"
grep -q "CLI_VERSION=\"$plain\"" "$ROOT/cli/tokenclock" || die "CLI version is not $plain"
grep -q "glass)  echo \"$VERSION\"" "$ROOT/cli/install.sh" || die "Glass installer tag is not $VERSION"
if [ "$ONLY_GLASS" -eq 0 ]; then
grep -q "normal) echo \"$VERSION\"" "$ROOT/cli/install.sh" || die "Normal installer tag is not $VERSION"
fi
if [ "$ONLY_GLASS" -eq 0 ]; then
grep -q "linux)  echo \"$VERSION\"" "$ROOT/cli/install.sh" || die "Linux installer tag is not $VERSION"
fi
grep -q "private let version = \"$VERSION\"" "$ROOT/Sources/TokenClock/Views/AboutView.swift" \
  || die "macOS About version is not $VERSION"
if [ "$WITHOUT_WINDOWS" -eq 0 ]; then
  grep -q "\"$VERSION\"" "$ROOT/Sources/TokenClock/Windows/WindowsApp.swift" \
    || die "Windows About version is not $VERSION"
fi
if [ "$ONLY_GLASS" -eq 0 ]; then
grep -q "\"$VERSION\"" "$ROOT/Sources/TokenClock/Linux/LinuxApp.swift" \
  || die "Linux About version is not $VERSION"
fi
bash -n "$ROOT/cli/install.sh"
bash -n "$ROOT/cli/tokenclock"

glass_sha="$(sha256_file "$ASSETS_DIR/TokenClock-glass-universal.tar.gz")"
normal_sha=""
if [ "$ONLY_GLASS" -eq 0 ]; then
normal_sha="$(sha256_file "$ASSETS_DIR/TokenClock-normal-universal.tar.gz")"
fi
grep -q "glass)  echo \"$glass_sha\"" "$ROOT/cli/install.sh" \
  || die "Glass tarball SHA is not pinned in cli/install.sh"
if [ "$ONLY_GLASS" -eq 0 ]; then
grep -q "normal) echo \"$normal_sha\"" "$ROOT/cli/install.sh" \
  || die "Normal tarball SHA is not pinned in cli/install.sh"
fi

say "Local validation passed: selected assets, checksums, architectures, signatures, and source pins"
[ "$PUBLISH" -eq 1 ] || { say "Validation only; add --publish after source and tag are pushed."; exit 0; }

git -C "$ROOT" rev-parse -q --verify "refs/tags/$VERSION" >/dev/null \
  || die "local tag $VERSION does not exist; create and review it first"
git -C "$ROOT" ls-remote --exit-code gitea "refs/tags/$VERSION" >/dev/null \
  || die "remote tag $VERSION does not exist; push the reviewed tag first"

publisher_args=()
[ "$WITHOUT_WINDOWS" -eq 0 ] || publisher_args+=(--without-windows)
[ "$ONLY_GLASS" -eq 0 ] || publisher_args+=(--only-glass)
source_args=(--source-ref glass=main)
if [ "$ONLY_GLASS" -eq 0 ]; then source_args+=(--source-ref normal=normal --source-ref windows=windows-port --source-ref linux=codex/linux-theme-parity); fi
python3 -B "$ROOT/scripts/publish-release.py" --version "$VERSION" \
  --assets-dir "$ASSETS_DIR" --output "$TMP_DIR/site" --repo "$ROOT" \
  "${source_args[@]}" "${publisher_args[@]}"

remote_stage="$(ssh -o BatchMode=yes "$PUBLISH_HOST" 'mktemp -d /home/debian/tokenclock-release.XXXXXX')"
case "$remote_stage" in /home/debian/tokenclock-release.*) ;; *) die "Invalid VPS staging directory" ;; esac
rsync -a "$TMP_DIR/site/" "$PUBLISH_HOST:$remote_stage/site/"
# Activate payloads first; metadata/latest pointers must never advertise a partial upload.
ssh -o BatchMode=yes "$PUBLISH_HOST" \
  "sudo install -d -m 755 /var/www/tokenclock && sudo rsync -a --exclude='latest*.json' --exclude='index.html' '$remote_stage/site/' /var/www/tokenclock/ && sudo rsync -a '$remote_stage/site/' /var/www/tokenclock/ && sudo chmod -R a+rX /var/www/tokenclock"

VERIFY_DIR="$TMP_DIR/downloaded"
mkdir -p "$VERIFY_DIR"
for name in $FILES; do
  curl -fL --retry 3 --connect-timeout 15 \
    "https://www.ailyre.com/tokenclock/releases/download/$VERSION/$name" -o "$VERIFY_DIR/$name"
  [ "$(sha256_file "$ASSETS_DIR/$name")" = "$(sha256_file "$VERIFY_DIR/$name")" ] \
    || die "uploaded asset differs after download: $name"
done
say "Published and re-downloaded successfully: $VERSION"

#!/usr/bin/env bash
#
# build-appimage.sh —— 在 swift:6.0-jammy 容器内构建 Linux x86_64 AppImage。
#
# 产物（落在仓库根）：TokenClock-x86_64.AppImage + TokenClock-x86_64.AppImage.sha256
#
# 用法（在装有 Docker 的 Linux/x86_64 主机上，于仓库根执行）：
#   docker run --rm -v "$PWD":/src -w /src swift:6.0-jammy bash scripts/build-appimage.sh
#
# 设计要点：
#   * swift:6.0-jammy = Ubuntu 22.04 / glibc 2.35 → AppImage 兼容 2022+ 主流发行版。
#   * -Xswiftc -static-stdlib：静态链 Swift 运行时，去掉对目标机 Swift 运行时的依赖。
#   * linuxdeploy + GTK 插件：把 GTK3 及其依赖打进 AppDir，用户机无需装 GTK，
#     只剩 glibc ≥ 2.35 一个运行期要求。
#   * APPIMAGE_EXTRACT_AND_RUN=1：容器内通常无 /dev/fuse，让 linuxdeploy/appimagetool
#     这俩 AppImage 工具自解压到 /tmp 运行，免 FUSE。
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ARCH=x86_64
APP=TokenClock
APPIMAGE="$APP-$ARCH.AppImage"
ICON_NAME=tokenclock

step() { printf '\n🛠  %s\n' "$*"; }
ok()   { printf '  ✓ %s\n' "$*"; }
die()  { printf '\n❌ %s\n' "$*" >&2; exit 1; }

# ── 1. 构建依赖 ──
step "Installing build deps (apt)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends \
  libgtk-3-dev libsqlite3-dev libcurl4-openssl-dev \
  pkg-config file ca-certificates wget libfuse2 \
  >/dev/null
ok "deps installed"

# ── 2. 编译 ──
step "Building TokenClock (swift build -c release · x86_64 · static stdlib)"
swift build -c release -Xswiftc -static-stdlib
BIN="$ROOT/.build/release/$APP"
[ -f "$BIN" ] || die "build artifact not found: $BIN"
ok "binary: $BIN ($(du -h "$BIN" | cut -f1))"

# ── 3. 组装 AppDir ──
step "Assembling AppDir"
APPDIR="$ROOT/AppDir"
rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr/bin" "$APPDIR/usr/share/applications" "$APPDIR/usr/share/icons/hicolor/256x256/apps"

cp "$BIN" "$APPDIR/usr/bin/$APP"
chmod +x "$APPDIR/usr/bin/$APP"

ICON_SRC="$ROOT/Sources/TokenClock/Resources/glass_disc.png"
[ -f "$ICON_SRC" ] || die "icon source not found: $ICON_SRC"
cp "$ICON_SRC" "$APPDIR/usr/share/icons/hicolor/256x256/apps/$ICON_NAME.png"
ok "icon installed ($ICON_SRC)"

cat > "$APPDIR/usr/share/applications/$APP.desktop" <<EOF
[Desktop Entry]
Name=TokenClock
Comment=Token usage clock for AI coding tools
Exec=$APP
Icon=$ICON_NAME
Type=Application
Categories=Utility;
Terminal=false
StartupWMClass=TokenClock
EOF
ok "desktop entry written"

# ── 4. linuxdeploy + GTK 插件 → bundle GTK，产出 AppImage ──
step "Fetching linuxdeploy + GTK plugin"
TOOLS="$ROOT/.appimage-tools"
mkdir -p "$TOOLS"
LD="$TOOLS/linuxdeploy-$ARCH.AppImage"
LDGTK="$TOOLS/linuxdeploy-plugin-gtk-$ARCH.AppImage"
[ -f "$LD" ]    || wget -q -O "$LD"    "https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-$ARCH.AppImage"
[ -f "$LDGTK" ] || wget -q -O "$LDGTK" "https://github.com/linuxdeploy/linuxdeploy-plugin-gtk/releases/download/continuous/linuxdeploy-plugin-gtk-$ARCH.AppImage"
chmod +x "$LD" "$LDGTK"
ok "linuxdeploy + gtk plugin ready"

# 容器内无 FUSE：让 AppImage 工具自解压运行
export APPIMAGE_EXTRACT_AND_RUN=1
export ARCH="$ARCH"
export VERSION="${VERSION:-0.0.0}"          # linuxdeploy 要求 VERSION 环境变量
export OUTPUT="$APPIMAGE"
export DEPLOY_GTK_VERSION=3                 # GTK 插件：bundle GTK3 全家桶

step "Packaging AppImage (linuxdeploy --plugin gtk --output appimage)"
# 用 linuxdeploy-plugin-gtk 提供的入口（它在内部调 linuxdeploy，并注入 GTK bundle 逻辑）
"$LD" --appdir "$APPDIR" \
      --plugin gtk \
      --desktop-file "$APPDIR/usr/share/applications/$APP.desktop" \
      --icon-file    "$APPDIR/usr/share/icons/hicolor/256x256/apps/$ICON_NAME.png" \
      --output appimage \
  || die "linuxdeploy packaging failed"
[ -f "$ROOT/$APPIMAGE" ] || die "AppImage not produced: $ROOT/$APPIMAGE"
chmod +x "$ROOT/$APPIMAGE"
ok "$APPIMAGE ($(du -h "$ROOT/$APPIMAGE" | cut -f1))"

# ── 5. SHA256 sidecar ──
step "SHA256 sidecar"
( cd "$ROOT" && sha256sum "$APPIMAGE" > "$APPIMAGE.sha256" )
ok "$APPIMAGE.sha256"

# ── 6. 修产物属主（容器内以 root 构建、挂载到主机时，把属主还给主机用户）──
HOST_OWNER="$(stat -c %u:%g "$ROOT" 2>/dev/null || true)"
if [ -n "$HOST_OWNER" ] && [ "$(id -u)" = 0 ] && [ "${HOST_OWNER%%:*}" != 0 ]; then
  chown "$HOST_OWNER" "$ROOT/$APPIMAGE" "$ROOT/$APPIMAGE.sha256" 2>/dev/null || true
  ok "ownership → $HOST_OWNER"
fi

echo
echo "Done: $ROOT/$APPIMAGE (+ $APPIMAGE.sha256)"

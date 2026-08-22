#!/bin/sh

# Keep host desktop plug-ins from being loaded into the AppImage's bundled GLib.
# Newer distributions can ship gvfs/IBus modules built against a newer GLib ABI;
# loading those modules would otherwise produce symbol errors even though
# TokenClock itself and all of its bundled libraries are compatible.
APP_ROOT="${APPDIR:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)}"
EMPTY_MODULES="$APP_ROOT/usr/lib/tokenclock-empty-modules"

export GIO_MODULE_DIR="$EMPTY_MODULES"
export GIO_EXTRA_MODULES=""
export GIO_USE_VFS="local"
export GTK_IM_MODULE="xim"

exec "$APP_ROOT/usr/bin/TokenClock" "$@"

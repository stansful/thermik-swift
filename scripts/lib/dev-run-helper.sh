#!/bin/sh
# Thermik (MIT). Developer convenience (no install, no root): run a freshly built helper in the foreground against
# the mock fan backend (MockFanController — the SMC is never touched) to watch its logs. Ctrl-C stops it (the
# SIGINT handler restores and exits 0). Real SMC access needs the installed daemon: launchd registers the Mach
# service, and a hand-started process cannot claim a system Mach service name, so no client can connect here.
#   scripts/lib/dev-run-helper.sh [path/to/Thermik.app]     default: build/DerivedData/Build/Products/Debug/Thermik.app
# In another terminal:  log stream --predicate 'subsystem == "app.thermik.helper"' --info
# Without --mock the helper refuses to run unless it is root (exit 77).
set -eu
if [ $# -gt 0 ]; then
    APP="$1"
else
    APP="$(cd "$(dirname "$0")/../.." && pwd)/build/DerivedData/Build/Products/Debug/Thermik.app"
fi
HELPER="$APP/Contents/MacOS/thermik-helper"
[ -x "$HELPER" ] || { echo "helper not found: $HELPER (run scripts/lib/build.sh Debug)" >&2; exit 2; }
exec "$HELPER" --mock

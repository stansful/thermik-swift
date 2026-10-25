#!/bin/sh
# Developer convenience (no install): run a freshly built helper in the foreground
# against the mock fan backend, to watch its logs. Real SMC access needs the
# installed daemon (launchd registers the Mach service; a hand-started process
# cannot claim a system Mach service name).
#   ./Scripts/dev-run-helper.sh build/Debug/Thermik.app
set -eu
APP="${1:?path to Thermik.app}"
exec "$APP/Contents/MacOS/thermik-helper" --mock

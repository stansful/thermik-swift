#!/bin/sh
# Removes the Thermik privileged helper (both install modes). Run by the USER:
#   sudo ./Scripts/uninstall-helper.sh
# The helper restores automatic fan control on SIGTERM (sent by bootout).
set -u
LABEL="app.thermik.helper"
if [ "$(id -u)" -ne 0 ]; then echo "run with sudo" >&2; exit 1; fi
/bin/launchctl bootout "system/$LABEL" 2>/dev/null || true
/bin/rm -f "/Library/LaunchDaemons/$LABEL.plist" "/Library/PrivilegedHelperTools/$LABEL" "/var/run/$LABEL.manual"
/bin/rm -rf "/Library/Application Support/Thermik"
echo "Thermik helper removed. If Thermik.app used SMAppService, also remove it from"
echo "System Settings > General > Login Items & Extensions (or delete Thermik.app)."

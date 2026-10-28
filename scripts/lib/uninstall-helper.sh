#!/bin/sh
# Thermik (MIT). Removes the Thermik privileged helper (both install modes). Run by the USER:
#   sudo scripts/lib/uninstall-helper.sh
# The helper restores automatic fan control on SIGTERM (sent by bootout) before it exits.
# The in-app "Uninstall Helper" does the same without a password (XPC uninstallLegacyHelper / SMAppService.unregister).
set -u
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
LABEL="app.thermik.helper"
if [ "$(id -u)" -ne 0 ]; then echo "run with sudo" >&2; exit 1; fi
launchctl bootout "system/$LABEL" 2>/dev/null || true
rm -f "/Library/LaunchDaemons/$LABEL.plist" "/Library/PrivilegedHelperTools/$LABEL" "/var/run/$LABEL.manual"
rm -rf "/Library/Application Support/Thermik"
if launchctl print "system/$LABEL" >/dev/null 2>&1; then
    echo "Note: system/$LABEL is still loaded — it was registered by Thermik.app through SMAppService."
fi
echo "Thermik helper removed. If Thermik.app used SMAppService (Team-ID build), also turn it off in"
echo "System Settings > General > Login Items & Extensions (or use Thermik's \"Uninstall Helper\", or delete Thermik.app)."

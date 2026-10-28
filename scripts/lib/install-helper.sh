#!/bin/sh
# Thermik (MIT). FALLBACK legacy install of the privileged helper (SPEC §6.1 R6) for ad-hoc builds, for when the
# in-app "Install Helper…" (administrator prompt via NSAppleScript) does not work. Run by the USER:
#   sudo scripts/lib/install-helper.sh [path/to/Thermik.app]     default: build/DerivedData/Build/Products/Debug/Thermik.app
#   scripts/lib/install-helper.sh --check [path/to/Thermik.app]  no root: verify the bundle and print what would be installed,
#                                                                incl. the client requirement the helper will enforce
# Same steps as LegacyHelperInstaller.installScript (the in-app path; `thermik-probe helper plan` prints that script):
#   1. boot out a running helper (it restores automatic fan control on SIGTERM),
#   2. copy the bundled helper into a temp file inside root-owned /Library/PrivilegedHelperTools and verify THAT copy
#      against the bundled helper's cdhash (Team requirement for Team-ID builds) before activating it; give the
#      verified copy Thermik's file icon (System Settings › Login Items shows it for an ad-hoc helper),
#   3. write /Library/LaunchDaemons/app.thermik.helper.plist (Program = the root-owned copy) and the root-owned trust
#      file that pins this Thermik.app build's cdhash(es) — the helper accepts no other client,
#   4. launchctl bootstrap system.
# Re-run after every ad-hoc rebuild: the app's cdhash changes. Remove with: sudo scripts/lib/uninstall-helper.sh
set -eu
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

LABEL="app.thermik.helper"
APP_ID="app.thermik.Thermik"
DST="/Library/PrivilegedHelperTools/$LABEL"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
SUPPORT="/Library/Application Support/Thermik"
TRUST="$SUPPORT/trusted-clients.plist"

CHECK=0
if [ "${1:-}" = "--check" ]; then CHECK=1; shift; fi
if [ $# -gt 0 ]; then
    APP="$(cd "$1" && pwd)"
else
    APP="$(cd "$(dirname "$0")/../.." && pwd)/build/DerivedData/Build/Products/Debug/Thermik.app"
fi
SRC="$APP/Contents/MacOS/thermik-helper"
APP_EXE="$APP/Contents/MacOS/Thermik"
{ [ -f "$SRC" ] && [ -f "$APP_EXE" ]; } || { echo "not a Thermik.app with an embedded helper: $APP" >&2; exit 2; }

# codesign -d prints its report on stderr.
field() { codesign -d --verbose=4 "$1" 2>&1 | sed -n "s/^$2=//p" | head -n 1; }
# cdhash of one architecture slice (empty if the binary has no such slice).
slice_cdhash() { codesign -d --verbose=4 -a "$2" "$1" 2>&1 | sed -n 's/^CDHash=//p' | head -n 1; }
cdhashes() { for arch in arm64 x86_64; do slice_cdhash "$1" "$arch"; done | awk 'length($0) == 40' | sort -u; }

[ "$(field "$SRC" Identifier)" = "$LABEL" ] || { echo "helper is not signed as $LABEL" >&2; exit 3; }
[ "$(field "$APP_EXE" Identifier)" = "$APP_ID" ] || { echo "app is not signed as $APP_ID" >&2; exit 3; }
codesign --verify --strict "$SRC" || { echo "helper signature invalid" >&2; exit 3; }
codesign --verify --strict "$APP" || { echo "app signature invalid" >&2; exit 3; }

TEAM="$(field "$SRC" TeamIdentifier)"
if [ -n "$TEAM" ] && [ "$TEAM" != "not set" ]; then
    REQ="anchor apple generic and certificate leaf[subject.OU] = \"$TEAM\" and identifier \"$LABEL\""
else
    REQ=""
    for h in $(cdhashes "$SRC"); do REQ="${REQ:+$REQ or }cdhash H\"$h\""; done
    [ -n "$REQ" ] || { echo "cannot read the helper's cdhash" >&2; exit 3; }
    REQ="($REQ) and identifier \"$LABEL\""
fi
CLIENTS="$(cdhashes "$APP_EXE")"
[ -n "$CLIENTS" ] || { echo "cannot read the app's cdhash" >&2; exit 3; }

write_plists() {   # $1 = launchd plist path, $2 = trust file path
    cat > "$1" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>AssociatedBundleIdentifiers</key>
	<array>
		<string>$APP_ID</string>
	</array>
	<key>KeepAlive</key>
	<dict>
		<key>SuccessfulExit</key>
		<false/>
	</dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>MachServices</key>
	<dict>
		<key>$LABEL</key>
		<true/>
	</dict>
	<key>ProcessType</key>
	<string>Adaptive</string>
	<key>Program</key>
	<string>$DST</string>
	<key>ProgramArguments</key>
	<array>
		<string>$DST</string>
	</array>
</dict>
</plist>
EOF
    {
        printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'
        printf '%s\n' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
        printf '%s\n' '<plist version="1.0">' '<dict>' '	<key>cdhashes</key>' '	<array>'
        for h in $CLIENTS; do printf '		<string>%s</string>\n' "$h"; done
        printf '%s\n' '	</array>' '</dict>' '</plist>'
    } > "$2"
    plutil -lint -s "$1" "$2"
}

if [ "$CHECK" -eq 1 ]; then
    TMPD="$(mktemp -d "${TMPDIR:-/tmp}/thermik-install-check.XXXXXX")"
    trap 'rm -rf "$TMPD"' EXIT
    write_plists "$TMPD/launchd.plist" "$TMPD/trust.plist"
    codesign --verify --strict -R "=$REQ" "$SRC"
    echo "app:                $APP"
    echo "helper requirement: $REQ (verified against the bundled helper)"
    # shellcheck disable=SC2086,SC2116 # the unquoted echo puts the hashes on one line
    echo "trusted cdhashes:   $(echo $CLIENTS)"
    echo "generated plists:   plutil -lint OK"
    # The client requirement the helper will enforce (same peer self-check as scripts/lib/build.sh). The bundled
    # helper is only executed here, unprivileged: never run code from the user-writable bundle as root.
    if [ "$(id -u)" -ne 0 ]; then
        PEER="$("$SRC" --peer-requirement "$APP")" || { echo "the helper produced no client requirement" >&2; exit 3; }
        for arch in $(lipo -archs "$APP_EXE"); do
            codesign --verify --strict -a "$arch" -R "=$PEER" "$APP" \
                || { echo "the $arch app does not satisfy the helper's client requirement: $PEER" >&2; exit 3; }
        done
        echo "client requirement: $PEER (verified against the app)"
        case "$PEER" in
            *get-task-allow*) ;;
            *) echo "WARNING: developer build (THERMIK_DEBUGGABLE): this helper accepts debuggable clients" ;;
        esac
    fi
    echo "check OK — install with: sudo $0 \"$APP\""
    exit 0
fi

[ "$(id -u)" -eq 0 ] || { echo "run with sudo (or use --check)" >&2; exit 1; }
umask 022
launchctl bootout "system/$LABEL" 2>/dev/null || true
install -d -m 0755 -o root -g wheel /Library/PrivilegedHelperTools "$SUPPORT"
T="$(mktemp /Library/PrivilegedHelperTools/.thermik-helper.XXXXXX)"
trap 'rm -f "$T" "$SUPPORT/.plist.new" "$SUPPORT/.trust.new" "$SUPPORT/.icon.new"' EXIT
cp -X "$SRC" "$T"
chown root:wheel "$T"
chmod 0755 "$T"
codesign --verify --strict -R "=$REQ" "$T"
# Thermik's icon: the resource fork LegacyHelperInstaller.iconResourceFork builds ('icns' resource -16455) plus the
# kHasCustomIcon Finder flag. Cosmetic, never fatal, and only after the verification (`--strict` rejects resource
# forks). The .icns is read as the invoking user (never root, so not from a root shell: SUDO_UID=0): a symlink in the
# user-writable bundle must not leak a root-only file. Same limits as LegacyHelperInstaller.appIcon: 256 KiB, 'icns'.
# shellcheck disable=SC2024 # only the read runs as the user; root writes into its own directory on purpose
if [ "${SUDO_UID:-0}" -ne 0 ] \
    && sudo -u "#$SUDO_UID" head -c 262145 -- "$APP/Contents/Resources/AppIcon.icns" > "$SUPPORT/.icon.new" \
    && N=$(($(wc -c < "$SUPPORT/.icon.new"))) && [ "$N" -le 262144 ] \
    && [ "$(head -c 4 "$SUPPORT/.icon.new")" = icns ]; then
    H="$(printf '%08x%08x%08x%08x' 256 $((260 + N)) $((4 + N)) 50)"
    {
        printf '%s%0480d%08x' "$H" 0 "$N" | xxd -r -p
        cat "$SUPPORT/.icon.new"
        printf '%s%s' "$H" 0000000000000000001c0032000069636e730000000abfb9ffff0000000000000000 | xxd -r -p
    } > "$T/..namedfork/rsrc" \
        && xattr -wx com.apple.FinderInfo 0000000000000000040000000000000000000000000000000000000000000000 "$T" || true
fi
mv -f "$T" "$DST"
write_plists "$SUPPORT/.plist.new" "$SUPPORT/.trust.new"
chown root:wheel "$SUPPORT/.plist.new" "$SUPPORT/.trust.new"
chmod 0644 "$SUPPORT/.plist.new" "$SUPPORT/.trust.new"
mv -f "$SUPPORT/.trust.new" "$TRUST"
mv -f "$SUPPORT/.plist.new" "$PLIST"
launchctl enable "system/$LABEL" 2>/dev/null || true
n=0
until launchctl bootstrap system "$PLIST"; do
    n=$((n + 1))
    [ "$n" -lt 5 ] || { echo "launchctl bootstrap failed" >&2; exit 4; }
    sleep 1
done
# shellcheck disable=SC2086,SC2116 # the unquoted echo puts the hashes on one line
echo "Thermik helper installed: $DST (trusts $(echo $CLIENTS))."
echo "Check: sudo launchctl print system/$LABEL | head -20"
echo "Logs:  log stream --predicate 'subsystem == \"$LABEL\"' --info"

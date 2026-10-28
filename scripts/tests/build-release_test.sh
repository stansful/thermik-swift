#!/usr/bin/env bash
# Tests of scripts/build-release.sh against a fake tree in a temp dir (TMPDIR), never this repository and never real
# Xcode: the fake root has the script, scripts/lib/version.sh and a Config/Shared.xcconfig (version 1.2.3, build 42),
# plus stubs of scripts/lib/build.sh (it writes a fake Release build, as STUB_* say: Thermik.app with its Info.plist,
# the "binaries" Thermik and thermik-helper with a UUID per architecture and a signature that seals the bundle's
# files, and the dSYMs of both binaries) and scripts/lib/selftest.sh (for --test). plutil, lipo, dwarfdump, codesign
# and ditto are stubs too, first on PATH, on macOS as well, so the test is the same on both systems: they read the fake
# build, and ditto's "zip" is a tar archive. Runs the script under $TEST_BASH (default: bash from PATH).
#
#   scripts/tests/build-release_test.sh          KEEP=1 keeps the temp dir
#
# Prints 'ok <name>' / 'not ok <name>: <why>' and exits non-zero on a failure.
# The conditions of check() are eval'd when it runs: single quotes on purpose, and the variables they read are
# set outside them.
# shellcheck disable=SC2016,SC2034
set -u
# SIGPIPE ignored, as on the GitHub runner (every step inherits that from its Node.js), for these tests and the
# scripts they run: a reader that stops early makes its writer fail with "Broken pipe" there instead of dying quietly
trap "" PIPE

HERE="$(cd "$(dirname "$0")" && pwd -P)"
TREE="$(cd "$HERE/../.." && pwd -P)"
BASH_BIN="${TEST_BASH:-bash}"
# no temp dir stops here: an empty WORK would make the current directory (the checkout) the work dir, and the
# EXIT trap would delete it
if ! WORK="$(mktemp -d "${TMPDIR:-/tmp}/build-release-test.XXXXXX")" || ! WORK="$(cd "$WORK" && pwd -P)"; then
  echo "not ok no temp dir in ${TMPDIR:-/tmp}"
  exit 1
fi
if [ -z "${KEEP:-}" ]; then trap 'rm -rf "$WORK"' EXIT; else echo "# work dir: $WORK"; fi

V=1.2.3
BUILD=42
APP_ZIP="Thermik-$V.zip"
DSYMS_ZIP="Thermik-$V-dSYMs.zip"
ASSETS="$APP_ZIP $DSYMS_ZIP SHA256SUMS"
ADHOC="ad-hoc, без нотаризации (как в релизах GitHub)"
NL='
'

# The environment of every run; a test changes a variable for one run with `VAR=value br ...`. The script runs no
# git, and nothing it runs may read the user's git config either (HOME is in the temp dir)
export HOME="$WORK/home" XDG_CONFIG_HOME="$WORK/home/.config" GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.invalid
# git never finds a repository above the temp dir (a TMPDIR inside some checkout)
GIT_CEILING_DIRECTORIES="$(dirname "$WORK")"
export GIT_CEILING_DIRECTORIES
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR CDPATH
export STUB_LOG="$WORK/stub.log"
unset STUB_BUILD_FAIL STUB_APP STUB_VERSION STUB_BUILD STUB_APP_ARCHS STUB_HELPER_ARCHS STUB_DSYM STUB_SIGN STUB_DITTO
unset STUB_SELFTEST_FAIL
mkdir -p "$HOME"
# the script's temp dir (and the ditto stub's) land here, an absolute path whatever the caller's TMPDIR (the script
# runs from WORK): the test checks that none is left behind
mkdir -p "$WORK/tmp"
export TMPDIR="$WORK/tmp"

pass=0 fail=0
ok() {
  echo "ok $1"
  pass=$((pass + 1))
}
nok() {
  echo "not ok $1: $2"
  fail=$((fail + 1))
}
check() {
  if eval "$2"; then ok "$1"; else nok "$1" "rc=$RC; condition: $2; output:
$OUT
stubs:
$(cat "$STUB_LOG" 2>/dev/null)"; fi
}
has() { case $OUT in *"$1"*) return 0 ;; esac; return 1; }
# line <s>: a line of the output is exactly s
line() { case "$NL$OUT$NL" in *"$NL$1$NL"*) return 0 ;; esac; return 1; }
# ends <s>: the output ends with s
ends() { case $OUT in *"$1") return 0 ;; esac; return 1; }
# in_order <s...>: the output has these strings, in this order
in_order() {
  local rest="$OUT" s
  for s; do
    case $rest in *"$s"*) rest=${rest#*"$s"} ;; *) return 1 ;; esac
  done
}
logged() { grep -qxF -- "$1" "$STUB_LOG" 2>/dev/null; }
# logged_like <pattern>: a line of the stub log matches the shell pattern
logged_like() {
  local l
  while IFS= read -r l; do
    # shellcheck disable=SC2254 # a pattern on purpose
    case $l in $1) return 0 ;; esac
  done <"$STUB_LOG"
  return 1
}
ran() { grep -q "^$1" "$STUB_LOG" 2>/dev/null; }
# nothing_ran: no stub ran in the last run; untouched: nor did it write anything to the fake root's build/
nothing_ran() { [ ! -s "$STUB_LOG" ]; }
untouched() { nothing_ran && [ ! -e "$ROOT/build" ]; }
# no_temp: TMPDIR is empty again (the script removed its temp dir, the ditto stub its own)
no_temp() { [ -z "$(ls -A "$TMPDIR")" ]; }
sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi
}
# sums_ok <dir> <file...>: SHA256SUMS in dir lists exactly these files, in this order, with their right sums
sums_ok() {
  local dir="$1" f want=''
  shift
  for f; do want="$want$(cd "$dir" && sha256 "$f")
"; done
  [ "$(cat "$dir/SHA256SUMS")" = "${want%
}" ] && (cd "$dir" && sha256 -c SHA256SUMS >/dev/null 2>&1)
}
# listing <dir>: the names in dir, hidden ones too, sorted, one line
# shellcheck disable=SC2012 # the release files have plain names
listing() { (cd "$1" && ls -A | LC_ALL=C sort | tr '\n' ' '); }
sorted() { printf '%s\n' "$@" | LC_ALL=C sort | tr '\n' ' '; }
# unpack <archive> <dir>: what an archive of the ditto stub (a tar archive) holds, into a new dir
unpack() { rm -rf "$2" && mkdir -p "$2" && tar -xf "$1" -C "$2"; }

echo "# scripts/build-release.sh under $("$BASH_BIN" -c 'echo "bash $BASH_VERSION"')"

# --- the stubs: the fake root's scripts in STUBS, the tools first on PATH in BIN
STUBS="$WORK/stubs"
BIN="$WORK/bin"
mkdir -p "$STUBS" "$BIN"
# seal_fn: the function with which the build.sh stub signs an app and the codesign stub verifies it: every file of
# the bundle but the seal itself, with its checksum, sorted
seal_fn() {
  cat <<'EOF'
# seal <bundle>: the files of the bundle (but the seal), each with its checksum
seal() {
  (cd "$1" && find . -type f ! -path ./Contents/_CodeSignature/CodeResources | LC_ALL=C sort |
    while IFS= read -r f; do printf '%s %s\n' "$(cksum <"$f")" "$f"; done)
}
EOF
}
{
  cat <<'EOF'
#!/bin/sh
# scripts/lib/build.sh stub: logs its arguments, then writes a fresh fake build into
# build/DerivedData/Build/Products/<configuration> as Xcode would: Thermik.app with an Info.plist of the version and
# the build number in Config/Shared.xcconfig, the "binaries" Contents/MacOS/Thermik and thermik-helper (one
# "uuid <UUID> <arch>" line per architecture), a resource and the signature, Contents/_CodeSignature/CodeResources: a
# "signer" line and the seal of every other file of the bundle; next to the app Thermik.app.dSYM and
# thermik-helper.dSYM, whose DWARF files have the binaries' UUIDs. STUB_*:
#   STUB_BUILD_FAIL=1  fails as xcodebuild does, writing nothing
#   STUB_APP           none: no app at all; nohelper: no Contents/MacOS/thermik-helper
#   STUB_VERSION       CFBundleShortVersionString instead of MARKETING_VERSION (none: no such key)
#   STUB_BUILD         CFBundleVersion instead of CURRENT_PROJECT_VERSION (none: no such key)
#   STUB_APP_ARCHS     the app's architectures (default: x86_64 arm64); STUB_HELPER_ARCHS the helper's
#   STUB_DSYM          missing-app, missing-helper: no such dSYM; stale-app, stale-helper: the dSYM of another build
#                      (other UUIDs); thin-helper: the helper's dSYM has arm64 only; nodebug-app, nodebug-helper: the
#                      dSYM has the UUIDs but no debug information (as dsymutil makes it from a stripped binary)
# It logs whether the products directory was there before ("products before build.sh: clean" or "stale"): Xcode
# builds on top of what it finds.
#   STUB_SIGN          adhoc (the default); team: an Apple Development identity with a Team ID; broken: a file of the
#                      app changes after the signing
printf 'build.sh %s\n' "$*" >>"$STUB_LOG"
if [ $# != 1 ] || { [ "$1" != Debug ] && [ "$1" != Release ]; }; then
  echo "usage: scripts/lib/build.sh [Debug|Release] [--debuggable]" >&2
  exit 64
fi
if [ -n "${STUB_BUILD_FAIL:-}" ]; then
  echo "xcodebuild FAILED (full log: build/xcodebuild-$1.log)" >&2
  exit 1
fi
root=$(cd "$(dirname "$0")/../.." && pwd)
products="$root/build/DerivedData/Build/Products/$1"
app="$products/Thermik.app"
if [ -e "$products" ]; then echo "products before build.sh: stale" >>"$STUB_LOG"; else echo "products before build.sh: clean" >>"$STUB_LOG"; fi
rm -rf "$products"
mkdir -p "$products"
[ "${STUB_APP:-}" != none ] || exit 0
EOF
  seal_fn
  cat <<'EOF'
# setting <name>: its value in Config/Shared.xcconfig
setting() { sed -n "s/^$1 = //p" "$root/Config/Shared.xcconfig"; }
# uuid <binary> <arch> <build>: a made-up UUID, the same for the same three
uuid() {
  printf '%s %s %s' "$1" "$2" "$3" | cksum | {
    read -r crc size
    printf '%08X-%04X-4000-8000-%012X\n' "$crc" "$size" "$crc"
  }
}
# macho <file> <binary> <archs> <build>: a fake Mach-O file of the binary (or the DWARF file of its dSYM)
macho() {
  {
    echo "fake Mach-O file of $2"
    for arch in $3; do echo "uuid $(uuid "$2" "$arch" "$4") $arch"; done
  } >"$1"
}
plist_head() {
  printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
    '<plist version="1.0">' '<dict>'
}
plist_tail() { printf '%s\n' '</dict>' '</plist>'; }
entry() { printf '\t<key>%s</key>\n\t<string>%s</string>\n' "$1" "$2"; }
# dsym <dSYM> <binary> <archs> <build> [nodebug]: the dSYM bundle of the binary, next to the app; its DWARF file has a
# "debug-info" line (the dwarfdump stub then finds compile units) unless nodebug
dsym() {
  mkdir -p "$products/$1/Contents/Resources/DWARF"
  {
    plist_head
    entry CFBundleIdentifier "com.apple.xcode.dsym.$2"
    plist_tail
  } >"$products/$1/Contents/Info.plist"
  macho "$products/$1/Contents/Resources/DWARF/$2" "$2" "$3" "$4"
  [ -n "${5:-}" ] || echo debug-info >>"$products/$1/Contents/Resources/DWARF/$2"
}
version=${STUB_VERSION:-$(setting MARKETING_VERSION)}
build=${STUB_BUILD:-$(setting CURRENT_PROJECT_VERSION)}
app_archs=${STUB_APP_ARCHS:-x86_64 arm64}
helper_archs=${STUB_HELPER_ARCHS:-x86_64 arm64}
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/_CodeSignature"
{
  plist_head
  entry CFBundleExecutable Thermik
  entry CFBundleIdentifier app.thermik.Thermik
  [ "$version" = none ] || entry CFBundleShortVersionString "$version"
  [ "$build" = none ] || entry CFBundleVersion "$build"
  plist_tail
} >"$app/Contents/Info.plist"
printf 'APPL????' >"$app/Contents/PkgInfo"
echo icon >"$app/Contents/Resources/AppIcon.icns"
macho "$app/Contents/MacOS/Thermik" Thermik "$app_archs" this
[ "${STUB_APP:-}" = nohelper ] || macho "$app/Contents/MacOS/thermik-helper" thermik-helper "$helper_archs" this
case ${STUB_DSYM:-} in
missing-app) ;;
stale-app) dsym Thermik.app.dSYM Thermik "$app_archs" earlier ;;
nodebug-app) dsym Thermik.app.dSYM Thermik "$app_archs" this nodebug ;;
*) dsym Thermik.app.dSYM Thermik "$app_archs" this ;;
esac
case ${STUB_DSYM:-} in
missing-helper) ;;
stale-helper) dsym thermik-helper.dSYM thermik-helper "$helper_archs" earlier ;;
thin-helper) dsym thermik-helper.dSYM thermik-helper arm64 this ;;
nodebug-helper) dsym thermik-helper.dSYM thermik-helper "$helper_archs" this nodebug ;;
*) dsym thermik-helper.dSYM thermik-helper "$helper_archs" this ;;
esac
case ${STUB_SIGN:-adhoc} in
adhoc | broken) signer=adhoc ;;
team) signer='ABCDE12345 Apple Development: Jane Doe (Q1W2E3R4T5)' ;;
*)
  echo "build.sh stub: unknown STUB_SIGN=$STUB_SIGN" >&2
  exit 2
  ;;
esac
{
  echo "signer $signer"
  seal "$app"
} >"$app/Contents/_CodeSignature/CodeResources"
[ "${STUB_SIGN:-}" != broken ] || echo changed >>"$app/Contents/Resources/AppIcon.icns"
echo "Built: build/DerivedData/Build/Products/$1/Thermik.app"
EOF
} >"$STUBS/build.sh"
cat >"$STUBS/selftest.sh" <<'EOF'
#!/bin/sh
# scripts/lib/selftest.sh stub: logs, then passes, or fails with STUB_SELFTEST_FAIL=1
echo selftest >>"$STUB_LOG"
if [ -n "${STUB_SELFTEST_FAIL:-}" ]; then
  echo "selftest: a check failed." >&2
  exit 1
fi
echo "All self-checks passed."
EOF
cat >"$BIN/plutil" <<'EOF'
#!/bin/sh
# plutil stub: only `plutil -extract KEY raw -o - FILE`, of a plist as the build.sh stub writes it (a top-level <key>
# line, then its <string> line): prints the value, or fails as plutil does without such a key or file
printf 'plutil %s\n' "$*" >>"$STUB_LOG"
if [ $# != 6 ] || [ "$1" != -extract ] || [ "$3 $4 $5" != "raw -o -" ]; then
  echo "plutil stub: unexpected arguments: $*" >&2
  exit 2
fi
if [ ! -f "$6" ]; then
  echo "$6: file does not exist or is not readable or is not a regular file" >&2
  exit 1
fi
awk -v key="<key>$2</key>" '
  want { if (sub(/^[ \t]*<string>/, "") && sub(/<\/string>[ \t]*$/, "")) { print; found = 1 } exit }
  { line = $0; gsub(/^[ \t]+|[ \t]+$/, "", line); if (line == key) want = 1 }
  END { exit !found }' "$6" && exit 0
echo "No value at that key path or invalid key path: $2" >&2
exit 1
EOF
cat >"$BIN/lipo" <<'EOF'
#!/bin/sh
# lipo stub: only `lipo -archs FILE`, of a fake Mach-O file of the build.sh stub: its architectures, in file order
printf 'lipo %s\n' "$*" >>"$STUB_LOG"
if [ $# != 2 ] || [ "$1" != -archs ]; then
  echo "lipo stub: unexpected arguments: $*" >&2
  exit 2
fi
if [ ! -f "$2" ]; then
  echo "fatal error: lipo: can't open input file: $2 (No such file or directory)" >&2
  exit 1
fi
awk '$1 == "uuid" { printf "%s%s", sep, $3; sep = " " } END { print "" }' "$2"
EOF
cat >"$BIN/dwarfdump" <<'EOF'
#!/bin/sh
# dwarfdump stub, of a fake Mach-O file or the DWARF files of a dSYM bundle (PATH/Contents/Resources/DWARF/*), as
# dwarfdump prints them. Only these forms:
#   dwarfdump --uuid PATH                                  "UUID: <UUID> (<arch>) <file>" for every architecture
#   dwarfdump --arch ARCH --debug-info --recurse-depth=0 PATH
#                                                          the .debug_info header of that architecture, with two
#                                                          DW_TAG_compile_unit lines when the file has debug-info
printf 'dwarfdump %s\n' "$*" >>"$STUB_LOG"
if [ $# = 2 ] && [ "$1" = --uuid ]; then
  arch=''
elif [ $# = 5 ] && [ "$1" = --arch ] && [ "$3 $4" = "--debug-info --recurse-depth=0" ]; then
  arch=$2
  shift 4
  set -- --uuid "$1"
else
  echo "dwarfdump stub: unexpected arguments: $*" >&2
  exit 2
fi
if [ -d "$2" ]; then set -- "$2"/Contents/Resources/DWARF/*; else set -- "$2"; fi
for f; do
  if [ ! -f "$f" ]; then
    echo "error: $f: No such file or directory" >&2
    exit 1
  fi
  if [ -z "$arch" ]; then
    awk -v f="$f" '$1 == "uuid" { print "UUID: " $2 " (" $3 ") " f }' "$f"
  else
    awk -v f="$f" -v a="$arch" '
      $1 == "uuid" && $3 == a { found = 1 }
      $1 == "debug-info" { info = 1 }
      END {
        if (!found) exit
        printf "%s(%s):\tfile format Mach-O %s\n\n.debug_info contents:\n", f, a, a
        if (info) printf "0x0000000c: DW_TAG_compile_unit\n0x00000057: DW_TAG_compile_unit\n"
      }' "$f"
  fi
done
EOF
{
  cat <<'EOF'
#!/bin/sh
# codesign stub, for an app the build.sh stub signed (Contents/_CodeSignature/CodeResources: a "signer" line, adhoc or
# "<Team ID> <authority>", then the seal of the bundle's other files). Only these forms:
#   codesign --verify --deep --strict APP  passes when the files of APP match the seal, else fails as codesign does
#   codesign -dvv APP                      prints the signature on stderr, as codesign does: Signature=adhoc, or the
#                                          signer's Authority= lines and its TeamIdentifier
printf 'codesign %s\n' "$*" >>"$STUB_LOG"
EOF
  seal_fn
  cat <<'EOF'
if [ $# = 4 ] && [ "$1 $2 $3" = "--verify --deep --strict" ]; then
  app=$4
elif [ $# = 2 ] && [ "$1" = -dvv ]; then
  app=$2
else
  echo "codesign stub: unexpected arguments: $*" >&2
  exit 2
fi
cr="$app/Contents/_CodeSignature/CodeResources"
if [ ! -f "$cr" ]; then
  printf '%s: code object is not signed at all\n' "$app" >&2
  exit 1
fi
if [ "$1" = --verify ]; then
  if [ "$(sed 1d "$cr")" != "$(seal "$app")" ]; then
    printf '%s: a sealed resource is missing or invalid\n' "$app" >&2
    exit 1
  fi
  exit 0
fi
signer=$(sed -n '1s/^signer //p' "$cr")
archs=$(awk '$1 == "uuid" { printf "%s%s", sep, $3; sep = " " }' "$app/Contents/MacOS/Thermik")
{
  printf '%s\n' "Executable=$app/Contents/MacOS/Thermik" "Identifier=app.thermik.Thermik" \
    "Format=app bundle with Mach-O universal ($archs)"
  if [ "$signer" = adhoc ]; then
    printf '%s\n' "CodeDirectory v=20500 size=1520 flags=0x10002(adhoc,runtime) hashes=36+7 location=embedded" \
      "Signature=adhoc" "Info.plist entries=24" "TeamIdentifier=not set"
  else
    printf '%s\n' "CodeDirectory v=20500 size=1520 flags=0x10000(runtime) hashes=36+7 location=embedded" \
      "Signature size=4797" "Authority=${signer#* }" \
      "Authority=Apple Worldwide Developer Relations Certification Authority" "Authority=Apple Root CA" \
      "Signed Time=28 Oct 2026 at 21:00:00" "Info.plist entries=24" "TeamIdentifier=${signer%% *}"
  fi
  printf '%s\n' "Runtime Version=26.0.0" "Sealed Resources version=2 rules=13 files=2" \
    "Internal requirements count=1 size=180"
} >&2
EOF
} >"$BIN/codesign"
{
  cat <<'EOF'
#!/bin/sh
# ditto stub; its "zip" is a tar archive. Only the forms build-release.sh uses:
#   ditto -c -k [--norsrc] [--keepParent] SRC ARCHIVE  archives what the directory SRC holds, or with --keepParent
#                                                      SRC itself, by its name
#   ditto -x -k ARCHIVE DIR                            extracts the archive into DIR
#   ditto [--norsrc] SRC DST                           copies the directory SRC to DST
# STUB_DITTO changes what an archive holds: lossy (no Contents/Resources/AppIcon.icns), otherversion (the app in it is
# version 0.9.0, sealed as such: an older build, say), macosx (a __MACOSX directory at the top too, as --sequesterRsrc
# makes; empty: macOS's tar would take "._" files in it for metadata), noparent (as without --keepParent)
printf 'ditto %s\n' "$*" >>"$STUB_LOG"
EOF
  seal_fn
  cat <<'EOF'
args=$*
unexpected() {
  echo "ditto stub: unexpected arguments: $args" >&2
  exit 2
}
# no AppleDouble files from macOS's tar
COPYFILE_DISABLE=1
export COPYFILE_DISABLE
create='' extract='' pkzip='' keep=''
while [ $# -gt 0 ]; do
  case $1 in
  -c) create=1 ;;
  -x) extract=1 ;;
  -k) pkzip=1 ;;
  --norsrc) ;;
  --keepParent) keep=1 ;;
  -*) unexpected ;;
  *) break ;;
  esac
  shift
done
[ $# = 2 ] || unexpected
if [ -n "$extract" ]; then
  [ -n "$pkzip" ] && [ -z "$create$keep" ] || unexpected
  mkdir -p "$2" && tar -xf "$1" -C "$2"
  exit
fi
if [ -z "$create" ]; then
  [ -z "$pkzip$keep" ] || unexpected
  mkdir -p "$2" && (cd "$1" && tar -cf - .) | (cd "$2" && tar -xf -)
  exit
fi
[ -n "$pkzip" ] || unexpected
stage=$(mktemp -d "${TMPDIR:-/tmp}/ditto-stub.XXXXXX") || exit 1
trap 'rm -rf "$stage"' EXIT
[ "${STUB_DITTO:-}" != noparent ] || keep=''
top=$stage
if [ -n "$keep" ]; then
  top="$stage/${1##*/}"
  mkdir "$top"
fi
(cd "$1" && tar -cf - .) | (cd "$top" && tar -xf -) || exit 1
case ${STUB_DITTO:-} in
lossy) rm -f "$top/Contents/Resources/AppIcon.icns" ;;
otherversion)
  if [ -f "$top/Contents/Info.plist" ]; then
    plist=$(awk '{ print } /<key>CFBundleShortVersionString<\/key>/ { getline; print "\t<string>0.9.0</string>" }' \
      "$top/Contents/Info.plist")
    printf '%s\n' "$plist" >"$top/Contents/Info.plist"
    cr="$top/Contents/_CodeSignature/CodeResources"
    signer=$(sed -n 1p "$cr")
    sealed=$(seal "$top")
    printf '%s\n%s\n' "$signer" "$sealed" >"$cr"
  fi
  ;;
macosx) mkdir "$stage/__MACOSX" ;;
esac
(cd "$stage" && tar -cf - .) >"$2"
EOF
} >"$BIN/ditto"
chmod +x "$STUBS"/* "$BIN"/*

# xcconfig <version line> <build line>: a fake root's Config/Shared.xcconfig, modelled on the real one, with these
# lines (an empty argument leaves its line out); its comments name both settings, which must not count
xcconfig() {
  cat <<'EOF'
// Shared signing defaults (a test fixture modelled on Config/Shared.xcconfig).
// MARKETING_VERSION = 9.9.9 and CURRENT_PROJECT_VERSION = 99 here are a comment, not settings.
DEVELOPMENT_TEAM =
CODE_SIGN_IDENTITY = -
CODE_SIGN_STYLE = Manual
ENABLE_HARDENED_RUNTIME = YES
OTHER_CODE_SIGN_FLAGS = $(inherited) --options=runtime
ENABLE_DEBUG_DYLIB = NO
EOF
  [ -z "$1" ] || printf '%s\n' "$1"
  [ -z "$2" ] || printf '%s\n' "$2"
  cat <<'EOF'
// Bump ONLY when helper code changes: the app reinstalls/re-registers the helper when this differs.
HELPER_BUILD_VERSION = 6
THERMIK_DEBUGGABLE = NO
#include? "Signing.local.xcconfig"
EOF
}
# new_root <name>: a new fake tree ROOT with the script, version.sh, Config/Shared.xcconfig (version V, build BUILD)
# and the stubs of build.sh and selftest.sh; REL is its release dir, PRODUCTS and APP what the build.sh stub writes.
# A name used twice stops the tests (the case would run in the earlier case's tree)
new_root() {
  ROOT="$WORK/$1"
  if [ -e "$ROOT" ]; then
    echo "not ok the test root name '$1' is used twice"
    exit 1
  fi
  REL="$ROOT/build/release"
  PRODUCTS="$ROOT/build/DerivedData/Build/Products/Release"
  APP="$PRODUCTS/Thermik.app"
  mkdir -p "$ROOT/scripts/lib" "$ROOT/Config"
  cp "$TREE/scripts/build-release.sh" "$ROOT/scripts/"
  cp "$TREE/scripts/lib/version.sh" "$STUBS/build.sh" "$STUBS/selftest.sh" "$ROOT/scripts/lib/"
  xcconfig "MARKETING_VERSION = $V" "CURRENT_PROJECT_VERSION = $BUILD" >"$ROOT/Config/Shared.xcconfig"
}
# br [args...]: build-release.sh of ROOT, run from WORK with the tool stubs first on PATH and a fresh stub log; sets
# OUT and RC
br() {
  rm -f "$STUB_LOG"
  OUT="$(cd "$WORK" && PATH="$BIN:$PATH" "$BASH_BIN" "$ROOT/scripts/build-release.sh" "$@" 2>&1)"
  RC=$?
}
# summary <dir> <signature> [architectures]: the summary the script ends with, for the release files in dir
summary() {
  local f
  printf '\nРелиз %s (сборка %s): %s\n' "$V" "$BUILD" "$1"
  for f in $ASSETS; do printf '  %9s  %s\n' "$(wc -c <"$1/$f" | tr -d ' ')" "$f"; done
  printf '\nПодпись: %s\nАрхитектуры: %s\n\nSHA256SUMS:\n' "$2" "${3:-x86_64 arm64}"
  sed 's/^/  /' "$1/SHA256SUMS" 2>/dev/null
}
# refused <name> <error>: the last run failed with "Ошибка: <error>" and wrote nothing to build/release or TMPDIR
refused() {
  WANT=$2
  check "$1" '[ $RC = 1 ] && line "Ошибка: $WANT" && ! has "Релиз $V" && [ ! -e "$REL" ] && no_temp'
}

# --- a release build: exactly the release files, SHA256SUMS over the two zips, the summary
new_root main
mkdir -p "$REL" "$PRODUCTS/Thermik.app.dSYM"
echo stale >"$REL/Thermik-1.2.2.zip"
echo finder >"$REL/.DS_Store"
echo stale >"$PRODUCTS/stale-product"
br
check "builds: exit 0, no error" '[ $RC = 0 ] && ! has "Ошибка"'
check "...from empty products: an earlier build's are gone before build.sh runs" \
  'logged "products before build.sh: clean" && [ ! -e "$PRODUCTS/stale-product" ]'
check "...scripts/lib/build.sh Release once, after saying so" \
  'logged "build.sh Release" && [ "$(grep -c "^build.sh" "$STUB_LOG")" = 1 ] &&
    in_order "== Сборка $V (сборка $BUILD): scripts/lib/build.sh Release" "Built: build/DerivedData/Build/Products/Release/Thermik.app" \
      "== Архивы: $APP_ZIP, $DSYMS_ZIP"'
check "...build/release holds exactly the release files (an older build's and other files are gone)" \
  '[ "$(listing "$REL")" = "$(sorted $ASSETS)" ]'
check "...SHA256SUMS lists the two zips, in release_assets order, with their sums" 'sums_ok "$REL" "$APP_ZIP" "$DSYMS_ZIP"'
check "...$APP_ZIP holds Thermik.app alone, as built" \
  'unpack "$REL/$APP_ZIP" "$WORK/x-app" && [ "$(listing "$WORK/x-app")" = "Thermik.app " ] && diff -r "$APP" "$WORK/x-app/Thermik.app" >/dev/null'
check "...$DSYMS_ZIP holds Thermik-$V-dSYMs/ alone, with the dSYMs of the app and the helper as built" \
  'unpack "$REL/$DSYMS_ZIP" "$WORK/x-dsyms" && [ "$(listing "$WORK/x-dsyms")" = "Thermik-$V-dSYMs " ] &&
    [ "$(listing "$WORK/x-dsyms/Thermik-$V-dSYMs")" = "Thermik.app.dSYM thermik-helper.dSYM " ] &&
    diff -r "$PRODUCTS/Thermik.app.dSYM" "$WORK/x-dsyms/Thermik-$V-dSYMs/Thermik.app.dSYM" >/dev/null &&
    diff -r "$PRODUCTS/thermik-helper.dSYM" "$WORK/x-dsyms/Thermik-$V-dSYMs/thermik-helper.dSYM" >/dev/null'
check "...ditto archives with --norsrc --keepParent, copies the dSYMs with --norsrc, and unzips the app" \
  '[ "$(grep -c "^ditto " "$STUB_LOG")" = 5 ] && logged "ditto -c -k --norsrc --keepParent $APP $REL/$APP_ZIP" &&
    logged_like "ditto --norsrc $PRODUCTS/Thermik.app.dSYM $TMPDIR/*/Thermik-$V-dSYMs/Thermik.app.dSYM" &&
    logged_like "ditto --norsrc $PRODUCTS/thermik-helper.dSYM $TMPDIR/*/Thermik-$V-dSYMs/thermik-helper.dSYM" &&
    logged_like "ditto -c -k --norsrc --keepParent $TMPDIR/*/Thermik-$V-dSYMs $REL/$DSYMS_ZIP" &&
    logged_like "ditto -x -k $REL/$APP_ZIP $TMPDIR/*"'
check "...checks the build: Info.plist, both binaries' architectures and dSYM UUIDs, the app's signature, the app unzipped" \
  'logged "plutil -extract CFBundleShortVersionString raw -o - $APP/Contents/Info.plist" &&
    logged "plutil -extract CFBundleVersion raw -o - $APP/Contents/Info.plist" &&
    logged "lipo -archs $APP/Contents/MacOS/Thermik" && logged "lipo -archs $APP/Contents/MacOS/thermik-helper" &&
    logged "dwarfdump --uuid $APP/Contents/MacOS/Thermik" && logged "dwarfdump --uuid $PRODUCTS/Thermik.app.dSYM" &&
    logged "dwarfdump --uuid $APP/Contents/MacOS/thermik-helper" && logged "dwarfdump --uuid $PRODUCTS/thermik-helper.dSYM" &&
    logged "dwarfdump --arch arm64 --debug-info --recurse-depth=0 $PRODUCTS/Thermik.app.dSYM" &&
    logged "dwarfdump --arch x86_64 --debug-info --recurse-depth=0 $PRODUCTS/Thermik.app.dSYM" &&
    logged "dwarfdump --arch arm64 --debug-info --recurse-depth=0 $PRODUCTS/thermik-helper.dSYM" &&
    logged "dwarfdump --arch x86_64 --debug-info --recurse-depth=0 $PRODUCTS/thermik-helper.dSYM" &&
    logged "codesign --verify --deep --strict $APP" && logged "codesign -dvv $APP" &&
    logged_like "codesign --verify --deep --strict $TMPDIR/*/Thermik.app" &&
    logged_like "plutil -extract CFBundleShortVersionString raw -o - $TMPDIR/*/Thermik.app/Contents/Info.plist"'
check "...the summary: version, build, directory, every file with its size, the signature, the architectures, the sums" \
  'ends "$(summary "$REL" "$ADHOC")" && ! has "другие файлы"'
check "...no self-checks without --test" '! ran selftest && ! has "Самопроверки"'
check "...nothing left in TMPDIR or HOME, nothing written in the root but build/release and the build" \
  'no_temp && [ -z "$(ls -A "$HOME")" ] &&
    [ "$(listing "$ROOT")" = "Config build scripts " ] && [ "$(listing "$ROOT/build")" = "DerivedData release " ]'

new_root 'my project'
br
check "a root path with a space builds" \
  '[ $RC = 0 ] && [ "$(listing "$REL")" = "$(sorted $ASSETS)" ] && sums_ok "$REL" "$APP_ZIP" "$DSYMS_ZIP" && ends "$(summary "$REL" "$ADHOC")" && no_temp'

new_root team
STUB_SIGN=team br
check "a Team ID signature builds: the summary names its first authority and the Team ID, and that GitHub's are ad-hoc" \
  '[ $RC = 0 ] && line "Подпись: Apple Development: Jane Doe (Q1W2E3R4T5) (Team ID ABCDE12345); релизы GitHub подписаны ad-hoc" &&
    ends "$(summary "$REL" "Apple Development: Jane Doe (Q1W2E3R4T5) (Team ID ABCDE12345); релизы GitHub подписаны ad-hoc")" &&
    ! has "Apple Root CA" && ! has "$ADHOC"'

new_root arm64e
STUB_APP_ARCHS="x86_64 arm64 arm64e" br
check "an architecture beyond RELEASE_ARCHS is fine, and the summary shows the app's" \
  '[ $RC = 0 ] && ends "$(summary "$REL" "$ADHOC" "x86_64 arm64 arm64e")"'

# --- --out DIR
new_root outroot
mkdir -p "$WORK/out"
echo notes >"$WORK/out/README.txt"
echo old >"$WORK/out/Thermik-1.2.2.zip"
echo finder >"$WORK/out/.DS_Store"
echo old >"$WORK/out/$APP_ZIP"
br --out out
check "--out DIR (relative to the current directory): the release files are copied there (an older $APP_ZIP replaced), their sums hold" \
  '[ $RC = 0 ] && sums_ok "$WORK/out" "$APP_ZIP" "$DSYMS_ZIP" && cmp -s "$REL/$APP_ZIP" "$WORK/out/$APP_ZIP" &&
    cmp -s "$REL/$DSYMS_ZIP" "$WORK/out/$DSYMS_ZIP" && cmp -s "$REL/SHA256SUMS" "$WORK/out/SHA256SUMS" &&
    [ "$(listing "$REL")" = "$(sorted $ASSETS)" ]'
check "...the summary is about DIR, and names the other files there, hidden ones too" \
  'ends "$(summary "$WORK/out" "$ADHOC")
В $WORK/out есть и другие файлы, в релиз они не входят: README.txt Thermik-1.2.2.zip .DS_Store"'
check "...and leaves them alone" \
  '[ "$(cat "$WORK/out/README.txt")" = notes ] && [ "$(cat "$WORK/out/Thermik-1.2.2.zip")" = old ] && [ "$(cat "$WORK/out/.DS_Store")" = finder ] && no_temp'
br "--out=$WORK/out 2/new"
check "--out=DIR: a new DIR (a path with a space) with exactly the release files, the summary about it" \
  '[ $RC = 0 ] && [ "$(listing "$WORK/out 2/new")" = "$(sorted $ASSETS)" ] && sums_ok "$WORK/out 2/new" "$APP_ZIP" "$DSYMS_ZIP" &&
    ends "$(summary "$WORK/out 2/new" "$ADHOC")"'
br --out "$REL"
check "--out build/release itself: nothing copied, the summary is about build/release" \
  '[ $RC = 0 ] && [ "$(listing "$REL")" = "$(sorted $ASSETS)" ] && sums_ok "$REL" "$APP_ZIP" "$DSYMS_ZIP" && ends "$(summary "$REL" "$ADHOC")"'
ln -s "$ROOT/build" "$WORK/build-link"
br --out build-link/release
check "--out build/release by another path (a symlink): nothing copied, the summary is about build/release" \
  '[ $RC = 0 ] && sums_ok "$REL" "$APP_ZIP" "$DSYMS_ZIP" && ends "$(summary "$REL" "$ADHOC")"'
br --out
check "--out without DIR is a usage error" \
  '[ $RC = 2 ] && line "Ошибка: --out: укажите каталог" && has "  scripts/build-release.sh [--test] [--out DIR]" && nothing_ran'
br --out ''
check "--out '' is a usage error" '[ $RC = 2 ] && line "Ошибка: --out: укажите каталог" && nothing_ran'
br --out=
check "--out= is an unknown option" '[ $RC = 2 ] && line "Ошибка: неизвестный параметр --out=" && nothing_ran'

# --- --test
new_root selftest
br --test
check "--test: the self-checks first, then the build" \
  '[ $RC = 0 ] && [ "$(head -n 2 "$STUB_LOG" | tr "\n" " ")" = "selftest build.sh Release " ] &&
    in_order "== Самопроверки: scripts/lib/selftest.sh" "All self-checks passed." "== Сборка $V (сборка $BUILD)" &&
    sums_ok "$REL" "$APP_ZIP" "$DSYMS_ZIP"'
new_root selftest-fails
STUB_SELFTEST_FAIL=1 br --test
check "--test: failing self-checks stop it before the build" \
  '[ $RC = 1 ] && line "Ошибка: самопроверки thermik-probe не прошли." && has "selftest: a check failed." && ran selftest && ! ran build.sh && [ ! -e "$ROOT/build" ]'

# --- options
new_root options
br --help
check "--help prints the usage and builds nothing" \
  '[ $RC = 0 ] && has "  scripts/build-release.sh [--test] [--out DIR]" && has "Собирает файлы релиза версии из Config/Shared.xcconfig" && ! has "Ошибка" && untouched'
br -h
check "-h prints the usage" '[ $RC = 0 ] && has "  -h, --help эта справка" && untouched'
br --bogus
check "an unknown option is a usage error" \
  '[ $RC = 2 ] && line "Ошибка: неизвестный параметр --bogus" && has "  --out DIR  ещё и скопировать файлы релиза в DIR" && untouched'
br 1.2.3
check "an argument is a usage error" '[ $RC = 2 ] && line "Ошибка: неизвестный параметр 1.2.3" && untouched'
br --test --bogus
check "...also after --test, before the self-checks" '[ $RC = 2 ] && line "Ошибка: неизвестный параметр --bogus" && untouched'

# --- the version and the build number in Config/Shared.xcconfig: refused before the self-checks and the build
n=0
for c in 1.2 v1.2.3 01.2.3 1.2.3.4 1.2.3-beta 1234567890.0.0 '' '$(BASE_VERSION)'; do
  n=$((n + 1))
  new_root "version-$n"
  xcconfig "MARKETING_VERSION = $c" "CURRENT_PROJECT_VERSION = $BUILD" >"$ROOT/Config/Shared.xcconfig"
  br --test
  check "MARKETING_VERSION = '$c' is refused before the self-checks and the build" \
    '[ $RC = 1 ] && line "Ошибка: в Config/Shared.xcconfig MARKETING_VERSION = «${c}», а не X.Y.Z (без ведущих нулей и «v», числа до 9 цифр)." && untouched'
done
for c in 0 01 1.0 abc -1 1234567890 '' '$(BUILD_NUMBER)'; do
  n=$((n + 1))
  new_root "build-$n"
  xcconfig "MARKETING_VERSION = $V" "CURRENT_PROJECT_VERSION = $c" >"$ROOT/Config/Shared.xcconfig"
  br --test
  check "CURRENT_PROJECT_VERSION = '$c' is refused before the self-checks and the build" \
    '[ $RC = 1 ] && line "Ошибка: в Config/Shared.xcconfig CURRENT_PROJECT_VERSION = «${c}», а не номер сборки (целое число от 1, до 9 цифр, без ведущих нулей)." && untouched'
done
# one_line <name> <version line> <build line> <the line the error asks for>: a Config/Shared.xcconfig without exactly
# one line of a setting is refused before the self-checks and the build
one_line() {
  new_root "$1"
  xcconfig "$2" "$3" >"$ROOT/Config/Shared.xcconfig"
  br --test
  WANT="в Config/Shared.xcconfig должна быть ровно одна строка $4."
  check "$1 (even of one value) are refused before the self-checks and the build" '[ $RC = 1 ] && line "Ошибка: $WANT" && untouched'
}
one_line "two MARKETING_VERSION lines" "MARKETING_VERSION = $V${NL}MARKETING_VERSION = $V" "CURRENT_PROJECT_VERSION = $BUILD" \
  "MARKETING_VERSION = X.Y.Z"
one_line "two CURRENT_PROJECT_VERSION lines" "MARKETING_VERSION = $V" \
  "CURRENT_PROJECT_VERSION = $BUILD${NL}CURRENT_PROJECT_VERSION = $BUILD" "CURRENT_PROJECT_VERSION = N"
new_root no-version-line
xcconfig "" "CURRENT_PROJECT_VERSION = $BUILD" >"$ROOT/Config/Shared.xcconfig"
br --test
check "no MARKETING_VERSION line is refused before the self-checks and the build" \
  '[ $RC = 1 ] && line "Ошибка: в Config/Shared.xcconfig должна быть ровно одна строка MARKETING_VERSION = X.Y.Z." && untouched'
new_root no-build-line
xcconfig "MARKETING_VERSION = $V" "" >"$ROOT/Config/Shared.xcconfig"
br --test
check "no CURRENT_PROJECT_VERSION line is refused before the self-checks and the build" \
  '[ $RC = 1 ] && line "Ошибка: в Config/Shared.xcconfig должна быть ровно одна строка CURRENT_PROJECT_VERSION = N." && untouched'
new_root no-xcconfig
rm "$ROOT/Config/Shared.xcconfig"
br --test
check "no Config/Shared.xcconfig is refused before the self-checks and the build" \
  '[ $RC = 1 ] && line "Ошибка: в Config/Shared.xcconfig должна быть ровно одна строка MARKETING_VERSION = X.Y.Z." && untouched'

# --- what the build made, wrong: refused before anything is written to build/release
new_root build-fails
STUB_BUILD_FAIL=1 br
refused "a failing scripts/lib/build.sh fails the release" "scripts/lib/build.sh Release не прошёл."
check "...with its own error" 'has "xcodebuild FAILED (full log: build/xcodebuild-Release.log)" && logged "build.sh Release"'
new_root no-app
STUB_APP=none br
refused "a build without Thermik.app is refused" "сборка прошла, но в $APP нет Contents/MacOS/Thermik и thermik-helper."
new_root no-helper
STUB_APP=nohelper br
refused "an app without Contents/MacOS/thermik-helper is refused" \
  "сборка прошла, но в $APP нет Contents/MacOS/Thermik и thermik-helper."
OVERRIDDEN="MARKETING_VERSION или CURRENT_PROJECT_VERSION переопределены (project.yml, Config/*.xcconfig)?"
new_root plist-version
STUB_VERSION=1.2.4 br
refused "an app of another version than Config/Shared.xcconfig's is refused" \
  "у собранного приложения версия «1.2.4» и сборка «${BUILD}», а в Config/Shared.xcconfig — $V и $BUILD: $OVERRIDDEN"
new_root plist-build
STUB_BUILD=41 br
refused "an app of another build number than Config/Shared.xcconfig's is refused" \
  "у собранного приложения версия «${V}» и сборка «41», а в Config/Shared.xcconfig — $V и $BUILD: $OVERRIDDEN"
new_root plist-none
STUB_VERSION=none STUB_BUILD=none br
refused "an app whose Info.plist has neither is refused" \
  "у собранного приложения версия «» и сборка «», а в Config/Shared.xcconfig — $V и $BUILD: $OVERRIDDEN"
new_root app-arm64
STUB_APP_ARCHS=arm64 br
refused "an app without x86_64 is refused" \
  "в Contents/MacOS/Thermik нет архитектуры x86_64 (есть: arm64), а релиз — универсальная сборка (arm64 x86_64)."
new_root helper-x86_64
STUB_HELPER_ARCHS=x86_64 br
refused "a helper without arm64 is refused" \
  "в Contents/MacOS/thermik-helper нет архитектуры arm64 (есть: x86_64), а релиз — универсальная сборка (arm64 x86_64)."
new_root no-app-dsym
STUB_DSYM=missing-app br
refused "a missing Thermik.app.dSYM is refused" "нет Thermik.app.dSYM рядом с приложением: символы для отчётов о сбоях не собраны."
new_root no-helper-dsym
STUB_DSYM=missing-helper br
refused "a missing thermik-helper.dSYM is refused" \
  "нет thermik-helper.dSYM рядом с приложением: символы для отчётов о сбоях не собраны."
new_root stale-app-dsym
STUB_DSYM=stale-app br
refused "a Thermik.app.dSYM of another build (other UUIDs) is refused" \
  "UUID в Thermik.app.dSYM не совпадают с Contents/MacOS/Thermik: символы не от этой сборки."
new_root stale-helper-dsym
STUB_DSYM=stale-helper br
refused "a thermik-helper.dSYM of another build is refused" \
  "UUID в thermik-helper.dSYM не совпадают с Contents/MacOS/thermik-helper: символы не от этой сборки."
new_root thin-helper-dsym
STUB_DSYM=thin-helper br
refused "a thermik-helper.dSYM without one of the helper's architectures is refused" \
  "UUID в thermik-helper.dSYM не совпадают с Contents/MacOS/thermik-helper: символы не от этой сборки."
# What dsymutil makes of a binary the last build already stripped: the right UUIDs, no debug information
new_root nodebug-app-dsym
STUB_DSYM=nodebug-app br
refused "a Thermik.app.dSYM without debug information is refused" \
  "в Thermik.app.dSYM нет отладочной информации для arm64: dsymutil прочитал уже урезанный бинарник?"
new_root nodebug-helper-dsym
STUB_DSYM=nodebug-helper br
refused "a thermik-helper.dSYM without debug information is refused" \
  "в thermik-helper.dSYM нет отладочной информации для arm64: dsymutil прочитал уже урезанный бинарник?"
new_root bad-signature
STUB_SIGN=broken br
refused "an app that codesign --verify does not accept is refused" "codesign не принял подпись $APP."
check "...with codesign's own error" 'has "$APP: a sealed resource is missing or invalid" && ! logged "codesign -dvv $APP"'

# --- the app as unzipped from Thermik-X.Y.Z.zip: refused without SHA256SUMS
new_root lossy-zip
STUB_DITTO=lossy br
check "an archive whose app fails codesign --verify, while the built app passes, is refused" \
  '[ $RC = 1 ] && line "Ошибка: Thermik.app из $APP_ZIP не проходит codesign --verify --deep --strict." &&
    logged "codesign --verify --deep --strict $APP" && logged_like "codesign --verify --deep --strict $TMPDIR/*/Thermik.app" &&
    has "Thermik.app: a sealed resource is missing or invalid" && ! has "Релиз $V" && [ ! -e "$REL/SHA256SUMS" ] && no_temp'
new_root other-version-zip
STUB_DITTO=otherversion br
check "an archive whose app passes codesign --verify but is another version is refused" \
  '[ $RC = 1 ] && line "Ошибка: у Thermik.app из $APP_ZIP не версия $V." && [ "$(grep -c "^codesign --verify" "$STUB_LOG")" = 2 ] &&
    ! has "Релиз $V" && [ ! -e "$REL/SHA256SUMS" ] && no_temp'
# TOP: what the script's ls prints for a top level of Thermik.app and __MACOSX, in its order
mkdir -p "$WORK/top/Thermik.app" "$WORK/top/__MACOSX"
# shellcheck disable=SC2012 # plain names, in the order the script's ls gives them
TOP="$(ls -A "$WORK/top" | tr '\n' ' ')"
new_root macosx-zip
STUB_DITTO=macosx br
check "an archive with more than Thermik.app at the top is refused" \
  '[ $RC = 1 ] && line "Ошибка: в $APP_ZIP наверху «${TOP}», а должно быть только Thermik.app." && ! has "Релиз $V" && [ ! -e "$REL/SHA256SUMS" ] && no_temp'
new_root parentless-zip
STUB_DITTO=noparent br
check "an archive without Thermik.app at the top is refused" \
  '[ $RC = 1 ] && line "Ошибка: в $APP_ZIP наверху «Contents », а должно быть только Thermik.app." && ! has "Релиз $V" && [ ! -e "$REL/SHA256SUMS" ] && no_temp'

# --- release_assets naming files the script does not build (the fake tree's version.sh, patched)
new_root extra-assets
awk '{ if ($0 == "  echo SHA256SUMS") { print "  echo \"Thermik-$1.dmg\""; print "  echo \"Thermik-$1.pkg\"" } print }' \
  "$TREE/scripts/lib/version.sh" >"$ROOT/scripts/lib/version.sh"
PATCHED="$("$BASH_BIN" -c '. "$0"; release_assets "$1" | tr "\n" " "' "$ROOT/scripts/lib/version.sh" "$V")"
br
check "release_assets naming files the script does not build is refused, without SHA256SUMS" \
  '[ "$PATCHED" = "$APP_ZIP $DSYMS_ZIP Thermik-$V.dmg Thermik-$V.pkg SHA256SUMS " ] && [ $RC = 1 ] &&
    line "Ошибка: не собраны: Thermik-$V.dmg Thermik-$V.pkg (их требует release_assets в scripts/lib/version.sh)." &&
    ! has "Релиз $V" && [ ! -e "$REL/SHA256SUMS" ] && no_temp'

# --- under a UTF-8 locale, as in people's terminals and on GitHub's macOS runners, whatever the caller's: bash 3.2 on
# macOS reads the first byte of a "«" or "»" right after $name as part of the name ("unbound variable" under set -u)
UTF8="$(locale -a 2>/dev/null | awk 'tolower($0) ~ /^(en_us|c)\.utf-?8$/ && u == "" { u = $0 } END { print u }')"
if [ -n "$UTF8" ]; then
  new_root utf8-main
  LC_ALL=$UTF8 br
  check "under $UTF8: a release build" '[ $RC = 0 ] && sums_ok "$REL" "$APP_ZIP" "$DSYMS_ZIP" && ends "$(summary "$REL" "$ADHOC")"'
  new_root utf8-version
  xcconfig "MARKETING_VERSION = 1.2" "CURRENT_PROJECT_VERSION = $BUILD" >"$ROOT/Config/Shared.xcconfig"
  LC_ALL=$UTF8 br
  check "under $UTF8: MARKETING_VERSION = '1.2' is refused with its message" \
    '[ $RC = 1 ] && line "Ошибка: в Config/Shared.xcconfig MARKETING_VERSION = «1.2», а не X.Y.Z (без ведущих нулей и «v», числа до 9 цифр)." && untouched'
  new_root utf8-build
  xcconfig "MARKETING_VERSION = $V" "CURRENT_PROJECT_VERSION = 0" >"$ROOT/Config/Shared.xcconfig"
  LC_ALL=$UTF8 br
  check "under $UTF8: CURRENT_PROJECT_VERSION = '0' is refused with its message" \
    '[ $RC = 1 ] && line "Ошибка: в Config/Shared.xcconfig CURRENT_PROJECT_VERSION = «0», а не номер сборки (целое число от 1, до 9 цифр, без ведущих нулей)." && untouched'
  new_root utf8-plist
  LC_ALL=$UTF8 STUB_VERSION=1.2.4 br
  refused "under $UTF8: an app of another version is refused with its message" \
    "у собранного приложения версия «1.2.4» и сборка «${BUILD}», а в Config/Shared.xcconfig — $V и $BUILD: $OVERRIDDEN"
  new_root utf8-zip
  LC_ALL=$UTF8 STUB_DITTO=noparent br
  check "under $UTF8: an archive without Thermik.app at the top is refused with its message" \
    '[ $RC = 1 ] && line "Ошибка: в $APP_ZIP наверху «Contents », а должно быть только Thermik.app." && [ ! -e "$REL/SHA256SUMS" ] && no_temp'
else
  echo "ok the release build under a UTF-8 locale # SKIP no UTF-8 locale in locale -a"
fi

echo "# $pass passed, $fail failed"
[ "$fail" = 0 ]

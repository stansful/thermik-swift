#!/usr/bin/env bash
# Tests of scripts/lib/version.sh: every function runs in a fresh $TEST_BASH (default: bash from PATH, /bin/bash 3.2
# on macOS) under `set -euo pipefail`, as the scripts that source it run. Files go to a temp dir (TMPDIR): the
# xcconfig fixtures, and a throwaway git repository whose `git tag -l` and `git ls-remote --tags` the tag functions
# read as the scripts give them; git reads only this test's config (HOME is the temp dir). The repository is only
# read (its Config/Shared.xcconfig).
#
#   scripts/tests/version_test.sh          KEEP=1 keeps the temp dir
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
LIB="$TREE/scripts/lib/version.sh"
BASH_BIN="${TEST_BASH:-bash}"
# no temp dir stops here: an empty WORK would make the current directory (the checkout) the work dir, and the
# EXIT trap would delete it
if ! WORK="$(mktemp -d "${TMPDIR:-/tmp}/version-test.XXXXXX")" || ! WORK="$(cd "$WORK" && pwd -P)"; then
  echo "not ok no temp dir in ${TMPDIR:-/tmp}"
  exit 1
fi
if [ -z "${KEEP:-}" ]; then trap 'rm -rf "$WORK"' EXIT; else echo "# work dir: $WORK"; fi

export HOME="$WORK/home" XDG_CONFIG_HOME="$WORK/home/.config" GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.invalid
# git never finds a repository above the temp dir (a TMPDIR inside some checkout)
GIT_CEILING_DIRECTORIES="$(dirname "$WORK")"
export GIT_CEILING_DIRECTORIES
# nor any config but this test's: no global file from the caller's environment, no `git -c` settings passed down
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR
unset GIT_CONFIG_GLOBAL GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS
mkdir -p "$HOME"
# app_version_set's temp files land here: the test checks that none is left behind
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
  if eval "$2"; then ok "$1"; else nok "$1" "rc=$RC; condition: $2; stdout: '$OUT'; stderr: '$ERR'"; fi
}
# fn <stdin (printf %b)> <function> [args...]: the function in a fresh BASH_BIN that sourced version.sh under
# set -euo pipefail; sets OUT, ERR, RC. stderr comes through the command substitution, which waits for every
# process holding it: a process substitution's late error lands in this ERR, not in a later one's
fn() {
  local input="$1"
  shift
  ERR="$(printf '%b' "$input" | "$BASH_BIN" -c 'set -euo pipefail; . "$0"; "$@"' "$LIB" "$@" 2>&1 >"$WORK/out")"
  RC=$?
  OUT="$(cat "$WORK/out")"
}
# is <name> <rc> <stdout>: the last fn exited with rc and printed exactly stdout, and nothing on stderr
is() {
  if [ "$RC" = "$2" ] && [ "$OUT" = "$3" ] && [ -z "$ERR" ]; then
    ok "$1"
  else
    nok "$1" "want rc=$2 stdout '$3'; got rc=$RC stdout '$OUT' stderr '$ERR'"
  fi
}
lines() { printf '%s\n' "$@"; }
# ls -l and ls -i, of plain names: the portable way to the mode and the inode (stat differs on BSD and GNU)
# shellcheck disable=SC2012
mode() { ls -l "$1" | cut -c1-10; }
# shellcheck disable=SC2012
inode() { ls -i "$1" | awk '{ print $1 }'; }

echo "# scripts/lib/version.sh under $("$BASH_BIN" -c 'echo "bash $BASH_VERSION"'), $(git --version)"

# --- version_valid: X.Y.Z, three numbers of up to 9 digits without leading zeros
for v in 0.0.0 1.2.3 3.7.0 10.20.30 2100.0.0 999999.999999.999999 100000000.0.0 0.0.999999999 \
  999999999.999999999.999999999; do
  fn '' version_valid "$v"
  is "version_valid: '$v' is a version" 0 ''
done
for v in '' 1 1.2 1.2.3.4 01.2.3 1.02.3 1.2.03 00.0.0 v1.2.3 V1.2.3 1.2.3-rc1 1.2.3+b ' 1.2.3' '1.2.3 ' \
  $'1.2.3\n' $'1.2.3\n4.5.6' a.b.c 1..3 .1.2 1.2. -1.2.3 1,2,3 1000000000.0.0 1234567890.1.2 0.1000000000.0 \
  0.0.1000000000 99999999999999999999.0.0; do
  fn '' version_valid "$v"
  is "version_valid: '$(printf '%s' "$v" | tr '\n' '|')' is not a version (| is a newline)" 1 ''
done

# --- version_cmp, version_gt
for c in "1.2.3 1.2.3 0" "1.2.3 1.2.4 -1" "1.2.4 1.2.3 1" "1.2.10 1.2.9 1" "1.2.9 1.2.10 -1" "1.10.0 1.9.999 1" \
  "2.0.0 10.0.0 -1" "0.0.0 0.0.1 -1" "1.0.0 0.999.999 1" "0.1.0 0.0.9 1" "3.7.0 3.6.0 1" "3.7.0 3.7.0 0" \
  "999999999.0.0 99999999.999999999.999999999 1" "0.0.999999998 0.0.999999999 -1" \
  "999999999.999999999.999999999 999999999.999999999.999999999 0" \
  "100000000000000000000.0.0 99999999999999999999.0.0 1" "0.0.99999999999999999999 0.0.100000000000000000000 -1"; do
  read -r a b want <<<"$c"
  fn '' version_cmp "$a" "$b"
  is "version_cmp $a $b = $want" 0 "$want"
done
fn '' version_gt 1.2.10 1.2.9
is "version_gt: 1.2.10 > 1.2.9 (numbers, not strings)" 0 ''
fn '' version_gt 10.0.0 9.99.999
is "version_gt: 10.0.0 > 9.99.999" 0 ''
fn '' version_gt 100000000.0.0 99999999.999999999.999999999
is "version_gt: 100000000.0.0 > 99999999.999999999.999999999" 0 ''
fn '' version_gt 1.2.3 1.2.3
is "version_gt: 1.2.3 is not > 1.2.3" 1 ''
fn '' version_gt 1.2.3 1.3.0
is "version_gt: 1.2.3 is not > 1.3.0" 1 ''

# --- version_bump
for c in "1.2.3 patch 1.2.4" "1.2.3 minor 1.3.0" "1.2.3 major 2.0.0" "0.1.0 minor 0.2.0" "0.0.0 patch 0.0.1" \
  "0.1.9 patch 0.1.10" "9.99.999 minor 9.100.0" "3.7.0 major 4.0.0" "3.7.0 minor 3.8.0" "3.7.0 patch 3.7.1" \
  "1.2.123456789 patch 1.2.123456790" "999999999.999999999.999999998 patch 999999999.999999999.999999999" \
  "999999999.999999998.999999999 minor 999999999.999999999.0" "999999998.999999999.999999999 major 999999999.0.0"; do
  read -r a b want <<<"$c"
  fn '' version_bump "$a" "$b"
  is "version_bump $a $b = $want" 0 "$want"
done
# The number it raises has 9 nines: the result is printed, and it is no version (make-release.sh leaves it out)
for c in "1.2.999999999 patch 1.2.1000000000" "1.999999999.3 minor 1.1000000000.0" \
  "999999999.2.3 major 1000000000.0.0" "999999999.999999999.999999999 patch 999999999.999999999.1000000000"; do
  read -r a b want <<<"$c"
  fn '' version_bump "$a" "$b"
  is "version_bump $a $b = $want" 0 "$want"
  fn '' version_valid "$want"
  is "...$want is not a version" 1 ''
done
for k in bogus '' Patch патч; do
  fn '' version_bump 1.2.3 "$k"
  is "version_bump: '$k' is not a bump" 1 ''
done

# --- build_valid: a number from 1 with up to 9 digits, without leading zeros
for b in 1 7 42 100 100000000 999999999; do
  fn '' build_valid "$b"
  is "build_valid: '$b' is a build number" 0 ''
done
for b in 0 00 01 007 1000000000 1234567890 -1 +1 1.2 1. '' ' 1' '1 ' a 1a 0x1 $'1\n' $'1\n2'; do
  fn '' build_valid "$b"
  is "build_valid: '$(printf '%s' "$b" | tr '\n' '|')' is not a build number (| is a newline)" 1 ''
done

# --- xcconfig_value, app_version_parse, app_build_parse: exactly one line `MARKETING_VERSION = X.Y.Z`, one line
# `CURRENT_PROJECT_VERSION = N`; the value is the rest of the line after the "=", without the blanks around it
XC='// Shared settings
//   MARKETING_VERSION = 9.9.9
// MARKETING_VERSION = 9.9.8
DEVELOPMENT_TEAM =
OTHER_CODE_SIGN_FLAGS = $(inherited) --options=runtime
MARKETING_VERSION_X = 9.9.7
MY_MARKETING_VERSION = 9.9.6
MARKETING_VERSIONS = 9.9.5
MARKETING_VERSION = 3.7.0
CURRENT_PROJECT_VERSION = 42
CURRENT_PROJECT_VERSION_X = 8
DYLIB_CURRENT_PROJECT_VERSION = 7
// CURRENT_PROJECT_VERSION = 6
HELPER_BUILD_VERSION = 5
INFOPLIST_KEY_CFBundleShortVersionString = $(MARKETING_VERSION)
#include? "Signing.local.xcconfig"
'
fn "$XC" app_version_parse
is "app_version_parse: the one version line among lines that only mention MARKETING_VERSION" 0 3.7.0
fn "$XC" app_build_parse
is "app_build_parse: the one build line among lines that only mention CURRENT_PROJECT_VERSION" 0 42
fn "$XC" xcconfig_value '^[ \t]*HELPER_BUILD_VERSION[ \t]*='
is "xcconfig_value: the value of the one line that matches" 0 5
fn "$XC" xcconfig_value '^[ \t]*OTHER_CODE_SIGN_FLAGS[ \t]*='
is 'xcconfig_value: a value with inner spaces and an "=" is returned as is' 0 '$(inherited) --options=runtime'
fn "$XC" xcconfig_value '^[ \t]*DEVELOPMENT_TEAM[ \t]*='
is "xcconfig_value: an empty value" 0 ''
fn "$XC" xcconfig_value '^[ \t]*MARKETING_VERSION'
is "xcconfig_value: three matching lines fail, printing nothing" 1 ''
fn "$XC" xcconfig_value '^[ \t]*NO_SUCH_SETTING[ \t]*='
is "xcconfig_value: no matching line fails, printing nothing" 1 ''
fn ' \tMARKETING_VERSION \t=\t 1.2.3\t \n' app_version_parse
is 'app_version_parse: spaces and tabs before the name, around the "=" and after the value' 0 1.2.3
fn '\t CURRENT_PROJECT_VERSION\t =  7 \t\n' app_build_parse
is 'app_build_parse: spaces and tabs before the name, around the "=" and after the value' 0 7
fn 'MARKETING_VERSION=1.2.3\nCURRENT_PROJECT_VERSION=7\n' app_version_parse
is 'app_version_parse: no blanks around the "="' 0 1.2.3
fn 'MARKETING_VERSION=1.2.3\nCURRENT_PROJECT_VERSION=7\n' app_build_parse
is 'app_build_parse: no blanks around the "="' 0 7
fn 'MARKETING_VERSION = 1.2.3 beta  2 \t\n' app_version_parse
is "app_version_parse: a value with inner spaces is returned as is, without the trailing blanks" 0 '1.2.3 beta  2'
fn 'CURRENT_PROJECT_VERSION = 7 8\t\n' app_build_parse
is "app_build_parse: a value with inner spaces is returned as is" 0 '7 8'
fn 'MARKETING_VERSION = x\nCURRENT_PROJECT_VERSION = 0\n' app_version_parse
is "app_version_parse: the value is not checked" 0 x
fn 'MARKETING_VERSION = x\nCURRENT_PROJECT_VERSION = 0\n' app_build_parse
is "app_build_parse: the value is not checked" 0 0
fn 'CURRENT_PROJECT_VERSION = 7\nMARKETING_VERSION = 1.2.3' app_version_parse
is "app_version_parse: a last line without a newline" 0 1.2.3
fn 'MARKETING_VERSION = 1.2.3\nCURRENT_PROJECT_VERSION = 7 \t' app_build_parse
is "app_build_parse: a last line without a newline, with trailing blanks" 0 7
fn 'DEVELOPMENT_TEAM =\n// MARKETING_VERSION = 1.2.3\nMARKETING_VERSION_X = 1.2.3\nCURRENT_PROJECT_VERSION = 7\n' \
  app_version_parse
is "app_version_parse: no version line (a comment, MARKETING_VERSION_X) fails, printing nothing" 1 ''
fn 'MARKETING_VERSION = 1.2.3\n// CURRENT_PROJECT_VERSION = 7\nCURRENT_PROJECT_VERSION_X = 7
DYLIB_CURRENT_PROJECT_VERSION = 7\n' app_build_parse
is "app_build_parse: no build line (a comment, CURRENT_PROJECT_VERSION_X, DYLIB_...) fails, printing nothing" 1 ''
fn 'MARKETING_VERSION = 1.2.3\nFOO = 1\n  MARKETING_VERSION = 1.2.3\n' app_version_parse
is "app_version_parse: two version lines fail, printing nothing, even with one value" 1 ''
fn 'MARKETING_VERSION = 1.2.3\nMARKETING_VERSION = 1.2.4\n' app_version_parse
is "app_version_parse: two different version lines fail" 1 ''
fn 'CURRENT_PROJECT_VERSION = 7\nFOO = 1\n\tCURRENT_PROJECT_VERSION = 7\n' app_build_parse
is "app_build_parse: two build lines fail, printing nothing, even with one value" 1 ''
fn '' app_version_parse
is "app_version_parse: empty input fails" 1 ''
fn '' app_build_parse
is "app_build_parse: empty input fails" 1 ''

# --- app_version_get, app_build_get: <root>/Config/Shared.xcconfig
XF=Config/Shared.xcconfig
ROOT="$WORK/root"
mkdir -p "$ROOT/Config"
printf '%b' "$XC" >"$ROOT/$XF"
fn '' app_version_get "$ROOT"
is "app_version_get: reads <root>/Config/Shared.xcconfig" 0 3.7.0
fn '' app_build_get "$ROOT"
is "app_build_get: reads <root>/Config/Shared.xcconfig" 0 42
fn '' app_version_get "$WORK/missing"
check "app_version_get: a missing file fails, printing nothing on stdout" '[ $RC != 0 ] && [ -z "$OUT" ]'
fn '' app_build_get "$WORK/missing"
check "app_build_get: a missing file fails, printing nothing on stdout" '[ $RC != 0 ] && [ -z "$OUT" ]'
fn '' app_version_get "$TREE"
tree_version=$OUT tree_rc=$RC
fn '' version_valid "$tree_version"
check "app_version_get: this repository's Config/Shared.xcconfig has one version line, X.Y.Z ($tree_version)" \
  '[ "$tree_rc" = 0 ] && [ $RC = 0 ]'
fn '' app_build_get "$TREE"
tree_build=$OUT tree_rc=$RC
fn '' build_valid "$tree_build"
check "app_build_get: this repository's Config/Shared.xcconfig has one build line, a build number ($tree_build)" \
  '[ "$tree_rc" = 0 ] && [ $RC = 0 ]'

# --- app_version_set: in place, only the values of the two lines, nothing on a failure
F="$ROOT/$XF"
chmod 640 "$F"
before_mode=$(mode "$F") before_inode=$(inode "$F")
printf '%b' "$XC" | sed -e 's/^MARKETING_VERSION = 3\.7\.0$/MARKETING_VERSION = 3.8.0/' \
  -e 's/^CURRENT_PROJECT_VERSION = 42$/CURRENT_PROJECT_VERSION = 43/' >"$WORK/expected"
fn '' app_version_set "$ROOT" 3.8.0 43
is "app_version_set: writes the version 3.8.0 and the build number 43 at once, printing nothing" 0 ''
check "...exactly the two lines changed, every other line is intact" 'cmp -s "$F" "$WORK/expected"'
check "...the file keeps its mode and inode" '[ "$(mode "$F")" = "$before_mode" ] && [ "$(inode "$F")" = "$before_inode" ]'
check "...no temp file is left in TMPDIR" '[ -z "$(ls -A "$WORK/tmp")" ]'
fn '' app_version_get "$ROOT"
is "...app_version_get reads the version back" 0 3.8.0
fn '' app_build_get "$ROOT"
is "...app_build_get reads the build number back" 0 43
cp "$F" "$WORK/before"
for v in 1.2 v3.9.0 03.9.0 3.9.0-rc1 '' ' 3.9.0' '3.9.0 ' 1000000000.0.0 '3.9.0 // x'; do
  fn '' app_version_set "$ROOT" "$v" 44
  check "app_version_set: the version '$v' is refused and the file is unchanged" \
    '[ $RC = 1 ] && [ -z "$OUT" ] && cmp -s "$F" "$WORK/before"'
done
for b in 0 01 -1 1.2 '' ' 44' '44 ' 1000000000 a '44 // x'; do
  fn '' app_version_set "$ROOT" 3.9.0 "$b"
  check "app_version_set: the build number '$b' is refused and the file is unchanged" \
    '[ $RC = 1 ] && [ -z "$OUT" ] && cmp -s "$F" "$WORK/before"'
done

printf '// x\n\t  MARKETING_VERSION   =  1.2.3  \t\nA=1\n \tCURRENT_PROJECT_VERSION\t=\t7 \n' >"$F"
printf '// x\n\t  MARKETING_VERSION   =  10.0.0  \t\nA=1\n \tCURRENT_PROJECT_VERSION\t=\t8 \n' >"$WORK/expected"
fn '' app_version_set "$ROOT" 10.0.0 8
check 'app_version_set: indented lines keep their indentation, the blanks around the "=" and the trailing blanks' \
  '[ $RC = 0 ] && cmp -s "$F" "$WORK/expected"'
printf 'CURRENT_PROJECT_VERSION=1\nMARKETING_VERSION=0.0.1\n' >"$F"
printf 'CURRENT_PROJECT_VERSION=999999999\nMARKETING_VERSION=999999999.999999999.999999999\n' >"$WORK/expected"
fn '' app_version_set "$ROOT" 999999999.999999999.999999999 999999999
check 'app_version_set: no blanks around the "=", the build line first, the highest version and build number' \
  '[ $RC = 0 ] && cmp -s "$F" "$WORK/expected"'
printf 'MARKETING_VERSION = 1.2.3 beta \nCURRENT_PROJECT_VERSION = 7 8\n' >"$F"
printf 'MARKETING_VERSION = 2.0.0 \nCURRENT_PROJECT_VERSION = 9\n' >"$WORK/expected"
fn '' app_version_set "$ROOT" 2.0.0 9
check "app_version_set: a value with inner spaces is replaced whole" '[ $RC = 0 ] && cmp -s "$F" "$WORK/expected"'
# A last line without a newline keeps going without one: awk's print would add it, and that line would change too
printf 'MARKETING_VERSION = 1.2.3\nCURRENT_PROJECT_VERSION = 7\n#include? "x.xcconfig"' >"$F"
printf 'MARKETING_VERSION = 1.3.0\nCURRENT_PROJECT_VERSION = 8\n#include? "x.xcconfig"' >"$WORK/expected"
fn '' app_version_set "$ROOT" 1.3.0 8
check "app_version_set: a last line without a newline stays without one" '[ $RC = 0 ] && cmp -s "$F" "$WORK/expected"'
printf 'A = 1\nMARKETING_VERSION = 1.2.3\nCURRENT_PROJECT_VERSION = 7' >"$F"
printf 'A = 1\nMARKETING_VERSION = 1.3.0\nCURRENT_PROJECT_VERSION = 8' >"$WORK/expected"
fn '' app_version_set "$ROOT" 1.3.0 8
check "...also when that line is the build line" '[ $RC = 0 ] && cmp -s "$F" "$WORK/expected"'

for c in 'no version line|CURRENT_PROJECT_VERSION = 1\n// MARKETING_VERSION = 1.2.3\nMARKETING_VERSION_X = 1.2.3\n' \
  'two version lines|MARKETING_VERSION = 1.2.3\nCURRENT_PROJECT_VERSION = 1\n  MARKETING_VERSION = 1.2.3\n' \
  'no build line|MARKETING_VERSION = 1.2.3\n// CURRENT_PROJECT_VERSION = 1\nDYLIB_CURRENT_PROJECT_VERSION = 1\n' \
  'two build lines|CURRENT_PROJECT_VERSION = 1\nMARKETING_VERSION = 1.2.3\n\tCURRENT_PROJECT_VERSION = 2\n' \
  'neither line (empty)|'; do
  printf '%b' "${c#*|}" >"$F"
  cp "$F" "$WORK/before"
  fn '' app_version_set "$ROOT" 2.0.0 2
  check "app_version_set: a file with ${c%%|*} fails and is unchanged" \
    '[ $RC = 1 ] && [ -z "$OUT" ] && cmp -s "$F" "$WORK/before"'
done
check "...no temp file is left in TMPDIR" '[ -z "$(ls -A "$WORK/tmp")" ]'
# its directory exists, so the file could be created
mkdir -p "$WORK/missing/Config"
fn '' app_version_set "$WORK/missing" 2.0.0 2
check "app_version_set: a missing file fails and is not created" '[ $RC != 0 ] && [ ! -e "$WORK/missing/$XF" ]'

# --- release_assets: the files of release X.Y.Z, in upload order; RELEASE_ARCHS: the architectures of the app
fn '' release_assets 1.2.3
is "release_assets 1.2.3: the zipped app, its zipped dSYMs and SHA256SUMS" 0 \
  "$(lines Thermik-1.2.3.zip Thermik-1.2.3-dSYMs.zip SHA256SUMS)"
fn '' eval 'printf "%s" "$RELEASE_ARCHS"'
is "RELEASE_ARCHS: the universal app, arm64 x86_64" 0 'arm64 x86_64'

# --- release_tags: tag names or `git ls-remote --tags` lines -> "<X.Y.Z> <tag>", once per tag
TAGS='0.1.0\nv0.2.0\nnot-a-release\n1.2\n\n01.0.0\nV0.5.0\nvv0.6.0\n0.3.0-rc1\n1000000000.0.0\n'
TAGS="${TAGS}aaaa\trefs/tags/0.3.0\nbbbb\trefs/tags/v0.4.0\ncccc\trefs/tags/v0.4.0^{}\nffff\trefs/tags/v1234567890.1.2\n"
TAGS="${TAGS}dddd\trefs/heads/0.9.0\n0.1.0\neeee\trefs/tags/0.10.0"
fn "$TAGS" release_tags
is "release_tags: X.Y.Z and vX.Y.Z tags, from names and ls-remote lines (peeled ones once), nothing else" 0 \
  "$(lines '0.1.0 0.1.0' '0.2.0 v0.2.0' '0.3.0 0.3.0' '0.4.0 v0.4.0' '0.10.0 0.10.0')"
fn '' release_tags
is "release_tags: no input, no tags" 0 ''

# --- highest_tag [skip]
fn "$TAGS" highest_tag
is "highest_tag: the highest version (0.10.0 > 0.4.0; the 10-digit tags are no versions)" 0 '0.10.0 0.10.0'
fn "$TAGS" highest_tag 0.10.0
is "highest_tag 0.10.0: the highest other tag" 0 '0.4.0 v0.4.0'
fn '0.9.0\n0.10.0\nv0.11.0\n1.0.0-rc1\n' highest_tag
is "highest_tag: a legacy v tag can be the highest" 0 '0.11.0 v0.11.0'
fn '0.9.0\nv0.11.0\n' highest_tag 0.11.0
is "highest_tag 0.11.0 skips only the tag named 0.11.0, not v0.11.0" 0 '0.11.0 v0.11.0'
fn 'nope\n1.2\n' highest_tag
is "highest_tag: nothing without release tags" 0 ''
fn '' highest_tag
is "highest_tag: nothing for no input" 0 ''

# --- tag_of_version
fn "$TAGS" tag_of_version 0.4.0
is "tag_of_version 0.4.0: the legacy tag v0.4.0" 0 v0.4.0
fn "$TAGS" tag_of_version 0.3.0
is "tag_of_version 0.3.0: the tag 0.3.0" 0 0.3.0
fn "$TAGS" tag_of_version 0.9.0
is "tag_of_version: nothing for a version without a tag (a branch named 0.9.0 is not one)" 0 ''
fn "$TAGS" tag_of_version 1.2
is "tag_of_version: nothing for a non-version" 0 ''
fn "$TAGS" tag_of_version 1000000000.0.0
is "tag_of_version: nothing for a 10-digit non-version, though a tag has that name" 0 ''
# Over 64 KiB (a pipe buffer) of release_tags output after the match: a tag_of_version that stops reading there
# leaves release_tags writing into a closed pipe every time, not only when it loses a race (the CI's Broken pipe)
fn "0.4.0$(awk 'BEGIN { for (i = 1; i <= 4000; i++) printf "\n1.0.%d", i }')" tag_of_version 0.4.0
is "tag_of_version: reads release_tags to the end, past a pipe buffer of tags after the match" 0 0.4.0

# --- tag_commit <tag>: the commit of refs/tags/<tag> in `git ls-remote --tags` lines
REFS='1111\trefs/tags/0.1.0\n2222\trefs/tags/v0.2.0\n3333\trefs/tags/v0.2.0^{}\n'
REFS="${REFS}4444\trefs/tags/10.1.0\n5555\trefs/tags/0.1.0.1\n6666\trefs/tags/0x1y0\n7777\trefs/heads/0.5.0\n"
fn "$REFS" tag_commit 0.1.0
is "tag_commit: a lightweight tag's own line" 0 1111
fn "$REFS" tag_commit v0.2.0
is "tag_commit: an annotated tag's peeled line, not the tag object" 0 3333
fn 'cccc\trefs/tags/0.4.0^{}\naaaa\trefs/tags/0.4.0\n' tag_commit 0.4.0
is "tag_commit: the peeled line wins wherever it is" 0 cccc
fn "$REFS" tag_commit 0.2.0
is "tag_commit: 0.2.0 is not v0.2.0" 0 ''
fn "$REFS" tag_commit 0.5.0
is "tag_commit: only refs/tags/<tag> counts (no branch, no longer names, no dots as wildcards)" 0 ''
fn "$REFS" tag_commit 0.1.0.1
is "tag_commit: a longer tag name is its own tag" 0 5555
fn '' tag_commit 0.1.0
is "tag_commit: nothing for no input" 0 ''

# --- what git itself prints: make-release.sh reads `git tag -l` and then `git ls-remote --tags origin`,
# release-state.sh and release.yml `git ls-remote --tags origin` (a tab between the commit and the ref, an annotated
# tag on two lines: its tag object, then its commit as <tag>^{}). A - B (annotated v0.2.0) - C (annotated 0.10.0,
# lightweight not-a-release); A has the lightweight 0.1.0.
GREPO="$WORK/git"
mkdir -p "$GREPO"
(
  set -e
  cd "$GREPO"
  git -c init.defaultBranch=master init -q .
  git commit -q --allow-empty -m A
  git tag 0.1.0
  git commit -q --allow-empty -m B
  git tag -a v0.2.0 -m legacy
  git commit -q --allow-empty -m C
  git tag -a 0.10.0 -m release
  git tag not-a-release
) || {
  echo "not ok the git fixture could not be built"
  exit 1
}
commit_of() { git -C "$GREPO" rev-parse "$1^{commit}"; }
LS_REMOTE="$(git -C "$GREPO" ls-remote --tags .)"
fn "$LS_REMOTE" tag_commit 0.1.0
is "tag_commit on git ls-remote --tags: a lightweight tag's commit" 0 "$(commit_of 0.1.0)"
fn "$LS_REMOTE" tag_commit v0.2.0
is "tag_commit on git ls-remote --tags: an annotated tag's commit, not the tag object" 0 "$(commit_of v0.2.0)"
fn "$LS_REMOTE" tag_commit 0.10.0
is "tag_commit on git ls-remote --tags: 0.10.0 is not 0.1.0" 0 "$(commit_of 0.10.0)"
fn "$LS_REMOTE" highest_tag 0.10.0
is "highest_tag 0.10.0 on git ls-remote --tags: the annotated v0.2.0" 0 '0.2.0 v0.2.0'
NAMES_AND_REFS="$(git -C "$GREPO" tag -l)
$LS_REMOTE"
fn "$NAMES_AND_REFS" release_tags
is "release_tags on git tag -l and git ls-remote --tags: every release tag once" 0 \
  "$(lines '0.1.0 0.1.0' '0.10.0 0.10.0' '0.2.0 v0.2.0')"
fn "$NAMES_AND_REFS" highest_tag
is "highest_tag on git tag -l and git ls-remote --tags: 0.10.0" 0 '0.10.0 0.10.0'
fn "$NAMES_AND_REFS" tag_of_version 0.2.0
is "tag_of_version 0.2.0 on git tag -l and git ls-remote --tags: v0.2.0" 0 v0.2.0

echo "# $pass passed, $fail failed"
[ "$fail" = 0 ]

#!/usr/bin/env bash
# Tests of .github/scripts/release-notes.sh: throwaway repositories in a temp dir (TMPDIR) with release tags, a side
# branch and a merge, the version in their Config/Shared.xcconfig. Runs the script under $TEST_BASH (default: bash
# from PATH). The notes are the body of the GitHub release: "- <commit subject>" lines, a blank line and one line on
# how to install the release files.
#
#   scripts/tests/release-notes_test.sh          KEEP=1 keeps the temp dir
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
if ! WORK="$(mktemp -d "${TMPDIR:-/tmp}/release-notes-test.XXXXXX")" || ! WORK="$(cd "$WORK" && pwd -P)"; then
  echo "not ok no temp dir in ${TMPDIR:-/tmp}"
  exit 1
fi
if [ -z "${KEEP:-}" ]; then trap 'rm -rf "$WORK"' EXIT; else echo "# work dir: $WORK"; fi

export HOME="$WORK/home" XDG_CONFIG_HOME="$WORK/home/.config" GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.invalid
GIT_CEILING_DIRECTORIES="$(dirname "$WORK")"
export GIT_CEILING_DIRECTORIES
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GH_REPO GITHUB_REPOSITORY GITHUB_SHA VERSION
mkdir -p "$HOME"

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
$OUT"; fi
}
# lines <line...>: the output is exactly these lines, each with its newline
lines() {
  local want
  want="$(printf '%s\n' "$@" && printf .)"
  [ "$OUT" = "${want%.}" ]
}
# install_line <X.Y.Z>: the install paragraph of the notes of X.Y.Z, one line (without its newline)
install_line() {
  printf '%s' "**Install:** open \`Thermik-$1.dmg\` and drag \`Thermik.app\` to Applications, or unzip" \
    " \`Thermik-$1.zip\` and move \`Thermik.app\` there. The app is ad-hoc" \
    " signed and not notarized, so macOS blocks its first launch: open it once, then allow it in System Settings ›" \
    " Privacy & Security › Open Anyway, or run \`xattr -dr com.apple.quarantine /Applications/Thermik.app\`." \
    " \`Thermik-$1.sha256\` holds the checksums."
}
# notes <X.Y.Z> <line...>: the output is exactly these lines, a blank line and the install paragraph of X.Y.Z
notes() {
  local v="$1"
  shift
  lines "$@" "" "$(install_line "$v")"
}
# names_assets <X.Y.Z>: the last line of the output follows a blank one and names, in backticks, every release file
# of X.Y.Z: release_assets of scripts/lib/version.sh, the files release.yml uploads
names_assets() {
  local names name last
  names="$("$BASH_BIN" -c '. "$1/scripts/lib/version.sh" && release_assets "$2"' ra "$TREE" "$1")" || return 1
  [ -n "$names" ] && [ -z "$(printf '%s' "$OUT" | tail -n 2 | head -n 1)" ] || return 1
  last="$(printf '%s' "$OUT" | tail -n 1)"
  while IFS= read -r name; do
    case $last in *"\`$name\`"*) ;; *) return 1 ;; esac
  done <<<"$names"
}

echo "# .github/scripts/release-notes.sh under $("$BASH_BIN" -c 'echo "bash $BASH_VERSION"'), $(git --version)"

# xcconfig <version>: Config/Shared.xcconfig with that version, shaped like the real one
xcconfig() {
  printf '%s\n' \
    '// Shared settings. scripts/make-release.sh sets MARKETING_VERSION and CURRENT_PROJECT_VERSION.' \
    'CODE_SIGN_IDENTITY = -' \
    "MARKETING_VERSION = $1" \
    'CURRENT_PROJECT_VERSION = 7' \
    'HELPER_BUILD_VERSION = 6' \
    '#include? "Signing.local.xcconfig"'
}
# new_repo <dir>: a repository with the scripts and Config/Shared.xcconfig 0.2.0, first commit 'Add the menu bar app'
new_repo() {
  REPO="$1"
  mkdir -p "$REPO/Config" "$REPO/scripts/lib" "$REPO/.github/scripts"
  cp "$TREE/scripts/lib/version.sh" "$REPO/scripts/lib/"
  cp "$TREE/.github/scripts/release-notes.sh" "$REPO/.github/scripts/"
  xcconfig 0.2.0 >"$REPO/Config/Shared.xcconfig"
  git -c init.defaultBranch=master init -q "$REPO"
  git -C "$REPO" symbolic-ref HEAD refs/heads/master
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m 'Add the menu bar app'
}
c() { git -C "$REPO" commit -q --allow-empty -m "$1"; }
# rn [VAR=value...]: release-notes.sh of REPO, run from WORK; sets OUT (stdout and stderr, byte for byte: "$(...)"
# alone would drop the newlines at the end) and RC
rn() {
  (cd "$WORK" && env "$@" "$BASH_BIN" "$REPO/.github/scripts/release-notes.sh") >"$WORK/out" 2>&1
  RC=$?
  OUT="$(cat "$WORK/out" && printf .)"
  OUT=${OUT%.}
}

# v0.0.9 (legacy, annotated) - Fix the fan curve (0.1.0) - [side: Side work (0.1.5)] - feat: release - version 0.1.9 -
# feat: release - version 0.2.0 - topic merge (Add the topic, feat: release - versioning docs, feat: release - version
# 1.2, feat: release - version 0.2.0 fixes) - Fix the menu
new_repo "$WORK/main"
git -C "$REPO" tag -a v0.0.9 -m legacy
c 'Fix the fan curve'
git -C "$REPO" tag 0.1.0
git -C "$REPO" checkout -q -b side
c 'Side work'
git -C "$REPO" tag 0.1.5
git -C "$REPO" checkout -q master
c 'feat: release - version 0.1.9'
c 'feat: release - version 0.2.0'
git -C "$REPO" checkout -q -b topic
c 'Add the topic'
c 'feat: release - versioning docs'
c 'feat: release - version 1.2'
c 'feat: release - version 0.2.0 fixes'
git -C "$REPO" checkout -q master
git -C "$REPO" merge -q --no-ff -m 'Merge branch topic' topic
git -C "$REPO" commit -q --allow-empty -m 'Fix the menu' -m 'A body line that is not a subject.'

rn
check "the commits since the previous release tag in the history (0.1.0, not the side branch's 0.1.5), newest first, then the install paragraph" \
  '[ $RC = 0 ] && notes 0.2.0 "- Fix the menu" "- feat: release - version 0.2.0 fixes" "- feat: release - version 1.2" "- feat: release - versioning docs" "- Add the topic"'
check "...no merges, no bodies, no release commits: those whose subject is exactly 'feat: release - version X.Y.Z' (0.1.9, 0.2.0)" \
  '! printf "%s" "$OUT" | grep -q -e Merge -e "body line" && ! printf "%s" "$OUT" | grep -qxF -e "- feat: release - version 0.1.9" -e "- feat: release - version 0.2.0"'
check "...'feat: release - versioning docs', 'feat: release - version 1.2' and 'feat: release - version 0.2.0 fixes' stay" \
  '[ "$(printf "%s" "$OUT" | grep -cxF -e "- feat: release - versioning docs" -e "- feat: release - version 1.2" -e "- feat: release - version 0.2.0 fixes")" = 3 ]'
check "...the install paragraph is one line after a blank one, naming every release file of 0.2.0 (release_assets)" \
  'names_assets 0.2.0'
git -C "$REPO" tag 0.2.0
rn
check "a tag of the version itself (a retry) is not the previous one" \
  '[ $RC = 0 ] && notes 0.2.0 "- Fix the menu" "- feat: release - version 0.2.0 fixes" "- feat: release - version 1.2" "- feat: release - versioning docs" "- Add the topic"'
rn GITHUB_SHA=0.1.0 VERSION=0.1.0
check "GITHUB_SHA and VERSION: the history up to that commit, since the legacy tag v0.0.9; the files of 0.1.0" \
  '[ $RC = 0 ] && notes 0.1.0 "- Fix the fan curve"'
rn GITHUB_SHA="$(git -C "$REPO" rev-parse side)" VERSION=0.1.5
check "GITHUB_SHA on the side branch: since 0.1.0 there" '[ $RC = 0 ] && notes 0.1.5 "- Side work"'
xcconfig 0.3.0 >"$REPO/Config/Shared.xcconfig"
rn
check "the version comes from Config/Shared.xcconfig: 0.3.0, so the tag 0.2.0 is the previous one" \
  '[ $RC = 0 ] && notes 0.3.0 "- Release 0.3.0"'

new_repo "$WORK/first"
c 'Fix a'
rn
check "no release tag yet: every commit" '[ $RC = 0 ] && notes 0.2.0 "- Fix a" "- Add the menu bar app"'
git -C "$REPO" tag 0.1.0
c 'feat: release - version 0.2.0'
rn
check "only a release commit since the last tag: '- Release X.Y.Z', then the install paragraph" \
  '[ $RC = 0 ] && notes 0.2.0 "- Release 0.2.0"'
rn VERSION=0.2.1
check "...with the version of VERSION, in that line and in the file names" '[ $RC = 0 ] && notes 0.2.1 "- Release 0.2.1"'
rn VERSION=
check "an empty VERSION reads Config/Shared.xcconfig" '[ $RC = 0 ] && notes 0.2.0 "- Release 0.2.0"'
for v in v0.2.0 0.2 0.2.0-rc1 0.2.0.1 1000000000.0.0 0.2.1000000000; do
  rn VERSION="$v"
  check "VERSION '$v' (not X.Y.Z, or a number of more than 9 digits) is refused" \
    '[ $RC = 1 ] && lines "release-notes: «${v}» is not X.Y.Z"'
done
rn VERSION=999999999.999999999.999999999
check "numbers of up to 9 digits make a version" \
  '[ $RC = 0 ] && notes 999999999.999999999.999999999 "- Release 999999999.999999999.999999999"'
REF='$(APP_VERSION)'
xcconfig "$REF" >"$REPO/Config/Shared.xcconfig"
rn
check "a MARKETING_VERSION that is not X.Y.Z (a build setting reference) is refused, naming it" \
  '[ $RC = 1 ] && lines "release-notes: «${REF}» is not X.Y.Z"'
{
  xcconfig 0.2.0
  echo 'MARKETING_VERSION = 0.2.0'
} >"$REPO/Config/Shared.xcconfig"
rn
check "Config/Shared.xcconfig with two MARKETING_VERSION lines is refused" \
  '[ $RC = 1 ] && lines "release-notes: «» is not X.Y.Z"'
rn VERSION=0.2.0
check "...unless VERSION is given" '[ $RC = 0 ] && notes 0.2.0 "- Release 0.2.0"'

echo "# $pass passed, $fail failed"
[ "$fail" = 0 ]

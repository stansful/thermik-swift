#!/usr/bin/env bash
# Tests of scripts/make-release.sh: throwaway repositories, each a clone of its own local bare "origin", in a temp
# dir (TMPDIR), with the script, scripts/lib/version.sh and a Config/Shared.xcconfig shaped like the real one
# (comments, other settings such as HELPER_BUILD_VERSION, the lines MARKETING_VERSION = 0.1.0 and
# CURRENT_PROJECT_VERSION = 1). The script runs from a directory outside the repository, under $TEST_BASH (default:
# bash from PATH, /bin/bash 3.2 on macOS). git reads only this test's config (HOME is the temp dir).
#
#   scripts/tests/make-release_test.sh          KEEP=1 keeps the temp dir
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
if ! WORK="$(mktemp -d "${TMPDIR:-/tmp}/make-release-test.XXXXXX")" || ! WORK="$(cd "$WORK" && pwd -P)"; then
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
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR
mkdir -p "$HOME"
# the script's temp files (app_version_set) land here, an absolute path whatever the caller's TMPDIR (the script runs
# from WORK)
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
# check <name> <condition (eval'd)>: on failure prints the script's output
check() {
  if eval "$2"; then ok "$1"; else nok "$1" "rc=$RC; condition: $2; output:
$OUT"; fi
}
has() { case $OUT in *"$1"*) return 0 ;; esac; return 1; }

echo "# scripts/make-release.sh under $("$BASH_BIN" -c 'echo "bash $BASH_VERSION"'), $(git --version)"

XC=Config/Shared.xcconfig
# xcconfig <version> <build>: the fixture's Config/Shared.xcconfig, shaped like the real one (comments, a commented
# example with "=", other settings, the helper's own build number, an include), with that version and build number
xcconfig() {
  cat <<EOF
// Shared signing defaults. Contributors without an Apple account get an ad-hoc ("Sign to Run Locally") build
// that installs the helper with the LEGACY installer (one admin prompt per rebuild).
// For a Team-ID build (SMAppService path) create Config/Signing.local.xcconfig (git-ignored) with:
//   DEVELOPMENT_TEAM = ABCDE12345
//   CODE_SIGN_IDENTITY = Apple Development
//   CODE_SIGN_STYLE = Automatic
DEVELOPMENT_TEAM =
CODE_SIGN_IDENTITY = -
CODE_SIGN_STYLE = Manual
ENABLE_HARDENED_RUNTIME = YES
OTHER_CODE_SIGN_FLAGS = \$(inherited) --options=runtime
ENABLE_DEBUG_DYLIB = NO
MARKETING_VERSION = $1
CURRENT_PROJECT_VERSION = $2
// Bump ONLY when helper code changes: the app reinstalls/re-registers the helper when this differs.
HELPER_BUILD_VERSION = 6
// Developer opt-in for a debuggable Debug build (see Debug.xcconfig); Release ignores it.
THERMIK_DEBUGGABLE = NO
#include? "Signing.local.xcconfig"
EOF
}
# blanks <version> <build>: the fixture with other blanks around the two values: none around the "=" of the version
# line; a tab before the build line, a tab after its "=" and blanks after its value
blanks() {
  xcconfig "$1" "$2" | awk '
    /^MARKETING_VERSION = / { sub(/ = /, "=") }
    /^CURRENT_PROJECT_VERSION = / { sub(/ = /, " =\t"); $0 = "\t" $0 " \t " }
    { print }'
}
# commented <version> <build>: the fixture with a commented-out version line and build line above the real ones
commented() {
  xcconfig "$1" "$2" | awk '
    /^MARKETING_VERSION = / { print "// MARKETING_VERSION = 9.9.9"; print "//CURRENT_PROJECT_VERSION = 99" }
    { print }'
}

# The fixture copies the lines the script reads from the real Config/Shared.xcconfig: one version line X.Y.Z and
# one build line N
OUT="$("$BASH_BIN" -c '. "$0" && v="$(app_version_get "$1")" && b="$(app_build_get "$1")" &&
  version_valid "$v" && build_valid "$b" && echo "MARKETING_VERSION = $v, CURRENT_PROJECT_VERSION = $b"' \
  "$TREE/scripts/lib/version.sh" "$TREE" 2>&1)"
RC=$?
check "the real Config/Shared.xcconfig has the fixture's lines: one version X.Y.Z, one build number" \
  '[ $RC = 0 ] && has "MARKETING_VERSION = "'

# --- the template: origin.git with master (Config/Shared.xcconfig 0.1.0, build 1, the script) and the tag 0.1.0 on
# its first commit
TPL="$WORK/tpl"
mkdir -p "$TPL/seed/Config" "$TPL/seed/scripts/lib"
cp "$TREE/scripts/make-release.sh" "$TPL/seed/scripts/"
cp "$TREE/scripts/lib/version.sh" "$TPL/seed/scripts/lib/"
xcconfig 0.1.0 1 >"$TPL/seed/$XC"
echo readme >"$TPL/seed/README"
printf 'build/\n' >"$TPL/seed/.gitignore"
(
  set -e
  cd "$TPL/seed"
  git -c init.defaultBranch=master init -q .
  git symbolic-ref HEAD refs/heads/master
  git add -A
  git commit -q -m init
  git tag 0.1.0
  echo more >>README
  git commit -q -am 'Fix something'
  git init -q --bare "$TPL/origin.git"
  git -C "$TPL/origin.git" symbolic-ref HEAD refs/heads/master
  git push -q "$TPL/origin.git" master 0.1.0
) || {
  echo "not ok the test fixture could not be built"
  exit 1
}

# new_case <name>: CASE/origin.git (a copy of the template's) and its clone REPO; a name used twice stops the tests
# (the clone would fail and the case would run in the earlier case's repository)
new_case() {
  CASE="$WORK/$1"
  if [ -e "$CASE" ]; then
    echo "not ok the test case name '$1' is used twice"
    exit 1
  fi
  mkdir -p "$CASE"
  cp -R "$TPL/origin.git" "$CASE/origin.git"
  git clone -q "$CASE/origin.git" "$CASE/repo"
  REPO="$CASE/repo"
}
# mr <stdin (printf %b)> [args...]: make-release.sh of REPO, run from WORK; sets OUT and RC
mr() {
  local input="$1"
  shift
  OUT="$(cd "$WORK" && printf '%b' "$input" | "$BASH_BIN" "$REPO/scripts/make-release.sh" "$@" 2>&1)"
  RC=$?
}
g() { git -C "$REPO" "$@"; }
# ver, bld: the value of the version line (or lines), of the build line (or lines), read without
# scripts/lib/version.sh
ver() { sed -n 's/^MARKETING_VERSION = //p' "$REPO/$XC"; }
bld() { sed -n 's/^CURRENT_PROJECT_VERSION = //p' "$REPO/$XC"; }
count() { g rev-list --count HEAD; }
origin_ref() { git -C "$CASE/origin.git" rev-parse -q --verify "refs/heads/$1"; }
all_tags() { { g tag -l && git -C "$CASE/origin.git" tag -l; } | LC_ALL=C sort | tr '\n' ' '; }
clean() { [ -z "$(g status --porcelain)" ]; }
# lines <old version> <old build> <new version> <new build>: the changed lines of the fixture's diff from the old
# values to the new ones
lines() {
  printf -- '-MARKETING_VERSION = %s\n-CURRENT_PROJECT_VERSION = %s\n+MARKETING_VERSION = %s\n+CURRENT_PROJECT_VERSION = %s' \
    "$1" "$2" "$3" "$4"
}
# shown_diff: the changed lines of the diff the script printed
shown_diff() { printf '%s\n' "$OUT" | grep '^[-+][^-+]'; }
# xcconfig_is <version> <build> [fixture]: Config/Shared.xcconfig is the fixture's (or what the function [fixture]
# prints), byte for byte, with that version and build number
xcconfig_is() {
  "${3:-xcconfig}" "$1" "$2" >"$WORK/expected" && cmp -s "$WORK/expected" "$REPO/$XC"
}
# release_commit <old version> <old build> <new version> <new build> [fixture]: HEAD is the release commit of the new
# version: its message is "feat: release - version <new version>", and against HEAD^ it changes
# Config/Shared.xcconfig from the fixture (or [fixture]) with the old version and build number to the one with the
# new ones: the version line and the build line, nothing else (no other line, file or mode)
release_commit() {
  local fixture="${5:-xcconfig}"
  [ "$(g log -1 --format=%B)" = "feat: release - version $3" ] &&
    [ "$(g diff --numstat HEAD^ HEAD)" = "$(printf '2\t2\t%s' "$XC")" ] &&
    [ -z "$(g diff --summary HEAD^ HEAD)" ] &&
    [ "$(g show "HEAD^:$XC")" = "$("$fixture" "$1" "$2")" ] &&
    [ "$(g show "HEAD:$XC")" = "$("$fixture" "$3" "$4")" ]
}

# --- Enter takes the suggestion, the next patch version; the build number goes up by one
new_case enter
before=$(count) head=$(g rev-parse HEAD) origin=$(origin_ref master) tags=$(all_tags)
mr '\n\n'
check "prints the current version and its build number" \
  'has "Текущая версия:         0.1.0 (Config/Shared.xcconfig, сборка 1)"'
check "prints the last release tag" 'has "Последний релизный тег: 0.1.0"'
check "...and no 'not released yet' note for a released version" '! has "Тега 0.1.0 ещё нет"'
check "prints the next patch, minor and major versions" 'has "Следующая: 0.1.1 (patch), 0.2.0 (minor), 1.0.0 (major)."'
check "suggests the next patch version" 'has "Новая версия [0.1.1]: "'
check "shows the diff, the version line and the build line, and asks to commit" \
  '[ "$(shown_diff)" = "$(lines 0.1.0 1 0.1.1 2)" ] && has "Закоммитить Config/Shared.xcconfig как «feat: release - version 0.1.1»? [Y/n] "'
check "Enter takes 0.1.1 and build 2, Enter commits (run from outside the repository)" \
  '[ $RC = 0 ] && [ "$(ver)" = 0.1.1 ] && [ "$(bld)" = 2 ] && xcconfig_is 0.1.1 2'
check "...exactly one new commit, on the old HEAD" '[ "$(count)" = $((before + 1)) ] && [ "$(g rev-parse HEAD^)" = "$head" ]'
check "...'feat: release - version 0.1.1': the version line and the build line + 1 of Config/Shared.xcconfig, nothing else" \
  'release_commit 0.1.0 1 0.1.1 2 && clean'
check "...prints the commit with its build number, and when the release comes out" \
  'has "Коммит $(g rev-parse --short HEAD): feat: release - version 0.1.1 (сборка 2)" && has "Релиз 0.1.1 выйдет, когда этот коммит окажется в master на GitHub (.github/workflows/release.yml)."'
check "...never pushes and never asks to: origin and tags untouched" \
  '[ "$(origin_ref master)" = "$origin" ] && [ "$(all_tags)" = "$tags" ] && ! has "Запуш" && ! has "запуш" && ! has "git push"'

new_case 'with space'
mr '' --yes
check "a repository path with a space works" '[ $RC = 0 ] && release_commit 0.1.0 1 0.1.1 2 && clean'

# --- bump words at the prompt
for c in 'patch|0.1.1' 'патч|0.1.1' 'minor|0.2.0' 'Минор|0.2.0' 'major|1.0.0' 'мажор|1.0.0' 'MAJOR|1.0.0' '  патч  |0.1.1'; do
  w=${c%|*} want=${c#*|}
  new_case "prompt-$want-$(printf '%s' "$w" | od -An -tx1 | tr -d ' \n')"
  mr "$w\n\n"
  check "prompt: '$w' is $want" '[ $RC = 0 ] && [ "$(ver)" = "$want" ] && release_commit 0.1.0 1 "$want" 2 && clean'
done

# --- bump words as the argument
new_case words
before=$(count)
for c in 'patch|0.1.1' 'minor|0.2.0' 'major|1.0.0' 'патч|0.1.1' 'минор|0.2.0' 'мажор|1.0.0' 'Patch|0.1.1' 'Мажор|1.0.0'; do
  w=${c%|*} want=${c#*|}
  mr '' "$w" --no-commit
  check "argument '$w' is $want" \
    '[ $RC = 0 ] && has "Новая версия: $want (сборка 2)" && xcconfig_is "$want" 2 && [ "$(count)" = "$before" ]'
  g checkout -q -- "$XC"
done
mr '' minor --yes
check "argument minor --yes commits 0.2.0" \
  '[ $RC = 0 ] && has "Новая версия: 0.2.0 (сборка 2)" && release_commit 0.1.0 1 0.2.0 2 && clean'

# --- no versionCode: numbers of up to 9 digits
new_case wide
mr '' 0.1000.0 --yes
check "0.1000.0 is a version" '[ $RC = 0 ] && has "Новая версия: 0.1000.0 (сборка 2)" && release_commit 0.1.0 1 0.1000.0 2 && clean'
mr '' 2101.0.0 --yes
check "...and so is 2101.0.0" '[ $RC = 0 ] && release_commit 0.1000.0 2 2101.0.0 3 && clean'
mr '' 999999999.0.0 --yes
check "...and 999999999.0.0, 9 digits" '[ $RC = 0 ] && release_commit 2101.0.0 3 999999999.0.0 4 && clean'

# --- the prompt asks again after a refused version
new_case reask
before=$(count)
mr '0.0.9\n0.1.0\n1.2\nv0.2.0\nV0.2.0\n01.2.3\n0.2.0-rc1\n1234567890.0.0\n0.1000000000.0\n0.2.1234567890\nбамп\n  0.3.0  \ny\n'
check "prompt: a lower version is refused" 'has "  версия 0.0.9 не выше текущей 0.1.0. Введите другую версию."'
check "prompt: an existing tag is refused" 'has "  тег 0.1.0 уже есть: версия 0.1.0 уже выпускалась. Введите другую версию."'
check "prompt: a malformed version is refused" \
  'has "  «1.2» — не версия X.Y.Z (три числа до 9 цифр без ведущих нулей, например 0.1.1). Введите другую версию." && has "«01.2.3» — не версия X.Y.Z" && has "«0.2.0-rc1» — не версия X.Y.Z" && has "«бамп» — не версия X.Y.Z"'
check "prompt: a version with v or V is refused" \
  'has "  «v0.2.0»: нужна версия без «v», например 0.2.0. Введите другую версию." && has "«V0.2.0»: нужна версия без «v», например 0.2.0"'
check "prompt: a number of 10 digits is refused" \
  'has "  «1234567890.0.0» — не версия X.Y.Z (три числа до 9 цифр без ведущих нулей, например 0.1.1). Введите другую версию." && has "«0.1000000000.0» — не версия X.Y.Z" && has "«0.2.1234567890» — не версия X.Y.Z"'
check "prompt: then 0.3.0 (spaces trimmed) is committed" \
  '[ $RC = 0 ] && [ "$(ver)" = 0.3.0 ] && [ "$(count)" = $((before + 1)) ] && release_commit 0.1.0 1 0.3.0 2 && clean'

# --- end of input at the prompt
new_case eof
before=$(count)
mr 'abc\n'
check "end of input at the prompt changes nothing" \
  '[ $RC = 1 ] && has "Ошибка: ввод прерван, ничего не изменено." && xcconfig_is 0.1.0 1 && [ "$(count)" = "$before" ] && clean'

# --- refused versions given as the argument
new_case refuse
before=$(count)
for c in "0.0.9|версия 0.0.9 не выше текущей 0.1.0." "0.1.0|тег 0.1.0 уже есть: версия 0.1.0 уже выпускалась." \
  "1.2|«1.2» — не версия X.Y.Z (три числа до 9 цифр без ведущих нулей, например 0.1.1)." \
  "1.2.3.4|«1.2.3.4» — не версия X.Y.Z" "v0.2.0|«v0.2.0»: нужна версия без «v», например 0.2.0." \
  "V1.0.0|«V1.0.0»: нужна версия без «v», например 1.0.0." "01.2.3|«01.2.3» — не версия X.Y.Z" \
  "1.02.3|«1.02.3» — не версия X.Y.Z" "0.2.0-rc1|«0.2.0-rc1» — не версия X.Y.Z" " 0.2.0|« 0.2.0» — не версия X.Y.Z" \
  "бамп|«бамп» — не версия X.Y.Z" "|версия не указана." "1234567890.0.0|«1234567890.0.0» — не версия X.Y.Z" \
  "0.1234567890.0|«0.1234567890.0» — не версия X.Y.Z" "0.2.1234567890|«0.2.1234567890» — не версия X.Y.Z" \
  "0.2.0000000001|«0.2.0000000001» — не версия X.Y.Z"; do
  v=${c%%|*} want=${c#*|}
  mr '' --yes "$v"
  check "argument '$v' is refused: $want" \
    '[ $RC = 1 ] && has "Ошибка: $want" && xcconfig_is 0.1.0 1 && [ "$(count)" = "$before" ] && clean'
done
mr '\n\n' 0.0.9
check "a refused argument does not fall back to the prompt" \
  '[ $RC = 1 ] && ! has "Новая версия [" && xcconfig_is 0.1.0 1 && [ "$(count)" = "$before" ]'

# --- tags: local only, origin only, a legacy annotated vX.Y.Z on origin
new_case tags
g tag 0.5.0
git clone -q "$CASE/origin.git" "$CASE/other"
git -C "$CASE/other" tag 0.7.0
git -C "$CASE/other" tag -a v0.8.0 -m legacy
git -C "$CASE/other" push -q origin 0.7.0 v0.8.0
before=$(count) origin=$(origin_ref master)
mr '' --yes 0.5.0
check "a local tag is refused" '[ $RC = 1 ] && has "Ошибка: тег 0.5.0 уже есть: версия 0.5.0 уже выпускалась."'
mr '' --yes 0.7.0
check "a tag only on origin is refused" '[ $RC = 1 ] && has "тег 0.7.0 уже есть"'
mr '' --yes 0.8.0
check "a legacy tag v0.8.0 on origin is refused for 0.8.0" '[ $RC = 1 ] && has "тег v0.8.0 уже есть: версия 0.8.0 уже выпускалась"'
mr '' --yes 0.6.0
check "a version below the highest tag is refused" '[ $RC = 1 ] && has "версия 0.6.0 не выше последнего релизного тега v0.8.0"'
check "...nothing changed" 'xcconfig_is 0.1.0 1 && [ "$(count)" = "$before" ] && clean'
mr ''
check "the last tag and the suggestions come from all tags" \
  'has "Последний релизный тег: v0.8.0" && has "Следующая: 0.8.1 (patch), 0.9.0 (minor), 1.0.0 (major)." && has "Новая версия [0.8.1]: " && [ $RC = 1 ]'
mr '' патч --no-commit
check "a bump word bumps the highest tag, not the current version; the build number is the file's + 1" \
  '[ $RC = 0 ] && has "Новая версия: 0.8.1 (сборка 2)" && xcconfig_is 0.8.1 2'
g checkout -q -- "$XC"
mr '' --yes
check "--yes takes the suggested 0.8.1 and commits without a question" \
  '[ $RC = 0 ] && has "Новая версия: 0.8.1 (сборка 2)" && ! has "Закоммитить" && release_commit 0.1.0 1 0.8.1 2 && [ "$(count)" = $((before + 1)) ] && clean'
check "--yes does not push" '[ "$(origin_ref master)" = "$origin" ] && ! has "Запуш"'

# --- origin's tags cannot be read: a warning, then the local tags only
new_case badorigin
git clone -q "$CASE/origin.git" "$CASE/other"
git -C "$CASE/other" tag 0.7.0
git -C "$CASE/other" push -q origin 0.7.0
g remote set-url origin "$CASE/missing.git"
mr '' -y
check "unreadable origin tags: a warning, the local tags only, the commit is made" \
  '[ $RC = 0 ] && has "Внимание: не удалось прочитать теги origin ($CASE/missing.git): сравниваю только с локальными тегами." && has "Последний релизный тег: 0.1.0 (из локальных тегов)" && release_commit 0.1.0 1 0.1.1 2'

# --- no release tags at all
new_case notags
g tag -d 0.1.0 >/dev/null
git -C "$CASE/origin.git" tag -d 0.1.0 >/dev/null
mr ''
check "no tags: says so, and that the current version is not released yet" \
  'has "Релизных тегов пока нет." && has "Тега 0.1.0 ещё нет: если коммит с этой версией уже в master на GitHub, релиз 0.1.0 выйдет и без новой версии." && has "Новая версия [0.1.1]: "'
mr '' 0.1.0 --yes
check "no tags: the current version itself is still refused" '[ $RC = 1 ] && has "версия 0.1.0 не выше текущей 0.1.0"'

# --- a dirty tree
new_case dirty
before=$(count)
echo change >>"$REPO/README"
mr '' --yes 0.2.0
check "a modified file is refused" \
  '[ $RC = 1 ] && has "Ошибка: есть незакоммиченные изменения (рабочее дерево или индекс):" && has " M README" && has "в релизный коммит входит только Config/Shared.xcconfig." && xcconfig_is 0.1.0 1 && [ "$(count)" = "$before" ]'
check "...and stays modified" '[ "$(g status --porcelain)" = " M README" ]'
g checkout -q -- README
xcconfig 0.5.0 1 >"$REPO/$XC"
mr '' --yes 0.2.0
check "a modified Config/Shared.xcconfig is refused and left as it is" \
  '[ $RC = 1 ] && has "есть незакоммиченные изменения" && has " M Config/Shared.xcconfig" && xcconfig_is 0.5.0 1 && [ "$(count)" = "$before" ]'
g checkout -q -- "$XC"
echo new >"$REPO/newfile"
g add newfile
mr '' --yes 0.2.0
check "a staged file is refused" \
  '[ $RC = 1 ] && has "есть незакоммиченные изменения" && xcconfig_is 0.1.0 1 && [ "$(count)" = "$before" ] && [ "$(g status --porcelain)" = "A  newfile" ]'
g reset -q
mkdir -p "$REPO/build"
echo log >"$REPO/build/build.log"
mr '' --yes 0.2.0
check "an untracked file is only a warning, and stays out of the commit" \
  '[ $RC = 0 ] && has "Внимание: есть файлы не в git, в релиз они не попадут:" && has "  newfile" && release_commit 0.1.0 1 0.2.0 2 && [ "$(g status --porcelain)" = "?? newfile" ]'
check "...ignored files are not listed" '! has "build.log"'
new_case untracked
for i in 01 02 03 04 05 06 07 08 09 10 11 12; do echo x >"$REPO/f$i"; done
mr '' --yes 0.2.0
check "more than 10 untracked files: the first 10 and …" \
  '[ $RC = 0 ] && has "  f10" && ! has "f11" && has "  …" && release_commit 0.1.0 1 0.2.0 2'

# --- git hooks: they run on the commit's own index, so what a pre-commit hook stages lands in the commit
# hook <commands>: REPO's pre-commit hook
hook() {
  mkdir -p "$REPO/.git/hooks"
  printf '#!/bin/sh\n%s\n' "$1" >"$REPO/.git/hooks/pre-commit"
  chmod +x "$REPO/.git/hooks/pre-commit"
}
no_verify="git commit --no-verify -m 'feat: release - version 0.2.0' -- Config/Shared.xcconfig"
new_case hooknew
hook 'echo x >>other && git add other'
head=$(g rev-parse HEAD) origin=$(origin_ref master)
mr '' 0.2.0 --yes
check "a hook that stages a new file: the release commit is undone" \
  '[ $RC = 1 ] && has "Ошибка: хук git (pre-commit или другой) изменил релизный коммит, а в нём должны быть только строки версии 0.2.0 и сборки 2 в Config/Shared.xcconfig. В коммит попало:" && [ "$(g rev-parse HEAD)" = "$head" ] && [ "$(origin_ref master)" = "$origin" ]'
check "...it names the files the commit had and how to commit past the hook" \
  'has "  Config/Shared.xcconfig" && has "  other" && has "scripts/make-release.sh 0.2.0 --no-commit, затем" && has "  $no_verify"'
check "...Config/Shared.xcconfig is back in the tree and the index, the hook's file is left untracked" \
  'has "Коммит отменён, Config/Shared.xcconfig возвращён; что хук поменял в рабочем дереве, там и осталось (git status)." && xcconfig_is 0.1.0 1 && [ "$(g status --porcelain)" = "?? other" ]'
mr '' 0.2.0 --no-commit
g commit -q --no-verify -m 'feat: release - version 0.2.0' -- "$XC"
check "...and that way past the hook is the release commit" \
  '[ $RC = 0 ] && release_commit 0.1.0 1 0.2.0 2 && [ "$(g status --porcelain)" = "?? other" ]'
new_case hooktracked
hook 'echo x >>README && git add README'
head=$(g rev-parse HEAD)
mr '' 0.2.0 --yes
check "a hook that stages a tracked file: the commit is undone, the hook's change is left unstaged" \
  '[ $RC = 1 ] && has "  README" && [ "$(g rev-parse HEAD)" = "$head" ] && xcconfig_is 0.1.0 1 && [ "$(g status --porcelain)" = " M README" ]'
new_case hookversion
hook "sed 's/^MARKETING_VERSION = 0.2.0\$/MARKETING_VERSION = 9.9.9/' $XC >.git/v && cat .git/v >$XC && git add $XC"
head=$(g rev-parse HEAD)
mr '' 0.2.0 --yes
check "a hook that rewrites the version line: the commit is undone" \
  '[ $RC = 1 ] && has "изменил релизный коммит" && [ "$(g rev-parse HEAD)" = "$head" ] && xcconfig_is 0.1.0 1 && clean'
new_case hookbuild
hook "sed 's/^CURRENT_PROJECT_VERSION = 2\$/CURRENT_PROJECT_VERSION = 3/' $XC >.git/v && cat .git/v >$XC && git add $XC"
head=$(g rev-parse HEAD)
mr '' 0.2.0 --yes
check "a hook that rewrites the build line (2 to 3): the commit is undone" \
  '[ $RC = 1 ] && has "изменил релизный коммит, а в нём должны быть только строки версии 0.2.0 и сборки 2" && has "  Config/Shared.xcconfig" && [ "$(g rev-parse HEAD)" = "$head" ] && xcconfig_is 0.1.0 1 && clean'
new_case hookline
hook "echo 'SWIFT_VERSION = 6.0' >>$XC && git add $XC"
head=$(g rev-parse HEAD)
mr '' 0.2.0 --yes
check "a hook that adds a line to Config/Shared.xcconfig: the commit is undone" \
  '[ $RC = 1 ] && has "изменил релизный коммит" && has "  Config/Shared.xcconfig" && [ "$(g rev-parse HEAD)" = "$head" ] && xcconfig_is 0.1.0 1 && clean'
new_case hookhelper
hook "sed 's/^HELPER_BUILD_VERSION = 6\$/HELPER_BUILD_VERSION = 7/' $XC >.git/v && cat .git/v >$XC && git add $XC"
head=$(g rev-parse HEAD)
mr '' 0.2.0 --yes
check "a hook that changes another line of it (HELPER_BUILD_VERSION): the commit is undone" \
  '[ $RC = 1 ] && has "изменил релизный коммит" && [ "$(g rev-parse HEAD)" = "$head" ] && xcconfig_is 0.1.0 1 && clean'
new_case hookfail
hook 'exit 1'
head=$(g rev-parse HEAD)
mr '' 0.2.0 --yes
check "a failing hook: no commit, Config/Shared.xcconfig is back" \
  '[ $RC = 1 ] && has "Ошибка: git commit не удался, Config/Shared.xcconfig возвращён." && [ "$(g rev-parse HEAD)" = "$head" ] && xcconfig_is 0.1.0 1 && clean'
new_case hookok
hook "git add $XC"
before=$(count)
mr '' 0.2.0 --yes
check "a hook that stages only Config/Shared.xcconfig (a formatter) keeps the release commit" \
  '[ $RC = 0 ] && [ "$(count)" = $((before + 1)) ] && release_commit 0.1.0 1 0.2.0 2 && clean'

# --- no push, ever
new_case nopush
origin=$(origin_ref master) tags=$(all_tags)
mr '\nд\n'
check "the commit stays local: no push question, origin and tags untouched" \
  '[ $RC = 0 ] && release_commit 0.1.0 1 0.1.1 2 && [ "$(origin_ref master)" = "$origin" ] && [ "$(all_tags)" = "$tags" ] && ! has "Запуш"'
mr '' 0.3.0 --push
check "--push is not an option" '[ $RC = 2 ] && has "неизвестный параметр --push"'

# --- the confirmation, --no-commit, options
new_case decline
before=$(count)
mr '0.2.0\nнет\n'
check "a declined commit puts Config/Shared.xcconfig back" \
  '[ $RC = 1 ] && has "Отменено: Config/Shared.xcconfig возвращён, коммита нет." && xcconfig_is 0.1.0 1 && [ "$(count)" = "$before" ] && clean'
mr '0.2.0\n'
check "end of input at the confirmation puts Config/Shared.xcconfig back" \
  '[ $RC = 1 ] && has "Ошибка: ввод прерван, Config/Shared.xcconfig возвращён." && xcconfig_is 0.1.0 1 && [ "$(count)" = "$before" ] && clean'
mr '0.2.0\nда\n'
check "'да' confirms" '[ $RC = 0 ] && release_commit 0.1.0 1 0.2.0 2 && clean'
new_case nocommit
before=$(count)
mr '\n' --no-commit
check "--no-commit at the prompt: Enter writes 0.1.1 and build 2, no confirmation" \
  '[ $RC = 0 ] && xcconfig_is 0.1.1 2 && ! has "Закоммитить" && [ "$(count)" = "$before" ]'
g checkout -q -- "$XC"
mr '' --bogus
check "an unknown option is a usage error" \
  '[ $RC = 2 ] && has "Ошибка: неизвестный параметр --bogus" && has "scripts/make-release.sh [X.Y.Z|patch|minor|major] [--yes] [--no-commit]"'
mr '' 0.2.0 0.3.0
check "two versions are a usage error" '[ $RC = 2 ] && has "версия указана дважды: 0.2.0 и 0.3.0" && xcconfig_is 0.1.0 1'
mr '' --help
check "--help prints the usage" \
  '[ $RC = 0 ] && has "scripts/make-release.sh [X.Y.Z|patch|minor|major] [--yes] [--no-commit]" && has "Готовит релиз Thermik" && ! has "Текущая версия"'
mr '' -h
check "-h prints the usage" '[ $RC = 0 ] && has "--no-commit   только записать версию в Config/Shared.xcconfig, без коммита"'
check "...options change nothing" 'xcconfig_is 0.1.0 1 && [ "$(count)" = "$before" ] && clean'
mr '' 0.2.0 --no-commit
check "--no-commit writes Config/Shared.xcconfig and commits nothing" \
  '[ $RC = 0 ] && xcconfig_is 0.2.0 2 && [ "$(count)" = "$before" ] && [ "$(g status --porcelain)" = " M Config/Shared.xcconfig" ]'
check "...the change is the version line and the build line only" \
  '[ "$(g diff --numstat)" = "$(printf "2\t2\t%s" "$XC")" ] && [ "$(g diff -U0 | grep "^[-+][^-+]")" = "$(lines 0.1.0 1 0.2.0 2)" ]'
check "...shows the diff, what it wrote and the commit command" \
  '[ "$(shown_diff)" = "$(lines 0.1.0 1 0.2.0 2)" ] && has "Config/Shared.xcconfig: версия 0.2.0, сборка 2. Коммит не создан (--no-commit). Закоммитьте только этот файл:" && has "  git commit -m '\''feat: release - version 0.2.0'\'' -- Config/Shared.xcconfig"'
g commit -q -m 'feat: release - version 0.2.0' -- "$XC"
check "...and that command makes the release commit" 'release_commit 0.1.0 1 0.2.0 2 && clean'

# --- branches
new_case branch
g checkout -q -b feature
origin=$(origin_ref master)
mr '' 0.2.0 --yes
check "another branch: a warning, then the commit on that branch" \
  '[ $RC = 0 ] && has "Внимание: вы на ветке feature, а релиз выходит из ветки по умолчанию master: этот коммит выпустится только после слияния в master." && [ "$(g symbolic-ref --short HEAD)" = feature ] && release_commit 0.1.0 1 0.2.0 2 && [ "$(origin_ref master)" = "$origin" ]'
new_case detached
g checkout -q --detach
mr '' 0.2.0 --yes
check "a detached HEAD is refused" \
  '[ $RC = 1 ] && has "Ошибка: HEAD не на ветке (detached HEAD): переключитесь на ветку, например: git switch master." && xcconfig_is 0.1.0 1 && clean'
new_case behind
git clone -q "$CASE/origin.git" "$CASE/other"
echo other >>"$CASE/other/README"
git -C "$CASE/other" commit -q -am 'Fix other'
git -C "$CASE/other" push -q origin master
g fetch -q origin
origin=$(origin_ref master)
mr '' 0.2.0 --yes
check "a branch behind origin: a warning to pull first, the commit is still made locally" \
  '[ $RC = 0 ] && has "Внимание: ветка master отстаёт от origin/master на 1 коммит(ов) (по последнему fetch): сначала git pull." && [ "$(origin_ref master)" = "$origin" ] && release_commit 0.1.0 1 0.2.0 2'

# --- no origin, no master or main
new_case noorigin
g remote remove origin
before=$(count)
mr '' --yes
check "without origin: local tags count, the commit is made" \
  '[ $RC = 0 ] && ! has "Внимание" && has "Последний релизный тег: 0.1.0" && release_commit 0.1.0 1 0.1.1 2 && [ "$(count)" = $((before + 1)) ]'
g branch -q -m master dev
mr '' --yes
check "neither origin nor master/main: a warning, the commit is made with the next build number" \
  '[ $RC = 0 ] && has "Внимание: не удалось определить ветку по умолчанию; релиз выходит только из master." && has "Новая версия: 0.1.2 (сборка 3)" && release_commit 0.1.1 2 0.1.2 3'

# --- every number has up to 9 digits: the next minor version of 0.999999999.0, 0.1000000000.0, is not X.Y.Z and is
# not offered; Enter takes the patch one
new_case nines
xcconfig 0.999999999.0 5 >"$REPO/$XC"
g commit -q -am 'feat: release - version 0.999999999.0'
before=$(count) head=$(g rev-parse HEAD)
mr '\n\n'
check "prompt: only the bumps that are X.Y.Z are offered, Enter takes the patch one" \
  'has "Следующая: 0.999999999.1 (patch), 1.0.0 (major)." && has "Новая версия [0.999999999.1]: " && ! has "0.1000000000.0" && [ $RC = 0 ] && release_commit 0.999999999.0 5 0.999999999.1 6'
g reset -q --hard "$head"
mr '0.1000000000.0\nminor\n1.0.0\nn\n'
check "prompt: 0.1000000000.0, typed or as minor, is refused" \
  '[ $RC = 1 ] && [ "$(printf "%s\n" "$OUT" | grep -cF "  «0.1000000000.0» — не версия X.Y.Z (три числа до 9 цифр без ведущих нулей, например 0.999999999.1). Введите другую версию.")" = 2 ] && xcconfig_is 0.999999999.0 5 && clean'
mr '' --yes
check "--yes takes 0.999999999.1" '[ $RC = 0 ] && has "Новая версия: 0.999999999.1 (сборка 6)" && release_commit 0.999999999.0 5 0.999999999.1 6'
g reset -q --hard "$head"
mr '' major --yes
check "...while major, 1.0.0, is X.Y.Z and is committed" '[ $RC = 0 ] && release_commit 0.999999999.0 5 1.0.0 6'
g reset -q --hard "$head"
xcconfig 999999999.5.0 7 >"$REPO/$XC"
g commit -q -am 'feat: release - version 999999999.5.0'
mr ''
check "at 999999999.5.0 the major version cannot grow: patch and minor are offered, the patch one suggested" \
  'has "Следующая: 999999999.5.1 (patch), 999999999.6.0 (minor)." && has "Новая версия [999999999.5.1]: " && [ $RC = 1 ]'
mr '' major --yes
check "...major, 1000000000.0.0, is refused" \
  '[ $RC = 1 ] && has "Ошибка: «1000000000.0.0» — не версия X.Y.Z (три числа до 9 цифр без ведущих нулей, например 999999999.5.1)." && xcconfig_is 999999999.5.0 7 && clean'
mr '' 999999999.999999999.999999999 --yes
check "the highest version, 999999999.999999999.999999999, is committed" \
  '[ $RC = 0 ] && release_commit 999999999.5.0 7 999999999.999999999.999999999 8 && clean'
before=$(count)
mr '' --yes
check "at 999999999.999999999.999999999 no bump is a version: refused, nothing changed" \
  '[ $RC = 1 ] && has "Ошибка: после 999999999.999999999.999999999 нет версии X.Y.Z с числами до 9 цифр: дальше выпускать некуда." && xcconfig_is 999999999.999999999.999999999 8 && [ "$(count)" = "$before" ] && clean'
mr '\n\n'
check "...at the prompt too, before it asks" \
  '[ $RC = 1 ] && has "дальше выпускать некуда" && ! has "Новая версия [" && [ "$(count)" = "$before" ] && clean'

# --- at 999999999.999999999.Z neither the minor nor the major version can grow, the patch version still can
new_case ninespatch
xcconfig 999999999.999999999.0 8 >"$REPO/$XC"
g commit -q -am 'feat: release - version 999999999.999999999.0'
before=$(count)
mr '' patch --no-commit
check "at 999999999.999999999.0 patch is 999999999.999999999.1, the one version left" \
  '[ $RC = 0 ] && has "Новая версия: 999999999.999999999.1 (сборка 9)" && xcconfig_is 999999999.999999999.1 9 && [ "$(count)" = "$before" ]'
g checkout -q -- "$XC"
mr '' 999999999.999999999.1 --yes
check "...and 999999999.999999999.1 given as the version is committed" \
  '[ $RC = 0 ] && release_commit 999999999.999999999.0 8 999999999.999999999.1 9 && clean'

# --- the build number: one more with every release, up to 999999999
new_case build
xcconfig 0.1.0 9 >"$REPO/$XC"
g commit -q -am 'Build 9'
mr '' 0.2.0 --yes
check "build 9 becomes 10" \
  '[ $RC = 0 ] && has "Текущая версия:         0.1.0 (Config/Shared.xcconfig, сборка 9)" && has "Новая версия: 0.2.0 (сборка 10)" && has "feat: release - version 0.2.0 (сборка 10)" && release_commit 0.1.0 9 0.2.0 10 && clean'
xcconfig 0.2.0 999999998 >"$REPO/$XC"
g commit -q -am 'Build 999999998'
mr '' 0.3.0 --yes
check "build 999999998 becomes 999999999, the last one of 9 digits" \
  '[ $RC = 0 ] && release_commit 0.2.0 999999998 0.3.0 999999999 && clean'
before=$(count)
mr '' 0.4.0 --yes
check "build 999999999 cannot grow: refused, nothing changed" \
  '[ $RC = 1 ] && has "Ошибка: номер сборки 999999999 больше не поднять: в нём уже 9 цифр." && xcconfig_is 0.3.0 999999999 && [ "$(count)" = "$before" ] && clean'
mr '\n\n'
check "...at the prompt too, before it asks" \
  '[ $RC = 1 ] && has "больше не поднять" && ! has "Новая версия [" && xcconfig_is 0.3.0 999999999 && [ "$(count)" = "$before" ]'

# --- origin's tags cannot be read and the clone has none: no claims about tags
new_case notags-offline
g tag -d 0.1.0 >/dev/null
g remote set-url origin "$CASE/missing.git"
mr '0.2.0\n' --no-commit
check "unreadable origin and no local tags: a warning, no claims about tags or an unreleased version" \
  '[ $RC = 0 ] && has "не удалось прочитать теги origin" && has "Релизные теги неизвестны: локальных нет, а origin не прочитан." && ! has "Релизных тегов пока нет" && ! has "ещё нет"'
g checkout -q -- .
g tag 0.1.0 HEAD~1
mr '0.2.0\n' --no-commit
check "unreadable origin with local tags: the last local tag, marked as such" \
  '[ $RC = 0 ] && has "Последний релизный тег: 0.1.0 (из локальных тегов)" && ! has "ещё нет"'

# --- the version line and the build line
new_case ahead
xcconfig 0.3.0 4 >"$REPO/$XC"
g commit -q -am 'feat: release - version 0.3.0'
mr ''
check "a version above every tag: says it is not released yet and suggests the next patch version" \
  'has "Текущая версия:         0.3.0 (Config/Shared.xcconfig, сборка 4)" && has "Тега 0.3.0 ещё нет" && has "Новая версия [0.3.1]: "'
for c in 'x|«x»' '0.1000000000.0|«0.1000000000.0»' '1.2|«1.2»' 'v0.3.0|«v0.3.0»' '|«»'; do
  xcconfig "${c%|*}" 4 >"$REPO/$XC"
  g commit -q -am "Broken version ${c%|*}"
  mr '' --yes 0.4.0
  check "MARKETING_VERSION '${c%|*}' is refused" \
    '[ $RC = 1 ] && has "Ошибка: в Config/Shared.xcconfig MARKETING_VERSION = ${c#*|}, а не X.Y.Z (без ведущих нулей и «v», числа до 9 цифр): исправьте файл вручную и закоммитьте." && xcconfig_is "${c%|*}" 4 && clean'
done
xcconfig 0.3.0 4 | sed '/^MARKETING_VERSION/d' >"$REPO/$XC"
g commit -q -am 'No version line'
cp "$REPO/$XC" "$WORK/before"
mr '' --yes 0.4.0
check "Config/Shared.xcconfig without a version line is refused" \
  '[ $RC = 1 ] && has "Ошибка: в Config/Shared.xcconfig должна быть ровно одна строка MARKETING_VERSION = X.Y.Z: исправьте файл вручную и закоммитьте." && cmp -s "$REPO/$XC" "$WORK/before" && clean'
{
  xcconfig 0.3.0 4
  echo 'MARKETING_VERSION = 0.3.0'
} >"$REPO/$XC"
g commit -q -am 'Two version lines'
cp "$REPO/$XC" "$WORK/before"
mr '' --yes 0.4.0
check "Config/Shared.xcconfig with two version lines is refused, even with one value" \
  '[ $RC = 1 ] && has "должна быть ровно одна строка MARKETING_VERSION = X.Y.Z" && cmp -s "$REPO/$XC" "$WORK/before" && clean'
for c in '0|«0»' '01|«01»' '1.5|«1.5»' 'x|«x»' '-1|«-1»' '1234567890|«1234567890»' '|«»'; do
  xcconfig 0.3.0 "${c%|*}" >"$REPO/$XC"
  g commit -q -am "Broken build ${c%|*}"
  mr '' --yes 0.4.0
  check "CURRENT_PROJECT_VERSION '${c%|*}' is refused" \
    '[ $RC = 1 ] && has "Ошибка: в Config/Shared.xcconfig CURRENT_PROJECT_VERSION = ${c#*|}, а не номер сборки (целое число от 1, до 9 цифр, без ведущих нулей): исправьте файл вручную и закоммитьте." && xcconfig_is 0.3.0 "${c%|*}" && clean'
done
xcconfig 0.3.0 4 | sed '/^CURRENT_PROJECT_VERSION/d' >"$REPO/$XC"
g commit -q -am 'No build line'
cp "$REPO/$XC" "$WORK/before"
mr '' --yes 0.4.0
check "Config/Shared.xcconfig without a build line is refused" \
  '[ $RC = 1 ] && has "Ошибка: в Config/Shared.xcconfig должна быть ровно одна строка CURRENT_PROJECT_VERSION = N: исправьте файл вручную и закоммитьте." && cmp -s "$REPO/$XC" "$WORK/before" && clean'
for b in 4 5; do
  {
    xcconfig 0.3.0 4
    echo "CURRENT_PROJECT_VERSION = $b"
  } >"$REPO/$XC"
  g commit -q -am "Two build lines, 4 and $b"
  cp "$REPO/$XC" "$WORK/before"
  mr '' --yes 0.4.0
  check "Config/Shared.xcconfig with two build lines (4 and $b) is refused" \
    '[ $RC = 1 ] && has "должна быть ровно одна строка CURRENT_PROJECT_VERSION = N" && cmp -s "$REPO/$XC" "$WORK/before" && clean'
done

# --- the rest of each line stays as it is: other blanks around the values; commented-out lines do not count
new_case blanks
blanks 0.1.0 1 >"$REPO/$XC"
g commit -q -am 'Other blanks'
mr '' 0.2.0 --yes
check "other blanks around the = and the values stay, only the values change" \
  '[ $RC = 0 ] && has "Текущая версия:         0.1.0 (Config/Shared.xcconfig, сборка 1)" && release_commit 0.1.0 1 0.2.0 2 blanks && xcconfig_is 0.2.0 2 blanks && clean'
new_case commented
commented 0.1.0 1 >"$REPO/$XC"
g commit -q -am 'Commented-out lines'
mr '' 0.2.0 --yes
check "commented-out version and build lines are neither counted nor changed" \
  '[ $RC = 0 ] && release_commit 0.1.0 1 0.2.0 2 commented && clean'

# --- no repository, no commits, Config/Shared.xcconfig not in git
REPO="$WORK/plain"
mkdir -p "$REPO/scripts/lib" "$REPO/Config"
cp "$TREE/scripts/make-release.sh" "$REPO/scripts/"
cp "$TREE/scripts/lib/version.sh" "$REPO/scripts/lib/"
xcconfig 0.1.0 1 >"$REPO/$XC"
mr '' 0.2.0 --yes
check "outside a git repository it is refused" \
  '[ $RC = 1 ] && has "Ошибка: $REPO — не git-репозиторий. Сначала git init, первый коммит и git remote add origin <url>." && xcconfig_is 0.1.0 1'
mr '' --help
check "...--help works there too" '[ $RC = 0 ] && has "scripts/make-release.sh [X.Y.Z|patch|minor|major]"'
git -c init.defaultBranch=master init -q "$REPO"
mr '' 0.2.0 --yes
check "a repository without commits is refused" \
  '[ $RC = 1 ] && has "Ошибка: в репозитории ещё нет коммитов: сначала закоммитьте проект." && xcconfig_is 0.1.0 1'
g add scripts
g commit -q -m scripts
mr '' 0.2.0 --yes
check "a Config/Shared.xcconfig that is not in git is refused" \
  '[ $RC = 1 ] && has "Ошибка: Config/Shared.xcconfig не в git: закоммитьте его." && xcconfig_is 0.1.0 1 && [ "$(count)" = 1 ]'

REPO="$WORK/outer/sub"
mkdir -p "$REPO/scripts/lib" "$REPO/Config"
cp "$TREE/scripts/make-release.sh" "$REPO/scripts/"
cp "$TREE/scripts/lib/version.sh" "$REPO/scripts/lib/"
xcconfig 0.1.0 1 >"$REPO/$XC"
git -c init.defaultBranch=master init -q "$WORK/outer"
git -C "$WORK/outer" add -A
git -C "$WORK/outer" commit -q -m init
mr '' 0.2.0 --yes
check "a script in a subdirectory of a repository is refused" \
  '[ $RC = 1 ] && has "Ошибка: $REPO — не корень git-репозитория (корень: $WORK/outer)." && xcconfig_is 0.1.0 1 && [ "$(git -C "$WORK/outer" rev-list --count HEAD)" = 1 ]'

echo "# $pass passed, $fail failed"
[ "$fail" = 0 ]

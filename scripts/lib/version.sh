# shellcheck shell=bash
# Release versions and release files, shared by scripts/make-release.sh, scripts/build-release.sh,
# .github/scripts/*.sh, .github/actions/xcode and the workflows in .github/workflows/ (sourced, not run).
#
# A version is X.Y.Z: three decimal numbers of up to 9 digits without leading zeros (0 itself is fine). It lives in
# Config/Shared.xcconfig as the line `MARKETING_VERSION = X.Y.Z` (CFBundleShortVersionString of the app and its
# helper), next to the build number, the line `CURRENT_PROJECT_VERSION = N` (the app's CFBundleVersion: a positive
# number of up to 9 digits), which scripts/make-release.sh raises by one with every new version. The version is also
# the release's tag (no "v") and part of the release file names. Tags vX.Y.Z count as version X.Y.Z.
# bash 3.2 (macOS) and 5 (Linux), BSD or GNU tools; no sort -V, which BSD sort lacks.

VERSION_RE='^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$'
BUILD_RE='^[1-9][0-9]{0,8}$'

# The file with the version and the build number, relative to the repository root
VERSION_FILE=Config/Shared.xcconfig
# Their lines, awk regexes (no character classes: mawk, Ubuntu's awk, may lack them); every function below accepts
# exactly one line of each
VERSION_LINE_RE='^[ \t]*MARKETING_VERSION[ \t]*='
BUILD_LINE_RE='^[ \t]*CURRENT_PROJECT_VERSION[ \t]*='

# The architectures of every release binary (scripts/build-release.sh checks them): the Release configuration builds
# a universal app
# shellcheck disable=SC2034 # used by the scripts that source this file
RELEASE_ARCHS="arm64 x86_64"

# version_valid <s>: whether s is X.Y.Z
version_valid() {
  [[ $1 =~ $VERSION_RE ]]
}

# build_valid <s>: whether s is a build number
build_valid() {
  [[ $1 =~ $BUILD_RE ]]
}

# version_cmp <a> <b>: prints -1, 0 or 1 for a < b, a = b, a > b (both valid). Numbers of any length: without
# leading zeros the longer number is the larger one, and numbers of one length compare as strings.
version_cmp() {
  local a="$1." b="$2." x y
  while [ -n "$a" ]; do
    x=${a%%.*} y=${b%%.*}
    a=${a#*.} b=${b#*.}
    [ "$x" = "$y" ] && continue
    if [ ${#x} -gt ${#y} ] || { [ ${#x} -eq ${#y} ] && [[ $x > $y ]]; }; then
      echo 1
    else
      echo -1
    fi
    return 0
  done
  echo 0
}

# version_gt <a> <b>: whether a > b
version_gt() {
  [ "$(version_cmp "$1" "$2")" = 1 ]
}

# version_bump <X.Y.Z> <patch|minor|major>: prints X.Y.(Z+1), X.(Y+1).0 or (X+1).0.0, which is not a version when
# the number it raises already has 9 nines
version_bump() {
  local x y z
  x=${1%%.*} z=${1##*.} y=${1#*.}
  y=${y%.*}
  case $2 in
  patch) echo "$x.$y.$((z + 1))" ;;
  minor) echo "$x.$((y + 1)).0" ;;
  major) echo "$((x + 1)).0.0" ;;
  *) return 1 ;;
  esac
}

# xcconfig_value <line re>: reads an xcconfig on stdin and prints the value of its one line that matches <line re>,
# the rest of the line after the "=" without the blanks around it; fails, printing nothing, unless exactly one line
# matches. The value is not checked.
xcconfig_value() {
  awk -v re="$1" '
    $0 ~ re { n++; v = $0; sub(/^[^=]*=[ \t]*/, "", v); sub(/[ \t]+$/, "", v) }
    END { if (n != 1) exit 1; print v }'
}

# app_version_parse, app_build_parse: read Config/Shared.xcconfig on stdin and print the version, the build number
app_version_parse() {
  xcconfig_value "$VERSION_LINE_RE"
}
app_build_parse() {
  xcconfig_value "$BUILD_LINE_RE"
}

# app_version_get <root>, app_build_get <root>: the version, the build number in <root>/Config/Shared.xcconfig
app_version_get() {
  app_version_parse <"$1/$VERSION_FILE"
}
app_build_get() {
  app_build_parse <"$1/$VERSION_FILE"
}

# app_version_set <root> <X.Y.Z> <build>: writes the version and the build number into their lines of
# <root>/Config/Shared.xcconfig, in place (the file keeps its inode and mode); only the values change, the rest of
# each line stays as it is, and so does a last line without a newline. Fails, changing nothing, unless both values
# are valid and the file has exactly one line of each.
app_version_set() {
  local file="$1/$VERSION_FILE" tmp eol=1
  version_valid "$2" && build_valid "$3" || return 1
  app_version_parse <"$file" >/dev/null && app_build_parse <"$file" >/dev/null || return 1
  # $(...) drops a final newline: anything left means the last line has none
  [ -z "$(tail -c 1 "$file")" ] || eol=0
  tmp="$(mktemp "${TMPDIR:-/tmp}/app-version.XXXXXX")" || return 1
  if awk -v vre="$VERSION_LINE_RE" -v bre="$BUILD_LINE_RE" -v v="$2" -v b="$3" -v eol="$eol" '
    # the line with its value replaced: what comes before the value, up to the blanks after the "=", and the blanks
    # after the value stay
    function with_value(line, value,   head, tail) {
      match(line, /[ \t]*$/)
      tail = substr(line, RSTART)
      head = substr(line, 1, RSTART - 1)
      match(head, /=[ \t]*/)
      return substr(head, 1, RSTART + RLENGTH - 1) value tail
    }
    $0 ~ vre { $0 = with_value($0, v) }
    $0 ~ bre { $0 = with_value($0, b) }
    # every line as it was read, the last one with a newline only if it had one
    NR > 1 { print prev }
    { prev = $0 }
    END { printf "%s%s", prev, (eol ? "\n" : "") }' "$file" >"$tmp" && cat "$tmp" >"$file"; then
    rm -f "$tmp"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# release_assets <X.Y.Z>: prints the names of the files release X.Y.Z publishes, one per line, in upload order: the
# app (universal, zipped), its debug symbols (the dSYMs of the app and the helper, zipped), SHA256SUMS over the others
release_assets() {
  echo "Thermik-$1.zip"
  echo "Thermik-$1-dSYMs.zip"
  echo SHA256SUMS
}

# release_tags: reads tag names, or the lines of `git ls-remote --tags` (refs/tags/<tag>, <tag>^{}), on stdin
# and prints "<X.Y.Z> <tag>" for every release tag (X.Y.Z or vX.Y.Z), once per tag
release_tags() {
  local line ref v seen=' '
  while IFS= read -r line || [ -n "$line" ]; do
    ref=${line##*[[:space:]]}
    ref=${ref#refs/tags/}
    ref=${ref%'^{}'}
    v=${ref#v}
    version_valid "$v" || continue
    case $seen in *" $ref "*) continue ;; esac
    seen="$seen$ref "
    echo "$v $ref"
  done
}

# highest_tag [skip]: reads what release_tags reads and prints "<X.Y.Z> <tag>" of the highest release tag other
# than the tag named skip; nothing when there is none
highest_tag() {
  local skip="${1:-}" v t best='' best_tag=''
  while read -r v t; do
    [ "$t" = "$skip" ] && continue
    if [ -z "$best" ] || version_gt "$v" "$best"; then
      best=$v best_tag=$t
    fi
  done < <(release_tags)
  [ -z "$best" ] || echo "$best $best_tag"
}

# tag_of_version <X.Y.Z>: reads what release_tags reads and prints the first tag of that version (X.Y.Z or
# vX.Y.Z); nothing when there is none. It reads release_tags to the end: a reader that stops early leaves
# release_tags writing into a closed pipe, which is "echo: write error: Broken pipe" where SIGPIPE is ignored (the
# GitHub runner)
tag_of_version() {
  local v t found=''
  while read -r v t; do
    if [ -z "$found" ] && [ "$v" = "$1" ]; then
      found=$t
    fi
  done < <(release_tags)
  [ -z "$found" ] || echo "$found"
}

# tag_commit <tag>: reads the lines of `git ls-remote --tags <remote>` (every tag: given a pattern, ls-remote leaves
# out an annotated tag's peeled line) on stdin and prints the commit refs/tags/<tag> is on: the peeled "<tag>^{}"
# line of an annotated tag, else the tag's own line; nothing when there is no such tag
tag_commit() {
  awk -v ref="refs/tags/$1" '
    $2 == ref { sha = $1 }
    $2 == ref "^{}" { peeled = $1 }
    END { if (peeled != "") print peeled; else if (sha != "") print sha }'
}

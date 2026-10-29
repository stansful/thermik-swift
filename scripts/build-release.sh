#!/usr/bin/env bash
# Builds the release files of the version in Config/Shared.xcconfig exactly as GitHub does (.github/workflows/ci.yml
# runs this script, and release.yml publishes what it built): the Release build of scripts/lib/build.sh (a universal
# Thermik.app with its helper, signed as the project config says: ad-hoc unless Config/Signing.local.xcconfig gives a
# Team ID, which GitHub never has) zipped and on a disk image (Thermik.app next to a link to /Applications), and the
# SHA-256 sums of both. The list is release_assets in scripts/lib/version.sh:
#   Thermik-X.Y.Z.zip  Thermik-X.Y.Z.dmg  Thermik-X.Y.Z.sha256
# The build starts from empty products (build/DerivedData/Build/Products/Release), as on GitHub. Fails unless the app
# carries the version and the build number of Config/Shared.xcconfig, the app and the helper have every architecture
# of RELEASE_ARCHS, and the app passes codesign --verify --deep --strict, also as unzipped from Thermik-X.Y.Z.zip and
# as on the mounted Thermik-X.Y.Z.dmg. Prints the version, the signature, the files with their sizes and the sums.
#
#   scripts/build-release.sh [--test] [--out DIR]
#
#   --test     first the thermik-probe self-checks (scripts/lib/selftest.sh)
#   --out DIR  also copy the release files to DIR (they are always in build/release)
#
# bash 3.2 (macOS). Needs what scripts/lib/build.sh needs (Xcode 27.1 or later, XcodeGen, python3), and ditto,
# codesign, lipo, plutil, hdiutil and diskutil, which macOS has. Messages are in Russian.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=scripts/lib/version.sh
. "$ROOT_DIR/scripts/lib/version.sh"

usage() {
  cat <<'EOF'
Собирает файлы релиза версии из Config/Shared.xcconfig так же, как GitHub Actions (ci.yml запускает этот скрипт,
а release.yml публикует собранное): универсальное приложение из Release-сборки scripts/lib/build.sh в архиве
Thermik-X.Y.Z.zip и на образе диска Thermik-X.Y.Z.dmg (со ссылкой на «Программы») и их контрольные суммы
Thermik-X.Y.Z.sha256.

  scripts/build-release.sh [--test] [--out DIR]

  --test     сначала самопроверки thermik-probe (scripts/lib/selftest.sh)
  --out DIR  ещё и скопировать файлы релиза в DIR (они всегда лежат в build/release)
  -h, --help эта справка

Подпись — как в настройках проекта: ad-hoc, как в релизах GitHub, а с Config/Signing.local.xcconfig — вашим Team ID.
Нужны Xcode 27.1 или новее, XcodeGen (brew install xcodegen) и python3.
EOF
}
say() { printf '%s\n' "$*"; }
die() {
  printf 'Ошибка: %s\n' "$*" >&2
  exit 1
}
usage_error() {
  printf 'Ошибка: %s\n\n' "$*" >&2
  usage >&2
  exit 2
}
sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$@"
  else
    shasum -a 256 "$@"
  fi
}
# plist_value <plist> <key>: the value of a top-level key; nothing when there is none
plist_value() {
  plutil -extract "$2" raw -o - "$1" 2>/dev/null || true
}
# quiet <command...>: runs it with its output in a log of the temp dir, shown only when it fails
quiet() {
  "$@" >"$work/tool.log" 2>&1 || {
    cat "$work/tool.log" >&2
    return 1
  }
}

run_tests='' out=''
while [ $# -gt 0 ]; do
  case $1 in
  -h | --help)
    usage
    exit 0
    ;;
  --test) run_tests=1 ;;
  --out)
    [ $# -ge 2 ] && [ -n "$2" ] || usage_error "--out: укажите каталог"
    out=$2
    shift
    ;;
  --out=?*) out=${1#--out=} ;;
  *) usage_error "неизвестный параметр $1" ;;
  esac
  shift
done

version="$(app_version_get "$ROOT_DIR")" ||
  die "в $VERSION_FILE должна быть ровно одна строка MARKETING_VERSION = X.Y.Z."
version_valid "$version" ||
  die "в $VERSION_FILE MARKETING_VERSION = «${version}», а не X.Y.Z (без ведущих нулей и «v», числа до 9 цифр)."
build="$(app_build_get "$ROOT_DIR")" ||
  die "в $VERSION_FILE должна быть ровно одна строка CURRENT_PROJECT_VERSION = N."
build_valid "$build" ||
  die "в $VERSION_FILE CURRENT_PROJECT_VERSION = «${build}», а не номер сборки (целое число от 1, до 9 цифр, без ведущих нулей)."
assets="$(release_assets "$version" | tr '\n' ' ')"
sums="Thermik-$version.sha256"
built="${assets% "$sums" }"
app_zip="Thermik-$version.zip"
dmg="Thermik-$version.dmg"

if [[ -n "$run_tests" ]]; then
  say "== Самопроверки: scripts/lib/selftest.sh"
  "$ROOT_DIR/scripts/lib/selftest.sh" || die "самопроверки thermik-probe не прошли."
fi

products="$ROOT_DIR/build/DerivedData/Build/Products/Release"
# Empty products, as on GitHub: every binary is linked anew, and nothing of an earlier build ends up in the app
rm -rf "$products"
say "== Сборка $version (сборка $build): scripts/lib/build.sh Release"
"$ROOT_DIR/scripts/lib/build.sh" Release || die "scripts/lib/build.sh Release не прошёл."

app="$products/Thermik.app"
exe="$app/Contents/MacOS/Thermik"
helper="$app/Contents/MacOS/thermik-helper"
[[ -f "$exe" && -f "$helper" ]] || die "сборка прошла, но в $app нет Contents/MacOS/Thermik и thermik-helper."

# --- the app: version and build number, architectures, signature
info="$app/Contents/Info.plist"
v="$(plist_value "$info" CFBundleShortVersionString)" b="$(plist_value "$info" CFBundleVersion)"
[[ "$v" == "$version" && "$b" == "$build" ]] ||
  die "у собранного приложения версия «${v}» и сборка «${b}», а в $VERSION_FILE — $version и $build: MARKETING_VERSION или CURRENT_PROJECT_VERSION переопределены (project.yml, Config/*.xcconfig)?"
for bin in "$exe" "$helper"; do
  archs="$(lipo -archs "$bin")" || die "lipo не прочитал архитектуры ${bin#"$app"/}."
  for arch in $RELEASE_ARCHS; do
    case " $archs " in
    *" $arch "*) ;;
    *) die "в ${bin#"$app"/} нет архитектуры $arch (есть: $archs), а релиз — универсальная сборка ($RELEASE_ARCHS)." ;;
    esac
  done
done
codesign --verify --deep --strict "$app" || die "codesign не принял подпись $app."
sig="$(codesign -dvv "$app" 2>&1)" || die "codesign не прочитал подпись $app."
if grep -qx 'Signature=adhoc' <<<"$sig"; then
  signing="ad-hoc, без нотаризации (как в релизах GitHub)"
else
  authority="$(sed -n 's/^Authority=//p' <<<"$sig")" team="$(sed -n 's/^TeamIdentifier=//p' <<<"$sig")"
  signing="${authority%%$'\n'*} (Team ID ${team:-?}); релизы GitHub подписаны ad-hoc"
fi

# --- the release files
release_dir="$ROOT_DIR/build/release"
rm -rf "$release_dir"
mkdir -p "$release_dir"
work="$(mktemp -d "${TMPDIR:-/tmp}/thermik-release.XXXXXX")"
# The disk image is mounted only while it is checked below. On exit an image still mounted is detached (forced when
# that fails); one that stays mounted keeps the temp dir, which rm -rf would only walk into
mounted=''
cleanup() {
  if [[ -n "$mounted" ]]; then
    dmg_detach "$mounted" >/dev/null 2>&1 || dmg_detach "$mounted" force >/dev/null 2>&1 || true
    if [[ -n "$(ls -A "$mounted" 2>/dev/null)" ]]; then
      printf 'Образ диска остался подключён к %s: отключите его и удалите %s.\n' "$mounted" "$work" >&2
      return
    fi
  fi
  rm -rf "$work"
}
trap cleanup EXIT

# dmg_create <volume name> <folder> <image>, dmg_attach <image> <mount point>, dmg_detach <mount point> [force]:
# macOS 27 deprecates hdiutil's create, attach and detach for diskutil's `image create from`, `image attach` and
# `eject`; an older macOS has no `diskutil image` and keeps hdiutil
if diskutil image create from --help >/dev/null 2>&1; then
  dmg_create() { diskutil image create from --format UDZO --volumeName "$1" "$2" "$3"; }
  dmg_attach() { diskutil image attach --readOnly --nobrowse --mountPoint "$2" "$1"; }
  dmg_detach() { diskutil eject ${2:+force} "$1"; }
else
  dmg_create() { hdiutil create -volname "$1" -srcfolder "$2" -fs APFS -format UDZO -ov "$3"; }
  dmg_attach() { hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$2" "$1"; }
  dmg_detach() { hdiutil detach ${2:+-force} "$1"; }
fi

say "== Архив и образ диска: $app_zip, $dmg"
# --norsrc: no AppleDouble files or extended attributes in the archive or on the image, only the bundle (the
# signature seals the bundle's files, never their attributes)
ditto -c -k --norsrc --keepParent "$app" "$release_dir/$app_zip"
# The image holds Thermik.app next to a link to /Applications to drag it onto
mkdir "$work/dmg"
ditto --norsrc "$app" "$work/dmg/Thermik.app"
ln -s /Applications "$work/dmg/Applications"
quiet dmg_create "Thermik $version" "$work/dmg" "$release_dir/$dmg" || die "не удалось создать $dmg."
quiet hdiutil verify "$release_dir/$dmg" || die "hdiutil verify не принял $dmg."

# The app as a user gets it: Thermik.app alone at the top of the archive, its signature intact, the same version
mkdir "$work/unzipped"
ditto -x -k "$release_dir/$app_zip" "$work/unzipped"
# shellcheck disable=SC2012 # plain file names
top="$(ls -A "$work/unzipped" | tr '\n' ' ')"
[[ "$top" == "Thermik.app " ]] || die "в $app_zip наверху «${top}», а должно быть только Thermik.app."
codesign --verify --deep --strict "$work/unzipped/Thermik.app" ||
  die "Thermik.app из $app_zip не проходит codesign --verify --deep --strict."
[[ "$(plist_value "$work/unzipped/Thermik.app/Contents/Info.plist" CFBundleShortVersionString)" == "$version" ]] ||
  die "у Thermik.app из $app_zip не версия $version."

# And as a user opens the image: Thermik.app and the link to /Applications (the volume's hidden files aside), the
# app's signature intact, the same version
mkdir "$work/mnt"
mounted="$work/mnt"
quiet dmg_attach "$release_dir/$dmg" "$work/mnt" || die "не удалось подключить $dmg."
# shellcheck disable=SC2012 # plain file names
top="$(ls "$work/mnt" | LC_ALL=C sort | tr '\n' ' ')"
[[ "$top" == "Applications Thermik.app " ]] ||
  die "на $dmg наверху «${top}», а должны быть только Thermik.app и ссылка Applications."
[[ -L "$work/mnt/Applications" && "$(readlink "$work/mnt/Applications")" == /Applications ]] ||
  die "Applications на $dmg — не ссылка на /Applications."
codesign --verify --deep --strict "$work/mnt/Thermik.app" ||
  die "Thermik.app с $dmg не проходит codesign --verify --deep --strict."
[[ "$(plist_value "$work/mnt/Thermik.app/Contents/Info.plist" CFBundleShortVersionString)" == "$version" ]] ||
  die "у Thermik.app с $dmg не версия $version."
# The volume can stay busy for a moment after the checks (Spotlight, say): four tries, then a forced one
tries=1
until dmg_detach "$work/mnt" >/dev/null 2>&1; do
  if [[ $tries -ge 4 ]]; then
    quiet dmg_detach "$work/mnt" force || die "не удалось отключить $dmg от $work/mnt."
    break
  fi
  tries=$((tries + 1))
  sleep 2
done
mounted=''

# Exactly the files of release_assets: a name in the list that this script does not build fails here
missing=''
for f in $built; do
  [[ -s "$release_dir/$f" ]] || missing="$missing $f"
done
[[ -z "$missing" ]] || die "не собраны:$missing (их требует release_assets в scripts/lib/version.sh)."
# shellcheck disable=SC2086 # $built is a list of plain file names
(cd "$release_dir" && sha256 $built >"$sums.tmp" && mv "$sums.tmp" "$sums")
(cd "$release_dir" && sha256 -c "$sums" >/dev/null) || die "файлы в build/release не совпадают с $sums."
# shellcheck disable=SC2012 # plain file names
listing="$(ls -A "$release_dir" | LC_ALL=C sort | tr '\n' ' ')"
# shellcheck disable=SC2086 # $assets is a list of plain file names
expected="$(printf '%s\n' $assets | LC_ALL=C sort | tr '\n' ' ')"
[[ "$listing" == "$expected" ]] || die "в build/release лежит ${listing% }, а должно быть ровно ${expected% }."

dest=$release_dir
if [[ -n "$out" ]]; then
  mkdir -p "$out"
  out="$(cd "$out" && pwd)"
  # -ef, not the paths as strings: a symlink or another letter case (a case-insensitive volume) is build/release too
  if [[ ! "$out" -ef "$release_dir" ]]; then
    for f in $assets; do
      cp "$release_dir/$f" "$out/$f"
    done
    (cd "$out" && sha256 -c "$sums" >/dev/null) || die "файлы в $out не совпадают с $sums."
    dest=$out
  fi
fi

say
say "Релиз $version (сборка $build): $dest"
for f in $assets; do
  printf '  %9s  %s\n' "$(wc -c <"$dest/$f" | tr -d ' ')" "$f"
done
say
say "Подпись: $signing"
say "Архитектуры: $(lipo -archs "$exe")"
say
say "$sums:"
sed 's/^/  /' "$dest/$sums"
other=''
for path in "$dest"/* "$dest"/.[!.]*; do
  [[ -e "$path" ]] || continue
  case " $assets " in *" ${path##*/} "*) continue ;; esac
  other="$other ${path##*/}"
done
[[ -z "$other" ]] || say "В $dest есть и другие файлы, в релиз они не входят:$other"

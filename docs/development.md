# Thermik — developer guide

This is the technical documentation that used to be the project README. For what Thermik does and how it looks,
see the [README](../README.md) ([по-русски](../README.ru.md)). Links, Shortcuts and hotkeys are in
[automation.md](automation.md).

Thermik is still in development. Its version is `MARKETING_VERSION` in `Config/Shared.xcconfig`; how it changes and
how releases are built is in [Releases and CI](#releases-and-ci).

## Requirements

- macOS 14 Sonoma or later (Liquid Glass on macOS 26 and later). Apple Silicon is the primary target;
  Intel is best effort.
- Xcode 27.1 or later (Swift 6).
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.46.0 or later: `brew install xcodegen`.

## Build

```sh
brew install xcodegen          # once
scripts/lib/build.sh Debug     # l10n merge → xcodegen generate → xcodebuild → codesign check
```

The app is built at `build/DerivedData/Build/Products/Debug/Thermik.app`. `scripts/lib/build.sh Release` builds
the Release configuration (`…/Products/Release/Thermik.app`). Release binaries are optimized for size (`-Osize`, also
for the package's libraries) and stripped; their symbols are in the `.dSYM` bundles next to the app, for crash reports.

`Thermik.xcodeproj` is generated from `project.yml` and is not committed. Never edit it by hand, and do not let
Xcode "upgrade" it. Change `project.yml` and run `xcodegen generate` (or `scripts/lib/build.sh`) instead. Other
generated, git-ignored outputs: `App/Info.plist`, `Helper/Info.plist`, `build/`, `Packages/ThermikCore/.build/`.

## Run

```sh
open build/DerivedData/Build/Products/Debug/Thermik.app --args -ThermikDemo YES   # demo mode
open build/DerivedData/Build/Products/Debug/Thermik.app                           # real sensors (read-only)
```

- **Demo mode** (`-ThermikDemo YES`) uses synthetic M4-Max-like sensors, two synthetic fans, synthetic system
  data and a mock helper. It works on any Mac and never touches the hardware. It is not limited to Debug
  builds, and it survives the in-app relaunch (language change, reset). The generated Xcode scheme already
  carries the argument `-ThermikDemo NO`: change it to `YES` in the scheme editor (Run › Arguments). The next
  `xcodegen generate` (or `scripts/lib/build.sh`) puts it back to `NO`.
- **Real mode** reads the SMC and HID sensors. Reading is unprivileged and read-only. Only the installed root
  helper ever writes to the SMC (fan targets and modes).

Thermik is a menu bar agent: it has no Dock icon until one of its windows is open. It runs as a single
instance: launching another copy (Debug or Release, demo or not) shows the main window of the copy that is
already running and exits. Note that `thermik://` links go to whichever copy Launch Services picks, so with
several builds on disk use `open -a <path/to/Thermik.app> 'thermik://…'`.

## Signing and the privileged helper

Fan control needs a small root helper (`thermik-helper`, embedded in the app). Thermik picks the install mode at
runtime from the app's own code signature:

| Build | How to get it | Helper install mode |
|---|---|---|
| **Ad-hoc** ("Sign to Run Locally", the default) | nothing to do: a fresh clone builds this way, no Apple account needed | **Legacy installer**: one administrator password prompt copies the helper to `/Library/PrivilegedHelperTools/app.thermik.helper` and pins the app's code hash in a root-owned trust file. Every ad-hoc rebuild changes that hash, so the app asks you to re-authorize the helper ("Update Helper…"). |
| **Team ID** (Apple Development / Developer ID) | `cp Config/Signing.local.xcconfig.example Config/Signing.local.xcconfig`, then put your Team ID in it (the file is git-ignored) | **SMAppService**: the app registers the bundled launch daemon; you approve it once in System Settings › General › Login Items & Extensions. |

Both binaries are always built with the hardened runtime (`OTHER_CODE_SIGN_FLAGS` forces `--options=runtime`,
because Xcode 27 drops it for ad-hoc signing). The app is **not** sandboxed: it needs AppleSMC access, and
`Resources/Thermik.entitlements` is an empty dictionary.

By default neither Debug nor Release builds carry the `get-task-allow` entitlement, and the helper refuses any
client that can be debugged. The helper runs as root, so a client that any same-user process could attach a
debugger to must not be able to drive the fans. `scripts/lib/build.sh` ends with a read-only peer self-check: the
built helper prints the exact client requirement it would enforce
(`thermik-helper --peer-requirement <Thermik.app>`), and `codesign --verify -R` checks every slice of the built
app against it. If that check fails, the build fails, because the helper would reject that app at runtime.

Monitoring works without the helper; only fan control needs it. The helper hands the fans back to macOS whenever
Thermik quits, crashes, hangs or loses its connection, and before the Mac sleeps.

The bundle identifiers `app.thermik.Thermik` and `app.thermik.helper` are placeholders for now.

### Helper versioning

`HELPER_BUILD_VERSION` in `Config/Shared.xcconfig` (currently 6) is the helper's bundle version. **Bump it
whenever helper code changes**: when the bundled build differs from the installed one, the app reports that the
helper needs an update and offers "Update Helper…", which reinstalls it (legacy) or re-registers it
(SMAppService).

### Helper scripts and flags

| Command | What it does |
|---|---|
| `sudo scripts/lib/uninstall-helper.sh` | removes a legacy-installed helper; an SMAppService (Team ID) helper is only stopped, so also turn it off in System Settings › General › Login Items & Extensions or use "Uninstall…" in Thermik |
| `sudo scripts/lib/install-helper.sh [Thermik.app]` | fallback legacy install, for when the in-app "Install Helper…" does not work |
| `scripts/lib/install-helper.sh --check [Thermik.app]` | no root: verifies the bundle and prints the install plan and the client requirement |
| `scripts/lib/dev-run-helper.sh [Thermik.app]` | runs the built helper in the foreground with `--mock` (no root, the SMC is never touched) |
| `thermik-helper --mock` | foreground run against `MockFanController` |
| `thermik-helper --peer-requirement <Thermik.app>` | prints the client requirement (used by the build self-check) |

Helper logs: `log stream --predicate 'subsystem == "app.thermik.helper"' --info`.

### Debugging Thermik itself (developer opt-in)

lldb and Xcode can attach only to a `get-task-allow` build, so this needs an explicit opt-in:
`scripts/lib/build.sh Debug --debuggable`, or `THERMIK_DEBUGGABLE = YES` in `Config/Signing.local.xcconfig` for Run
from Xcode. The opt-in works only in Debug. It signs both binaries with `get-task-allow` and builds a helper that
accepts debuggable clients; the helper logs a warning at startup. Install such a helper only for a debugging
session, then reinstall the helper from a normal build.

## Project layout

| Path | Contents |
|---|---|
| `App/` | the app: SwiftUI + AppKit, stores, menu bar, panel, main window pages, settings, runtime (sampling, links, intents, hotkeys) |
| `App/DesignSystem/` | tokens, components, charts, effects (bitmaps drawn on the CPU) |
| `Helper/main.swift` | the root helper's entry point |
| `Packages/ThermikCore/` | local Swift package: all hardware access and engines, plus the `thermik-probe` CLI |
| `Config/` | xcconfigs (versions, signing, hardened runtime) |
| `Resources/` | entitlements, the helper's launchd plist |
| `scripts/` | `make-release.sh` and `build-release.sh` ([Releases and CI](#releases-and-ci)) |
| `scripts/lib/` | build, self-checks, helper install/uninstall, l10n merge, icon renderer, `version.sh` (shared by the release scripts) |
| `scripts/tests/` | tests of the release scripts and the workflows |
| `.github/` | the CI and release workflows and their scripts |

Package products and who links them. Every product is linked **statically**, and `ENABLE_DEBUG_DYLIB = NO`,
because an ad-hoc hardened-runtime binary cannot load another ad-hoc image.

| Product | Linked by | Role |
|---|---|---|
| `ThermikCore` | app | sensors, system data, fan engine, alerts, diagnostics, CSV logging, demo samplers |
| `ThermikSMC` | app + helper | read-only SMC access, fan hardware discovery |
| `ThermikHelperShared` | app + helper | XPC protocol, connection, code identity, legacy installer |
| `ThermikSMCWriter` | **helper only** | SMC writes, fan write sequencer, thermal safety monitor |
| `ThermikHelperCore` | **helper only** | XPC server, control lease, peer validation, recovery |

The app never links `ThermikSMCWriter`: only the helper can write to the SMC.

## Fan control invariants

Keep these in mind when touching fan code:

- **Auto is macOS's alone.** In Auto the fan engine does not run: no curve, no thermal guard and no safety latch
  ever takes a fan from macOS. Every launch starts in Auto unless the user turns on "Restore the last fan mode
  when Thermik starts" (Settings › Fans).
- **Safety.** In Curve, Fixed and Max the app forces every controlled fan to 100 % in one tick when the smoothed
  mean of the four hottest safety sensors reaches 100 °C (or the hottest raw die reading 105 °C), and holds it
  for at least 10 s and until that mean is 6 °C lower. In Fixed, speeds also ramp toward 100 % from 90 °C. The
  helper has an independent backstop at 103 / 108 °C (release below 95 °C) that works even if the app hangs.
  These limits are not user-adjustable.
- **Fan stop.** A curve can stop the fans below its first point (Apple Silicon only; it acts as Minimum on Intel).
  The helper applies 0 rpm only while the die reads below 90 °C, its 1 Hz watchdog restarts the fans at minimum
  at 95 °C or with no reading, and stops them again below 85 °C.
  On M4 Max (macOS 27) the SMC refuses `F%dMd=0` with `0x82` while a fan stands still, so the sequencer hands
  stopped fans back by writing their minimum as the target first (all of them at once) and retrying the mode
  write every 0.5 s for up to 12 s while they spin up (`FanWriteSequencer.releaseMode`); there the SMC accepted
  it 6.1 s and 7.3 s after the new target. Before helper build 6 every restore path left both fans manual at
  0 rpm (found 2026-10-27).
- **The recovery marker means "ours".** While it is on disk every revert is forced, so a helper that restarted
  after a failed restore still hands back the fans it does not own and keeps the marker until that works. The
  app asks the helper (`isControlling`) before it calls such forcing another app.
- **Curves are always linked**: one curve drives every fan, mapped to each fan's own min–max range. Per-fan
  values exist only in Fixed mode. On M3/M4 (`Ftst` hardware) control is all-or-nothing.
- **Never fight another app.** When another app holds the fans, Thermik switches to Auto, disables its mode
  switcher and names the other app.
- The control lease ties the helper to a live app: if the app stops renewing it, the helper returns the fans to
  macOS by itself.

## Sensor catalog

Verified sensor names ship only for Apple M4 Max (`t6041`); an unverified Intel list is bundled too
(`Packages/ThermikCore/Sources/ThermikCore/Resources/SensorDB/`). Every other chip falls back to heuristics, and
the app shows an "Approximate sensor names" note. To add a chip:

- `thermik-probe sensors discover [seconds]` drafts a database from the live SMC/HID keys;
- `thermik-probe sensors resolve <db> KEY,… [--hid P,…]` dry-runs a bundled database against a key list:
  `<db>` is a file name in `SensorDB/` without `.json` (for example `intel`), or `heuristic:<platform>` for the
  heuristics alone, so add a drafted database to `SensorDB/` and rebuild the probe before resolving it.

## Sampling and power use

Thermik reads the sensors every 2 seconds by default (Settings › General › Update interval, 1–60 s) and only the
ones it needs: the headline and safety sensors, pinned sensors, alert subjects, the menu bar sensors, the fan
curve's input, the CSV log's sensor columns and the inspected sensor.

It switches to a 1-second cadence while the menu bar panel is open, while the Overview, Sensors, Fans, Battery
or System page is on screen, while the sensor inspector is open, or while Thermik drives the fans. **Every**
listed sensor is read while the panel, the Overview page or the Sensors page is visible, while the CSV log
records all sensors, and while the menu bar, an enabled alert or the fan curve uses "Hottest sensor" or "All
sensors average"; otherwise the reduced set is read. Sampling pauses while the Mac sleeps.

History stays in memory only and is lost on quit: every reading for 15 minutes, then 10-second
minimum/average/maximum buckets for 24 hours (6 hours for individual sensors that are not pinned).

```sh
log stream --predicate 'subsystem == "app.thermik.Thermik" && category == "sampling"' --level debug
log stream --predicate 'subsystem BEGINSWITH "app.thermik"' --info      # everything, app and helper
```

## Verification

There are no unit tests in v1. Verification means building and running the app (demo mode works on any Mac) and
the `thermik-probe` self-checks, which act as the regression suite and are cited in commit messages.
`scripts/lib/selftest.sh` builds the probe and runs all of them (locally; CI runs no tests):

| Command | Checks | Exit code |
|---|---|---|
| `thermik-probe fans sim` | fan write path and safety rules against an in-memory fake SMC | prints the result, always 0 |
| `thermik-probe helper selftest` | helper safety invariants with a mock fan backend (no root, nothing installed) | 1 on failure |
| `thermik-probe alerts replay` | synthetic 1 Hz series through the default alert rules | 1 on failure |
| `thermik-probe diagnostics selftest` | synthetic frames through every diagnostics rule | 1 on failure |
| `thermik-probe log write <dir>` | writes a sample CSV log into `<dir>` (never into ~/Documents) | 1 on failure, 2 if `<dir>` is in ~/Documents |

## Releases and CI

The version is `MARKETING_VERSION` in `Config/Shared.xcconfig`: X.Y.Z without "v", which is also the release's tag.
`CURRENT_PROJECT_VERSION` next to it is the build number (`CFBundleVersion`), one higher with every version.

- **New version:** `scripts/make-release.sh` shows the current version and the last release tag and asks for the
  new version (Enter takes the next patch one). The new version must be higher than the current one and every release
  tag, local or on `origin`. The script writes it and the next build number into `Config/Shared.xcconfig` and commits
  that file alone as `feat: release - version X.Y.Z`. `X.Y.Z`, `patch`, `minor` or `major` as the argument skips the
  question.
  `--yes` skips both the question (taking the next minor version) and the confirmation; `--no-commit` only writes the
  file. It never pushes and never tags.
- **Publishing:** every push to `master` runs `.github/workflows/release.yml`: the whole CI, and, when the version
  has no release yet, the GitHub release "Thermik X.Y.Z", published as the latest release with the tag `X.Y.Z` on the
  pushed commit. It holds the files of the CI's release build: `Thermik-X.Y.Z.zip` (the universal app, ad-hoc signed,
  not notarized), `Thermik-X.Y.Z-dSYMs.zip` (the symbols for crash reports) and `SHA256SUMS`; its notes list the
  commit subjects since the previous release and how to install. A push whose version is already released only runs
  the checks. A version that has no tag is released by the next push to `master` that carries it, so the first push
  of the repository to GitHub releases the version it has. One release run goes at a time: a newer push replaces a run
  that is still waiting, and its own run releases the version. The workflow reads the tags of `origin` without
  credentials, so the repository must be public.
- **CI:** other branches and pull requests run `.github/workflows/ci.yml`: actionlint, shellcheck, the Debug build,
  which must leave every tracked file as committed (it regenerates `Localizable.xcstrings`), and the release build,
  kept as the run's `release-X.Y.Z` artifact. The macOS jobs run on GitHub's `xcode-27` runners with Xcode 27.1. CI
  runs no tests: run the release scripts' tests (`scripts/tests/run.sh`) and the self-checks
  (`scripts/lib/selftest.sh`) locally.
- **Local release build:** `scripts/build-release.sh` builds the same files into `build/release/`, from empty
  Release products as on GitHub. `--test` runs the self-checks first, `--out DIR` also copies the files to `DIR`. It
  checks the version and the build number of the built app, both architectures, the dSYMs (the binaries' UUIDs and
  debug information for both architectures) and the signature, then the signature and the version again in the app
  unzipped from `Thermik-X.Y.Z.zip`. With `Config/Signing.local.xcconfig` the app is signed with your Team ID
  instead of ad-hoc.

Releases need no secrets. Without a Developer ID they are ad-hoc signed, so macOS blocks the first launch of a
downloaded copy until it is allowed in System Settings › Privacy & Security; the release notes say how.

## `thermik-probe` (developer CLI)

`thermik-probe` is a command-line tool in the local Swift package. It builds without Xcode or XcodeGen. All its
subcommands are read-only on real hardware.

```sh
swift build --package-path Packages/ThermikCore
swift run --package-path Packages/ThermikCore thermik-probe smc read B0DC,B0CT,#KEY,RPlt   # raw SMC keys
swift run --package-path Packages/ThermikCore thermik-probe smc dump                       # every SMC key
swift run --package-path Packages/ThermikCore thermik-probe fans                           # a group's usage
```

The top-level `help` text is outdated. `fans`, `alerts` and `log` print their own usage when run without a
subcommand. The other groups run a default instead: `smc` dumps every key, `sensors` runs `groups`, `system` runs
`all`, `helper` runs `selftest` and `diagnostics` runs the live check. `sensors`, `system` and `helper` print
their usage for an unknown subcommand.

| Subcommand | What it shows |
|---|---|
| `sensors groups` · `snapshot` · `bench` · `watch [s] [--keys] [--wake]` · `discover [s]` · `resolve <db> KEY,…` | the sensor catalog with live values, aggregates, timings; heuristics for unknown chips; database drafting |
| `system all` (or `machine`, `battery`, `load`, `ioreport`, `smart`, `boot`, `thermal`, `pmset [n]`, `top [n]`, `bench`, `loadtest [s]`) | battery, power, CPU/GPU load, frequencies, SSD SMART, boot history, thermal pressure |
| `fans profile` · `snapshot [n]` · `inspect` · `dryrun [s]` | fan hardware, live state, other apps that hold the SMC, what each preset would command (printed, never sent) |
| `fans sim` | the fan write path and safety rules against an in-memory fake SMC |
| `helper selftest` · `status` · `plan` | the helper's safety invariants with a mock fan backend; install state and the install plan |
| `alerts replay` | synthetic series through the alert rules |
| `log write <dir> [daily\|weekly\|never\|size:N]` | a sample CSV log |
| `diagnostics [--demo] [--seconds N]` · `diagnostics selftest` | the diagnostics checks and report |

`scripts/lib/render-icon.swift` regenerates the app icon renditions (see the comment at the top of the file).

## Debug-only switches

Debug builds add a "Debug" item to the main menu (Dump History Stats) and a "Debug" submenu to the status item's
right-click menu: label-style override and 3-second cycling, and simulated states (stale readings, fanless Mac,
◆ / safety badges, engaging, Max countdown, a foreign fan controller, helper states, thermal pressure, first-run
and hidden-item hints). The same states can be set with launch arguments:

`-ThermikDebugFanless YES`, `-ThermikDebugHelper <state>`, `-ThermikDebugForeign <name>`,
`-ThermikDebugStale YES`, `-ThermikDebugBadge override|safety`, `-ThermikDebugPressure <n>`,
`-ThermikDebugEngaging YES`, `-ThermikDebugMaxCountdown YES`, `-ThermikDebugCycleStyles YES`,
`-ThermikDebugStyle <style>`.

`-ThermikMaxRevertMinutes <n>` overrides the Max auto-revert timer and is **not** limited to Debug builds.

## Localization

English strings are the keys in code. Russian translations live in per-unit fragments in
`App/Resources/L10n/*.json`. A fragment value is either a plain Russian string, an object `{ "ru", "comment" }`,
or a plural form `{ "en": { "one", "other" }, "ru": { "one", "few", "many", "other" } }`.

`scripts/lib/build.sh` runs `scripts/lib/l10n-merge.py`, which regenerates `App/Resources/Localizable.xcstrings`. The
catalog is generated but committed; never edit it by hand. `python3 -I scripts/lib/l10n-merge.py --missing` lists
UI strings that have no Russian translation yet.

Siri and Spotlight phrases (App Shortcuts) are the exception: they live only in
`App/Resources/AppShortcuts.xcstrings`, which is edited by hand and not touched by the merge script.

## Privacy

Thermik has **no telemetry, no analytics and no network access**: the sources contain no networking code at all.
Sensor data, settings and the optional CSV logs stay on the Mac. A future opt-in update check is the only planned
network feature.

## Legal and clean-room rules

Thermik is an independent project. It is **not affiliated with, endorsed by or derived from Tunabelly Software or
TG Pro**. TG Pro is a trademark of its owner and is mentioned only to describe interoperability (for example,
Thermik notices when TG Pro is already controlling the fans and then does not fight it).

Thermik is written clean-room, and contributions must keep it that way:

- no code, binaries, resources, icons, strings or data from TG Pro or any other proprietary app may be used,
  inspected or reverse-engineered (no `strings`, `nm`, `otool`, nib or `Assets.car` parsing of their binaries);
- hardware facts come from Apple's public documentation, Thermik's own read-only measurements on real Macs, and
  permissively licensed (MIT, BSD, Apache) projects, with attribution in the code (see Settings › About);
- GPL projects are used for facts only, never for code.

`research/` and any `*.zip` are git-ignored: they hold local notes and proprietary material that must never be
committed.

## License

[MIT](../LICENSE) © 2026 Thermik contributors.

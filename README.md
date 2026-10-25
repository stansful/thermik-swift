# Thermik

*See the heat. Ride it calmly.*

Thermik is a free, open-source (MIT) menu bar app for macOS that shows temperatures, fans, battery and
system diagnostics, and (once its helper is installed) controls the fans with explicit modes:
Auto, Curve, Fixed and Max. It is written in Swift 6 with SwiftUI, AppKit and Metal, and ships in
English and Russian.

> **Status: early development.** This is the project skeleton. It builds, runs in demo mode and reads
> the SMC, but most features (sensor catalog, fan control, alerts, logging, the full UI) are still
> being implemented.

[Русская версия ниже](#thermik-по-русски)

## Requirements

- macOS 14 Sonoma or later (Liquid Glass on macOS 26 and later). Apple Silicon is the primary target;
  Intel is best effort.
- Xcode 27.1 or later (Swift 6).
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.46.0 or later: `brew install xcodegen`.

## Build

```sh
brew install xcodegen          # once
Scripts/build.sh Debug         # l10n merge → xcodegen generate → xcodebuild → codesign check
```

The app is built at `build/DerivedData/Build/Products/Debug/Thermik.app`. `Thermik.xcodeproj` is
generated from `project.yml` and is not committed: never edit it by hand, and do not let Xcode
"upgrade" it. Change `project.yml` and run `xcodegen generate` (or `Scripts/build.sh`) instead.
`Scripts/build.sh Release` builds the Release configuration.

There are no automated tests in v1. Verification means building and running the app or the
`thermik-probe` CLI (see below).

## Signing and the privileged helper

Fan control needs a small root helper (`thermik-helper`, embedded in the app). Thermik picks the install
mode at runtime from the app's own code signature:

| Build | How to get it | Helper install mode |
|---|---|---|
| **Ad-hoc** ("Sign to Run Locally", the default) | nothing to do: a fresh clone builds this way, no Apple account needed | **Legacy installer**: one administrator password prompt copies the helper to `/Library/PrivilegedHelperTools/app.thermik.helper` and pins the app's code hash in a root-owned trust file. Every ad-hoc rebuild changes that hash, so the app asks you to re-authorize the helper. |
| **Team ID** (Apple Development / Developer ID) | `cp Config/Signing.local.xcconfig.example Config/Signing.local.xcconfig`, then put your Team ID in it (the file is git-ignored) | **SMAppService**: the app registers the bundled launch daemon; you approve it once in System Settings › General › Login Items & Extensions. |

Both binaries are always built with the hardened runtime: the helper only talks to a client with the
runtime flag. Monitoring works without the helper; only fan control needs it. The helper is designed to
hand the fans back to macOS whenever Thermik quits, crashes or loses its connection, and before the Mac
sleeps.

To remove the helper (both modes), run `sudo Scripts/uninstall-helper.sh` yourself.

The bundle identifiers `app.thermik.Thermik` and `app.thermik.helper` are placeholders for now.

## Run

```sh
open build/DerivedData/Build/Products/Debug/Thermik.app --args -ThermikDemo YES   # demo mode
open build/DerivedData/Build/Products/Debug/Thermik.app                           # real sensors (read-only)
```

- **Demo mode** (`-ThermikDemo YES`) uses synthetic sensors, two synthetic fans and a mock helper. It works
  on any Mac and never touches the hardware. In Xcode, enable the `-ThermikDemo` argument in the scheme
  editor (Run › Arguments).
- **Real mode** reads the SMC and HID sensors. Reading is unprivileged and read-only. Only the installed
  root helper ever writes to the SMC (fan targets and modes).

Thermik is a menu bar agent: it has no Dock icon until one of its windows is open.

## `thermik-probe` (developer CLI)

`thermik-probe` is a command-line tool in the local Swift package. It builds without Xcode or XcodeGen.
All its subcommands are read-only on real hardware.

```sh
swift build --package-path Packages/ThermikCore
swift run --package-path Packages/ThermikCore thermik-probe smc read B0DC,B0CT,#KEY,RPlt   # raw SMC keys
swift run --package-path Packages/ThermikCore thermik-probe smc dump                       # every SMC key
swift run --package-path Packages/ThermikCore thermik-probe help                           # all commands
```

Other subcommands (`sensors`, `system`, `fans`, `helper`, `alerts`, `log`, `diagnostics`) land
together with the features they exercise. Until then they print "not implemented yet".

## Localization

English strings are the keys in code. Russian translations live in per-unit fragments in
`App/Resources/L10n/*.json`. `Scripts/build.sh` runs `Scripts/l10n-merge.py`, which regenerates
`App/Resources/Localizable.xcstrings`. Never edit the catalog by hand.
`python3 -I Scripts/l10n-merge.py --missing` lists UI strings that have no Russian translation yet.

## Privacy

Thermik has **no telemetry, no analytics and no network access**. Sensor data, settings and the
optional CSV logs stay on your Mac. A future opt-in update check is the only planned network feature.

## Legal and clean-room note

Thermik is an independent project. It is **not affiliated with, endorsed by or derived from
Tunabelly Software or TG Pro**. TG Pro is a trademark of its owner and is mentioned only to describe
interoperability (for example, Thermik is designed to notice when TG Pro is already controlling the fans
and then not to fight it).

Thermik is written clean-room: no code, binaries, resources, icons, strings or data from TG Pro or any
other proprietary app were used, inspected or reverse-engineered. Hardware facts come from Apple's
public documentation, Thermik's own read-only measurements on real Macs, and permissively licensed
(MIT, BSD, Apache) projects, with attribution in the code. GPL projects are used for facts only,
never for code.

## License

[MIT](LICENSE) © 2026 Thermik contributors.

---

## Thermik по-русски

*Видеть жар. Оставаться спокойным.*

Thermik — бесплатное приложение с открытым исходным кодом (MIT) для строки меню macOS. Оно показывает
температуры, вентиляторы, аккумулятор и диагностику системы, а после установки помощника управляет
вентиляторами в явных режимах: «Авто», «Кривая», «Фиксированная» и «Максимум». Интерфейс на русском и
английском.

> **Статус: ранняя разработка.** Сейчас это каркас проекта: он собирается, работает в демо-режиме и
> читает SMC. Большая часть функций ещё в работе.

**Сборка.** Нужны macOS 14+, Xcode 27.1+ и XcodeGen (`brew install xcodegen`). Затем
`Scripts/build.sh Debug`. Приложение появится в `build/DerivedData/Build/Products/Debug/Thermik.app`.
Файл `Thermik.xcodeproj` генерируется из `project.yml`: не редактируйте его вручную.

**Подпись и помощник.** По умолчанию сборка подписывается ad-hoc («Sign to Run Locally»), учётная
запись Apple не нужна. Тогда помощник ставится старым способом: один запрос пароля администратора, а
после каждой пересборки его нужно разрешить заново. С собственным Team ID (файл
`Config/Signing.local.xcconfig`, образец — `Config/Signing.local.xcconfig.example`) помощник
регистрируется через SMAppService и один раз разрешается в Системных настройках › Объекты входа.
Мониторинг работает и без помощника. Удалить помощник: `sudo Scripts/uninstall-helper.sh`.

**Запуск.** `open …/Thermik.app --args -ThermikDemo YES` — демо-режим с синтетическими данными (не
трогает оборудование). Без аргумента приложение читает реальные датчики, только чтение.

**Утилита для разработчиков.**
`swift run --package-path Packages/ThermikCore thermik-probe smc read B0DC,B0CT,#KEY` — чтение ключей
SMC (только чтение); `thermik-probe help` — список команд.

**Конфиденциальность.** Никакой телеметрии, аналитики и сетевых запросов. Все данные остаются на вашем Mac.

**Правовая оговорка.** Thermik — независимый проект. Он **не связан с Tunabelly Software и TG Pro** и не
основан на них. При разработке не использовались и не изучались код, ресурсы, значки, строки или данные
TG Pro и других проприетарных программ; никакой обратной разработки. Сведения об оборудовании взяты из
публичной документации Apple, собственных измерений (только чтение) и проектов под лицензиями MIT, BSD
и Apache (с указанием авторства в коде).

Лицензия: [MIT](LICENSE).

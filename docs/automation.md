# Automation · Автоматизация

[English](#english) · [Русский](#русский)

## English

### Shortcuts

Thermik adds three actions to the Shortcuts app. They work without opening Thermik.

| Action | What it does |
|---|---|
| **Get Temperature** | returns one of 10 values (CPU average, CPU hottest, GPU average, GPU hottest, CPU or GPU (hotter), hottest sensor, all sensors average, memory, SSD, battery) as a number in °C |
| **Set Fan Mode** | switches the fans to Auto, Curve, Fixed or Max (uses the curve and fixed speed set in Thermik) |
| **Apply Fan Preset** | applies Quiet, Balanced, Cool or Performance as the power-adapter curve and switches to Curve (a separate battery curve, if you use one, stays as it is) |

*Get Temperature* and *Set Fan Mode* also answer to Siri and Spotlight: "Thermik temperature", "Get the Thermik
temperature", "Set the Thermik fan mode", "Change the Thermik fan mode". Except for switching to Auto, the fan
actions need the helper and fail while another app controls the fans. On a Mac without fans they all fail.

### `thermik://` links

| Link | Action |
|---|---|
| `thermik://open?page=sensors` | main window on a page: `overview`, `sensors`, `fans`, `battery`, `system`, `diagnostics`, `logs`, `alerts`, `settings` |
| `thermik://open?page=sensors&sensor=smc:Tp01` | the Sensors page with that sensor in the inspector |
| `thermik://panel` | show or hide the menu bar panel |
| `thermik://settings/fans` | Settings on a tab: `general`, `menubar`, `sensors`, `fans`, `alerts`, `logging`, `appearance`, `helper`, `advanced`, `about` |
| `thermik://fans/mode/max` | fan mode `auto`, `curve`, `fixed` or `max` |
| `thermik://fans/preset/quiet` | apply a preset (`quiet`, `balanced`, `cool`, `performance`) as the power-adapter curve and switch to Curve |
| `thermik://fans/fixed?percent=60` | Fixed speed for all fans (`&fan=0` for one fan) |

Fan links other than Auto need the helper: without it, or while another app controls the fans, they just open
the Fans page. A Mac without fans ignores fan links. Any web page can open a link, so a link that takes control
of the fans asks first. **Cancel** is the default
button, so a stray Return never counts as consent. You can tick "Always allow links to change fan control"; only
Settings › General › Reset to Defaults… clears that choice. Switching back to Auto never asks.

### Keyboard and mouse

- **Global shortcuts** (work in any app): "Show main window" and "Show or hide the panel". Record them in
  Settings › General › Keyboard Shortcuts. None is set by default, so Thermik never collides with another app.
- **Menu bar item**: click opens the panel, ⌥-click opens the main window, right-click (or ⌃-click) opens a
  menu with the fan modes, Settings and Quit.
- **Main window**: ⌘1…⌘8 open the pages, ⌘, opens Settings, ⌘0 opens the main window, ⌃⌘S shows or hides
  the sidebar. In the curve editor, ⌘Z / ⇧⌘Z undo and redo.

---

## Русский

### Быстрые команды

Thermik добавляет три действия в приложение «Быстрые команды». Они работают, даже если окно Thermik закрыто.

| Действие | Что делает |
|---|---|
| **Узнать температуру** | возвращает одно из 10 значений (ЦП (среднее и максимум), ГП (среднее и максимум), ЦП или ГП (что горячее), самый горячий датчик, среднее по всем датчикам, память, SSD, аккумулятор) числом в °C |
| **Задать режим вентиляторов** | включает режим «Авто», «Кривая», «Фиксированная» или «Максимум» (кривая и скорость берутся из настроек Thermik) |
| **Применить пресет вентиляторов** | применяет «Тихий», «Сбалансированный», «Прохладный» или «Производительность» как кривую для адаптера питания и включает режим «Кривая» (отдельная кривая для аккумулятора, если она включена, не меняется) |

Первые два действия доступны также в Siri и Spotlight: «Температура Thermik», «Узнать температуру Thermik»,
«Задать режим вентиляторов Thermik», «Сменить режим вентиляторов Thermik». Для действий с вентиляторами, кроме
возврата в «Авто», нужен помощник, и они не сработают, пока вентиляторами управляет другое приложение. На Mac
без вентиляторов не работает ни одно из них.

### Ссылки `thermik://`

Таблица ссылок — [в английском разделе](#thermik-links): адреса одинаковые на любом языке. Ссылкам на
вентиляторы, кроме возврата в «Авто», нужен помощник: без него или пока вентиляторами управляет другое
приложение они просто открывают страницу «Вентиляторы». На Mac без вентиляторов такие ссылки игнорируются.
Если ссылка меняет управление вентиляторами, Thermik сначала спрашивает разрешение. По умолчанию выбрана кнопка
«Отменить», поэтому случайное нажатие Return ничего не разрешит. Флажок «Всегда разрешать ссылкам менять управление
вентиляторами» снимается только сбросом настроек (Настройки › Основные › Сбросить настройки…). Возврат в
«Авто» разрешения не требует.

### Клавиатура и мышь

- **Глобальные сочетания** работают в любом приложении: «Показать главное окно» и «Показать или скрыть
  панель». Задаются в разделе Настройки › Основные › Сочетания клавиш. По умолчанию ни одно не задано.
- **Значок в строке меню**: щелчок открывает панель, ⌥-щелчок — главное окно, правый щелчок (или ⌃-щелчок) —
  меню с режимами вентиляторов, настройками и выходом.
- **Главное окно**: ⌘1…⌘8 открывают страницы, ⌘, — настройки, ⌘0 открывает главное окно, ⌃⌘S показывает
  или скрывает боковую панель. В редакторе кривой работают ⌘Z и ⇧⌘Z.

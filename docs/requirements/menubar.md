# Menu bar — requirements (current behavior)

Source of truth for what Penknife's own menu bar item (logo, status dots, recording indicator, its menu and the shortcut that opens it) and the three reading items (weather, Mac temperature, speed test) share must do TODAY (main after 4c4fa00). What each reading shows is in its module's file (`weather.md` WX-11, `cputemp.md` CT-07, `speedtest.md` ST-08, ST-09); the recording indicator in `recording.md` REC-31; each dot's meaning in `microphone.md` and `jiggler.md` JG-13. The history stays in `docs/REQUIREMENTS.md` (R-14, R-17, R-19, R-20 MENU BAR DOTS, R-29, R-30) and `docs/DECISIONS.md` (Menu bar dots, Menu bar readings).

**How to use it.** Before changing anything in the menu bar, read the rules of the parts you change. After the change, run `scripts/test.sh` and check EVERY affected rule by its Verify line, not only the new behavior. A new or changed wish → change the rule here, and keep the story in REQUIREMENTS.md.

Code abbreviations: SM = `App/StatusMenu.swift`, MR = `App/MenuBarReadings.swift`, AD = `App/AppDelegate.swift`, MGR = `Core/ModuleManager.swift`, SC = `Core/Shortcuts.swift`, GT = `Settings/GeneralTab.swift`, SV = `Settings/SettingsView.swift` (MenuBarToggle), ST = `Settings/ShortcutsTab.swift`.

**Tests:** `PenknifeTests/MenuBarRulesTests.swift` (8 tests; MB-01, 04, 05, 06, 08, 10, 12, WX-11's item look). The readings' default per Touch Bar is in `TouchBarRulesTests` (R-30). A test must never create a status item, open a menu or write `UserDefaults.standard`.

## 1. Rules

### A. Penknife's item and its menu

- **MB-01** Penknife's item shows only the logo (template `MenuBarIcon`, VoiceOver "Penknife"), square, no data beside it except the dots (MB-04) and the recording time (MB-06). A click opens the menu; so does the shortcut "Open the Penknife menu" / "Abrir el menú de Penknife" (`openMenu`, default ⌃⌥P, Settings › Shortcuts).
  Source: R-14 "Only the logo"; R-12 · Code: SM:glyph, init, open; SC:openMenu; AD:onKeyUp(.openMenu); ST · Verify: **auto** — the ⌃⌥P default; manual — ⌃⌥P opens the menu with the keyboard ready (arrows move).
- **MB-02** The menu is built only when it opens, top to bottom: the actions of the modules that are on, in module order (symbol — shown on macOS 26, hidden by macOS 27's default, which the user chose to follow on 2026-11-23: "lo nativo de apple"; never forced with `preferredImageVisibility` — title, a checkmark for toggles such as the jiggler, the action's shortcut shown); a separator; the readings (MB-08) and a separator, when there is any; "Check for Updates…" (greyed while Sparkle can't check, R-17); "Settings…" ⌘,; "Quit Penknife" ⌘Q. No icons on the last three, like other Mac apps.
  Source: R-3, R-15, R-17, R-19 · Code: SM:menuNeedsUpdate; MGR:enabledActions · Verify: manual — open the menu; turn a module off in Settings and open it again: its action is gone.
- **MB-03** Choosing an action runs it after the menu has closed (a screenshot never captures the menu). While any Penknife menu is open (this one or a reading's, MB-11) every Penknife shortcut is paused, ⌃⌥P included, and back when it closes.
  Source: D: Menu bar dots · Code: SM:runAction, menuWillOpen, menuDidClose; MR:menuWillOpen, menuDidClose; MGR:pauseShortcuts · Verify: manual — menu › Screenshot: the overlay shows without the menu in it.

### B. Status dots (R-20, IMPERATIVE)

- **MB-04** Two 6 pt dots (as Apple's; 4 pt until 2026-11-19) stacked beside the logo, always in these slots: TOP = microphone (orange: filled = open, 1.25 pt ring = muted), BOTTOM = mouse jiggler (system blue: filled = on, ring = off). A dot shows only while "Show microphone and Mouse Jiggler dots" is on (`menuBar.statusDots`, default on) and its module is on; the microphone dot also needs an input device (without one it would claim an open mic). One, the other, both or none.
  Source: R-20 MENU BAR DOTS (variant 3, 2026-11-13); JG-13 · Code: SM:dots, dotsOn, updateIcon · Verify: **auto** — `dots(shown:microphone:jiggler:)` for every case; `dotsOn(in:)` nothing stored → on; manual — F12: the bottom dot fills; mute: the top dot becomes a ring.
- **MB-05** Look and cost: the logo in the menu bar's text color plus a fixed 6 pt column (dots 2 pt apart, 3 pt from the logo), so the icon keeps its width whatever the dots show; it follows light, dark and tinted menu bars. VoiceOver value "Microphone muted, Mouse jiggler on" (microphone first, as on screen; O-30) and a value-changed announcement when it changes from elsewhere (Touch Bar, Teams, Control Center). Redrawn only on a real change; no timer: the jiggler and the modules by observation, the microphone by CoreAudio listeners that run only while the mic dot can show; other settings writes are ignored.
  Source: R-20; R-11; R-19 · Code: SM:icon, updateIcon, dotsValue, trackState, micWatcher · Verify: **auto** — `dotsValue` order and empty case; manual — light/dark menu bar: logo and dots legible, width doesn't jump.

### C. While recording

- **MB-06** From the end of the countdown to Stop the logo becomes the recording indicator (REC-31: red `record.circle.fill` and " 0:05", the dots stay); a click stops instead of opening the menu; VoiceOver "Recording, 0:05. Click to stop." / "Recording paused at 0:05. Click to stop.". After Stop the logo and the menu come back.
  Source: R-29 CHOSEN; REC-31 · Code: SM:showRecording, recordingLabel, stopRecording, updateIcon · Verify: **auto** — `recordingLabel` has the time and differs when paused; manual — see REC-31.
- **MB-07** ⌃⌥P opens the menu while recording too (attached for that one click; O-17 decided); stopping stays on the item and ⌃⌥R.
  Source: O-17 (2026-11-19, user: "abrir menu") · Code: SM:open · Verify: manual — see REC-31 / O-17 in recording.md.

### D. Readings in the menu

- **MB-08** The readings block, in this order, each only while its module is on: "Weather: Clear sky, 18°" with the condition symbol (only with a report), "CPU temperature: 54°" with `thermometer.medium` (only when readable), then the speed test lines (ST-08). Lines are enabled so VoiceOver reads them normally and do nothing when chosen.
  Source: R-19 (Touch Bar readings reachable from the menu); WX-11; ST-08 · Code: SM:readingLines, reading · Verify: **auto** — order, missing ones leave no line, nothing → empty (no separator).

### E. Reading items (R-30)

- **MB-09** Up to three items of their own, apart from Penknife's icon: weather, Mac temperature, speed test, each movable with ⌘-drag, its place remembered (`penknife.<kind>`). Each shows a symbol and maybe a short text; what each shows is in WX-11, CT-07 and ST-09; VoiceOver label = tooltip.
  Source: R-30 "SEPARATE menu bar items … each movable with ⌘-drag" · Code: MR:update, draw · Verify: manual — ⌘-drag one, relaunch: it stays there.
- **MB-10** An item exists only while its module is on and its switch "Show in the menu bar" is on (`menuBar.show.weather` / `.temperature` / `.speedTest`; default on without a Touch Bar, off with one). A switch or a module change shows or hides only that item, at once.
  Source: R-30 acceptance · Code: MR:wanted, isShown, shownByDefault, update; SV:MenuBarToggle · Verify: **auto** — `wanted` for every mix; keys; default (TouchBarRulesTests R-30); manual — each switch shows/hides its item at once.
- **MB-11** A click on an item opens its own menu: weather (the reading, then "Update Weather" or "Allow Location…", WX-11), temperature (the reading or "CPU temperature not available"), speed test (ST-08, "Run Speed Test"). Shortcuts paused while open (MB-03).
  Source: R-30 "Click on an item" · Code: MR:menuNeedsUpdate · Verify: manual — open each item's menu.
- **MB-12** One style for the three, Settings › General "Menu bar readings": Simple (default; outline symbols: `.fill` dropped, regular weight, follows the menu bar), Color (weather in its own colors, `cpu` for the Mac, the temperature orange from 85 °C, CT-07), Bold (filled symbols, medium weight symbol and text, follows the menu bar). Text in monospaced digits. A stored value that isn't one of these reads as Simple. A style change redraws without restarting the speed test sequence (ST-09).
  Source: R-30 "ME GUSTAN LAS 3. QUE EL USUARIO ESCOJA CUÁL QUIERE" · Code: MR:Style, style(in:), symbolLook, draw; GT · Verify: **auto** — `symbolLook` per style and kind; `style(in:)` default and unknown; manual — switch the style: all three items change at once.
- **MB-13** Cost: the items are rebuilt only when the set of wanted items or the style changes (any other settings write is ignored); weather and speed test redraw on their own notifications; the only timers are the temperature read (10 s, only while its item exists and the screens are awake, CT) and the speed test sequence (only around a test, ST-09). A module off has no item and nothing is read.
  Source: R-11; R-15; R-30 "Cost" · Code: MR:update, updateTemperatureWatch, speedTestChanged · Verify: manual — `measure-resources` with all three items: idle CPU as before (~0.2 %).

### F. Settings and language

- **MB-14** Settings › General, first section: "Launch at login", "Show microphone and Mouse Jiggler dots" (MB-04), "Menu bar readings" (MB-12); each module page with a reading has "Show in the menu bar" (MB-10).
  Source: R-16, R-20, R-30 · Code: GT:GeneralPage; SV:MenuBarToggle · Verify: manual — the rows and their effect at once.
- **MB-15** Every visible or spoken menu bar string (menu, dots values, item labels, style names) exists in English and Spanish.
  Source: R-16 · Code: Localizable.xcstrings · Verify: manual — the app in Spanish: menu, Settings › General, VoiceOver on the icon.

## 2. Open questions and known bugs

For the user:
- DONE 2026-11-19 (user: "go" = the recommendation; test MB-05 seen to fail first): **O-30 VoiceOver reads the dots in the opposite order of the screen.** The microphone dot is on top, but VoiceOver says "Mouse Jiggler on, Microphone muted" (MB-05). [Recommended: read the microphone first, as on screen; tiny change.]

Not measured / noted (nothing to decide yet):
- An unreadable temperature leaves no line in Penknife's menu (MB-08) but the item's own menu says "CPU temperature not available" (MB-11). Not asked; probably fine.
- DONE 2026-11-19: bigger dots. `ux-ui-designer` variants shown live (4/5/6/7 pt, 6 pt with 3 pt gap); user: "2, como la de apple" = 6 pt dots, 2 pt gap, 1.25 pt ring, same 6 pt column (item width unchanged).

## 3. Rejected / out of scope (do not rebuild)

- Data next to Penknife's logo (R-14); the readings live in their own items (R-30).
- One item for weather and temperature together (R-30 chose separate items).
- Dots that disappear when off (R-20 chose always visible, ring = off).

## 4. Test plan (step B)

**Done 2026-11-19** (autonomous routine work): as-is tests + S1–S3 in `PenknifeTests/MenuBarRulesTests.swift`, 242 pass in all; each rule broken on purpose made its test fail (mutation run: no input still shows a mic dot, dots off still shows the jiggler, readings order, item without its module, Simple keeping `.fill` in Bold, any failure as "location not allowed", microphone read first); no behavior change. Each seam is a pure function the code calls with the same values as before.

- **Testable as-is:** `openMenu` default, `StatusMenu.dotsOn(in:)` (MB-01, MB-04); `Kind` keys and modules (MB-10).
- **S1 Dots and labels** (SM). `StatusMenu.dots(shown:microphone:jiggler:)`, `dotsValue(mic:jiggler:)`, `recordingLabel(time:paused:)`. Covers MB-04, MB-05, MB-06.
- **S2 Menu readings** (SM). `StatusMenu.readingLines(weather:celsius:speed:)`. Covers MB-08.
- **S3 Reading items** (MR). `MenuBarReadings.wanted(isEnabled:isShown:)`, `style(in:)`, `symbolLook(_:kind:style:)`, `weatherLook(report:status:)`. Covers MB-10, MB-12, WX-11's item look.

Manual only (no seam worth it): MB-02, MB-03, MB-07, MB-09, MB-11, MB-13, MB-14, MB-15 (status items, menus, observers).

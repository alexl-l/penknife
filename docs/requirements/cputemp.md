# CPU temperature — requirements (current behavior)

Source of truth for what the CPU Temperature module (the Mac's CPU temperature read from the SMC, shown on the Touch Bar, in the menus and as a menu bar item) must do TODAY (main after 7290f97). The history behind each rule stays in `docs/REQUIREMENTS.md` (R-9; R-25 for the Touch Bar thresholds; R-30 for the menu bar item; R-11, R-15, R-19 for cost, modules and accessibility) and `docs/DECISIONS.md` (CPU temperature in Swift, Menu bar readings, Mac App Store not viable, License).

**How to use it.** Before changing anything that touches the temperature, read the rules of the parts you change. After the change, run `scripts/test.sh` and check EVERY affected rule by its Verify line, not only the new behavior. A new or changed wish → change the rule here, and keep the story in REQUIREMENTS.md.

Code abbreviations: CT = `Modules/CPUTemperatureModule.swift` (CPUTemperatureModule, TemperatureText), MO = `Core/Module.swift`, SV = `Settings/SettingsView.swift`, BL = `TouchBar/BarLooks.swift`, TM = `TouchBar/TouchBarModule.swift`, SM = `App/StatusMenu.swift`, MR = `App/MenuBarReadings.swift`.

**Tests:** `PenknifeTests/CPUTemperatureRulesTests.swift` (7 tests; CT-01, 03, 04, 05, 07); the Touch Bar look is in `TouchBarRulesTests` (TB-26). A test must never call `read()` (it opens the SMC), never create a menu bar item, never write `UserDefaults.standard`.

## 1. Rules

### A. The module

- **CT-01** Module "CPU Temperature" / "Temperatura de la CPU" (symbol `thermometer.medium`, orange in Settings), on by default, no actions, no shortcuts, no Accessibility, works with or without a Touch Bar. Description: "Shows the CPU temperature on the Touch Bar and in the menu." / "Muestra la temperatura de la CPU en la Touch Bar y en el menú."
  Source: R-9, R-15 · Code: MO:title, summary, symbol, defaultOn; SV:tint; CT:actions · Verify: **auto** — `ModuleID.cpuTemperature` symbol, `defaultOn`, not `needsTouchBar`; a new module has no actions and no Accessibility.
- **CT-02** Settings › CPU Temperature has only "Show in the menu bar" / "Mostrar en la barra de menús" (`menuBar.show.temperature`; default on without a Touch Bar, off with one; R-30).
  Source: R-30 · Code: SV:case .cpuTemperature, MenuBarToggle · Verify: manual — Settings › CPU Temperature: the one toggle; switching it shows/hides the item at once. (The default is tested in TouchBarRulesTests/R-30 `shownByDefault`.)

### B. How it reads

- **CT-03** Which sensor: SMC key `TCMb` when it answers (the value MacFanPro shows); otherwise every core key that answers, tried in this order: `Tp` then `Te`, each with `0` + one of `0–9 A–Z a c–w y`, then `1a`…`9a` (136 keys). The keys are found at the first reading (not at start) and kept until Penknife quits, also when none answered (then the reading stays "not available" until a relaunch).
  Source: R-9; D: CPU temperature in Swift · Code: CT:read, findKeys, coreKeys · Verify: **auto** (S1) — `coreKeys`: 136, no repeats, first `Tp00`, last `Te9a`, has `Tp0a`, `Tp01`, `Tp05`, `Te0y`, `Tp5a`, not `Tp0b`, `Tp15`, `TCMb`, all `Tp` before `Te`.
- **CT-04** A reading: read-only through the AppleSMC user client (key info, then read; only `flt ` keys); a value counts only above 0 and below 150 °C; the result is the hottest key, truncated to whole degrees (54.9 → 54). The SMC can't be opened → no reading. Never writes to the SMC, no fan control.
  Source: R-9 "Read-only… truncated… No fan control" · Code: CT:readTemperature, celsius(raw:), degrees(_:), open · Verify: **auto** (S1) — 0, −3, 150, 200 → none; 0.5, 149.9 → kept; [] → none; [41.2, 63.99, 58] → 63.
- **CT-05** Text: whole degrees in the system's unit with no letter, "54°" (°F converts the truncated °C and rounds); VoiceOver and long labels say it in words ("54 degrees Celsius" / "54 grados Celsius"). Thresholds (CT-06, CT-07) stay in °C whatever the unit.
  Source: Phase 2 "Temperatures follow the system unit, shown as 54°" · Code: CT:TemperatureText · Verify: **auto** — `short(54)` ends in "°" with a number and no C/F.

### C. When it reads

- **CT-06** Only when shown, never in the background: the module's `start()` does nothing; each place that shows the temperature reads on its own (Touch Bar every 10 s, TB-26; menu bar item every 10 s, CT-07; a menu when it opens, CT-08). No reading while the screens sleep. `stop()` closes the SMC connection; the next reading opens it again.
  Source: R-9 "only while shown"; R-11; R-30 "Cost"; D: CPU temperature in Swift · Code: CT:start, stop, open; TM:updateTemperature; MR:updateTemperatureWatch, readTemperature · Verify: manual — Touch Bar button hidden, menu bar item off: Activity Monitor shows Penknife at 0 % CPU and no wakeups from it every 10 s.

### D. Where it shows

- **CT-07** Menu bar item (R-30), while the module is on and its toggle is on: Simple and Bold `thermometer.medium`, Color `cpu`; "54°" (monospaced digits) or "—" when unreadable; from 85 °C the text turns orange in Color only, and VoiceOver adds ", hot" / ", alta". VoiceOver: "Mac temperature: 54 degrees Celsius" / "Temperatura del Mac: …"; unreadable "CPU temperature not available" / "Temperatura de la CPU no disponible". Read when the item appears, then every 10 s (2 s tolerance) only while it exists and the screens are awake (checked with `CGDisplayIsAsleep` when the watch starts, then by sleep/wake notices; a wake reads at once). Its menu: one line "CPU temperature: 54°" / "Temperatura de la CPU: 54°" (`thermometer.medium`), read when the menu opens, or "CPU temperature not available".
  Source: R-30 · Code: MR:temperatureLook, hot, updateTemperatureWatch, readTemperature, menuNeedsUpdate · Verify: **auto** (S2) — symbol per style; 84 not hot, 85 hot with ", hot" in the label; unreadable → "—", never hot, in every style; manual — Settings › CPU Temperature › Show in the menu bar: the item appears with a reading that changes within 10 s under load; click: its one line.
- **CT-08** Main menu: "CPU temperature: 54°" / "Temperatura de la CPU: 54°" with `thermometer.medium`, among the readings, only while the module is on; read when the menu opens; unreadable → no line.
  Source: R-9, R-19 · Code: SM:readings · Verify: manual — open Penknife's menu: the line, same number as the Touch Bar within 10 s.
- **CT-09** Touch Bar: TB-26 (thermometer low/medium/high at 50 and 75 °C, "54°", "—" unreadable, 10 s while the button is on the bar, tap reads at once).
  Source: TB-26 · Code: BL:cpu, thermometer; TM:updateTemperature · Verify: see TB-26 (auto in TouchBarRulesTests).
- **CT-10** Off: switching the module off removes the Touch Bar button (TB-42), the menu bar item (R-30) and the main menu line, stops both 10 s timers, and closes the SMC connection. On again: the places come back and read at once.
  Source: R-15 "A module that is off uses no CPU/RAM"; R-30 "Module off → its item disappears" · Code: CT:stop; MR:update; TM:rebuildButtons; SM:isEnabled · Verify: manual — switch CPU Temperature off: no button, no item, no menu line; on again: all three with a reading.

## 2. Open questions and known bugs

For the user (minor, wording):
- DECIDED 2026-11-19 (user: "go" = keep as is): **O-28 Two names for one reading.** The menu bar item's VoiceOver says "Mac temperature" (R-30 asked for it), but its menu, the main menu, the Touch Bar and the "not available" text say "CPU temperature". [Keep as is: VoiceOver-only, and R-30 chose it; change only if the user wants one name.]

Not measured (check live; nothing to decide yet):
- With the Touch Bar button AND the menu bar item both shown, each has its own 10 s timer: two SMC readings per 10 s, and the two numbers can differ for up to 10 s.
- Which key answers on this Mac (M1) and whether `TCMb` exists on M2, M3, M4 chips; a chip with neither `TCMb` nor these core keys would always show "—" (CT-03).
- The readings run on the main thread; the first one without `TCMb` makes up to 272 SMC calls (all keys, info + value).

## 3. Rejected / out of scope (do not rebuild)

- Fan control or any write to the SMC (R-9).
- GPU, battery or other sensors; a history or chart (not asked).
- Mac App Store version (private AppleSMC access; D: Mac App Store not viable).

## 4. Test plan (step B)

**Done 2026-11-19** (autonomous routine work): as-is tests + S1–S2 in `PenknifeTests/CPUTemperatureRulesTests.swift`, 219 pass in all; each rule broken on purpose made its test fail (mutation run: CT-03 key list, CT-04 range and truncation, CT-07 threshold and symbol); no behavior change. Each seam is a pure function that the code calls with the same values as before.

- **Testable as-is:** `ModuleID.cpuTemperature` (CT-01); `TemperatureText.short` (CT-05); the Touch Bar look (TB-26, in TouchBarRulesTests).
- **S1 Reading rules** (CT). `CPUTemperatureModule.coreKeys`, `celsius(raw:)`, `degrees(_:)`. Covers CT-03, CT-04.
- **S2 Menu bar look** (MR). `MenuBarReadings.temperatureLook(celsius:style:)`, `hot`. Covers CT-07.

Manual only (no seam worth it): CT-02, CT-06, CT-08, CT-10 (SMC and observers).

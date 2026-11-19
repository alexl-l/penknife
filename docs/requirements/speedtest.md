# Speed test — requirements (current behavior)

Source of truth for what the Speed Test module (macOS `networkQuality`, started from the menu, the Touch Bar, a shortcut or its menu bar item) must do TODAY (main after 51ff4a0). The history behind each rule stays in `docs/REQUIREMENTS.md` (R-10; R-20 for the alerts; R-30 for the menu bar item; R-11, R-15, R-19 for cost, modules and accessibility) and `docs/DECISIONS.md` (Speed test (R-10), Speed units, Menu bar readings).

**How to use it.** Before changing anything that touches the speed test, read the rules of the parts you change. After the change, run `scripts/test.sh` and check EVERY affected rule by its Verify line, not only the new behavior. A new or changed wish → change the rule here, and keep the story in REQUIREMENTS.md.

Code abbreviations: ST = `Modules/SpeedTestModule.swift` (SpeedTestModule, Result, SpeedText), MO = `Core/Module.swift`, SC = `Core/Shortcuts.swift`, HUD = `Core/HUD.swift`, SV = `Settings/SettingsView.swift`, BL = `TouchBar/BarLooks.swift`, TM = `TouchBar/TouchBarModule.swift`, SM = `App/StatusMenu.swift`, MR = `App/MenuBarReadings.swift`.

**Tests:** `PenknifeTests/SpeedTestRulesTests.swift` (12 tests; ST-01, 04, 05, 06, 08, 09); the Touch Bar button is in `TouchBarRulesTests` (TB-27, B-6, B-7). A test must never call `run()` (it starts networkQuality), never create a menu bar item, never write `UserDefaults.standard`.

## 1. Rules

### A. The module

- **ST-01** Module "Speed Test" / "Test de velocidad" (symbol `speedometer`, green in Settings), on by default, works with or without a Touch Bar, no Accessibility. One action "Speed Test" (`speedometer`) in Penknife's menu with the shortcut `speedTest` (Settings › Shortcuts, no default key). Its alerts are their own type "Speed Test" (Settings › Alerts, shown by default). Description: "Measures download, upload, latency and responsiveness with macOS networkQuality, from the menu, the Touch Bar or a shortcut. Keeps only the last result."
  Source: R-10, R-15, R-20 · Code: MO:title, summary, symbol; SV:tint; ST:actions; SC:speedTest; HUD:AlertCategory · Verify: **auto** — symbol, `defaultOn`, not `needsTouchBar`, one action with shortcut `.speedTest`, no Accessibility, `.speedTest` alert type exists.
- **ST-02** Settings › Speed Test has only "Show in the menu bar" (`menuBar.show.speedTest`; default on without a Touch Bar, off with one; R-30).
  Source: R-30 · Code: SV:case .speedTest, MenuBarToggle · Verify: manual — the one toggle; switching it shows/hides the item at once. (The default is tested in TouchBarRulesTests/R-30.)

### B. A test

- **ST-03** Starting: any of the four ways in (menu action, shortcut, Touch Bar tap, "Test Speed Now" in the item's menu) calls `run()`. While a test runs another start does nothing (only a log line "already running; tap ignored"; no alert, no second tool). A start clears the last failure, shows the alert "Testing internet speed…" (`speedometer`) and tells every place (Touch Bar, menu bar item). The tool is `/usr/bin/networkQuality -c` (upload and download in parallel, uncapped: 20–45 s here; `-M` gives wrong numbers), run off the main thread, its output read to the end.
  Source: R-10 "Launch from ALL THREE", "A TAP WHILE A TEST RUNS MUST NOT START ANOTHER ONE", "It takes too long"; R-30 · Code: ST:run, measure, runTool · Verify: manual + log — start from the menu, then press the shortcut while it runs: `/usr/bin/log show --last 5m --predicate 'subsystem == "Penknife" AND category == "SpeedTest"'` shows one "started", one "tap ignored", one "ended, status 0".
- **ST-04** Reading the output: `dl_throughput` and `ul_throughput` (bits/s → Mbps), `base_rtt` (ms), `responsiveness` (RPM, rounded). A result needs at least one throughput above 0; a missing latency or RPM reads as 0. Exit status 0 alone is not trusted (an error run exits 0 with only `error_code`). No result → failure (ST-07).
  Source: D: Speed test (R-10) · Code: ST:parse · Verify: **auto** — a real output (2026-11-19) → 87.6 / 196.5 Mbps, 106.8 ms, 82 RPM; `error_code` only, both 0, only one key, not JSON, empty → none; upload only → kept, latency and RPM 0.
- **ST-05** Text, the same everywhere: speeds scaled to 3 significant digits in the locale's number format (850 kbps, 9.4 Mbps, 245 Mbps, 1.2 Gbps, then whole Gbps), spelled out for VoiceOver ("245 megabits per second"); the result line "↓ 245 Mbps · ↑ 45 Mbps" and "Latency 21 ms · Responsiveness Medium (812 RPM)" with the bands Low < 300 ≤ Medium < 1000 ≤ High (IETF draft; Apple publishes none).
  Source: R-10 "Shows EVERYTHING"; D: Speed units · Code: ST:SpeedText, Result.speeds, details, rating · Verify: **auto** — bands at 299/300/999/1000; units at 0.85, 9.4, 245, 999.4, 1200, 12 000 Mbps; both arrows, whole ms, RPM.
- **ST-06** Only the last result is kept, with its time (`speedTest.lastResult`, JSON); it survives a relaunch; unreadable data counts as none. A failure is not saved and doesn't erase the last result. No history.
  Source: R-10 "Only the last result is kept, with its time" · Code: ST:load, save, init, finish · Verify: **auto** — save → load and a new module read it back; garbage → none.
- **ST-07** The end: success → the result is saved and the alert shows "↓ … · ↑ …" with the details (`speedometer`). Failure (the tool can't start, a non-zero exit, or no result) → the alert "Speed test failed" / "Check the internet connection." (`wifi.exclamationmark`, error look) and the failure line in the menus. Cancelled (module off or Penknife quitting) → the tool is ended (SIGTERM, also when it was still starting), no alert, not a failure, the last result stays. Nothing runs between tests: no process, no timer.
  Source: R-10 "No network → a clear error", "The process is ended if Penknife quits"; R-11 · Code: ST:finish, cancel, start, stop · Verify: manual — Wi-Fi off, start a test: the failure alert and menu line; Wi-Fi on, start one and quit Penknife at once: `pgrep networkQuality` finds nothing.

### C. Where it shows

- **ST-08** Penknife's menu, among the readings, only while the module is on; and the menu bar item's menu: while a test runs one line "Speed test: testing…"; otherwise the failure line "Speed test failed. Check the internet connection." (if the last test failed) above the last result "Speed (14:05): ↓ … · ↑ …" (the date too when it isn't from today) and its details line (`timer`). The item's menu ends with "Test Speed Now" (after a separator when there is a result), hidden while testing.
  Source: R-10 "Menu: the last result under the item, Testing… while it runs"; R-30 · Code: ST:menuLines; SM:readings; MR:menuNeedsUpdate · Verify: **auto** — `menuLines`: testing hides the result and the failure; failure above result; nothing → no lines; date only when not today.
- **ST-09** Menu bar item (R-30), while the module is on and its toggle is on: `speedometer` ("Speed Test"); while testing the needle sweeps (0 → 33 → 67 → 100 %, one step every 0.6 s); then "↓ 245 Mbps" for 3 s, "↑ 45 Mbps" for 3 s (number and unit on one line, VoiceOver "Download 245 megabits per second"), then idle; a failure shows `wifi.exclamationmark` for 6 s. The result or failure plays only after a test the item saw running (an item that appears later shows idle). A style change redraws without restarting the sequence. Timers only around a test.
  Source: R-30 "TAMBIÉN CON EL SPEEDTEST" · Code: MR:speedSteps, speedLook, speedTestChanged, setSpeedPhase · Verify: **auto** — `speedSteps` per case, `speedLook` per phase; manual — start a test from the item: needle, then both speeds, then idle.
- **ST-10** Touch Bar: TB-27 (same sequence, number over its unit; failure "Tap to try again"; a tap while testing does nothing; timers only while the button is on the bar, B-6).
  Source: TB-27 · Code: BL:speedSteps, speedTest; TM:speedTestChanged · Verify: see TB-27 (auto in TouchBarRulesTests).
- **ST-11** Off: switching the module off ends a running test (ST-07), removes the menu action, the Touch Bar button (TB-42), the menu bar item and the menu lines. On again: everything back with the last result; no test starts by itself.
  Source: R-15 · Code: ST:stop; MR:update; TM:rebuildButtons; SM:isEnabled · Verify: manual — off during a test: no `networkQuality` process, no button, no item, no line; on again: the last result in the menu.

## 2. Open questions and known bugs

For the user:
- **O-29 A start while testing gives no feedback from the menu or the shortcut.** The Touch Bar and the menu bar item show the needle, but on a Mac without either shown, pressing the shortcut again looks like nothing happened. [Recommended: show the "Testing internet speed…" alert again, no second test.]

Suspected, found reading the code, NOT seen live:
- **B-22 A tool killed by a signal we didn't send counts as cancelled (breaks ST-07).** `runTool` maps any `uncaughtSignal` end to SIGTERM, so a networkQuality crash ends with no alert and no failure line: the needle stops and the item goes idle. [Fix: count only Penknife's own cancel as silent.] Low priority; fix without asking per the routine-work rule when touched next.

Not measured (check live; nothing to decide yet):
- No timeout of our own: if networkQuality never ends (a stalled network, a captive portal), "testing…" stays until the module is turned off or Penknife quits. Whether networkQuality has its own limit is not measured.
- A failure keeps the old result under it, with its old time (ST-08): by design, but not asked.

## 3. Rejected / out of scope (do not rebuild)

- History, choosing servers, Ookla (R-10).
- Capping the test with `-M` (wrong numbers, R-10).
- A static "…" or "speedometer + …" look while testing; animated SF Symbol effects (60 fps, 2–5 % CPU) (R-10).

## 4. Test plan (step B)

**Done 2026-11-19** (autonomous routine work): as-is tests + S1–S3 in `PenknifeTests/SpeedTestRulesTests.swift`, 231 pass in all; each rule broken on purpose made its test fail (mutation run: rating band, one direction enough, bits → Mbps, failure line, date when not today, stored result, one decimal under 10, menu bar sequence only after a test, unit on one line); no behavior change. Each seam is a pure function the code calls with the same values as before.

- **Testable as-is:** `ModuleID.speedTest` (ST-01); `SpeedText`, `Result.rating`, `speeds`, `details` (ST-05).
- **S1 Output and storage** (ST). `parse(_:now:)` (was private), `load(from:)`, `save(_:to:)`, `init(defaults:)`. Covers ST-04, ST-06.
- **S2 Menu lines** (ST, SM, MR). `SpeedTestModule.menuLines(isRunning:failed:result:isToday:)`, used by both menus (they had the same code twice). Covers ST-08.
- **S3 Menu bar sequence and looks** (MR). `MenuBarReadings.speedSteps(isRunning:failed:hasResult:wasTesting:)` on top of `BarLooks.speedSteps` (the item had its own copy of the Touch Bar's sequence and needles), `speedLook(phase:needleStep:result:)`. Covers ST-09.

Manual only (no seam worth it): ST-02, ST-03, ST-07, ST-11 (the tool, alerts and observers).

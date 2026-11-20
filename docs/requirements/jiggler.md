# Mouse Jiggler — requirements (current behavior)

Source of truth for what the Mouse Jiggler (moving the mouse after a pause, the key it presses, following the screen lock, its menu item, shortcut, dot and settings) must do TODAY (main at 7bafb5b). The history behind each rule stays in `docs/REQUIREMENTS.md` (R-3, R-24; R-11, R-15, R-19, R-20 for cost, modules, accessibility, alerts and dots) and `docs/DECISIONS.md` (Jiggler without event tap, Jiggler follows the lock, Jiggler key, Jiggler interval, Menu bar dots); where they disagree with this file, this file wins. Written 2026-11-19 from the code at 7bafb5b and those docs: sixth module of "complete requirements per module + tests that validate them" (user, 2026-11-17), after the microphone, the Touch Bar, the screenshot, the recording and the clipboard. The Touch Bar's jiggler button and the game it opens are in `touchbar.md` (TB-20, TB-47) and are only referenced here.

**How to use it.** Before changing anything that touches the jiggler, read the rules of the parts you change. After the change, run `scripts/test.sh` and check EVERY affected rule by its Verify line, not only the new behavior. A new or changed wish → change the rule here, and keep the story in REQUIREMENTS.md.

Code abbreviations: JM = `Modules/JigglerModule.swift`, LM = `Modules/LockModules.swift`, SV = `Settings/SettingsView.swift` (JigglerIntervalPicker, JigglerKeyPicker, module options), SM = `App/StatusMenu.swift`, MO = `Core/Module.swift`, MGR = `Core/ModuleManager.swift`, EP = `Core/EventPoster.swift`, HUD = `Core/HUD.swift`, PM = `Core/Permissions.swift`.

**Tests:** none of its own yet (step B below). Already covered elsewhere: the F12 default (TouchBarRulesTests, TB-58) and the Touch Bar button look (TB-20). A test must never call `JigglerModule.start()`, `toggle()` or `activate()` (they ask for Accessibility and move the real mouse), never post events, never write `UserDefaults.standard` (use `MemoryDefaults` as in ScreenshotRulesTests).

## 1. Rules

### A. The module

- **JG-01** Module "Mouse Jiggler" / "Mover ratón" (symbol `computermouse`, blue in Settings), on by default, needs Accessibility. Description: "Keeps you shown as active by nudging the mouse when you stop for a while." / "Te mantiene como activo moviendo el ratón cuando haces una pausa."
  Source: R-3 · Code: MO:title, summary, symbol, defaultOn; JM:needsAccessibility; SV:tint · Verify: manual — Settings › Mouse Jiggler: the switch is on and the text reads as above.
- **JG-02** One action, "Mouse Jiggler" / "Mover ratón", a toggle: in the Penknife menu with a checkmark while on, and as the shortcut `toggleJiggler` (default F12, customizable; also with Fn from the Touch Bar's F keys, TB-58); the Touch Bar button runs the same toggle (TB-20). Shown and registered only while the module is on.
  Source: R-3 "Mouse jiggler (toggle)"; Phase 1 "F12 from the Touch Bar works" · Code: JM:actions; Shortcuts.swift:7; SM (enabledActions, state); MGR:setShortcuts · Verify: **auto** — "default shortcuts" (F12, TouchBarRulesTests); manual — press F12: the alert says "Mouse Jiggler on" and the menu item has a checkmark; F12 again: "Mouse Jiggler off".
- **JG-03** Turning it on needs Accessibility. With it: the jiggler is on and the alert "Mouse Jiggler on" / "Mover ratón activado" shows (`cursorarrow.motionlines`, "on" kind). Without it: the first time in a session macOS's prompt shows; each time the alert "Mouse Jiggler" — "Open Settings › Permissions to allow it" / "Abre Ajustes › Permisos para permitirlo" (O-31, 2026-11-19) / "Necesita el permiso de Accesibilidad" (`lock.fill`, permission kind) shows and the jiggler stays off (never silently does nothing). Turning it off by hand shows "Mouse Jiggler off" / "Mover ratón desactivado" (`cursorarrow`, "off" kind); being turned off by the lock (JG-08, JG-09) or by the module going off (JG-12) shows nothing. All these alerts are of the "Mouse Jiggler" type: turning that type off in Settings hides them all, the permission one included (R-20).
  Source: R-3 "If the Accessibility permission is missing, the jiggler says so instead of doing nothing"; R-20 alert types · Code: JM:toggle, activate, deactivate; PM:ensureAccessibility; HUD:AlertCategory.jiggler · Verify: **auto** (S3) — with a fake permission false: activate → off, one permission alert; true → on, one "on" alert; deactivate → no alert; manual — F12 twice: "on", then "off".
- **JG-04** The on/off state is not saved: after quitting, Penknife starts with the jiggler off, and it is turned on at launch only by following the lock (JG-08).
  Source: R-3 "launching at login counts as unlocking" · Code: JM:isActive (not stored), start · Verify: manual — with "Turn on when unlocking…" off, turn the jiggler on, quit and open Penknife: it is off.

### B. Moving the mouse

- **JG-05** No event tap and no Input Monitoring: while on, a one-shot timer (at least 0.5 s, 1 s tolerance, common run-loop modes) wakes when the next jiggle could be due and reads the system's idle time (seconds since any input in the user's session, `CGEventSource.secondsSinceLastEventType`). Idle ≥ the interval (JG-10) → it jiggles and waits the whole interval again; else it waits only what is left (interval − idle). So: at most one wakeup per interval while on, none while off, and nothing moves while you are using the Mac.
  Source: R-3 "moves the mouse after 10 s idle"; R-11; D: Jiggler without event tap · Code: JM:schedule, tick · Verify: **auto** (S2) — `JigglerTiming.next(idle:interval:)`: idle 12, interval 10 → jiggle, wait 10; idle 3 → no jiggle, wait 7; idle 9.8 → wait 0.5 (the floor); manual — turn it on, don't touch anything: after 10 s the pointer makes a tiny square.
- **JG-06** A jiggle, from where the pointer is: a 3 px square (right, down, left, up, back to the start), one move every 80 ms; then the chosen key (JG-07), Caps Lock pressed twice 100 ms apart so its state doesn't change. The pointer ends where it was. If the user moves the mouse during the square (pointer more than 3 px from the last move), the square stops there and no key is pressed (B-19). A jiggle never starts while another is still running. Same movement as the old Hammerspoon script.
  Source: R-3; D: Jiggler without event tap ("Same movement as Hammerspoon (3 px square + Caps Lock twice)") · Code: JM:jiggle; EP:mouseLocation, moveMouse, key · Verify: **auto** (S2) — `JigglerMotion.steps(from: (100, 100))` = (103,100), (100,103), (97,100), (100,97), (100,100); (B-19) `JigglerMotion.perform`: untouched → all 5 moves; grabbed after the first → stops; clamped at an edge → all 5; manual — watch the pointer after 10 s idle: it moves a little and comes back; Caps Lock's light stays as it was.
- **JG-07** "Also press" / "Pulsar también" (`jiggler.key`), so Teams and Slack also see keyboard activity; only keys that type nothing: "Caps Lock (twice)" / "Bloq Mayús (dos veces)" (default, and any unknown value), "Shift" / "Mayúsculas", "Control", "Option" / "Opción", "F18", "None (mouse only)" / "Ninguna (solo ratón)". Key codes 57, 56, 59, 58, 79; none presses nothing. Read at each jiggle, so a change applies to the next one. F15 is not offered (F14/F15 change brightness on Apple keyboards).
  Source: R-3 "THE KEY IS CONFIGURABLE (user, 2026-11-13)"; D: Jiggler key · Code: JM:JigglerKey; SV:JigglerKeyPicker · Verify: **auto** — `JigglerKey.allCases` in that order; `keyCode` and `presses` (Caps Lock 2, the others 1, none no key); (S1) `JigglerKey.current(in:)`: nothing stored or "x" → capsLock.

### C. Interval, lock and Lock Screen

- **JG-08** "Turn on when unlocking, off when locking" / "Activar al desbloquear y desactivar al bloquear" (`jiggler.followsLock`, on by default). While the module is on and this is on, Penknife listens to the system's "screen is locked" (→ jiggler off, no alert) and "screen is unlocked" (→ jiggler on, with JG-03's alerts, the permission one included) notifications; the module starting counts as unlocking (at launch, at login, and when the module is switched on), so the jiggler turns on. With it off, locking and unlocking never touch the jiggler (nor does Lock Screen, JG-09). Switching the option on doesn't turn the jiggler on by itself; it waits for the next unlock. The notifications are listened to only while the module and the option are both on.
  Source: R-3 "Jiggler follows the lock (changed 2026-11-13)"; D: Jiggler follows the lock; R-15 · Code: JM:followsLock, start, updateLockObservers · Verify: **auto** (S3) — fake lock center: start with followsLock on → on and observing; "locked" → off; "unlocked" → on; option off → no observers, lock/unlock change nothing; stop → no observers; manual — jiggler on, ⌃⌘Q, unlock: the alert says "Mouse Jiggler on".
- **JG-09** Penknife's Lock Screen action (F6, menu, Touch Bar) turns the jiggler off first when it follows the lock, then locks; with the option off it leaves the jiggler as it is. The Lock Screen module's description says so: "Locks the screen and turns off Mouse Jiggler." / "Bloquea la pantalla y desactiva «Mover ratón»."
  Source: R-3 "Penknife's lock action turns it off before locking … when off, neither locking nor Penknife's lock action touch the jiggler" · Code: LM:LockScreenModule.actions; MO:summary · Verify: **auto** (S4) — Lock Screen with a fake locker: followsLock on → jiggler off before the lock; off → unchanged; manual — jiggler on, F6, unlock: it is on again (JG-08).
- **JG-10** "Move the mouse after" / "Mover el ratón tras" (`jiggler.interval`): 10 seconds (default), 30 seconds, 1 minute, 2 minutes, 5 minutes, written by the system's duration format in the Mac's language ("10 segundos", "1 minuto"). Any other stored value means 10 s. Changing it while the jiggler is on counts again from that moment, so a shorter time applies at once.
  Source: R-24 IMPERATIVE (user, 2026-11-13); D: Jiggler interval · Code: JM:intervals, idleThreshold, intervalChanged; SV:JigglerIntervalPicker · Verify: **auto** — `JigglerModule.intervals` = [10, 30, 60, 120, 300]; (S1) `JigglerModule.interval(in:)`: nothing, 0 or 45 → 10; 120 → 120; manual — set 30 s: no jiggle at 10 s idle, one at 30 s.

### D. Settings, menu bar, module off

- **JG-11** The Mouse Jiggler page in Settings, in this order: "Turn on when unlocking, off when locking" (JG-08), "Move the mouse after" (JG-10), "Also press" (JG-07). General › Accessibility explains: "Needed for the mouse jiggler, the meeting mute shortcuts and dialog detection." / "Necesario para mover el ratón, los atajos para silenciar reuniones y la detección de diálogos."
  Source: R-3; R-24; R-16 · Code: SV:options (.jiggler); GeneralTab.swift:68 · Verify: manual — Settings › Mouse Jiggler shows those three rows in that order.
- **JG-12** Turning the module off stops everything at once: the timer, the lock notifications, the jiggler (off, no alert); the menu item and the shortcut go away; the Touch Bar button is hidden (TB-08) and the menu bar dot too (JG-13). Turning it back on starts it as at launch (JG-08). A module that is off holds no timer and no observer.
  Source: R-15 "A module that is off uses no CPU/RAM: no timers, observers or event taps" · Code: JM:stop, deactivate, updateLockObservers; MGR:setEnabled · Verify: **auto** (S3) — start, stop: no timer, no observers, off; manual — module off: F12 does nothing and the dot is gone.
- **JG-13** The bottom of the two dots beside the menu bar icon (system blue, 4 pt): filled while the jiggler is on, a 1 pt ring while it is off; shown only while the module is on and "status dots" are on (`menuBar.statusDots`, on by default); the microphone's dot stays on top. VoiceOver reads the icon's value "Mouse Jiggler on" / "Mover ratón activado" or "Mouse Jiggler off" / "Mover ratón desactivado". Redrawn only when the state changes (observation, no timer); kept while recording, next to the time.
  Source: R-20 MENU BAR DOTS (IMPERATIVE, 2026-11-13); D: Menu bar dots · Code: SM:trackState, update, icon, showRecording · Verify: **auto** — `StatusMenu.dotsOn(in:)`: nothing stored → true; manual — F12: the bottom dot fills; F12: a ring. See "For later: Bigger dots" in REQUIREMENTS.md.
- **JG-14** Cost: off = nothing runs; on = one timer wakeup per interval at most, plus the lock notifications while JG-08 is on. Nothing reads keys or the pointer between wakeups.
  Source: R-11; D: Jiggler without event tap ("≤1 wakeup per ~10 s while on, none while off") · Code: JM:schedule, tick · Verify: measure — `measure-resources` with the jiggler on and the Mac idle: about one wakeup per interval; none with it off.
- **JG-15** Privacy: no network; it reads only how many seconds since the last input (never which keys or where), and uses Accessibility only to post its own mouse moves and key.
  Source: general privacy rule; D: Jiggler without event tap ("no Input Monitoring permission") · Code: JM (no URLSession, no event tap) · Verify: **auto** — a source check: no `URLSession`, `CGEvent.tapCreate` or `addGlobalMonitorForEvents` in `JigglerModule.swift` (as CB-30).
- **JG-16** Every visible string has its Spanish translation (the ones quoted above), VoiceOver strings too.
  Source: general (Spanish always) · Code: Localizable.xcstrings · Verify: **auto** — catalog test: each JG string has an "es" value.
- **JG-17** While Penknife itself waits for the user — a recording (from its countdown to Stop), the capture overlay, or the clipboard panel — a due jiggle is skipped (no move, no key) and the next wait starts as usual; the jiggler stays on, no alert. Otherwise the square would be recorded, or the pointer could pick another row or window under it.
  Source: O-23 (user: "sip", 2026-11-19) · Code: JM:holdsOff, tick; AppDelegate (screenshot.session / recording, clipboard.isPanelOpen) · Verify: **auto** — test "JG-17 O-23" (fake Mac: held off → nothing posted, still scheduled; released → moves); manual — start a recording, leave the Mac idle past the interval: no cursor twitch in the file.

## 2. Open decisions, questions and known bugs

Questions for the user (asked 2026-11-19; recommendation in brackets):
- DONE 2026-11-19 (user: "sip" = every recommendation), now JG-17: **O-23 The jiggler also moves the pointer while Penknife is recording the screen.** With the Mac idle for the interval during a screen recording (a demo where you stop to talk), the 3 px square and the key are recorded too (a small cursor twitch every 10 s). The same happens over the capture overlay (the window under the pointer can change) and the clipboard panel (hover can pick another row if the pointer sits on a row's edge). [Skip the jiggle while a recording runs or one of Penknife's own panels is open; it is waiting for you there anyway. Small change; or leave as is.]
- DECIDED 2026-11-19 (user: "sip"), kept as is: **O-24 An alert at every unlock.** With JG-08 on, every unlock (and every launch) shows "Mouse Jiggler on"; without Accessibility, every unlock shows "Open Settings › Permissions to allow it" / "Abre Ajustes › Permisos para permitirlo" (O-31, 2026-11-19). [Leave as is: it is how you know it is on, and the type can be hidden in Settings › Alerts.]

Ideas for later (not designed):
- **Stop time** (user, 2026-11-19): each person picks a time when the jiggler turns itself off (e.g. 18:00). Details and open points in REQUIREMENTS.md › Future ideas "Jiggler stop time". Phone remote control was discussed and not chosen (REQUIREMENTS.md › Rejected).

Not measured (check live; nothing to decide yet):
- Whether Teams and Slack really count the jiggle as activity with each key choice (the user is happy with Caps Lock ×2; Shift, Control and Option are posted as plain key presses, not as modifier changes).
- Whether the system idle time counts Penknife's own moves (if it didn't, a jiggle would still happen once per interval; same result).
- Idle cost with the jiggler on not measured since 2026-11-13 (JG-14).

Known bugs (found reading the code on 2026-11-19, not seen live):
- **B-19 FIXED 2026-11-19.** Moving the mouse during a jiggle pulled the pointer back (the square's points were fixed at the start and posted over 400 ms). Now before each move the pointer is compared with where the last move put it; more than 3 px off (one step, so a step clamped at a screen edge doesn't count) → the square stops and the key is not pressed (the user is active). Test: "B-19 the square stops as soon as the user moves the mouse" (seen to fail with the check removed).

Doc conflicts (code wins; marked in REQUIREMENTS.md/DECISIONS.md on 2026-11-19):
- R-3 "moves the mouse after 10 s idle" → JG-10 (a setting since R-24, 10 s is the default).
- R-3 "Current behavior and shortcuts: dotfiles `macos/hammerspoon/init.lua`" → this file.
- D: Jiggler without event tap "≤1 wakeup per ~10 s" → per interval (JG-14).

## 3. Rejected / out of scope (do not rebuild)

- An event tap or Input Monitoring to notice activity (D: Jiggler without event tap: idle time is enough).
- Polling every second (D: Jiggler without event tap).
- Keys that type something, and F15 (D: Jiggler key).
- The "End of day" action (R-3: replaced by following the lock).
- Remembering on/off across launches (JG-04: launch counts as unlocking).

## 4. Test plan (step B)

**Done 2026-11-19** (user: "go"): S1–S4 in `PenknifeTests/JigglerRulesTests.swift` (11 tests; JG-03, 05, 06, 07, 08, 09, 10, 12), 193 pass in all; each rule broken on purpose made its test fail (mutation run); no behavior change. S3 took the shape of the other modules: `JigglerModule(env:)` with a `JigglerEnvironment` (`live` = the real Mac: defaults, permission, alerts, lock observation, one-shot timer, idle seconds, pointer, mouse moves, key), not a long init. Proposed 2026-11-19. Same method as the other modules: each seam is a pure rule the app keeps calling with exactly the same reads, tests pass plain values, each test is named after its rule and is seen to fail with its rule broken on purpose (one mutation run per step). No S-step changes behavior; B-19 and O-23/O-24 only after the user's yes, each in its own commit, after the S-step that can guard it.

- **Testable as-is:** `JigglerKey.allCases`, `keyCode`, `presses` (JG-07); `JigglerModule.intervals` (JG-10); `ModuleID.jiggler` symbol and `defaultOn` (JG-01); `StatusMenu.dotsOn(in:)` (JG-13); the catalog and source checks (JG-15, JG-16).
- **S1 Settings readers** (JM). `JigglerKey.current(in:)`, `JigglerModule.interval(in:)`, `JigglerModule.followsLock(in:)` (default true); the app passes `.standard`. Covers JG-07, JG-08 (default), JG-10.
- **S2 Timing and motion** (JM). `JigglerTiming.next(idle:interval:) -> (jiggle: Bool, wait: TimeInterval)` used by `tick`; `JigglerMotion.steps(from:)` used by `jiggle`. Covers JG-05, JG-06; then guards B-19.
- **S3 Injected environment** (JM). `JigglerModule(defaults:permission:alerts:lockCenter:scheduler:idle:poster:)` with the app's defaults; a fake lock center that posts "locked"/"unlocked", a fake scheduler (no real timer), a fake poster (no real events). Covers JG-03, JG-08, JG-12; then guards O-23.
- **S4 Lock Screen** (LM). `LockScreenModule(jiggler:lock:)` with an injected lock function. Covers JG-09.

Manual only (no seam worth it): JG-02 (live part), JG-04, JG-11, JG-13 (look), JG-14 (measure).

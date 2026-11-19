# Lock Screen — requirements (current behavior)

Source of truth for what the Lock Screen module (locking the Mac at once from the menu, a shortcut or the Touch Bar) must do TODAY (main after a42d997). The history behind each rule stays in `docs/REQUIREMENTS.md` (R-3; Phase 2 for the Touch Bar slot; R-11, R-15, R-19 for cost, modules and accessibility) and `docs/DECISIONS.md` (Lock screen, Jiggler follows the lock).

**How to use it.** Before changing anything that touches locking, read the rules of the parts you change. After the change, run `scripts/test.sh` and check EVERY affected rule by its Verify line, not only the new behavior. A new or changed wish → change the rule here, and keep the story in REQUIREMENTS.md.

Code abbreviations: LM = `Modules/LockModules.swift` (ScreenLocker, LockScreenModule), MO = `Core/Module.swift`, SC = `Core/Shortcuts.swift`, SV = `Settings/SettingsView.swift`, PM = `Core/Permissions.swift`, EP = `Core/EventPoster.swift`, JM = `Modules/JigglerModule.swift`, BL = `TouchBar/BarLayout.swift`, TM = `TouchBar/TouchBarModule.swift`, SM = `App/StatusMenu.swift`.

**Tests:** `PenknifeTests/LockRulesTests.swift` (3 tests; LK-01, LK-02); the jiggler before the lock (LK-03) is JG-09 in `JigglerRulesTests`; the F6 default and the Touch Bar button in `TouchBarRulesTests` (TB-08, TB-58). A test must never call `ScreenLocker.lock()` (it locks this Mac) or post keys.

## 1. Rules

- **LK-01** Module "Lock Screen" / "Bloquear pantalla" (symbol `lock`, indigo in Settings), on by default, works with or without a Touch Bar, no permission of its own. One action "Lock Screen" (`lock`) in Penknife's menu with the shortcut `lockScreen` (default F6, Settings › Shortcuts). Description: "Turns off the mouse jiggler and locks the screen." / "Desactiva «Mover ratón» y bloquea la pantalla." Its Settings page has no options. No alert, no sound of its own: the lock screen is the feedback.
  Source: R-3 "lock screen"; R-15 · Code: MO:title, summary, symbol; SV:tint, case .lockScreen; LM:actions; SC:lockScreen · Verify: **auto** — symbol, `defaultOn`, not `needsTouchBar`, one action with `.lockScreen`, no Accessibility; F6 in TouchBarRulesTests.
- **LK-02** Locking: the system's own call (`SACLockScreenImmediate` in the private login.framework, what the Apple menu's "Lock Screen" uses; no permission) locks at once. Only if that call is missing or fails, Penknife presses ⌃⌘Q (macOS's Lock Screen shortcut), which needs Accessibility: without it, macOS's prompt shows once per launch and nothing else happens (B-23).
  Source: D: Lock screen · Code: LM:ScreenLocker.lock, lock(system:accessibility:pressKeys:); PM:ensureAccessibility; EP:key · Verify: **auto** (S1) — the call exists on this macOS; call 0 → no keys, no permission asked; call fails or missing → keys only with Accessibility; key 12 with ⌃⌘; manual — F6: the screen locks at once.
- **LK-03** Before locking, the jiggler is turned off when it follows the lock (`jiggler.followsLock`), so it doesn't run while locked; with that option off it is left as it is. After unlocking, the jiggler's own rule turns it back on (JG-08). This is JG-09; the rule lives in `jiggler.md`.
  Source: R-3 "Penknife's lock action turns it off before locking" · Code: LM:LockScreenModule.actions; JM:followsLock, deactivate · Verify: see JG-09 (auto, S4 there).
- **LK-04** Touch Bar: TB-23 (`lock.fill`, VoiceOver "Lock Screen", a tap runs this action; color #7176EB, TB-09; in the old "End of day" slot, TB-07).
  Source: Phase 2; R-26 · Code: BL:BarItem.lock; TM:run(.lockScreen) · Verify: see TB-23.
- **LK-05** Off: switching the module off removes the menu action, the shortcut and the Touch Bar button (TB-08). Nothing runs in either state: no timer, no observer; the lock call is looked up only the first time it is used.
  Source: R-11, R-15 · Code: LM:start, stop, lockFunction (lazy); SM; TM:rebuildButtons · Verify: manual — module off: F6 does nothing, no menu item, no button.

## 2. Open questions and known bugs

Suspected, found reading the code, NOT seen live:
- **B-23 Without the system call and without Accessibility, nothing tells you why it didn't lock (LK-02).** After the first prompt, later presses do nothing at all. It only matters if a macOS update removes `SACLockScreenImmediate` (the test LK-02 would fail first, on this Mac). [Fix if it ever happens: the Jiggler's "Needs the Accessibility permission" alert.] Low priority.

Nothing open for the user.

## 3. Rejected / out of scope (do not rebuild)

- The "End of day" action (R-3: replaced by the jiggler following the lock).
- Screen saver, sleeping the displays or logging out instead of locking (not asked).

## 4. Test plan (step B)

**Done 2026-11-19** (autonomous routine work): S1 in `PenknifeTests/LockRulesTests.swift`, 234 pass in all; each rule broken on purpose made its test fail (mutation run: keys without Accessibility, keys after a successful call); no behavior change. The seam is a pure function the app calls with the real call, permission and key press.

- **Testable as-is:** `ModuleID.lockScreen`, `LockScreenModule.actions` (LK-01); JG-09 (S4 in jiggler.md).
- **S1 Lock order** (LM). `ScreenLocker.lock(system:accessibility:pressKeys:)`, `hasSystemLock`, `fallbackKey`, `fallbackFlags`. Covers LK-02.

Manual only: LK-05 (module lifecycle).

# Keep Awake — requirements (current behavior)

Source of truth for Keep Awake / "Mantener despierto" (R-39, approved 2026-11-22: user "yep" to the proposal). Code: `Modules/KeepAwakeModule.swift` (KA). Tests: `PenknifeTests/KeepAwakeRulesTests.swift` (fake Mac: never takes a real assertion nor listens to the real lock).

## Rules

- **KA-01** Module "Keep Awake" / "Mantener despierto" (symbol `cup.and.saucer`, green in Settings (designer: brown would match Native Dialogs)), on by default, second in the module order (after Mouse Jiggler), no permission needed. Description: "Keeps the Mac and the display awake without moving the mouse. Turns off when the Mac locks." / "Mantiene el Mac y la pantalla despiertos sin mover el ratón. Se desactiva al bloquear el Mac." One toggle action "Keep Awake" in the Penknife menu (checkmark while on) and the shortcut `toggleKeepAwake` with NO default key (Settings › Shortcuts). No options page, no Touch Bar button, no menu bar dot.
  Verify: **auto** — "KA-01"; GN-08 order test.
- **KA-02** On = one power assertion `PreventUserIdleDisplaySleep` (what `caffeinate -d` takes): no idle display sleep, so no idle system sleep. No timer, no polling, never moves the mouse or presses keys (Teams/Slack may still show you as away; that is the jiggler's job). Closing the lid or the Apple menu's Sleep still sleep the Mac. macOS releases it if Penknife quits or crashes.
  Verify: **auto** — "KA-02"; manual — `pmset -g assertions` shows "Penknife Keep Awake" while on, nothing when off.
- **KA-03** Alerts (own type "Keep Awake", hideable in Settings › Alerts): turning it on by hand → "Keep Awake on" / "Mantener despierto activado" (`cup.and.saucer.fill`, on); off by hand → "Keep Awake off" / "Mantener despierto desactivado" (`cup.and.saucer`, off). If macOS refuses the assertion → "Couldn't keep the Mac awake" / "No se pudo mantener el Mac despierto" (error) and it stays off.
  Verify: **auto** — "KA-02 KA-03", "KA-03 macOS refuses".
- **KA-04** Not saved: Penknife always starts with it off.
- **KA-05** Locking the Mac (any way, Penknife's Lock Screen included) turns it off silently. The lock notification is listened to only while it is on.
  Verify: **auto** — "KA-05".
- **KA-06** Turning the module off releases the assertion and the observer at once, silently; the menu item and the shortcut go away.
  Verify: **auto** — "KA-06".
- **KA-07** Cost: zero CPU in both states (one assertion + one notification observer while on, nothing while off).
- **KA-08** Every visible string has Spanish. Verify: **auto** — MIC-71 (whole catalog).

## For later (ideas, not designed)
- Durations ("1 hour", "until 18:00"), shared with the jiggler stop time idea.

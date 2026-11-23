# Penknife — plan

The ordered task list. Read this first after `/clear`. Every checkpoint updates it (done items move to "Done", new approved work goes in order). Details live in `REQUIREMENTS.md` and `requirements/<module>.md`.

## Now
- Menu icons gone on macOS 27 (user asked 2026-11-23): not our change; macOS 27 hides menu item symbols by default (`NSMenuItem.preferredImageVisibility`, new in the 27 SDK). User chose "lo nativo de apple": no code change (the OS decides). `docs/screenshots/menu.png` retaken 2026-11-23 (1.16 menu, no icons, no personal data); committed locally, NOT pushed.

## Next, in order
- Jiggler stop time: proposal sent 2026-11-23 (Settings row "Turn off at" + time, off by default, daily, one timer, off on wake if missed, alert), waiting for the user's yes.

## To choose
All product ideas of 2026-11-22 are done or rejected.

## Later (ideas only)
- Jiggler stop time ("stop jiggling at 6:00 pm").

## Done recently
- 2026-11-23: security review of `disable-library-validation`: KEEP it. Cannot be removed while self/ad-hoc signed (no Team ID); risk moderate-to-low (see DECISIONS, Sparkle updates). Real fix only with a paid Developer ID.
- 2026-11-23 (builds 387–388, local, NOT published; goes in the next release): MAC-80 Add Step › Return (a Key step with ↩ already set). Designer approved (+ VoiceOver label). User: Enter on a Mac = Return, "entonces return ya está". User confirmed it works (2026-11-23).
- 2026-11-23: 1.19 published (build 385): MAC-77 a new step scrolls into view (QA passed). MAC-78 a macro can be allowed in password fields, per macro, with a warning alert (QA passed UI/alert/persistence; real typing into a password field and Esc under secure input NOT verified: user to try). MAC-79 select several steps (click, ⌘, ⇧), copy/paste within or across macros, in-app copy that leaves the system clipboard alone (QA passed). Editor min width 620 → 680 (the detail was cut). User confirmed all of it works (2026-11-23), password fields included.
- 2026-11-23: 1.18 published (build 375): MAC-76 new macro steps go below the selected step: QA passed 1–5 + drag + typing; context menu and MAC-74(c) not re-checked (QA stopped when Safari came to the front). Designer: system unemphasized selection color. User confirmed it works (2026-11-23).
- 2026-11-23: REJECTED: split one clipboard pin into parts for a macro (user: "mejor no"). Macro data rows already cover several values.
- 2026-11-23: 1.17 published: emoji search in the icon editor (CB-37; macOS's Emoji & Symbols search can't reach a menu bar app), macro editor fixes (MAC-74: paste from Clipboard History into the editor, emoji first pick, click elsewhere drops focus), emoji icons not clipped (MAC-75), panel search refocuses after the pin editor. QA passed, designer approved CB-37; user confirmed the fixes and emoji search live ("Listo, fixed").
- 2026-11-23: user confirmed live: hold to talk works (R-41), import keeps everything (R-42), clipboard with more than 5 pins works (CB-36), Keep Awake and the battery bolt work.
- 2026-11-23: 1.16 published (pin, color picker, Copy Text, hold to talk, mute on lock, Keep Awake, export/import settings, Touch Bar fills, pinned rows). Hold to talk (R-41, MIC-89…92) and export/import (R-42, GN-28…31): QA passed on the real Mac (after a fix: build 356 broke the F5 tap, see DECISIONS), security + designer reviewed. User confirmed it works.
- 2026-11-23: Pin a screenshot on screen (R-40, SS-67…73, builds 331–350): Pin button + ⌘P, pin glides to a corner (bottom left by default, setting), stacks; move, resize (invisible 8 pt margin + inner zones, pinch, smart zoom, scroll), grows away from the nearer screen edge; double-click reopens the editor with editable marks; right-click menu; focus after pinning. QA passed, designer approved, user: "funciona muy bien".
- 2026-11-23: Touch Bar battery bolt as soon as the Mac is on power (TB-16; measured: macOS's "is charging" comes ~10 s after "AC Power"). User confirmed it works.
- 2026-11-23: Quick audio output REJECTED (macOS Sound menu already does it).
- 2026-11-22: Keep Awake (R-39, KA-01…08, builds 324–325): own module after Mouse Jiggler, menu toggle + shortcut with no default, one PreventUserIdleDisplaySleep assertion, off at launch and on lock, own alert type, green tile (designer). QA passed all 7 live checks (0 % CPU). User confirmed it works. Note: this Mac runs in English, so the app shows English labels.
- 2026-11-22: Color picker (R-38, SS-63…66, builds 318–322): I in the screenshot overlay + own "Pick Color" shortcut (no default) + menu item; round loupe (variant A, user's choice), exact sRGB hex, ~12 % CPU while moving. QA passed, `ux-ui-designer` APPROVED. User tried it 2026-11-23: "funciona bien".
- 2026-11-22: Mute the mic when the Mac locks (R-37, MIC-86…88, build 314): off by default, Settings › Microphone. Designer approved (shorter footer applied); simulated lock verified (mutes, silent; already muted / option off → nothing). User tried it live: works ("esto también se bloquea"). Also 2026-11-22: user confirmed Teams consent auto-accept (B-3) works on the work Mac.
- 2026-11-22: Clipboard "Pinned rows shown" (CB-36, build 312): 3/5/8/12/All, History keeps 3 rows. Settings approved live by `ux-ui-designer`; the panel with many pins NOT seen live yet (user has 2 pins, empty History; QA wouldn't touch real data) — User confirmed it works live.
- 2026-11-22: Touch Bar fills (O-34): holds fill (variant A), speed test fills, holding Screenshot with the capture open switches to recording (builds 302–309; user: "lo veo bien"; designer + performance reviews passed).
- 2026-11-22: Copy Text from a screenshot (R-36, build 300; user: "funciona muy bien").
- 2026-11-22: design audit of Settings (notes as footers, Monochrome picker, Shortcuts grouped) — committed locally, not pushed.
- 2026-11-22: 1.15 published (Macros).

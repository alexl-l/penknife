# Penknife — plan

The ordered task list. Read this first after `/clear`. Every checkpoint updates it (done items move to "Done", new approved work goes in order). Details live in `REQUIREMENTS.md` and `requirements/<module>.md`.

## Now
- NEXT, APPROVED (user, 2026-11-22: "yep"): **Screenshot → color picker** (product idea #4: copies the hex of the pixel under the pointer). Not designed yet: clarify where it lives (screenshot editor? its own shortcut?) and show rendered variants before building. After it, keep going through "To choose" in the order Claude judges best (user: "sigue en el orden que consideres"). Publish 1.16 at the end of the session.

## Next, in order
- Publish 1.16 at the END of a session, when the user is running low on tokens (user, 2026-11-22: "publiquemos al final"). Contents so far: mute on lock (R-37), Copy Text, Touch Bar fills, hold-to-record with the capture open, pinned rows setting CB-36. Keep adding work to it until then. Nothing pushed yet.

## To choose (product ideas, 2026-11-22, list in `REQUIREMENTS.md` › Product ideas)
Push to talk · pin a capture on screen · export/import settings · keep awake · quick audio output · mic-open warning after a call.

## Later (ideas only)
- Jiggler stop time ("stop jiggling at 6:00 pm").

## Done recently
- 2026-11-22: Mute the mic when the Mac locks (R-37, MIC-86…88, build 314): off by default, Settings › Microphone. Designer approved (shorter footer applied); simulated lock verified (mutes, silent; already muted / option off → nothing). User tried it live: works ("esto también se bloquea"). Also 2026-11-22: user confirmed Teams consent auto-accept (B-3) works on the work Mac.
- 2026-11-22: Clipboard "Pinned rows shown" (CB-36, build 312): 3/5/8/12/All, History keeps 3 rows. Settings approved live by `ux-ui-designer`; the panel with many pins NOT seen live yet (user has 2 pins, empty History; QA wouldn't touch real data) — covered by unit tests only. Ask the user to try it when they have more than 5 pins.
- 2026-11-22: Touch Bar fills (O-34): holds fill (variant A), speed test fills, holding Screenshot with the capture open switches to recording (builds 302–309; user: "lo veo bien"; designer + performance reviews passed).
- 2026-11-22: Copy Text from a screenshot (R-36, build 300; user: "funciona muy bien").
- 2026-11-22: design audit of Settings (notes as footers, Monochrome picker, Shortcuts grouped) — committed locally, not pushed.
- 2026-11-22: 1.15 published (Macros).

# Penknife — plan

The ordered task list. Read this first after `/clear`. Every checkpoint updates it (done items move to "Done", new approved work goes in order). Details live in `REQUIREMENTS.md` and `requirements/<module>.md`.

## Now
- NEXT: pick the next item from "To choose" in the order Claude judges best (user: "sigue en el orden que consideres"); R-40 Pin a screenshot on screen approved 2026-11-23 (rules SS-67…72): BUILT (builds 331–339) with the user's changes of 2026-11-23: pins glide to a corner (bottom left by default, setting; SS-73) and bigger resize zones (SS-69b). QA passed, designer approved. User tried it 2026-11-23 and asked for changes, all built: corner placement ("funciona bien"), growth away from the screen edge ("funciona muy bien"), invisible 8 pt resize margin (SS-69e, "ya funciona bien"), click then pinch / two-finger double-tap (SS-69f, "funcionaaaaa"). Ask the user to try Keep Awake (menu › Keep Awake) and confirm. Publish 1.16 at the end of the session.

## Next, in order
- Publish 1.16 at the END of a session, when the user is running low on tokens (user, 2026-11-22: "publiquemos al final"). Contents so far: Pin a screenshot (R-40), Keep Awake (R-39), color picker (R-38), mute on lock (R-37), Copy Text, Touch Bar fills, hold-to-record with the capture open, pinned rows setting CB-36. Keep adding work to it until then. Nothing pushed yet.

## To choose (product ideas, 2026-11-22, list in `REQUIREMENTS.md` › Product ideas)
Push to talk · export/import settings · mic-open warning after a call.

## Later (ideas only)
- Jiggler stop time ("stop jiggling at 6:00 pm").

## Done recently
- 2026-11-22: Keep Awake (R-39, KA-01…08, builds 324–325): own module after Mouse Jiggler, menu toggle + shortcut with no default, one PreventUserIdleDisplaySleep assertion, off at launch and on lock, own alert type, green tile (designer). QA passed all 7 live checks (0 % CPU). NOT tried by the user yet. Note: this Mac runs in English, so the app shows English labels.
- 2026-11-22: Color picker (R-38, SS-63…66, builds 318–322): I in the screenshot overlay + own "Pick Color" shortcut (no default) + menu item; round loupe (variant A, user's choice), exact sRGB hex, ~12 % CPU while moving. QA passed, `ux-ui-designer` APPROVED. User tried it 2026-11-23: "funciona bien".
- 2026-11-22: Mute the mic when the Mac locks (R-37, MIC-86…88, build 314): off by default, Settings › Microphone. Designer approved (shorter footer applied); simulated lock verified (mutes, silent; already muted / option off → nothing). User tried it live: works ("esto también se bloquea"). Also 2026-11-22: user confirmed Teams consent auto-accept (B-3) works on the work Mac.
- 2026-11-22: Clipboard "Pinned rows shown" (CB-36, build 312): 3/5/8/12/All, History keeps 3 rows. Settings approved live by `ux-ui-designer`; the panel with many pins NOT seen live yet (user has 2 pins, empty History; QA wouldn't touch real data) — covered by unit tests only. Ask the user to try it when they have more than 5 pins.
- 2026-11-22: Touch Bar fills (O-34): holds fill (variant A), speed test fills, holding Screenshot with the capture open switches to recording (builds 302–309; user: "lo veo bien"; designer + performance reviews passed).
- 2026-11-22: Copy Text from a screenshot (R-36, build 300; user: "funciona muy bien").
- 2026-11-22: design audit of Settings (notes as footers, Monochrome picker, Shortcuts grouped) — committed locally, not pushed.
- 2026-11-22: 1.15 published (Macros).

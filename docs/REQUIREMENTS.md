# Penknife — requirements

All-in-one personal macOS menu bar app ("the pocket knife for your Mac") that replaces Hammerspoon, MTMR, noTunes, Maccy and Lightshot. Swift, Apple Silicon, latest macOS. May be published later.

Status: **phase 2 in progress** (phase 1 committed; user said go on 2026-11-13).

## Phases (plan agreed 2026-11-13)
1. Base: Xcode project (menu bar only, macOS 26, es/en), module architecture (R-15), menu bar icon + keyboard menu (R-14), Settings: General / Modules / Shortcuts (R-12, R-16), stable signing, actions (R-3), dialog handoff groundwork (R-4). Review: qa, security, accessibility, performance.
2. Touch Bar (R-1) or F-keys (R-2), music (R-5, R-6), CPU temperature (R-9). `legal-advisor` before reusing MTMR code.
3. Clipboard (R-7).
4. Screenshots (R-8).
Speed test (R-10) and weather (R-13) fit in any phase.

Phase 1 progress (2026-11-13): built, installed in /Applications and reviewed (security, accessibility, performance; fixes applied). Code not committed yet.
- Pending: user's hands-on test (QA agent could not drive the UI: no Accessibility for its shell); logo (menu bar uses an SF Symbol placeholder); test Settings memory release after closing.
- Interim behavior: screenshot = system area capture to clipboard until R-8; "Native dialogs" module off by default until the Touch Bar uses it (phase 2).
- Added for R-19: confirmation HUD duration setting (2/4/8/15 s, default 4 s); Window menu General/Modules/Shortcuts with ⌘1–⌘3.
- F12 from the Touch Bar works (user confirmed 2026-11-13): Fn twins + 0.4 s de-duplication. Default F-key shortcuts clash with system functions on Macs without Touch Bar (accessibility review); kept as the user's Hammerspoon keys. Before making the repo public: license + legal review.

Phase 2 progress (2026-11-13): Touch Bar module built and installed (battery, brightness, keyboard light, jiggler, mic, screenshot, lock, volume, time; color modes; dialog step-aside; Settings toggle "Close sliders and the date automatically"). MTMR must be closed while Penknife's Touch Bar is on.
- Lock button takes the old "End of day" slot (lock.fill icon).
- Sliders approved by the user (2026-11-13); while one is open, all other buttons are hidden.
- Pending: music (R-5, R-6), CPU temp (R-9), weather (R-13).

## Requirements

**R-1 Touch Bar** — agreed
OWN IMPLEMENTATION WRITTEN FROM SCRATCH (confirmed 2026-11-13): MTMR is only a reference for how to call Apple's private Touch Bar APIs; no MTMR code is copied (if that ever seems necessary, `legal-advisor` first). When phase 2 is done, MTMR and Hammerspoon are uninstalled.
Reproduce the current MTMR setup (see the dotfiles repo, `macos/mtmr/`): 12 equal-width buttons, battery · brightness · keyboard light · jiggler · mic · screenshot · end of day · music ‖ weather · CPU temp · volume · time.
- Brightness / keyboard light / volume open a slider from their button position (left half opens rightwards, right half leftwards); slider and close ✕ are one gray element, full bar height, round white knob, track tinted with the item color; closes ~0.4 s after release (at most 1 s after the last change; user found 4 s too slow after touching it, 2026-11-13) or after 4 s if untouched; ✕ closes it.
- Battery tap cycles icon colors: own colors → all white → rainbow left to right (including texts).
- Time in 12 h (h:mm); tap shows the date as DD/MM/YY for 4 s, tap again hides it.
- EASTER EGG (user, 2026-11-13, changed): long press on the time: the penknife (own drawing: red handle, silver blade) writes "Hello Penknife!" in calligraphy (Snell Roundhand) with its tip gliding along a smoothed copy of the ink path (moving average, ~3 s), turns and slashes it right to left; the halves drift apart and the buttons fade back (~5 s). Reduce Motion: static text. A tap ends it. Pac-Man version and confetti marquee discarded.
- No loading placeholders (no hourglass).
- Only active on Macs with a Touch Bar.

**R-2 F1–F12 keys (Mac without Touch Bar)** — agreed
For each F key choose either a Penknife action or its native function (brightness, volume, etc.).

**R-3 Actions (from Hammerspoon)** — agreed
Mouse jiggler (toggle; moves the mouse after 10 s idle), microphone toggle synced with Microsoft Teams and Google Meet, lock screen, screenshot shortcut.
- Jiggler follows the lock (changed 2026-11-13): turns off whenever the Mac locks (Penknife's lock action turns it off before locking) and on whenever it unlocks; launching at login counts as unlocking. On by default, can be turned off in Settings → Modules. Replaces the "End of day" action, which was removed.
- If the Accessibility permission is missing, the jiggler says so instead of doing nothing. Current behavior and shortcuts: dotfiles `macos/hammerspoon/init.lua`.

**R-4 Native dialogs** — agreed
While a sheet, modal window or system prompt is in front, step aside so the Touch Bar shows the app's own native buttons (Save, Delete, Allow…), unchanged (native colors), and come back after. Plain "AXDialog" windows must not count (Warp keeps hidden ones). Event-driven, no polling.

**R-5 Music** — agreed
Music button and taps: 1 play/pause, 2 next, 3 previous; opens the player if closed. The player is selectable (Spotify, Apple Music, others), not only Spotify.

**R-6 Block Apple Music (noTunes)** — agreed
Prevent Apple Music from launching on play; off when Apple Music is the chosen player.

**R-7 Clipboard (Maccy)** — agreed (updated 2026-11-13)
History with search, pin the most used items, global shortcut to open it. Skip concealed/transient items (passwords).
- Stores text, images and files (files as references to the original, not copies).
- Lives in memory only: the history is gone when the Mac restarts (or the app quits).
- Limit by memory used, not by days or count; oldest unpinned items drop first. Default 100 MB (our choice), configurable.
- Manual clear: one item or the whole history.
- Shortcut customizable, default ⌃⌥V.
- PINNED ITEMS ARE NEVER DELETED, NOT BY RESTART, LIMIT OR "CLEAR HISTORY"; ONLY WHEN THE USER REMOVES THEM MANUALLY. They are saved to disk (app's Application Support, owner-only permissions) and do not count toward the memory limit.

**R-8 Screenshots (Lightshot)** — agreed (updated 2026-11-13)
Select an area, annotate (arrows, text, highlight), copy or save. NOTHING is uploaded to the web.
- Shortcut customizable, default F1 (note: on Macs without Touch Bar F1 is brightness; R-2 decides which wins).
- Two buttons: **Copy** (also ⌘C) and **Save** to a folder chosen in Settings (also ⌘S, our choice).

**R-9 CPU temperature** — agreed
Read-only, same value as MacFanPro: SMC key `TCMb` truncated to whole degrees (fallback hottest core key). Refresh ~30 s. No fan control.

**R-10 Internet speed test** — agreed
From the menu bar, using macOS `networkQuality` (replaces Ookla Speedtest).

**R-11 Resources** — agreed, IMPERATIVE
Minimum possible CPU/RAM/battery: event-driven over polling, timers aligned to when data changes, no repeated process spawning where avoidable.

**R-12 Settings** — agreed
A settings window to configure everything, designed so others could use it if published.

**R-13 Weather** — agreed (changed 2026-11-13)
Weather on the Touch Bar from Open-Meteo (free, no account or API key). Replaces the first choice, Apple's WeatherKit, which needs the paid developer account.
- Location from macOS (location permission); only rounded coordinates are sent.
- Refresh ~30 min (our choice); no request while the module is off or the Mac sleeps.
- Show the data attribution ("Weather data by Open-Meteo.com", CC BY 4.0) in Settings/About.

**R-14 Menu bar icon** — agreed
Only the logo, no data next to it.

**R-15 Modules and customization** — agreed, IMPERATIVE
EVERY FUNCTION CAN BE TURNED ON/OFF AND EVERYTHING IS CUSTOMIZABLE (shortcuts included), from Settings (R-12).
- A module that is off uses no CPU/RAM: no timers, observers or event taps.

**R-16 General** — agreed
- Launch at login (on by default, can be turned off).
- Both languages: Spanish and English, following the system language.
- Minimum macOS 26 (Tahoe), the current version on the user's Mac (our choice; analysis in DECISIONS.md).

**R-17 Distribution and updates** — agreed (changed 2026-11-13)
No paid Apple Developer account (user's decision). Without it there is no notarization and no Mac App Store.
- Personal use: self-signed certificate, as now.
- If published: open source on GitHub (build from source, or download a release that Gatekeeper warns about the first time; user opens it via System Settings → Privacy & Security → Open Anyway).
- Updates: Sparkle (works without the paid account; its signing key never goes in the repo). Manual until published.
- Mac App Store discarded: needs the paid account and doesn't allow the private APIs.

**R-18 Open source** — agreed
The repo may become public. NOTHING SENSITIVE CAN BE EXPOSED: no keys, certificates, passwords, personal paths, emails or personal data in code, docs or git history.

**R-19 Accessibility and keyboard** — agreed, IMPERATIVE
The user does not want an accessibility lawsuit, and the more the app works by keyboard the better (faster for them).
- EVERYTHING usable without a mouse: menu, settings, clipboard, screenshot editor; Esc closes, Return confirms, arrows/Tab navigate, visible focus.
- Every function has a customizable shortcut (R-15); Touch Bar functions are also reachable from menu/keyboard.
- VoiceOver labels on every control (Spanish and English); never color alone for state; respects Increase Contrast, Reduce Motion, Reduce Transparency.
- Auto-closing elements (sliders, date) have a setting or non-timed alternative.
- Reference: WCAG 2.2 AA. Every UI change is checked by the `accessibility-reviewer` agent.

**R-20 Confirmation alerts** — agreed (2026-11-13), IMPERATIVE, future
THE CURRENT ON/OFF ALERTS (HUD panel "Mover ratón activado/desactivado", etc.) MUST BE REPLACED; the user finds them ugly. Not designed yet: ask `ux-ui-designer` for native-looking options (e.g. system-style OSD like volume/brightness, menu bar icon change, Touch Bar feedback) and let the user choose. Keep R-19 (VoiceOver announcement, duration setting or non-timed alternative).

## Rejected / out of scope
- Fan control (MacFanPro stays out; risky SMC writes).
- Long press on the time to sleep the Mac (MTMR had it; user said no, 2026-11-13).
- Uploading screenshots to the web.
- Mac App Store (private APIs needed for Touch Bar, brightness, temperature; sandbox blocks controlling other apps).
- Archive extraction (RAR/7Z) — little benefit for the work.
- Names: Hilt (Google shows swords), Lighthouse / Pocket Knife / Clasp / Whittle (taken), Toolkit (too generic).

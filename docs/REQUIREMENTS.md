# Penknife — requirements

All-in-one personal macOS menu bar app ("the pocket knife for your Mac") that replaces Hammerspoon, MTMR, noTunes, Maccy and Lightshot. Swift, Apple Silicon, latest macOS. May be published later.

Status: **agreed, not started** (user said not to code until they say go).

## Phases
1. Base: menu bar app, settings window, stable signing, actions (R-3), dialog handoff (R-4).
2. Touch Bar (R-1) or F-keys (R-2) depending on the Mac; music (R-5, R-6).
3. Clipboard (R-7).
4. Screenshots (R-8).
Speed test (R-10) and temperature (R-9) fit in any phase.

## Requirements

**R-1 Touch Bar** — agreed
Reproduce the current MTMR setup (see the dotfiles repo, `macos/mtmr/`): 12 equal-width buttons, battery · brightness · keyboard light · jiggler · mic · screenshot · end of day · music ‖ weather · CPU temp · volume · time.
- Brightness / keyboard light / volume open a slider from their button position (left half opens rightwards, right half leftwards); slider and close ✕ are one gray element, full bar height, round white knob, track tinted with the item color; closes ~0.4 s after release or after 4 s idle; ✕ closes it.
- Battery tap cycles icon colors: own colors → all white → rainbow left to right (including texts).
- Time in 12 h (h:mm); tap shows the date as DD/MM/YY for 4 s, tap again hides it.
- No loading placeholders (no hourglass).
- Only active on Macs with a Touch Bar.

**R-2 F1–F12 keys (Mac without Touch Bar)** — agreed
For each F key choose either a Penknife action or its native function (brightness, volume, etc.).

**R-3 Actions (from Hammerspoon)** — agreed
Mouse jiggler (toggle; moves the mouse after 10 s idle), microphone toggle synced with Microsoft Teams and Google Meet, lock screen, end of day (stop jiggler + lock after 2 s), screenshot shortcut. Current behavior and shortcuts: dotfiles `macos/hammerspoon/init.lua`.

**R-4 Native dialogs** — agreed
While a sheet, modal window or system prompt is in front, step aside so the Touch Bar shows the app's own native buttons (Save, Delete, Allow…), unchanged (native colors), and come back after. Plain "AXDialog" windows must not count (Warp keeps hidden ones). Event-driven, no polling.

**R-5 Music** — agreed
Music button and taps: 1 play/pause, 2 next, 3 previous; opens the player if closed. The player is selectable (Spotify, Apple Music, others), not only Spotify.

**R-6 Block Apple Music (noTunes)** — agreed
Prevent Apple Music from launching on play; off when Apple Music is the chosen player.

**R-7 Clipboard (Maccy)** — agreed
History with search, pin the most used items, global shortcut to open it. Skip concealed/transient items (passwords).

**R-8 Screenshots (Lightshot)** — agreed
Select an area, annotate (arrows, text, highlight), copy or save. NOTHING is uploaded to the web.

**R-9 CPU temperature** — agreed
Read-only, same value as MacFanPro: SMC key `TCMb` truncated to whole degrees (fallback hottest core key). Refresh ~30 s. No fan control.

**R-10 Internet speed test** — agreed
From the menu bar, using macOS `networkQuality` (replaces Ookla Speedtest).

**R-11 Resources** — agreed, IMPERATIVE
Minimum possible CPU/RAM/battery: event-driven over polling, timers aligned to when data changes, no repeated process spawning where avoidable.

**R-12 Settings** — agreed
A settings window to configure everything, designed so others could use it if published.

## Rejected / out of scope
- Fan control (MacFanPro stays out; risky SMC writes).
- Uploading screenshots to the web.
- Archive extraction (RAR/7Z) — little benefit for the work.
- Names: Hilt (Google shows swords), Lighthouse / Pocket Knife / Clasp / Whittle (taken), Toolkit (too generic).

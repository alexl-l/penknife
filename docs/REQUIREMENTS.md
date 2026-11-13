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

**R-13 Weather** — agreed, blocked until paid Apple Developer account
Weather on the Touch Bar from Apple's native WeatherKit (user's choice).
- WeatherKit needs the paid Apple Developer Program (signed App ID with the WeatherKit capability) and Apple's weather attribution; with the free self-signed certificate it cannot work, so the weather button stays hidden until then.
- Needs location permission. Refresh ~30 min (our choice).

**R-14 Menu bar icon** — agreed
Only the logo, no data next to it.

**R-15 Modules and customization** — agreed, IMPERATIVE
EVERY FUNCTION CAN BE TURNED ON/OFF AND EVERYTHING IS CUSTOMIZABLE (shortcuts included), from Settings (R-12).
- A module that is off uses no CPU/RAM: no timers, observers or event taps.

**R-16 General** — agreed
- Launch at login (on by default, can be turned off).
- Both languages: Spanish and English, following the system language.
- Minimum macOS 26 (Tahoe), the current version on the user's Mac (our choice; analysis in DECISIONS.md).

**R-17 Distribution and updates** — agreed (2026-11-13)
Direct download (notarized, Developer ID) + Sparkle updates; manual updates until published. Mac App Store discarded: the private APIs cannot be removed without losing the core features (see DECISIONS.md).

**R-18 Open source** — agreed
The repo may become public. NOTHING SENSITIVE CAN BE EXPOSED: no keys, certificates, passwords, personal paths, emails or personal data in code, docs or git history.

**R-19 Accessibility and keyboard** — agreed, IMPERATIVE
The user does not want an accessibility lawsuit, and the more the app works by keyboard the better (faster for them).
- EVERYTHING usable without a mouse: menu, settings, clipboard, screenshot editor; Esc closes, Return confirms, arrows/Tab navigate, visible focus.
- Every function has a customizable shortcut (R-15); Touch Bar functions are also reachable from menu/keyboard.
- VoiceOver labels on every control (Spanish and English); never color alone for state; respects Increase Contrast, Reduce Motion, Reduce Transparency.
- Auto-closing elements (sliders, date) have a setting or non-timed alternative.
- Reference: WCAG 2.2 AA. Every UI change is checked by the `accessibility-reviewer` agent.

## Rejected / out of scope
- Fan control (MacFanPro stays out; risky SMC writes).
- Uploading screenshots to the web.
- Mac App Store (private APIs needed for Touch Bar, brightness, temperature; sandbox blocks controlling other apps).
- Archive extraction (RAR/7Z) — little benefit for the work.
- Names: Hilt (Google shows swords), Lighthouse / Pocket Knife / Clasp / Whittle (taken), Toolkit (too generic).

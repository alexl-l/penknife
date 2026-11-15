# Penknife — requirements

All-in-one personal macOS menu bar app that replaces Hammerspoon, MTMR, noTunes, Maccy and Lightshot. Swift, Apple Silicon, latest macOS. May be published later.

Status: **phase 4 done** (2026-11-13). **R-20 alerts + R-24 jiggler interval** built, reviewed (QA, accessibility, performance; fixes applied), approved by the user, committed and pushed (2026-11-13). **R-25** (state icons, battery toggle/hold, tap click) and the smarter Apple Music block (R-6) built, reviewed (QA, performance), tested and approved by the user, committed and pushed (2026-11-13). **R-6 Now Playing** (headphone clicks go to the chosen player) built, tested, approved and committed and pushed (2026-11-13). **R-23 slicing game** built, reviewed (QA, performance), played by the user, committed (2026-11-14; not pushed). **Later (user, 2026-11-14):** lower the game's CPU while playing (~18 %) with Core Animation layers (option A, same look, est. 3–5 %); 30 fps, removing glows, and leaving it as is were the other options. **R-10 speed test** built, reviewed (QA, UX), approved and committed (2026-11-14). Commits since the last push (R-23 game, R-10, R-26, Settings sidebar, docs) are NOT pushed. **R-26 customizable Touch Bar** built, QA'd, tested by the user and committed (2026-11-14). Modules tab redesigned as a System Settings sidebar (user picked variant A of 3 in a live demo, 2026-11-14: "me gusta mucho"); R-26 slow-drag jitter fixed. Settings is now ONE System Settings style sidebar window (user picked variant A of 3 in a live demo, 2026-11-14; "me gusta"): General (start, dots, alerts), Permissions, Shortcuts (full list), the 12 modules (each with its own Shortcut section), About. No toolbar tabs, ⌘1–⌘3 removed. User tweaks: smaller sidebar icons (18 pt); group spacing = the system's (~13 pt; user picked A in a live demo, 2026-11-14: the extra gap, ~32 pt, looked excessive; ~20 pt via row padding discarded). Discarded: General holding Permissions/About (B), no central Shortcuts page (C). **R-23 game CPU** lowered with Core Animation layers (option A): ~4 % while playing (was ~18 %), same look (user, 2026-11-14: "lo veo igual igual"), committed. **Version 1.0** (2026-11-14): version + build in About, build = commit count, `CHANGELOG.md`, tag `v1.0` (commit pushed by the user). **Done (2026-11-14, committed, not pushed):** Settings opens focused (sidebar no longer jumps), system spacing between sidebar groups (user picked A), MIT license + THIRD_PARTY_LICENSES.md + README. Settings memory checked in code. **Sparkle (R-17)** built and tested by the user (2026-11-14), committed, not pushed. **Version 1.1 published** (2026-11-14): GitHub release + live appcast; the user updated 1.0 → 1.1 from the menu ("todo bien"). From now on a release = bump MARKETING_VERSION, CHANGELOG section, commit, tag + push, `scripts/release.sh --publish`, commit + push `docs/appcast.xml`. Release notes show in Sparkle's window on the real 1.1 update (user: nothing empty; QA's blank box was only its local test). MTMR + Hammerspoon uninstalled by the user and their leftovers removed (2026-11-14). Name and MTMR code checked (2026-11-14): low risk, nothing to add (see DECISIONS, License). v1.0 is on GitHub; the social preview upload (by the user) is still pending. Until Sparkle, reinstall with `scripts/install.sh`. MTMR + Hammerspoon uninstalled by the user and their leftovers removed (2026-11-14). Open idea: colored icon tiles in Settings (offered, user kept the current look).

## Phases (plan agreed 2026-11-13)
1. Base: Xcode project (menu bar only, macOS 26, es/en), module architecture (R-15), menu bar icon + keyboard menu (R-14), Settings: General / Modules / Shortcuts (R-12, R-16), stable signing, actions (R-3), dialog handoff groundwork (R-4). Review: qa, security, accessibility, performance.
2. Touch Bar (R-1) or F-keys (R-2), music (R-5, R-6), CPU temperature (R-9). `legal-advisor` before reusing MTMR code.
3. Clipboard (R-7).
4. Screenshots (R-8).
Speed test (R-10) and weather (R-13) fit in any phase.

Phase 1 progress (2026-11-13): built, installed in /Applications and reviewed (security, accessibility, performance; fixes applied). Code not committed yet.
- Settings memory: code releases the window on close (performance review, 2026-11-14; no live cycles, the agent can't drive the UI). Hands-on test done by the user; logo done in R-21.
- Interim behavior: screenshot = system area capture to clipboard until R-8; "Native dialogs" module off by default until the Touch Bar uses it (phase 2).
- Added for R-19: confirmation HUD duration setting (2/4/8/15 s, default 4 s); Window menu General/Modules/Shortcuts with ⌘1–⌘3.
- F12 from the Touch Bar works (user confirmed 2026-11-13): Fn twins + 0.4 s de-duplication. Default F-key shortcuts clash with system functions on Macs without Touch Bar (accessibility review); kept as the user's Hammerspoon keys. Before making the repo public: license + legal review.

Phase 2 progress (2026-11-13): Touch Bar module built and installed (battery, brightness, keyboard light, jiggler, mic, screenshot, lock, volume, time; color modes; dialog step-aside; Settings toggle "Close sliders and the date automatically"). MTMR must be closed while Penknife's Touch Bar is on.
- Lock button takes the old "End of day" slot (lock.fill icon).
- Sliders approved by the user (2026-11-13); while one is open, all other buttons are hidden.
- Music (R-5), Block Apple Music (R-6), CPU temperature (R-9) and weather (R-13) built and installed (2026-11-13), each its own module; values also shown in the menu. Reviewed (security, accessibility, performance, QA; fixes applied). Tested by the user and committed (2026-11-13).
- Player choices: see R-5 (configurable list, 2026-11-13). Play/pause, next and previous also have shortcuts (no default keys). Tap on weather refreshes it (or opens Location settings if denied). Temperatures follow the system unit, shown as "54°".

Phase 3 (2026-11-13): clipboard history (R-7) built as its own module, reviewed (security, performance, accessibility; fixes applied), tested, approved and committed. Not verified hands-on by us: pasting with/without formatting (user to confirm).

## Requirements

**R-1 Touch Bar** — agreed
OWN IMPLEMENTATION WRITTEN FROM SCRATCH (confirmed 2026-11-13): MTMR is only a reference for how to call Apple's private Touch Bar APIs; no MTMR code is copied (if that ever seems necessary, `legal-advisor` first). When phase 2 is done, MTMR and Hammerspoon are uninstalled.
Reproduce the current MTMR setup (see the dotfiles repo, `macos/mtmr/`): 12 equal-width buttons, battery · brightness · keyboard light · jiggler · mic · screenshot · end of day · music ‖ weather · CPU temp · volume · time.
- Brightness / keyboard light / volume open a slider from their button position (left half opens rightwards, right half leftwards); slider and close ✕ are one gray element, full bar height, round white knob, track tinted with the item color; closes ~0.4 s after release (at most 1 s after the last change; user found 4 s too slow after touching it, 2026-11-13) or after 4 s if untouched; ✕ closes it.
- Battery tap cycles icon colors: own colors → all white → rainbow left to right (including texts). CHANGING (R-25, 2026-11-13): the tap will toggle percentage ↔ battery icon; the color modes move to a long press.
- Time in 12 h (h:mm); tap shows the date as DD/MM/YY for 4 s, tap again hides it.
- EASTER EGG (user, 2026-11-13, changed): long press on the time: the penknife (own drawing: red handle, silver blade) writes "Hello Penknife!" in calligraphy (Snell Roundhand) with its tip gliding along a smoothed copy of the ink path (moving average, ~3 s), turns and slashes it right to left; the halves drift apart and the buttons fade back (~5 s). Reduce Motion: static text. A tap ends it. Pac-Man version and confetti marquee discarded.
- No loading placeholders (no hourglass).
- Only active on Macs with a Touch Bar.

**R-2 F1–F12 keys (Mac without Touch Bar)** — agreed
For each F key choose either a Penknife action or its native function (brightness, volume, etc.).

**R-3 Actions (from Hammerspoon)** — agreed
Mouse jiggler (toggle; moves the mouse after 10 s idle), microphone toggle synced with Microsoft Teams and Google Meet, lock screen, screenshot shortcut.
- Jiggler follows the lock (changed 2026-11-13): turns off whenever the Mac locks (Penknife's lock action turns it off before locking) and on whenever it unlocks; launching at login counts as unlocking. On by default, can be turned off in Settings → Modules; when off, neither locking nor Penknife's lock action touch the jiggler (user, 2026-11-13). Replaces the "End of day" action, which was removed.
- After moving, the jiggler presses a key so Teams and Slack also see activity; THE KEY IS CONFIGURABLE (user, 2026-11-13): Caps Lock pressed twice (default, user likes it: harmless), Shift, Control, Option, F18 or none.
- If the Accessibility permission is missing, the jiggler says so instead of doing nothing. Current behavior and shortcuts: dotfiles `macos/hammerspoon/init.lua`.

**R-4 Native dialogs** — agreed
While a sheet, modal window or system prompt is in front, step aside so the Touch Bar shows the app's own native buttons (Save, Delete, Allow…), unchanged (native colors), and come back after. Plain "AXDialog" windows must not count (Warp keeps hidden ones). Event-driven, no polling.

**R-5 Music** — agreed
Music button and taps: 1 play/pause, 2 next, 3 previous; opens the player if closed. The player is selectable (Spotify, Apple Music, others), not only Spotify.
- PLAYER CONFIGURABLE BY THE USER, SAME BEHAVIOR FOR ALL (user, 2026-11-13): Spotify, Apple Music (iTunes on old Macs), YouTube Music, Amazon Music and any other app chosen with "Choose another app…" (e.g. a YouTube Music web app installed from Chrome). Known apps are listed when installed. Spotify and Apple Music/iTunes are driven by Apple Events (exact app); the others by media keys after making sure the app is open (needs Accessibility). Extra choice "Any app (media keys)" controls whatever is playing.

**R-6 Block Apple Music (noTunes)** — agreed
Prevent Apple Music (and iTunes) from launching on play; MUST NOT CLASH with the player choice: paused automatically while Apple Music or iTunes is the chosen player, and Settings says so.
- CLARIFIED (user, 2026-11-13): the goal is noTunes (github.com/tombonez/noTunes) — Apple Music opening BY ITSELF when headphones connect or are clicked. Opening it manually MUST work (it was blocked: the user couldn't open Music or play a .wav). noTunes blocks every launch and has a menu bar toggle; agreed: block only automatic launches + "Allow Apple Music" menu toggle as backup (until Penknife quits). Built 2026-11-13: a launch counts as the user's when a click or key press happened ≤ 1.5 s before (3 s let a headphone click right after a menu click through; Dock launch measured 0.8 s) and the audio output didn't change in the last 4 s; every decision is logged (`BlockAppleMusic` category) to tune the windows. User's test: Dock launch kept, headphone clicks detected and closed, but Music still showed up (polite quit, forced 2 s later); now force-quit at once as noTunes does. User: "perfecto" (2026-11-13). Open idea, to investigate later (user, 2026-11-13): register Penknife as the Now Playing app (MediaPlayer remote commands) so headphone clicks reach Penknife and go to the chosen player, and Music never launches; cost: Penknife may show in Control Center's Now Playing. Tested with a scratch app ("pausa" mode, paused Now Playing, no audio): clicks reached it, Music didn't open (user, 2026-11-13: works very well). Built 2026-11-13 inside Block Apple Music: Penknife registers as paused Now Playing; headphone play/pause/next/previous go to the chosen player only while it is running (connecting headphones never opens anything; our choice); only for Apple Events players (Spotify), since media keys would loop back to Penknife; off while Apple Music is the player. The launch block stays as backup. Tested and approved by the user (2026-11-13).

**R-7 Clipboard (Maccy)** — agreed (updated 2026-11-13)
History with search, pin the most used items, global shortcut to open it. Skip concealed/transient items (passwords).
- Stores text, images and files (files as references to the original, not copies).
- Lives in memory only: the history is gone when the Mac restarts (or the app quits).
- Limit by memory used, not by days or count; oldest unpinned items drop first. Default 100 MB (our choice), configurable.
- Manual clear: one item or the whole history.
- Shortcut customizable, default ⌃⌥V.
- PINNED ITEMS ARE NEVER DELETED, NOT BY RESTART, LIMIT OR "CLEAR HISTORY"; ONLY WHEN THE USER REMOVES THEM MANUALLY. They are saved to disk (app's Application Support, owner-only permissions) and do not count toward the memory limit.
- Panel (our choices, 2026-11-13, pending the user's design approval): floating glass panel that doesn't take Penknife to the front, so the paste lands in the app you were in. Search field on top, "Pinned" then "History", app icon / image thumbnail per row. Opens centered like Spotlight or at the pointer (setting). Clicking outside or Esc closes it.
- Keys: ↑↓ move, Return pastes, ⌥Return only copies, ⌘1–⌘9 paste that row, ⌘P pin/unpin, ⌘⌫ delete, ⌘⇧⌫ clear history (asks first). Right-click menu with the same actions.
- Text formatting configurable (user, 2026-11-13): "Keep text formatting" (on by default) pastes with fonts/bold/colors, off pastes plain text; ⇧Return in the panel does the opposite once (our choice). Row icons 18 pt (user asked for smaller).
- Panel design approved by the user (2026-11-13: "lo veo muy muy bien").
- Idea for later (user, 2026-11-13): select several history items (e.g. holding Shift) and paste them together, e.g. into a Finder folder. Check keyboard/VoiceOver accessibility before designing.
- Images chosen from the history while Finder is in front are pasted as a PNG file into the open folder (user, 2026-11-13); in other apps as the image. Files already paste as files.
- Settings: memory limit (25/50/100/250/500 MB), "Paste after choosing an item" (on; needs Accessibility, otherwise it only copies and says so), where it opens, clear history. Turning the module off empties the history (pins stay).

**R-8 Screenshots (Lightshot)** — agreed (updated 2026-11-13)
Select an area, annotate, copy or save. NOTHING is uploaded to the web.
- Shortcut customizable, default F1 (note: on Macs without Touch Bar F1 is brightness; R-2 decides which wins).
- Selection: click and drag an area, as Lightshot. Pressing Space while selecting switches to window mode: the window under the pointer is highlighted and a click selects it (user, 2026-11-13); Space again goes back to area.
- Screen frozen at the moment of the shortcut or live while selecting: both, setting (user, 2026-11-13). Default frozen (our choice, as Lightshot).
- Tools (user, 2026-11-13): arrow, text, highlighter, rectangle, ellipse (circle), free pen, blur (hide sensitive data). Pixelate replaced by a real blur (user: the squares looked ugly). Blur look chosen by the user (2026-11-13): frosted glass (rounded corners, light tint, hairline of light, soft shadow); icon `aqi.medium` (diffuse dots; the drop looked like a color picker). Rhombus/triangle not needed (user, unsure, left out).
- Colors (user, 2026-11-13: more variety, red too): red, orange, yellow, green, blue, purple, white, black. The starting color is a setting (default blue; user wants to pick e.g. red).
- Size (user, 2026-11-13): line thickness of every shape and text size are adjustable (4 sizes, keys - and +, scroll wheel). Scroll up = thicker by default; the direction is a setting (user: some people want it reversed).
- Color and size choices: the open row replaces its button (no option shown twice) and closes when choosing a tool or clicking the screenshot (user, 2026-11-13).
- ⌘Z/⇧⌘Z behave exactly like the toolbar's undo/redo, also after typing text (bug fixed 2026-11-13).
- Holding Space must not flicker (key repeat ignored). In window mode the desktop itself can be captured (pointer over no window), as macOS does.
- A selected window is captured as macOS does: the window alone with its rounded corners and colored title bar buttons (transparent corners). The chosen window gets the focus behind the scenes before it is captured, so it looks active (user, 2026-11-13), not the screen area it covers. Window and desktop capture and the blur approved by the user (2026-11-13).
- Paste into Finder folders (user, 2026-11-13): Copy also offers the screenshot as a PNG file, so ⌘V in a Finder folder creates it; other apps still paste the image. Setting "Copy also as a file", on by default. Images copied by other apps are not touched (too invasive). Implemented before the user approved it (our mistake); user keeps it to test (2026-11-13).
- Those files are kept (so several can be pasted later) until the space the user gives them is full (100 MB–2 GB, default 500 MB, our choice); then the oldest are deleted. An image bigger than that space is copied only as an image. Not deleted when copying something else nor after a day (user, 2026-11-13). Button to delete them now.
- Two buttons: **Copy** (also ⌘C) and **Save** to a folder chosen in Settings (also ⌘S, our choice). Both close the capture (user, 2026-11-13). Esc cancels.
- Toolbar (user chose variant B, 2026-11-13): one glass capsule below the selection (tools | color | undo/redo | Copy, Save), icons only with tooltips; moves above, or inside, when there is no room. Selected tool = filled system-blue circle. Size label "800 × 600" above the selection's top-left corner. Tool keys V arrow, T text, H highlighter, R rectangle, O ellipse, P pen, B blur (inactive while typing text). Colors 1–8.

**R-9 CPU temperature** — agreed
Read-only, same value as MacFanPro: SMC key `TCMb` truncated to whole degrees (fallback hottest core key). Refresh every 10 s (user, 2026-11-13; was 30 s), only while shown. No fan control.

**R-10 Internet speed test** — built, approved by the user (2026-11-14)
Measure the internet speed with macOS `networkQuality` (replaces Ookla Speedtest). Its own module (R-15), can be turned off.
- Launch from ALL THREE (user, 2026-11-14): the menu bar menu ("Speed test" item), a Touch Bar button, and a keyboard shortcut (Settings → Shortcuts, no default key).
- Shows EVERYTHING networkQuality gives (user's choice): download, upload, latency (idle ping) and responsiveness (RPM, with Apple's Low / Medium / High rating).
- Only the last result is kept, with its time (user's choice); no history.
- Our defaults (to confirm): `networkQuality -c` (machine-readable output), upload and download in parallel (~15–20 s, the tool's default); one test at a time (launching again while one runs does nothing). Menu: the last result under the item, "Testing…" while it runs. Touch Bar (user, 2026-11-14): a new button right before the time (13 buttons, slightly narrower), `speedometer` icon; while testing, a static "…" (no animation, saves CPU); afterwards "↓320 ↑45" for a while, full detail in the menu. When it finishes, a glass alert (R-20, new alert type "Speed test", can be turned off) shows the full result (user, 2026-11-14: yes). No network → a clear error in the menu and the alert. The process is ended if Penknife quits. Mbps, whole numbers.
- USER FEEDBACK after the first build (2026-11-14), to fix:
  - A TAP WHILE A TEST RUNS MUST NOT START ANOTHER ONE. The user saw it re-trigger once; the code guards it with `isRunning`. `log.notice` lines were added ("Speed test started / tap ignored / ended"), but `log show` from Claude's shell returned nothing, so they couldn't be read. Open: if it happens again, read them with Console.app or `log show --predicate 'subsystem == "Penknife"'` in the user's Terminal.
  - THE BUTTON SHOWS DOWNLOAD, THEN UPLOAD, THEN GOES BACK TO NORMAL (it showed "↓320 ↑45" truncated: only download was visible).
  - The "speedometer + …" testing look is "very ugly". `ux-ui-designer` proposed: testing = static `gauge.with.dots.needle.67percent` (0 CPU) or a needle sweep 0/33/67/100 % every 0.6 s (~0.1 % CPU); result = `arrow.down.circle.fill` + "320" + small "Mb" for 4 s, then `arrow.up.circle.fill` + "45 Mb" for 4 s (or plain arrows without a unit, 3 s each); then `speedometer`. Animated SF Symbol effects were discarded (60 fps, 2–5 % CPU). Chosen after a live demo (user, 2026-11-14): VARIANT 4, needle sweep while testing, plain `arrow.down` + number (no unit) for 3 s, then `arrow.up` + number for 3 s, then `speedometer`; a failure shows `wifi.exclamationmark` for 6 s. Built.
  - "It takes too long": networkQuality needs 20–45 s on this connection; capping it with `-M` gives wrong numbers (measured 2026-11-14: 8 s → 4 Mbps down, 12 s → 11 Mbps, full test 29–42 Mbps). Kept uncapped (full test).
- Out of scope: history (user chose the last result only), choosing servers, Ookla.
- Acceptance: each of the three entry points starts the test; a second launch while running is ignored; menu, Touch Bar and alert show download, upload, latency and RPM; the last result and its time survive a relaunch; with no network an error shows and nothing hangs; no CPU or processes left after the test.

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

**R-17 Distribution and updates** — agreed (changed 2026-11-14)
No paid Apple Developer account (user's decision). Without it there is no notarization and no Mac App Store.
- Personal use: self-signed certificate, as now.
- If published: open source on GitHub (build from source, or download a release that Gatekeeper warns about the first time; user opens it via System Settings → Privacy & Security → Open Anyway).
- Updates: Sparkle (works without the paid account; its signing key never goes in the repo). Manual until published. The user decided to publish (2026-11-14), so Sparkle is planned.
- Sparkle details (user, 2026-11-14), status: built, QA'd (local feed, fake 1.1–1.3), security-reviewed and tested by the user (2026-11-14: menu item → update to 1.1 → "todo funciona", jiggler OK). Goes live with the first release that ships `docs/appcast.xml`:
  - Checks automatically once a day (our recommendation, accepted). No silent installs: when a new version exists it ASKS before installing (Sparkle's standard window with the release notes).
  - "Check for Updates…" item in the MENU BAR MENU, NOT in Settings.
  - Defaults we chose: the appcast (`appcast.xml`) is served from GitHub Pages (`docs/`), the update zip is the GitHub release asset, updates are signed with an EdDSA key kept only in this Mac's Keychain (never in the repo); Sparkle added via Swift Package Manager and listed in `THIRD_PARTY_LICENSES.md`.
  - Acceptance: a build with a lower version finds the newer one at launch/daily check and from the menu item; nothing installs without the user's OK; after updating, privacy permissions (Accessibility, etc.) are kept and the app relaunches; no extra CPU/RAM when idle (one check per day); "you're up to date" message when there is nothing new.
  - Out of scope: silent automatic installs (user wants to be asked); the option in Settings (user wants it in the menu).
- Versions (user, 2026-11-14): version number + build number shown in About ("1.0 (N)"), `CHANGELOG.md`, git tag per version. 1.0 = phases 1–4.
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
THE CURRENT ON/OFF ALERTS (HUD panel "Mover ratón activado/desactivado", etc.) MUST BE REPLACED; the user finds them ugly. Keep R-19 (VoiceOver announcement, duration setting or non-timed alternative).
- Chosen (2026-11-13, after a live demo): option A, a Liquid Glass capsule (44 pt high, fitted width) at the top right, 12 pt under the menu bar and 16 pt from the edge, like the macOS 26 volume/brightness indicator. SF Symbol 18 pt + 13 pt medium text; "on" in system blue, "off" in grey, errors with a yellow triangle (no red). Long messages: short title + 11 pt second line (e.g. "Copiado" / "Activa Accesibilidad para pegar"), at most 2 lines. Fade + short slide in, plain fade with Reduce Motion; solid background under Reduce Transparency, outline under Increase Contrast. The user liked B (centered "Dynamic Island" capsule) but followed the designer's advice.
- SETTING PER TYPE OF ALERT (IMPERATIVE, 2026-11-13): the user chooses which alerts to show, e.g. screenshots off, mouse jiggler off. Replaces the single on/off switch. VoiceOver announcements stay.
- All alerts last the same time, set by the user: 1/2/4/8/15 s (1 s ADDED, IMPERATIVE).
- MENU BAR DOTS (IMPERATIVE): two small dots stacked beside the menu bar icon. User's spec (2026-11-13): TOP = MICROPHONE, BOTTOM = MOUSE JIGGLER, always in those slots; each with its own color; a dot shows only while its function is on, otherwise nothing (one, the other, both or none). Reason: the user can't tell whether the jiggler is on without waiting for the mouse to move. Reviewed by `ux-ui-designer`. Chosen after a live demo (2026-11-13, variant 3): both dots always visible, filled = on, 1 pt ring = off. Mic: orange (as Apple's mic indicator), filled = mic open, ring = muted. Mouse: system blue, filled = jiggler on, ring = off. 4 pt dots, 2 pt gap, 3 pt right of the glyph, fixed-width column. Same look under Increase Contrast (the outlined version was "horrible"). Green (= camera on Apple) and purple discarded. VoiceOver: status item value states both ("Mouse jiggler on, microphone muted"). Setting to hide the dots.
- Alert types (agreed): mouse jiggler, microphone, screenshots, clipboard, music; turning a type off hides all its alerts, errors included.

**R-25 Touch Bar icons that follow state; battery button** — agreed, built (2026-11-13)
The user loved that the jiggler icon changes with its state; ALL ICONS SHOULD DO THE SAME.
- Screen brightness: many rays when high (`sun.max`), few when low (`sun.min`). Keyboard light: same idea, 2–3 levels. Volume: 3/2/1 waves, crossed speaker when muted. CPU temperature (our proposal): thermometer fills with the temperature. Music: different static icon while playing vs paused (note with waves / plain note); no animation (battery).
- Battery TAP toggles percentage ↔ battery icon that fills/empties (remembered). Icon color: green > 50 %, yellow 20–50 %, red < 20 % (our thresholds, red explicitly asked here), bolt while charging. Only in multicolor mode: in monochrome and rainbow the battery follows the mode's color.
- Battery LONG PRESS cycles the color mode: multicolor → monochrome → rainbow. Changed by the user (2026-11-13): first change after 1 s, then one more every second while held.
- Default mode: MULTICOLOR (user, 2026-11-13).
- Built (2026-11-13): brightness `sun.min`/`sun.max`, keyboard `light.min`/`light.max` (2 levels), volume 1/2/3 waves or slash, CPU thermometer low < 50 °C ≤ medium < 75 °C ≤ high, music `music.note` paused / `music.quarternote.3` playing (user liked it). Monochrome also colors the texts.
- Known limit: playing state comes only from Spotify and Apple Music notifications; at launch, and for other players, the icon shows "paused" until the next change.
- TAP FEEDBACK (user, 2026-11-13): wanted a haptic like the trackpad click; the Touch Bar has no haptic engine (the trackpad's only vibrates under a finger), so every tap plays a short dry click like the trackpad actuator (synthesized `TapClick.wav`, variant "seco" chosen by the user from three; "Tink" rejected). Setting "Click sound on every tap" (on by default), also a checkable item "Touch Bar click sound" in the menu bar menu (user, 2026-11-13); sounds on touch-down; silent when macOS UI sound effects are off.
- Settings: monochrome color (user picks it; white by default) and the mode (same value the long press changes).
- Answered: macOS notifies brightness and keyboard light changes (see DECISIONS), so nothing polls.

**R-24 Jiggler interval** — agreed (2026-11-13), IMPERATIVE
THE TIME WITHOUT INPUT BEFORE THE JIGGLER MOVES THE MOUSE MUST BE A SETTING (today fixed at 10 s). Options agreed: 10 s (default), 30 s, 1 min, 2 min, 5 min.

**R-21 App icon** — agreed (2026-11-13), IMPERATIVE
THE APP MUST HAVE ITS OWN ICON (user doesn't like it having none): app icon (Finder, Settings, Spotlight, System Settings lists) plus the menu bar logo (R-14), same design.
- A PENKNIFE (single folding blade), NOT a Swiss/multi-tool knife. MUST LOOK VERY "APPLE" (user, 2026-11-13). Red discarded (user dislikes it).
- Chosen (2026-11-13): the menu bar glyph (which the user likes a lot) in white Liquid Glass on a system-blue gradient. Discarded: blue-handle knife with silver blade on black ("looks like 2015", "something is missing"), glyph on black with blue glow.
- Built as a native Icon Composer `.icon` (the system renders the glass). Menu bar and Touch Bar tray use the same glyph as a template image.

**R-22 Settings window** — agreed (2026-11-13), IMPERATIVE
THE SETTINGS WINDOW CAN BE RESIZED AND LONG TABS SCROLL; the size and position are remembered.
- Modules tab: one section per module, options flush inside it, as System Settings does (user approved, 2026-11-13). Colored icon tiles offered, not chosen.

**R-23 Touch Bar slicing game** — built, played by the user (2026-11-14); CPU lowered to ~4 % with Core Animation layers (2026-11-14)
The user wants a game where you cut things with the penknife, in the genre of Fruit Ninja (original design: own drawings and name, nothing copied).
- Start: HOLD THE MOUSE (JIGGLER) BUTTON on the Touch Bar for ~3 s (user, 2026-11-13). That long press doesn't toggle the jiggler; a normal tap still does.
- Objects: fruits drawn by us in Penknife's style (user's choice). They come in from the edges and arc across the bar; swiping through one cuts it in two halves (penknife trail on the swipe).
- Rules (user's choice): 3 lives; a fruit that leaves the bar uncut costs one life; cutting a bomb ends the game. Points per fruit, more for several in one swipe (our proposal). Speed and the number of objects increase over time. The high score is saved.
- Look chosen after a live demo (user, 2026-11-13: "está buenísimo", keep it as is): THREE STYLES THE USER PICKS, with buttons inside the game bar next to the score, remembered: Glossy (gradient fruit with shine, white glowing trail), Flat (flat colors, seeds in the cut halves, small red-and-silver penknife at the finger), Neon (glowing outlines, rainbow trail). Fruits: apple, orange, lime, plum, lemon; bombs dark with a red cross and a lit fuse. Speed, sizes and bomb rate as in the demo (`docs/demos/slice-demo.swift`).
- Our defaults: the game takes the whole Touch Bar; score on the left, lives on the right; an X exits at any time (no Esc: the game covers the whole Touch Bar, Esc included); game over shows the score and the record for a few seconds, then the normal buttons come back. Cuts play the tap click when "Click sound on every tap" is on. Zero cost when not playing; animation runs only during a game and stops if the Mac locks or Penknife's Touch Bar is hidden.
- Out of scope / rejected: a jump-over-obstacles game and a very long press on the time (earlier ideas, 2026-11-13; the time long press stays the easter egg); copying any existing game's art, names or sounds.
- Acceptance: holding the mouse button 3 s starts the game and leaves the jiggler state unchanged; a short tap still toggles it; swiping through a fruit cuts it and adds points; an escaped fruit removes a life; 3 lost lives or a bomb end the game; the record persists after relaunching; X exits and the normal buttons return; CPU is back to idle after the game.

**R-26 Customizable Touch Bar** — built, reviewed (UX, QA), tested by the user and committed (2026-11-14)
The user wants to choose which buttons appear on the Touch Bar (for example, someone who doesn't need music or the jiggler).
- Settings: a list of all Touch Bar buttons, each with a checkbox to show or hide it, and drag to reorder (user's choice).
- Hiding only affects the Touch Bar: the function keeps working from the menu and its shortcut; the Modules switch still turns the whole function off (user's choice).
- EVERY button can be hidden, including battery, brightness, keyboard light, volume and time (user's choice); at least one always stays.
- Default: today's order and set (speed test before the time).
- Design chosen after a live demo (user, 2026-11-14), `ux-ui-designer` pick (variant 1 of 3): in Modules → Touch Bar a "Buttons: Customize…" button opens a sheet with a live preview strip of the bar, the list (checkbox, icon in the button's color, name, ≡ handle), a caption, "Restore Defaults" and "Done". Changes apply at once. A button whose module is off is dimmed with "Module off" and keeps its place. The last visible button's checkbox is disabled. Reorder by dragging any row: the system List drag didn't work for the user, so it is a custom drag gesture (row lifts with a shadow, others make room); VoiceOver gets "Move up"/"Move down". Discarded: own Settings tab (variant 2), inline in Modules (variant 3, too long, unreliable drag).
- Acceptance: hiding a button removes it at once and the others widen; the order persists after relaunch; a hidden module's menu item and shortcut still work; the last visible button can't be hidden.

**R-27 Attractive GitHub presence** — published (2026-11-14); only the social preview upload (by the user) is left
The user finds the repo too plain and wants it to look beautiful and make people want to download Penknife.
- Scope (user's choice): visual README, repo card (description, topics, social preview image), nicer release page, and a landing page on GitHub Pages (`alexl-l.github.io/penknife`).
- README in English (`README.md`) plus Spanish (`README.es.md`), linked to each other at the top (user's choice).
- Screenshots and GIFs taken by Claude from the running app (user's choice). No personal data may appear (clipboard contents, file names, location, email, other apps); every image is checked before anything is uploaded.
- Look chosen by the user (2026-11-14) from 3 `ux-ui-designer` variants: VARIANT 2 "Dark stage" — the Touch Bar strip is the hero (glow, rainbow battery mode as accent), alternating feature rows, black social preview with a rainbow strip. Discarded: variant 1 "Apple product page" (designer's pick) and variant 3 "warm indie spec sheet". Mock kept in `docs/design/github-presence.html`.
- Touch Bar images are real captures (`screencapture -b`, 2008×60).
- Progress (2026-11-14): done and approved in `docs/screenshots/`: `touchbar.png` (normal), `touchbar-rainbow.png` (hero; the user keeps the low red battery as is), `touchbar-game.png` (best of 10 shots). The user cleaned the desktop and the clipboard history (so sample clipboard items can be copied for the shot).
- Captures done (2026-11-14, checked for personal data): `settings.png`, `settings-music.png`, `menu.png`, `clipboard.png` (sample items), `screenshot-editor.png` (+ `-full`). Method: a watcher captures Penknife's windows by ID (`screencapture -l`, `-o` for the clipboard panel to avoid a square frame); the desktop widgets show the city, so never capture the full screen.
- README.md + README.es.md written (2026-11-14, not committed): centered header (icon, tagline, download badge, shields), rainbow Touch Bar hero, feature table, install, collapsed details. Editor shot as JPEG (1600 px) to keep the repo light. Approved by the user as is (2026-11-14; GitHub strips CSS, so the README can't look like the mock; a banner-image header was offered and declined).
- Landing `docs/index.html` (variant 2 with real captures, dark/light, og tags; Pages from `/docs`, `.nojekyll`) and `docs/screenshots/social-preview.png` (1280×640, real rainbow Touch Bar) approved by the user (2026-11-14). Release notes draft: `docs/release-notes/v1.0.md` (fixed install step).
- Published (2026-11-14, user: "sipi"): pushed, Pages live at https://alexl-l.github.io/penknife/ (main `/docs`), description + homepage + 8 topics set, v1.0 release notes replaced. Pending: the user uploads `docs/screenshots/social-preview.png` in GitHub Settings → Social preview (no API).
- Fix: the v1.0 release notes say "right-click → Open"; on macOS 26 it is System Settings → Privacy & Security → Open Anyway.
- Acceptance: README shows icon, tagline, download button, real screenshots per module, works in light and dark GitHub themes; the repo card has description, topics and social preview; the landing page loads at the Pages URL; nothing personal in any image.

## Public copy (user, 2026-11-15)
- Tagline (GitHub description, README, web, release notes): "Your Touch Bar, clipboard, screenshots and music controls, finally done right. One tiny menu bar app, free and open source." Spanish README: "Tu Touch Bar, el portapapeles, las capturas y el control de la música, por fin bien hechos."
- Public text is written by the `copywriter` agent: benefit first, no hype. Other apps are named once only (README "Coming from…" line).
- English menu items and buttons use Title Case (Apple style); Spanish uses sentence case and Spain wording (tiempo, auriculares, pulsa, la Touch Bar, desactivado).

## Rejected / out of scope
- Tagline "The pocket knife for your Mac" and describing the app as "replaces Hammerspoon, MTMR, noTunes, Maccy and Lightshot" (user disliked it, 2026-11-15).
- Fan control (MacFanPro stays out; risky SMC writes).
- Long press on the time to sleep the Mac (MTMR had it; user said no, 2026-11-13).
- Uploading screenshots to the web.
- Mac App Store (private APIs needed for Touch Bar, brightness, temperature; sandbox blocks controlling other apps).
- Archive extraction (RAR/7Z) — little benefit for the work.
- Names: Hilt (Google shows swords), Lighthouse / Pocket Knife / Clasp / Whittle (taken), Toolkit (too generic).

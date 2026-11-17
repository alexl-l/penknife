# Changelog

Version = `MARKETING_VERSION` in the Xcode project. Build = number of git commits (set by
`scripts/install.sh`). Each version gets a git tag `vX.Y`.

## 1.4 — 2026-11-17

Weather, Mac temperature and the speed test can now live in the menu bar, and Teams can remember your unmute choice.

- **Weather, Mac temperature and speed test as menu bar items.** Handy on Macs without a Touch Bar, where they are on by default. Turn each on or off with "Show in the menu bar" in its module.
- **Three styles** in Settings → General: Simple, Color and Bold. In Color, the temperature turns orange when your Mac runs hot.
- **Click for a small menu.** Weather offers Update now. Speed test shows your last result and Test Speed Now.
- **Optional: "Remember my choice for Teams' unmute dialog"** in Settings → Microphone, off by default. When you unmute with Penknife's shortcut and Teams asks "Do you agree to the use of your audio and video?", Penknife presses Yes for you. It only applies when unmuting with the shortcut, in the Microsoft Teams desktop app set to English. You remain responsible for consent, so check your employer's policy first.

## 1.3 — 2026-11-17

Meeting mute now stays in sync with your call, and the Mac's microphone is muted along with it.

- **Mic mute follows the call's own button.** Each press checks the mic button in Meet or Teams and only changes it when needed, so clicking the mic inside the call no longer leaves the call and your Mac out of step. Where the button can't be read (Firefox, for example), it uses the app's shortcut as before.
- **The Mac's microphone is now muted too during a meeting**, so the menu bar icon matches the call. You can turn this off with "Also mute the Mac's microphone" in Settings.
- Meetings in the browser are detected in Chrome, Chrome Dev, Opera, Safari and Firefox, with no permission prompt. In Chrome-based browsers, accessibility must not be turned off in chrome://accessibility.
- Fixed: shortcut presses being ignored during calls.
- Fixed: Google Meet in Safari muting the Mac but not the call.

## 1.2 — 2026-11-16

The microphone shortcut now mutes the meeting you are in.

- Meeting-aware mic mute for Teams, Google Meet, Zoom, Slack Huddles and Webex: it uses each app's own shortcut (editable in Settings), and only apps in a call count.
- With no call, it mutes the Mac's microphone. Optional setting to also mute the Mac's microphone during a meeting.
- The microphone icon and status dot always show the real microphone state.
- Speed test shows units (kbps, Mbps or Gbps).
- Touch Bar taps no longer click.
- Quick presses always register.

## 1.1 — 2026-11-14

Penknife now updates itself. If you have 1.0, download this version once by hand; from then on, updates arrive from the app.

- Checks for updates once a day and always asks before installing.
- **Check for Updates…** in the menu bar menu.
- Updates are signed (EdDSA) and verified before they are unpacked.

## 1.0 — 2026-11-14

First complete version.

- Menu bar app with modules that can be turned on and off, shortcuts and status dots (microphone, mouse jiggler).
- Own Touch Bar: brightness, keyboard light, volume, music (chosen player), weather, CPU temperature, battery, time; state icons; customizable buttons and order.
- Music: headphone clicks go to the chosen player; Apple Music no longer opens by itself.
- Clipboard history with pinned items and search.
- Screenshot editor (frozen or live, window mode, marks, blur, copy and save).
- Alerts, mouse jiggler with interval, speed test (networkQuality).
- Slicing game on the Touch Bar (hold the jiggler 3 s), drawn with Core Animation (~4 % CPU).
- Settings: one System Settings style sidebar (General, Permissions, Shortcuts, modules, About).

# Changelog

Version = `MARKETING_VERSION` in the Xcode project. Build = number of git commits (set by
`scripts/install.sh`). Each version gets a git tag `vX.Y`.

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

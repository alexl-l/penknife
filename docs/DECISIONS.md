# Penknife — decisions and lessons

- **Name**: Penknife (English, free on Mac app stores; Google shows a folding pocket knife, matching the logo idea).
- **Signing**: free self-signed certificate in the login keychain for stable permissions; paid Apple Developer account later, when publishing several apps. Never the "Apple Development" certificate for installed builds (see the `macos-build-sign-install` skill).
- **Prior art to reuse** (all from 2026-11-12, dotfiles repo and fork `alexl-l/MTMR` branch `touchbar-custom`):
  - Touch Bar via private DFR APIs as in MTMR (`presentSystemModal`, `minimizeSystemModal`); MTMR is MIT — check obligations with `legal-advisor` before copying code.
  - Keyboard backlight: CoreBrightness `KeyboardBrightnessClient` (`setBrightness:forKeyboard:`); disable `enableAutoBrightness:forKeyboard:` on manual change, or a bright room keeps the light off.
  - Display brightness: DisplayServices `DisplayServicesSetBrightness`.
  - CPU temp: AppleSMC user client, key `TCMb` (`macos/mtmr/mactemp.c`).
  - Dialog detection: Accessibility; real dialogs = `AXSheet` role, `AXSystemDialog` subrole or `AXModal`; check only the focused window and focus chain; drive it with AX observers (`AXFocusedWindowChanged`, `AXFocusedUIElementChanged`, `AXWindowCreated`, `AXSheetCreated`), not polling.
  - System prompt apps: SecurityAgent, UserNotificationCenter, coreservices.uiagent, LocalAuthentication.UIAgent, CoreLocationAgent, accessibility.universalAccessAuthWarn.
- **Token-heavy verification** (screenshots, logs) goes to the `qa-tester` agent.
- **Minimum macOS 26** (2026-11-13): the user's Mac runs 26.6; supporting older versions adds testing and code paths for no gain in a personal app. Touch Bar Macs (M1/M2 13" MacBook Pro) run macOS 26. Revisit if published and users ask.
- **Mac App Store not viable for the full app** (2026-11-13): App Review rejects private APIs (guideline 2.5.1) and the sandbox blocks controlling other apps. Penknife depends on private DFR (Touch Bar), DisplayServices/CoreBrightness (brightness), AppleSMC (temperature) and Accessibility/event posting (dialogs, jiggler, F keys). Store version would lose most features. Proposed path: notarized Developer ID download + Sparkle (MIT, standard for non-store apps); Sparkle is forbidden inside the App Store anyway.
- **No paid Apple Developer account** (2026-11-13, user's decision): rules out WeatherKit, notarization and the Mac App Store. Sparkle still works (own EdDSA keys).
- **Private APIs can't be removed** (2026-11-13): a menu bar app is never frontmost, so public `NSTouchBar` never shows; only private DFR gives a global Touch Bar. No public API sets built-in display or keyboard backlight brightness on Apple Silicon (only simulating brightness keys, which gives steps, not a slider). Outside the App Store private APIs are allowed; the risk is that a macOS update breaks them, so each one lives behind its module (R-15) and fails gracefully.
- **Public repo hygiene** (2026-11-13): git author is `alexl-l <53312543+alexl-l@users.noreply.github.com>` (history rewritten, repo-local config set); `.gitignore` excludes builds, xcuserdata, certificates and secrets. Never commit keys, certificates, personal paths or emails. License pending (MIT likely; check MTMR obligations with `legal-advisor`).
- **Accessibility**: global `accessibility-reviewer` agent reviews every UI change (R-19).
- **Shortcuts: KeyboardShortcuts library** (sindresorhus, MIT; 2026-11-13): native recorder control, keyboard and VoiceOver accessible, avoids writing our own. Add its license notice to the app.
- **Weather: Open-Meteo** (2026-11-13): free for non-commercial use, no key (nothing secret in the repo), data CC BY 4.0 (attribution required). If Penknife ever becomes commercial, check their terms with `legal-advisor`.

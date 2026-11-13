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

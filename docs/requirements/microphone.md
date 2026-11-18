# Microphone — requirements (current behavior)

Source of truth for what the microphone module must do TODAY (Penknife 1.9). The history behind each rule (who asked, when, what was tried) stays in `docs/REQUIREMENTS.md` (R-3, R-20, R-25, R-28, R-29, R-31, R-34) and `docs/DECISIONS.md`; where they disagree with this file, this file wins. Written 2026-11-18 from the code at cdeebbe and those docs: pilot of "complete requirements per module + tests that validate them" (user, 2026-11-17).

**How to use it.** Before changing anything that touches the microphone, read the rules of the parts you change. After the change, run `scripts/test.sh` and check EVERY affected rule by its Verify line, not only the new behavior. A new or changed wish → change the rule here, and keep the story in REQUIREMENTS.md.

Code paths are relative to `Penknife/`: `MM` = Modules/MicrophoneModule.swift, `MS` = Modules/MeetingSync.swift (MeetingPlatform, MeetingTracker), `TC` = Modules/TeamsConsent.swift. "R-28 (11-17)" = the REQUIREMENTS.md R-28 line dated 2026-11-17; "D: <title>" = the DECISIONS.md bullet with that bold title.
Verify kinds: **auto** (unit test as the code is today) · **auto after refactor** (seam named; see §4) · **manual** (the user's normal action only) · **log** (`/usr/bin/log show --last 1h --predicate 'subsystem == "Penknife" AND category == "Microphone"' --style compact`).
Count (2026-11-18, after S2 and B-2): 85 rules = 19 auto (all tested) · 13 auto after refactor · 20 log · 33 manual.
**Tests:** `scripts/test.sh` (unit tests in `PenknifeTests/`, ~3 s once built; safe on this Mac: the test host starts no module and nothing writes the user's settings). Each test is named after its rule ("MIC-24 …").

## 1. Rules

### A. Triggers and pressing with no call

- **MIC-01** The same toggle runs from three places: the global shortcut "Mute Microphone" (default F5, editable in Settings › Shortcuts), the menu item "Mute Microphone" (checkmark on while the mic shows muted when the menu opens, MIC-40), and the Touch Bar mic button.
  Source: R-3; R-28 (11-16); menu checkmark code only · Code: MM:actions, Core/ModuleManager.swift:init/run, App/StatusMenu.swift (menu build), TouchBar/TouchBarModule.swift:run · Verify: manual — press F5, use the menu item, tap the Touch Bar button; each flips the mic.
- **MIC-02** One press = one action: the shortcut runs on key release (once even when held); a bare F key's Fn twin arriving < 0.1 s after the same press is dropped; Touch Bar and menu presses always run; no de-dup window between real presses.
  Source: D: One press = one action (11-16) · Code: ModuleManager:runHotKey, run · Verify: auto after refactor — `shouldRun(last:(fn,at)?, fn:Bool, now) -> Bool`: same twin 0.05 s later → true; other twin 0.05 s → false; other twin 0.2 s → true.
- **MIC-03** With no call found (MIC-09), a press sets the Mac's default input to the opposite of its current real state (MIC-63).
  Source: R-28 (11-16) "No call → the Mac's microphone toggles" · Code: MM:toggle → toggleMac → setMac · Verify: **auto, tested** (S1) — `route(meeting: nil)` → `.mac` whatever the settings; `newMacMuted(appMuted: nil, macMuted:)` = the opposite.
- **MIC-04** Write policy: settable mute → the mute property is set; else settable input volume → mute = volume 0 (previous volume remembered in memory), unmute = remembered volume, or 1.0 if none (e.g. after relaunch); neither settable → nothing is written (open decision O-2).
  Source: D: Mic state bug (11-16); the 1.0 fallback is code only · Code: MM:setMac(muted:) · Verify: auto after refactor — `writePlan(muteSettable, volumeSettable, mute, currentVolume, savedVolume) -> (write, newSaved)`.
- **MIC-05** Every press that changes the Mac's mic (with or without a call) shows the HUD "Microphone muted" (`mic.slash.fill`, grey) or "Microphone unmuted" (`mic.fill`, blue), Microphone alert type.
  Source: R-20 (11-13) look; texts code only · Code: MM:setMac · Verify: manual — press F5 with no call; the capsule appears at the top center.
- **MIC-06** No default input device → nothing changes and the HUD shows the error "No microphone found" (yellow triangle).
  Source: code only · Code: MM:setMac · Verify: **auto, tested** (S1) — `macGate(siriListening: false, device: nil)` → `.noDevice`.
- **MIC-07** The no-call path needs no Accessibility permission (only a meeting press asks for it).
  Source: code only · Code: MM:toggle (ensureAccessibility only after a target is found) · Verify: **auto, tested** (S1) — `route(meeting: nil)` never evaluates `axGranted` (so no prompt).
- **MIC-08** Microphone module off (Settings › Modules): its shortcut is unregistered (F5 reaches the front app), the menu item and the Touch Bar button disappear, the mic dot is hidden, and the module holds no observers or listeners (B-1 fixed 2026-11-18).
  Source: R-15 (Core/Module.swift header); R-20 · Code: ModuleManager:setEnabled/setShortcuts, TouchBar/BarLayout.swift (items filter), StatusMenu:updateIcon, MM:stop · Verify: manual — turn the module off, press F5: nothing in Penknife.

### B. Detecting a call

- **MIC-09** A meeting exists ONLY while a meeting app or known browser is recording from a microphone right now (CoreAudio process list, the signal behind macOS's orange dot); an open Teams/Slack/Zoom or a Meet page without a call is not a meeting, so the press toggles the Mac.
  Source: R-28 (11-16) IMPERATIVE "IN A CALL" · Code: MS:findCurrent, appsUsingMicrophone · Verify: manual — Teams open, no call, press F5 → HUD "Microphone muted/unmuted".
- **MIC-10** A recording helper counts for its app: each CoreAudio process is mapped to its responsible app's pid (Chrome Dev → `com.google.Chrome.helper`, Safari → `com.apple.WebKit.GPU`); if that lookup is unavailable the process stands for itself.
  Source: R-28 BUG (11-16); D: Meeting detection fix (b) · Code: MS:appsUsingMicrophone, responsiblePID · Verify: log — `Recording: com.google.Chrome.helper, com.apple.CoreSpeech; in a call: com.google.Chrome.dev`.
- **MIC-11** Desktop apps by bundle ID: Teams `com.microsoft.teams2`/`com.microsoft.teams`, Zoom `us.zoom.xos`, Slack `com.tinyspeck.slackmacgap`, Webex `Cisco-Systems.Spark`/`com.webex.meetingmanager`; Meet has none.
  Source: R-28 (11-16) platforms; IDs code only · Code: MS:MeetingPlatform.bundleIDs, forApp · Verify: **auto, tested** — `forApp("us.zoom.xos") == .zoom`, `forApp("com.apple.Safari") == nil`, `forApp(nil) == nil`.
- **MIC-12** Every press logs who records and which candidates are in a call.
  Source: D: Meeting = in a call ("Mic logs use .notice") · Code: MS:findCurrent · Verify: log — `Recording: <bundle IDs, comma-separated>; in a call: <bundle IDs>`.

### C. Choosing which meeting

- **MIC-13** Candidate order: the frontmost app (if it is a meeting app or known browser), then recently activated candidates (most recent first, at most 6 remembered, quit apps dropped), then any other running candidate; the first one in a call that resolves to an enabled platform is the target.
  Source: R-28 (11-16) "CURRENT meeting … focus … last meeting app that had focus"; "never-in-front apps still count" is code only · Code: MS:findCurrent, remember · Verify: auto after refactor — S3 `orderCandidates(front:recent:running:micPIDs:) -> [pid]`.
- **MIC-14** Only that one meeting changes: with two calls (e.g. Teams + Meet in Chrome), the one in front, or else the last one used, gets the shortcut; the other is untouched.
  Source: R-28 (11-16) · Code: MS:findCurrent (stops at the first match) · Verify: manual — two calls, Chrome in front, press F5 → only Meet changes.
- **MIC-15** A meeting app whose platform is off in Settings is skipped and the next candidate is tried; if none qualifies, the Mac toggles.
  Source: R-28 "Each platform can be turned off"; skip-to-next is code only · Code: MS:findCurrent · Verify: auto after refactor — S3 `pickTarget(candidates:[(bundleID, title?)], enabled:) -> (platform, index, isBrowser)?`.
- **MIC-16** Recent apps are learned only from NSWorkspace "did activate application" (no polling), kept in memory, cleared when the module stops.
  Source: D: Meeting = in a call (no polling) · Code: MS:start/stop/remember · Verify: auto after refactor — pure `remember(recent, app) -> recent` (dedupe by pid, insert first, cap 6).

### D. Per-platform shortcuts

- **MIC-17** Five platforms, each with its own mute shortcut, EDITABLE in Settings › Modules › Microphone › Meetings; defaults: Teams ⌘⇧M, Meet ⌘D, Zoom ⌘⇧A, Slack ⌘⇧Space, Webex ⌘⇧M; "Restore Defaults" resets the five.
  Source: R-28 (11-16) · Code: MS:KeyboardShortcuts.Name.meeting*, Settings/SettingsView.swift:MeetingOptions · Verify: **auto, tested** — each `Name.meetingX.defaultShortcut` equals the table.
- **MIC-18** Each platform is on by default (`meeting.<platform>.enabled`); turned off, it is never targeted and its recorder is disabled and dimmed to 40 %.
  Source: R-28 (11-16); Settings variant B (11-16) · Code: MS:MeetingPlatform.isEnabled, MeetingOptions · Verify: auto after refactor — inject a UserDefaults suite: empty → true.
- **MIC-19** Meeting shortcuts are only SENT to the meeting app, never registered as global hotkeys: ⌘⇧M in any other app still does that app's own thing.
  Source: code only (MS header comment) · Code: MS:MeetingPlatform; ModuleManager registers module actions only · Verify: manual — in Mail press ⌘⇧M with Penknife running → Mail's own action.
- **MIC-20** A desktop app gets key down + up posted to its process in the background, with the recorded modifiers (⌘ ⇧ ⌥ ⌃); focus never moves.
  Source: R-28; D: Meeting = in a call · Code: MS:send, flags; Core/EventPoster.swift:key · Verify: auto after refactor — make `flags(_:)` internal: `[.command,.shift]` → `[.maskCommand,.maskShift]`; focus part manual (press F5 in a Teams call from the editor → editor stays in front).
- **MIC-21** A platform with no shortcut recorded gets nothing; the Mac part (MIC-29) still runs.
  Source: code only · Code: MS:send (guard) · Verify: manual — clear Zoom's shortcut in Settings, press F5 in a Zoom call → only the Mac changes (`route` doesn't depend on the shortcut; `send` returns before posting).

### E. Browsers

- **MIC-22** Known browsers: Chrome, Chrome Dev/Beta/Canary, Edge, Brave, Arc, Safari, Safari Technology Preview, Opera, Opera GX, Firefox, Firefox Developer Edition, Firefox Nightly. IT MUST WORK IN CHROME, CHROME DEV, OPERA, SAFARI AND FIREFOX.
  Source: R-28 (11-16) BROWSERS IMPERATIVE; the others code only · Code: MS:MeetingTracker.browsers · Verify: **auto, tested** — the set contains the 5 imperative bundle IDs.
- **MIC-23** A browser call counts only when the meeting is the ACTIVE tab: the focused (else main) window title is read through Accessibility (0.15 s timeout); no AppleScript/Apple Events, no Automation prompt, no "Allow JavaScript from Apple Events".
  Source: R-28 (11-16); D: Meeting detection fix (c) · Code: MS:windowTitle, findCurrent · Verify: manual — Meet call in Firefox as the active tab, F5 mutes the call; switch tab, F5 toggles the Mac.
- **MIC-24** Title rule: the lower-cased title is split at `- – — | ·`; a trimmed part must equal a brand — "microsoft teams"; "meet", "google meet"; "zoom", "zoom meeting", "zoom workplace"; "slack"; "webex", "cisco webex" — or the title contains a Meet code `abc-defg-hij` (→ Meet). "Slack tips" does not count. First enabled platform in the order Teams, Meet, Zoom, Slack, Webex wins.
  Source: R-28 (11-16); code · Code: MS:MeetingPlatform.matches(title:) · Verify: **auto, tested** — "Meet - abc-defg-hij" → meet; "Chat | Microsoft Teams" → teams; "abc-defg-hij" → meet; "Slack tips" → none; "Zoom Workplace" → zoom.
- **MIC-25** A browser in a call whose title can't be read is not a meeting; the next candidate is tried.
  Source: code only · Code: MS:windowTitle · Verify: log — `No window title for browser pid <pid>`.
- **MIC-26** Sending to a browser that is not frontmost: it is brought forward and the shortcut is posted only once it is frontmost (checked every 50 ms, up to 20 times ≈ 1 s); never in front → nothing typed anywhere; 0.1 s after posting, the previous app comes back only if the browser is still frontmost. Already frontmost → posted at once.
  Source: R-28; D: Meeting = in a call (≤ 1 s) · Code: MS:send, whenFrontmost · Verify: manual — Meet call in Chrome, editor in front, press F5 → Meet toggles and the editor is back.
- **MIC-27** Chromium browsers expose the call's button only with Chrome's accessibility allowed (`chrome://accessibility`, "Suppress automatic accessibility enablement" unchecked; README FAQ); otherwise the read is "unreadable" and MIC-29's fallback applies. Safari needs nothing; Firefox and Opera reads not measured.
  Source: R-28 (11-17); D: Meeting button read in Chrome · Code: MS:withWebTree, micButtonState · Verify: log — `App mic: unreadable (… 41 elements …)` vs `App mic: muted (…)`.

### F. Reading the call's mic state and self-healing

- **MIC-28** With "Also mute the Mac's microphone" on, each meeting press reads the call's mic button once through Accessibility, off the main thread, then ALWAYS sends the platform's shortcut.
  Source: R-28 CHANGED (11-17) "Manda la llamada" · Code: MM:toggle, MS:readMuted · Verify: **auto, tested** (S1) — `route(…, alsoMac: true)` → `.meeting(.readAndSend)`; log — `Meeting: teams` then `App mic: muted|open|unreadable (<ms> ms, <n> windows, <n> elements; roles: …)`.
- **MIC-29** New Mac state = the opposite of the CALL's state read before the press (call muted → Mac unmuted); only when the button can't be read, the opposite of the Mac's state. So a readable press always leaves call and Mac equal (self-healing), even after a click inside the app inverted them.
  Source: R-28 CHANGED (11-17); PROBLEM (11-16) · Code: MM:toggle (`after`) · Verify: **auto, tested** (S1) — `newMacMuted(appMuted:macMuted:)` and `afterSend(alsoMac: true, …)`: (true,false)→false, (false,true)→true, (nil,true)→false, (nil,false)→true.
- **MIC-30** The call's button is recognized by its label (title, else description), case-insensitive prefix, English and Spanish: muted = "unmute mic", "unmute microphone", "turn on microphone", "activar (el) micrófono", "reactivar (el) micrófono"; open = "mute mic", "mute microphone", "turn off microphone", "desactivar (el) micrófono", "silenciar (el) micrófono"; other labels → unknown.
  Source: R-28 option A (measured labels); D: Reading a meeting app's mute state · Code: MS:state(fromLabel:) · Verify: **auto, tested** — "Unmute mic"→true, "Mute mic"→false, "Desactivar micrófono"→false, "Activar micrófono"→true, "Mic settings"→nil.
- **MIC-31** Only buttons/checkboxes inside the page's web content (AXWebArea) count, so a browser's own "microphone in use" toolbar button is never read as the call's.
  Source: D: Meet in Safari read Safari's own button (11-17) · Code: MS:search · Verify: manual — Meet call in Safari, press F5 twice → call and Mac change together both times.
- **MIC-32** Windows searched: an app's focused window first, then its other windows (a Teams call in its own window); a browser only its focused window.
  Source: code; R-28 · Code: MS:meetingWindows · Verify: manual — Teams call in a separate window, main Teams window focused, press F5 → both change together.
- **MIC-33** The search is bounded: breadth-first, ≤ 6000 elements, depth < 40, AX timeout 0.25 s; if Penknife just turned the web tree on, it retries 5 × 0.2 s (≈ 1 s), then "unreadable".
  Source: D: Meeting button read in Chrome (~1 s); limits code only · Code: MS:micButtonState, search, withWebTree · Verify: log — ms and element count in the `App mic:` line.
- **MIC-34** The call's state is never watched between presses: clicking mute inside the app doesn't update Penknife at that moment; the next Penknife press re-aligns both (accepted limit).
  Source: R-28 (11-16) "Not covered (user accepted)" · Code: MS:readMuted (press only) · Verify: manual — click mute in Teams, press F5 → Teams and the Touch Bar/dot end equal.
- **MIC-35** "Also mute the Mac's microphone" off: no read, the shortcut is sent blind, the Mac's mic is untouched, and the HUD shows the platform name with "Microphone toggled" (`mic.badge.xmark`, blue).
  Source: R-28 (11-16) setting; HUD text code only · Code: MM:toggle · Verify: auto (S1) — `route(…, alsoMac: false)` → `.meeting(.sendOnly)`; `afterSend(alsoMac: false, …)` → `.showToggled`, also in the Teams consent flow; manual — setting off, press F5 in a Zoom call → "Zoom · Microphone toggled", Touch Bar unchanged.
- **MIC-36** A desktop-app meeting press without Accessibility does nothing except the system Accessibility prompt, at most once per launch; no HUD (open decision O-3).
  Source: D: Accessibility prompt once per launch; silent result code only · Code: MM:toggle, Core/Permissions.swift:ensureAccessibility · Verify: **auto, tested** (S1) — `route(meeting: <any>, axGranted: false)` → `.nothing`.

### G. Mac mic follows the call

- **MIC-37** "Also mute the Mac's microphone" is ON by default (`microphone.alsoMuteMac`), so the Touch Bar icon and the dot, which show the Mac's mic, match the call.
  Source: R-28 (11-16) "Decided … ON by default"; D: Meeting detection fix (d) · Code: MM:alsoMuteMac, MeetingOptions · Verify: auto after refactor — injected empty defaults → true.

### H. Siri

- **MIC-38** Siri (`com.apple.CoreSpeech`) counts as listening only when it is the ONLY process recording; Siri recording alongside a call app doesn't count.
  Source: D: Meeting detection fix (a) (11-16) · Code: MM:isSiriListening · Verify: **auto, tested** (S2) — `isSiriListening(recorders:)`: [CoreSpeech]→true; [CoreSpeech, teams2]→false; [CoreSpeech, Penknife]→false; []→false.
- **MIC-39** While Siri listens, a press that would change the Mac's mic does nothing (no change, no HUD); checked once at the press.
  Source: R-28 TRUTHFUL MIC STATE (11-16) · Code: MM:setMac · Verify: auto (S1) — `macGate(siriListening: true, …)` → `.siriListening`, checked before the device; log — `Toggle ignored: Siri is listening`.
- **MIC-40** No Siri badge: while Siri hears the user (its panel is on screen AND Siri records), the Touch Bar icon, the dot and the menu's checkmark show the mic open, whatever the mute says; when the panel closes they show the device again. Siri woken by a Mac sound shows no panel, so the mic stays shown muted (R-34); "Type to Siri" (panel, no recording) changes nothing. Works with music playing and with AirPods. The panel is found by Accessibility: macOS 26 draws it in Notification Center as an element identified `SiriWindow` (a notification banner is another element); it shows ~0.7 s after Siri starts listening. Without Accessibility: the device only (watched again once it is granted).
  Source: R-28 (11-16); B-2 fix (11-18, user: "si siri se activa, el ícono del mic se debería abrir… y después que siri lo cierre, el ícono cambia"; "listo, arreglado"); D: Siri's panel tells when Siri hears you · Code: MM:SiriWatcher, siriHears, shownMuted, showsMuted; TouchBarModule:updateMicrophone; StatusMenu:updateIcon · Verify: **auto, tested** — `siriHears(panelShown:recorders:)`, `shownMuted(deviceMuted:siriHears:)`; log (debug) — `Siri panel: shown, hears you: true` / `Siri panel: gone, hears you: false`; manual — muted, with and without music, "Hey Siri" → icon open while Siri shows, muted after (checked by the user 2026-11-18: 4 sessions).
- **MIC-41** Touch Bar taps make no sound (only the slicing game clicks), so a tap never triggers Siri's mute clear that undid the tap.
  Source: R-25 TAP FEEDBACK REMOVED (11-16); D: Hey Siri vs the mic mute · Code: TouchBar/BarView.swift (GameSound only) · Verify: manual — "Hey Siri" on, tap the mic button several times → each tap sticks.
- **MIC-42** Called Siri still hears you: a mute cleared with no sound started in the previous 0.5 s is not put back by Penknife; Siri restores the mute itself when done.
  Source: R-34 REGRESSION fix (11-17) IMPERATIVE "quiero las dos cosas" · Code: MM:microphoneChanged · Verify: **auto, tested** (S2) — `shouldRemute` with the sound 0.5 s, 30 s or never before → false; manual — muted, ask Siri the time → it answers.

### I. "Keep the microphone muted" (R-34)

- **MIC-43** Setting "Keep the microphone muted", ON by default (`microphone.keepMuted`), its own section after "Also mute the Mac's microphone", footer "If another app unmutes the Mac's microphone while you are muted, Penknife mutes it again."; takes effect at once (no relaunch).
  Source: R-34 IMPERATIVE "DEJEMOS ESTO EN CONFIGURACIÓN"; Built (designer's spec) · Code: MM:keepMuted, updateKeeper (defaults observer), MeetingOptions · Verify: auto after refactor — injected defaults → true.
- **MIC-44** Re-mute rule: with the setting on, when the default input goes muted → open, Penknife mutes it again at once only if ALL hold: it happened ≤ 0.5 s after the Mac's sound output started running; > 1 s after Penknife's own last change; no process other than Siri is recording.
  Source: R-34 REGRESSION fix (11-17); D: R-34 keep-muted · Code: MM:microphoneChanged, OutputWatcher · Verify: **auto, tested** (S2) — `shouldRemute(wasMuted:isMuted:now:ownChangeUntil:outputStarted:recorders:)`: all hold (Siri or nobody recording, sound ≤ 0.49 s before) → true; any other mute change → false without reading the recorders.
- **MIC-45** Result: muted with no call, a system sound (Finder's trash) or video leaves the mic muted again within ~0.15 s (measured 0.13–0.15 s) and it stays muted through Siri's ~6 s.
  Source: R-34 measured (11-17) · Code: MM:microphoneChanged · Verify: manual — muted, delete a file (trash sound) → the dot/Touch Bar end muted.
- **MIC-46** Penknife's own unmute is never undone (1 s window after each Mac change Penknife makes).
  Source: R-34 acceptance + Built (11-17) · Code: MM:setMac (`ownChangeUntil`) · Verify: **auto, tested** (S2) — `now` ≤ `ownChangeUntil` → false; 0.01 s after → true.
- **MIC-47** No re-mute while another app (not Siri) records, e.g. during a call or Penknife's own recording with the mic on (open question O-4).
  Source: R-34 Built (11-17) · Code: MM:microphoneChanged · Verify: **auto, tested** (S2) — recorders [teams2], [CoreSpeech, teams2] or [Penknife] → false.
- **MIC-48** The re-mute writes the same control as a press (settable mute → 1, else volume 0) on the current default input, silently: no HUD.
  Source: R-34 Built "Re-mutes silently (debug log, no HUD)" · Code: MM:microphoneChanged · Verify: log (debug level: `/usr/bin/log stream --level debug --predicate 'subsystem == "Penknife"'`) — `Kept muted: the mute was cleared by someone else`.
- **MIC-49** Known, accepted limit: if a sound starts within 0.5 s before the user calls Siri, that Siri call is muted.
  Source: R-34 (11-17) · Code: MM:microphoneChanged · Verify: **auto, tested** (S2) — sound 0.3 s before, only Siri recording → true (the limit is kept on purpose).
- **MIC-50** Setting off: no listeners, nothing is re-muted (Siri opens the mic ~5.5 s after a sound, as macOS does).
  Source: R-34 acceptance "with it off, today's behavior" · Code: MM:updateKeeper · Verify: manual — setting off, muted, trash sound → icon open a few seconds, then muted by Siri.
- **MIC-51** Siri note: only when the setting is on AND "Listen for Siri" is on (`com.apple.Siri` `VoiceTriggerUserEnabled`), Settings shows "“Hey Siri” is on: it opens the microphone when the Mac plays a sound, and Penknife mutes it again. When you call Siri, it still hears you." with a link button "Open Siri Settings…".
  Source: R-34 Built + REGRESSION (note changed); growth review · Code: MeetingOptions; MM:heySiriOn · Verify: manual — open Settings › Microphone with Hey Siri on, then off.

### J. Teams consent (R-31)

- **MIC-52** Setting "Remember my choice for Teams' unmute dialog", OFF by default (`microphone.teamsConsent`); turning it on first asks "Answer Teams' unmute dialog for you?" (Turn On / Cancel); off needs no confirmation; disabled with "Requires Microsoft Teams in the list above." while Teams is off; footer with the responsibility note and "Not affiliated with Microsoft."
  Source: R-31 Built (11-17); legal-advisor (11-17) · Code: TC:isEnabled; MeetingOptions · Verify: manual — turn it on in Settings, Cancel, then Turn On.
- **MIC-53** Scope: only with the option on, a Penknife press (shortcut, Touch Bar or menu item) whose target is the Teams DESKTOP app (Teams in a browser: not covered), and the call's mic read muted just before (= the press unmutes). Muting or unreadable → the shortcut only.
  Source: R-31 Fix built (11-17); D: Teams consent dialog (R-31) · Code: MM:toggle, TC:press · Verify: auto (S1) — `route` → `.meeting(.teamsConsent)` only for Teams desktop with the option on, whatever "Also mute the Mac" says; log — `Teams dialog: muting: not watched via shortcut` / `mic unreadable: not watched`.
- **MIC-54** Always the shortcut first (focus untouched); the Mac follows right after it (MIC-29), not after the watch.
  Source: R-31 "Atajo primero" (11-17) · Code: TC:press (`sendNow`) · Verify: log — `Teams dialog: … (<ms> ms)` ≥ the HUD time; manual — Touch Bar flips at once.
- **MIC-55** Not touched when the call window couldn't be read whole within 0.3 s / 4000 elements, or an alert was already open before the press.
  Source: D: Teams consent dialog (R-31) · Code: TC:press, dialogs · Verify: log — `window too large to check: not watched` / `an alert was already open: not touched`.
- **MIC-56** Watch every 0.1 s for ≤ 1.5 s, only in the call's window, no text read: mic reads open → stop; exactly one web dialog (`AXApplicationDialog`/`AXApplicationAlertDialog`) whose last button row has exactly two labelled buttons → its last (main) button is pressed; 2+ dialogs → nothing; nothing by the deadline → nothing.
  Source: R-31 v2 (11-17, "no lo hagas hardcodeando el texto"); D: Teams consent dialog · Code: TC:press, dialogs, mainButton · Verify: auto after refactor — `mainButton(in: Node)` over a plain tree struct; outcomes via log (`unmuted without an alert`, `pressed the main button (<subrole>)`, `<n> alerts: not touched`, `no alert shown`).
- **MIC-57** Shortcut ignored (consent meeting): 0.6 s after the shortcut, mic still muted and no alert → Teams is brought forward if needed (≤ 1 s + 0.1 s), the call window raised if another Teams window had focus, the mic re-read right before the Space (changed → skip), its mic button pressed, then 1.5 s more watching for the alert.
  Source: R-31 Fix built (11-17); D: Teams ignores its shortcut · Code: TC:press, bringForward, raise, activate · Verify: log — `… via shortcut ignored, then mic button[, Teams brought forward]`; failures `shortcut ignored; Teams didn't come forward` / `mic button not focused (…)`.
- **MIC-58** Pressing = focus the element, confirm Teams' focused element is it (5 × 0.05 s), post Space to Teams; not confirmed → nothing sent. AXPress is never used.
  Source: D: Teams consent dialog ("AXPress does nothing in Teams") · Code: TC:activate · Verify: log — `couldn't focus the main button (<kind>, set <code>, focus on <role/subrole>): not touched`.
- **MIC-59** Afterwards the user gets their place back: brought forward → their previous app returns 0.15 s later (only if Teams is still frontmost); Teams already in front → the previous Teams window is raised and the focused element (e.g. the chat box) re-focused.
  Source: R-31 (11-17, "el foco volvió al texto") · Code: TC:press (`defer`, previousApp) · Verify: manual — work Mac, consent meeting, typing in the chat, press F5 → focus back in the chat.
- **MIC-60** Normal meetings never bring Teams forward or move its focus.
  Source: R-31 Changed (11-17: typing lost letters) · Code: TC:press · Verify: log — `Teams dialog: unmuted without an alert via shortcut (… ms)` with no "brought forward".
- **MIC-61** Never camera, screen sharing, background presses, or any element other than the call's mic button and the single new dialog's main button.
  Source: R-31 proposal + legal-advisor (11-17) · Code: TC:press · Verify: manual — code review that `activate` is only called with `call.button` or `mainButton(...)`.
- **MIC-62** One log line per Teams press: `Teams dialog: <outcome> via <shortcut | shortcut ignored, then mic button>[, Teams brought forward] (<ms> ms)`.
  Source: D: Teams consent dialog; R-31 (11-17) · Code: TC:press · Verify: log.

### K. Truthful icon, Touch Bar, menu bar dot, HUD

- **MIC-63** TRUTHFUL: the Touch Bar button and the dot show the real state of the default input, never what Penknife thinks, and change at once whatever changes it (Penknife, Teams, Control Center, Siri, a device switch), via CoreAudio listeners on mute, input volume and default input device; plus open while Siri hears the user (MIC-40). Presses and Keep muted decide by the device state only.
  Source: R-28 TRUTHFUL MIC STATE IMPERATIVE (11-16); MM:isMuted comment (user 11-16) · Code: MM:MicrophoneWatcher, TouchBarModule:updateMicrophone, StatusMenu:updateIcon · Verify: manual — mute from Control Center → Touch Bar and dot change at once.
- **MIC-64** Read policy (same control that is written, MIC-04): settable+readable mute → mute ≠ 0; else readable volume → volume == 0; else readable mute → mute ≠ 0; else open; no device → open (open decision O-1).
  Source: D: Mic state bug (11-16) · Code: MM:isMuted · Verify: auto after refactor — `readMuted(muteSettable:mute:volume:) -> Bool`.
- **MIC-65** Touch Bar mic button: `mic.slash.fill` muted / `mic.fill` open, VoiceOver "Microphone muted" / "Microphone on", color #FF5D49 (state by symbol, not only color); shown only while the mic module is on and the button isn't hidden; refreshed right after its own tap.
  Source: R-25 (11-13) "ALL ICONS"; D: Touch Bar icons; R-19 · Code: TouchBarModule:updateMicrophone, run; BarLayout · Verify: manual — tap it; the symbol flips.
- **MIC-66** Menu bar dot: top slot, system orange, 4 pt; filled = open, 1 pt ring = muted; same look under Increase Contrast; shown only with "Show status dots in the menu bar" on (default on, `menuBar.statusDots`), the module on and an input device present; redrawn only on a real change; kept beside the red record symbol while recording.
  Source: R-20 MENU BAR DOTS IMPERATIVE (11-13); D: Menu bar dots · Code: StatusMenu:updateIcon, icon, showRecording · Verify: manual — press F5, look at the dot.
- **MIC-67** VoiceOver: the status item's value states both dots ("Mouse jiggler on, Microphone muted") and VoiceOver is told when it changes from elsewhere.
  Source: R-20 (11-13) · Code: StatusMenu:updateIcon · Verify: manual — VoiceOver on, focus the menu bar icon, press F5.
- **MIC-68** Microphone alerts belong to the "Microphone" alert type (`alerts.microphone`, on by default); off hides all of them, errors included, but VoiceOver still announces them; top-center capsule; duration = shared setting 1/2/4/8/15 s (default 4).
  Source: R-20 SETTING PER TYPE IMPERATIVE; CHANGED top center (11-18); R-19 · Code: Core/HUD.swift:show, AlertCategory · Verify: manual — turn Microphone alerts off, press F5 → no capsule.

### L. Settings, defaults, language

- **MIC-69** Defaults: module on (`module.microphone.enabled`); F5; meeting shortcuts as MIC-17; platforms on; Also mute the Mac ON; Keep muted ON; Teams consent OFF; status dots ON; Microphone alerts ON; alert duration 4 s; recording mic OFF (`recording.microphone`).
  Source: MIC-17/18/37/43/52/66/68/79 · Code: Core/Module.swift:defaultOn, Core/Shortcuts.swift, MM, TC, SettingsView, Settings/GeneralTab.swift · Verify: auto after refactor — every reader takes an injected `UserDefaults` suite; one assertion per key on an empty suite.
- **MIC-70** Settings › Modules › Microphone, in order: Meetings (5 rows: app icon or symbol, name, recorder, switch; Restore Defaults; footer "Shortcut = the keys Penknife sends to each app to mute. Match them to the app's own setting."); "Also mute the Mac's microphone" (footer "Off: only the current meeting is muted. If no meeting is found, the Mac's microphone is muted."); "Keep the microphone muted"; Teams consent; "Current meeting" ("The meeting in front, or the last one you used." / "Browser meetings count only when they are the active tab.").
  Source: R-28 variant B (11-16); R-31; R-34 · Code: SettingsView:MeetingOptions, MeetingIcon · Verify: manual — open Settings › Microphone.
- **MIC-71** Every visible mic string exists in English and Spanish (Spain wording); brand names are not translated.
  Source: Phases (es/en); Public copy (11-15); MS:name comment · Code: Resources/Localizable.xcstrings · Verify: **auto, tested** — script over the catalog: each mic key has an `es` value.

### M. Privacy and logging

- **MIC-72** Browser window titles (they can name the meeting) are used only to match and are never logged or stored.
  Source: D: Meeting detection fix (c) "Titles are never logged" · Code: MS:windowTitle, findCurrent · Verify: log — no meeting title appears in a day of Microphone logs.
- **MIC-73** No text of Teams' dialogs or buttons is read for matching or logged; logs carry outcome, role/subrole, counts and ms only. Siri's panel is found by its element identifier; nothing of Notification Center (banners included) is read beyond identifiers, or logged.
  Source: R-31 v2 (11-17); legal-advisor "no storing/logging" · Code: TC (all), MS:readMuted (roles only) · Verify: log — `Teams dialog:` and `App mic:` lines contain no label text.
- **MIC-74** Logs: subsystem `Penknife`, category `Microphone`; press lines at notice (kept by `log show`), keep-muted and Siri's panel at debug; recording processes' bundle IDs are logged in clear.
  Source: D: Meeting = in a call (".notice"); R-34 Built (debug) · Code: MM, MS, TC loggers · Verify: log.
- **MIC-75** Nothing is stored or sent: recent apps and the saved input volume live in memory only; the module makes no network calls; the Hey Siri preference is only read.
  Source: code only (R-31 legal "no storing") · Code: MM:savedVolume, heySiriOn; MS:recent · Verify: manual — code review (no writes besides the settings keys, no URLSession).
- **MIC-76** Permissions: Accessibility for meeting presses (titles, button read, key posting, Teams consent) and for Siri's panel (MIC-40); no Automation/Apple Events; the mute toggle itself needs no Microphone permission (only the screen recording's voice does).
  Source: D: Meeting detection fix (c); "needs no Microphone permission" is code only · Code: MM:needsAccessibility; GeneralTab (Accessibility text) · Verify: manual — fresh install: F5 with no call works before granting anything.

### N. Resource use

- **MIC-77** No polling. Between presses only: one NSWorkspace activation observer; with Keep muted on, CoreAudio listeners on the default input (mute, volume, device) and on the default output's "is running"; the dot's watcher only while the mic dot is shown; the Touch Bar's watcher while the Touch Bar runs; with Accessibility, one AX observer on Notification Center (window created / element destroyed; one look 0.15 s after a burst, the recorder list read only while Siri's panel shows). Call detection, the call's state and the Siri check at a press are read only at the press. Idle: 0 % CPU.
  Source: R-28 (11-16) "no constant watching"; R-34 acceptance "zero cost"; D: Menu bar dots · Code: MS:start, MM:updateKeeper, StatusMenu:updateIcon, TouchBarModule:startSources · Verify: manual — `measure-resources` skill on idle Penknife: 0 % CPU, no wakeups from Microphone.
- **MIC-78** The Chromium/Electron web accessibility tree (`AXManualAccessibility`, `AXEnhancedUserInterface`) is turned on only for the read and turned off right after, unless it was already on (VoiceOver); measured +80 MB while on, freed after.
  Source: D: Reading a meeting app's mute state; D: Meeting button read in Chrome · Code: MS:withWebTree · Verify: auto after refactor — inject the AX get/set: attributes already on are never set; the ones set are cleared at the end.
- **MIC-79** All Accessibility work runs off the main thread and every wait is bounded (browser ≤ 1 s; read ≤ ~1 s retry; Teams watch 1.5 s, +1.5 s after a button press).
  Source: MS:findCurrent/readMuted comments; R-31 · Code: MS, TC (global queue) · Verify: log — `(<ms> ms)` in `App mic:` and `Teams dialog:` lines (measured 50–1300 ms).
- **MIC-80** Module off releases everything it holds: activation observer, defaults observer, keep-muted listeners (B-1 fixed 2026-11-18), the Siri panel observer.
  Source: R-15 · Code: MM:stop · Verify: **auto, tested** — start/stop twice, `holdsObservers` is false (fails without the B-1 fix; checked 2026-11-18).

### O. The screen recording's microphone (R-29)

- **MIC-81** The recording's mic switch is off by default and remembered (`recording.microphone`); it can be switched during the recording (toolbar `mic`/`mic.slash`, help "Microphone: on/off", VoiceOver value On/Off).
  Source: R-29 "mic and Mac sound off by default and remembered"; R-33 · Code: Recording/RecordingState.swift:RecordingPrefs, RecordingToolbar.swift, RecordingSession.swift:toggleMicrophone · Verify: manual — record with the mic on, record again → still on.
- **MIC-82** First use asks for the Microphone permission; denied → the recording continues without voice and the HUD says "Recording without the microphone" / "Allow Penknife in System Settings › Privacy & Security › Microphone" (Screenshots alert type).
  Source: R-29 · Code: RecordingSession:microphoneAllowed · Verify: manual — deny the prompt; the recording goes on.
- **MIC-83** No microphone or it can't be opened → the switch turns off and the HUD says "Recording without the microphone" / "No microphone could be opened".
  Source: code only · Code: ScreenRecorder.swift:startMicrophone, RecordingSession:microphoneFailed · Verify: log — `No microphone to record` / `Microphone can't be opened` (Recording log).
- **MIC-84** The capture session exists only while the switch is on, so macOS shows the mic in use only then.
  Source: ScreenRecorder header (R-29) · Code: ScreenRecorder:setMicrophone · Verify: manual — record with the mic off → no orange dot.
- **MIC-85** Recording never changes the Mac's mute (recording while muted records silence); while it records with the mic on, Penknife counts as another app using the mic, so Keep muted doesn't re-mute and the Siri check doesn't block presses. Code only, not measured.
  Source: code only · Code: ScreenRecorder; MM:microphoneChanged, isSiriListening · Verify: auto (S2) — Penknife among the recorders → no re-mute, not "Siri listening"; manual — muted, record with mic on, speak → silent track (to confirm with the user if wanted).

## 2. Open decisions, questions and known bugs

Waiting for the user (asked 2026-11-18; recommendation in brackets):
- **O-1 No input device.** The Touch Bar shows the mic open (`isMuted` is false with no device), while the menu bar dot hides because it "would claim an open mic". [Design question: `ux-ui-designer` + visual variants.]
- **O-2 A device that can't be muted.** Neither mute nor input volume settable: nothing is written, but the HUD still says "Microphone muted/unmuted". Also DECISIONS says input volume 0 is not a true mute (−12 dB), yet it is the fallback mute (MIC-04). [Say clearly that it couldn't be muted.]
- **O-3 Meeting press without Accessibility.** Nothing happens apart from the system prompt (once per launch); no alert. R-3 asks the jiggler to "say so instead of doing nothing". [Show an alert.]
- **O-4 Mac sound during a muted call (not measured).** Keep muted doesn't act while another app records, so with Hey Siri on a sound can open the Mac's mic ~5 s; DECISIONS measured that Teams unmutes itself when the Mac's mic is unmuted (0.3–0.5 s). Whether this unmutes a muted Teams call is unknown. [Measure before deciding.]

Not measured, no decision yet:
- **O-5 Press right after a Mac sound.** With Keep muted and Hey Siri on and no call: Penknife re-mutes, but Siri keeps recording ~5.5 s, so `isSiriListening` is true and an F5 press then may be ignored ("Toggle ignored: Siri is listening").
- **O-6 R-31 after consent (2026-11-18 log).** (1) A second press 44 ms after accepting read Teams still muted (the user may have pressed twice); (2) a later unmute again needed the mic button, without an alert. Act only if a single press ever leaves the user muted.

Known bugs:
- **B-2 Called Siri hears you while the icon says muted (breaks MIC-40, MIC-63).** Measured 2026-11-18 (user: "el ícono no mostraba el estado real. ESE ERA EL BUG"): "Hey Siri" with the Mac muted → Siri recorded ~5 s and answered, the input mute stayed 1 the whole time, with Penknife running AND with Penknife quit, so the icon (which follows the mute) stayed closed. Not caused by a commit: since R-34 (verified live 11-17) only B-1 and S1 touched the module, and with Penknife quit nothing of Penknife runs. The 11-16/11-17 measurements saw Siri clear the mute when called; today it didn't (a sound still makes it clear the mute: 12:46, 0.05 s after the sound). macOS announces nothing (again: no CoreAudio process or device event, no app activation, no Siri window). FIXED 2026-11-18 (MIC-40 rewritten; user: "listo, arreglado"): the icon also follows Siri's panel. Tried first and replaced the same day: the built-in speakers' "running" state (it does follow a called Siri, also with AirPods) plus who plays (a Mac sound's player shows at once): it worked without music, but with music Siri records all the time and calling it announces nothing (user: "SOLO PASA CON MUSICA"); a rule on Siri's voice (`com.apple.sirittsd`) didn't help either (no announcement when it spoke over music).
- **B-1 Module off kept a CoreAudio listener (broke R-15).** `MM:stop()` stopped `keeper` but not `outputWatcher`; each off→on cycle left one more listener on the default output's "is running". FIXED 2026-11-18 (on main, not released yet); test "MIC-80 module off holds nothing" fails without the fix.

Doc conflicts fixed on 2026-11-18 (REQUIREMENTS/DECISIONS lines marked superseded): "Also mute the Mac" default (ON wins), option A's "send only if needed" (always sent), R-31 v1 text-matching flow (v2 text-free wins), "MuteGuard" rejected vs R-34 built (R-34 wins, narrower), old Apple Events/bundle-prefix browser detection (window title + responsible pid win), stale headers ("not built", "not released"). The stale code comments (`MS:findCurrent` "Apple Events", `SettingsView` "quoting Teams' text", MM's "only a workspace notification") were fixed on 2026-11-18.

## 3. Rejected / out of scope (do not rebuild)

- Muting only the Mac without touching the app (option B, Mic Drop style): others wouldn't see you muted (kept only as a fallback idea).
- Teams' local WebSocket API (port 8124): retired by Microsoft on 2026-06-30.
- Watching the meeting's mic state between presses: constant watching, CPU/battery (user, 11-16).
- Siri badge / Siri-listening indicator: macOS gives no signal; it needed polling (0.03 % CPU), "invasive".
- Click sound on Touch Bar taps: with Hey Siri on it made Siri undo the tap's toggle.
- 0.4–0.6 s de-dup window on presses: swallowed quick second presses (the "long press" was really Siri).
- "MuteGuard" re-muting every Siri clear (11-16), and R-34's first version that re-muted every clear: fought Siri and broke "called Siri hears you".
- AppleScript / Apple Events (tab URLs) for browser meetings: Firefox has none, Opera's is unreliable, needs Automation; replaced by window titles. No "Allow JavaScript from Apple Events". No new browsers installed for testing (user).
- Matching Teams' consent text (v1, exact English question): texts change, admins customize them, localized (user: "no lo hagas hardcodeando el texto").
- Pressing Teams' mic button on every unmute: ~0.3 s of focus lost letters typed in the chat; it would bring Teams forward on every unmute (visible while sharing).
- AXPress on Teams' buttons: reports success, does nothing.
- Consent: camera, screen sharing, pressing in the background, Teams in a browser, detecting consent meetings in advance; a sharing check and an alert-kind check were not applied (sharing already needs consent; text-free by the user's choice).
- Advising users to "disable Hey Siri for the best experience", or claiming the mic "never opens": sounds broken; say "mutes it again" instead (growth review).
- Native macOS notifications for mic alerts: hidden while sharing/DND, so no mic confirmation in meetings.
- Telling a called Siri by audio (B-2, 2026-11-18): the built-in speakers' running state + who plays fails with music (Siri records all the time); polling who records doesn't help either. Siri's panel is the signal.

## 4. Test plan (step B in progress)

Done 2026-11-18: test target `PenknifeTests` (Swift Testing, host = Penknife.app), the as-is tests below + MIC-80; S1, S2 and B-2 (22 tests pass). Next: S3–S5, one at a time, each refactor verified by its tests AND the affected manual rules.

Warning: with Penknife.app as the test host, `UserDefaults.standard` is the user's real settings. Readers must take an injected suite before any defaults test.

- **Testable as-is:** `MeetingPlatform.matches(title:)` (MIC-24), `MeetingTracker.state(fromLabel:)` (MIC-30), `MeetingPlatform.forApp(_:)`/`bundleIDs` (MIC-11), `MeetingTracker.browsers` (MIC-22), `KeyboardShortcuts.Name.meeting*` defaults (MIC-17). Small tweaks: `isChromium` should take a bundle ID; `flags(_:)` should be internal (MIC-20).
- **S1 Press routing** — DONE 2026-11-18 (MM, "Press rules"). Three steps, as the press happens (the call's state is known only after the read): `route(meeting: (platform, isBrowser)?, axGranted: @autoclosure, alsoMac, teamsConsent) -> PressRoute` (`.mac`, `.nothing`, `.meeting(.teamsConsent | .readAndSend | .sendOnly)`); `afterSend(alsoMac, appMuted, macMuted) -> .setMac(muted:) | .showToggled` with `newMacMuted(appMuted:macMuted:)`; `macGate(siriListening, device) -> .siriListening | .noDevice | .write(device)`. Covers MIC-03, 06, 07, 28, 29, 35, 36, 39, 53. MIC-21 stays manual (`route` has no shortcut input by design).
- **S2 Keep-muted decision** — DONE 2026-11-18 (MM, next to `isSiriListening`). `shouldRemute(wasMuted, isMuted, now, ownChangeUntil, outputStarted, recorders: @autoclosure) -> Bool` (the CoreAudio recorder query runs only when everything else holds) and `isSiriListening(recorders:)`. Covers MIC-38, 42, 44, 46, 47, 49, 85. Test lesson: `#expect(f(x()))` evaluates `x()` itself, so a laziness check computes the result outside `#expect`.
- **S3 Meeting picker** — `orderCandidates(front, recent, running, micPIDs)` + `pickTarget(candidates: [(bundleID, title?)], enabled: Set<MeetingPlatform>)` + `remember(recent, app)`. Covers MIC-09, 13, 14, 15, 16, 25.
- **S4 Device control policy** — `readMuted(muteSettable, mute, volume) -> Bool` and `writePlan(muteSettable, volumeSettable, mute, currentVolume, savedVolume)`. Covers MIC-04, 48, 64, O-1, O-2.
- **S5 Teams consent step** — `mainButton(in: Node)` over a plain tree struct, plus `nextStep(elapsed, micState: Bool?, dialogs: Int, mainButtonFound, buttonPressed) -> Step` for the 0.1 s loop. Covers MIC-55, 56, 57, 60.

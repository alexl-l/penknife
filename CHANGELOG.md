# Changelog

Version = `MARKETING_VERSION` in the Xcode project. Build = number of git commits (set by
`scripts/install.sh`). Each version gets a git tag `vX.Y`.

## 1.22 — 2026-11-26

Save a recording from the keyboard, and see each shortcut when you hover.

- **End window shortcuts.** In the window that opens after a screen recording, ⌘S now saves the video (Return still does too) and ⇧⌘S saves the GIF. Hover a button to see its shortcut: "Save as Video (⌘S)", "Save as GIF (⇧⌘S)" and "Copy (⌘C)".

## 1.21 — 2026-11-26

Going back to Mouse while recording takes one press.

- **Mouse button.** While recording the screen, pressing Mouse in the recording toolbar (or its key Q) now gives the clicks back to your apps right away, whether a drawing tool is armed or not. Before, after picking a tool such as the rectangle, the first press only disarmed it and you stayed in drawing mode, so you had to press twice. Esc still steps back one level at a time: it ends text, deselects, disarms the tool, then returns to Mouse.

## 1.20 — 2026-11-23

Let the Mouse Jiggler turn itself off at the end of your day, and add Return to macros in one click.

- **Turn off at.** A new row in Settings › Mouse Jiggler, with a time and a switch. It is off by default and the time is 6:00 PM. Every day at that time the jiggler turns itself off and shows "Mouse Jiggler off — Scheduled time". If you turn it on after that time, it stays on until the same time the next day. If the Mac is asleep then, it turns off when the Mac wakes. No network and no background polling.
- **Return step.** The Add Step menu has a Return item that adds a Key step with ↩ already set. Before, you added a Key step and then recorded Return.

## 1.19 — 2026-11-23

Copy and paste macro steps, and decide whether a macro may run in password fields.

- **Select, copy and paste steps.** In the macro editor, select several steps with click, ⌘-click and ⇧-click, as in Finder. Copy them with ⌘C or right-click, then paste with ⌘V or right-click into the same macro or another. They land below the selected step, or at the end. Copied steps stay inside Penknife: the system clipboard and Clipboard History are not touched. In a text field, ⌘C and ⌘V still work on text.
- **The list follows new steps.** After you add or paste steps, the list scrolls to them.
- **Allow in password fields.** A new option for each macro, off by default. Macros normally stop when a password field or Secure Keyboard Entry is on. Turning the option on asks you first. While secure input is on, Esc can't stop the macro, but a click or switching apps does. Use it at your own risk. The option is not included when you export macros.
- **Macros window.** It no longer gets so narrow that its right side is cut off.

## 1.18 — 2026-11-23

Add macro steps where you need them.

- **Steps go where you are.** In the macro editor, select a step or type in it, and Add Step puts the new one right below it instead of at the end. Create from Text… works the same way. With nothing selected, new steps still go at the end.

## 1.17 — 2026-11-23

Pick an emoji by typing its name, and a handful of macro editor and clipboard fixes.

- **Emoji search in the icon editor.** For macros and pinned clipboard items. Type a word in English, such as "smile", then click an emoji or press Return. The list comes from macOS, so new emojis arrive with macOS updates. Flags, skin tones and professions are still in the Emoji & Symbols button, without searching. macOS's own search couldn't hand the chosen emoji back to a menu bar app.
- **Macro editor.** Choosing an item in Clipboard History pastes it into the field you were typing in, with no ⌘V. An emoji picked in Emoji & Symbols is set the first time. Clicking outside a text or time field takes the focus away. Emoji icons are no longer clipped in the macro list.
- **Clipboard.** After you close a pin's icon editor, typing searches the history again.

## 1.16 — 2026-11-23

Pin a screenshot above your windows, pick any color on screen, hold a key to talk while muted, and keep your Mac awake.

- **Pin a screenshot.** A Pin button (⌘P) in the screenshot editor floats the capture above every window in a corner of the screen (bottom left by default, you can change it). Pins stack. Move one, resize it (drag the edges, pinch or scroll), double-click to edit it again with its marks still editable, or right-click to copy, save or close.
- **Color picker.** Press I in the screenshot overlay, or use its own shortcut or the "Pick Color" menu item. A round loupe follows the pointer and a click copies the pixel's exact hex.
- **Copy Text.** Copy the text in a screenshot. Recognition runs on your Mac.
- **Hold to talk.** With the mic muted, hold the mute shortcut (F5) or the Touch Bar mic button to talk. Let go and it mutes again. It works in calls too. On by default, in Settings › Microphone.
- **Mute when the Mac locks.** Optional, off by default.
- **Keep Awake.** A new module that stops the Mac from sleeping without moving the pointer. Toggle it from the menu or with an optional shortcut. It turns off when Penknife starts and when you lock the Mac.
- **Export and import settings.** Settings › General › Settings File saves your settings, shortcuts, Touch Bar, pinned items and macros in one file. Importing replaces them and restarts Penknife. The Teams consent switch is not included: you confirm it on each Mac.
- **Touch Bar.** Hold buttons fill while you hold them. Holding Screenshot while the capture is open switches to recording. The battery bolt shows as soon as the Mac is plugged in.
- **Clipboard.** Choose how many pinned rows show: 3, 5, 8, 12 or All.
- **Settings.** Notes sit as footers under their options and shortcuts are grouped.

## 1.15 — 2026-11-22

Macros fill forms for you, and you can update a pinned clipboard item without leaving the panel.

- **Macros.** A new module. Record or write a sequence of steps (keys, text, waits, files, values from your data table) and run it from a panel (⌃⌥M) or from its own shortcut. It types in the app in front and stops if you switch apps, click or press Esc. The menu bar icon shows a play symbol while it runs.
- **A data table for repeated runs.** The Data tab is a table you edit in place. Each run uses the next row, and `{name}` in a text step is filled from the column of that name. Paste a table from Excel, Numbers or Sheets to start.
- **An icon for each macro.** Give a macro a letter or an emoji on a background color, the same as pinned clipboard items. It shows in the editor and in the list.
- **Import and export.** Share a macro as a file. Macros from someone else ask before they can paste files or press ⌘ shortcuts. Changes are saved automatically.
- **Update a pinned value.** In the clipboard, "Update Value…" (⌘U) opens an editor beside the row. Type or paste the new text and the pin keeps its place and icon. Pins can also be reordered.
- **Alerts on the Touch Bar.** Alerts show their buttons on the Touch Bar, with Delete in red, instead of leaving it black.
- **Shortcut recorders.** Updated KeyboardShortcuts to 3.1.0: shortcut fields record on the first click again on macOS 26.

## 1.14 — 2026-11-20

Pressing Play from Penknife now opens Apple Music when nothing is playing, and Settings always shows which page you're on.

- **Play opens Apple Music.** With "Any app (media keys)" as the player and nothing playing, Play from the Touch Bar, a shortcut or the menu opens Apple Music, and Block Apple Music no longer closes it. Headphone clicks are still blocked.
- **Apple Music is the default player.** New users who haven't picked a player start with Apple Music, not Spotify. Your existing choice is never changed.
- **Settings title.** The window title shows the current page from the moment it opens, instead of "Penknife Settings".

## 1.13 — 2026-11-20

Change the speed of a recording before you save it, and pin clipboard items with an icon of your own.

- **Recording speed.** The recording window has a speed menu: 1×, 1.5×, 2× or 4×. It applies to the preview, the saved video, the GIF and the copy. The voice keeps its pitch, it works with trim, and the note shows how long the result will last.
- **Your own icon for pinned items.** Give a pinned clipboard item a letter or an emoji on a background color. Right-click and choose Customize Icon…, or press ⌘E.
- **A more compact clipboard panel.** Pinned items stay fixed at the top. Rows and icons are smaller, and the panel height follows the number of items.
- **Clearer wording.** Settings, menus, alerts, the Touch Bar and recording now say things more plainly, in English and Spanish. In Spanish, the speed test is now "Prueba de velocidad".
- **Smaller fixes.** Settings shows every page name in full in the sidebar. Recording no longer keeps a little memory after each 3-2-1 countdown.

## 1.12 — 2026-11-19

Hold the Screenshot shortcut to record your screen, and every button in the editor and recording toolbar now has a key.

- **Hold to record.** Hold the Screenshot shortcut (F1 by default) or the Touch Bar Screenshot button (2 seconds by default), pick the area, and the 3-2-1 countdown starts. Choose 1, 1.5, 2 or 3 seconds, or turn it off. The Touch Bar follows your settings at once.
- **Toolbar during the countdown.** The recording toolbar now shows while the 3-2-1 runs. Stop cancels the recording. Switch the microphone and Mac sound with M and S, and the first change restarts the count.
- **A key for every button.** Every button in the screenshot editor and the recording toolbar has a keyboard key, shown on hover or while you hold ⌘. Drawing while you record uses the same keys as the editor, and a shape's letter places it. ⌘D duplicates a mark. ⇧⌘R stops a recording while Penknife has the keyboard, and ⌃⌥D switches Mouse and Edit in one press.
- **Close after saving.** A new setting, off by default, closes the recording window after you save the video or GIF, or copy it.
- **Safer recordings.** Quitting Penknife asks before it discards a recording you have not saved. If the sound fails, the video is kept without sound. ⌃⌥P opens the menu while you record.
- **Microphone just works.** Recording with the microphone unmutes a muted Mac mic, then mutes it again afterwards. With no microphone connected, the Touch Bar button and the menu item are dimmed.
- **Screenshot fixes.** The toolbar stays on screen for a window that extends past the bottom edge. Main-menu keys no longer leave the editor. Recording from the editor now captures the right part of the screen.
- **New Permissions page.** Settings lists the five macOS permissions Penknife can use, with the state of each, and permission alerts point to it. New alerts cover missing meeting and media key access, a refused Automation request, and a microphone that can't be muted.
- **Settings and menu bar look.** Sidebar icons now look like macOS System Settings tiles, in solid colors. The menu bar status dots are bigger, at 6 pt like Apple's.
- **Smoother Touch Bar.** The bar comes back at once when you close a dialog with its button on the Touch Bar. Sliders follow your finger and keep their level when you lift outside the slider.
- **Clipboard history.** The panel opens at once even with many screenshots. Web formatting is kept, and files that no longer exist leave the list. The Clipboard page shows the space pasted images use.
- **Smaller fixes.** Launch at login now follows System Settings, so removing it there turns the choice off. Mouse Jiggler stops when you move the mouse. The speed test reports a crash of its tool as a failure, and weather older than 2 hours shows as no data.

## 1.11 — 2026-11-18

Unmute works on microphones the Mac can only mute by volume, and the Touch Bar uses less power when buttons are hidden.

- **Unmute works on volume-only microphones.** On inputs the Mac can only mute by volume, a press during a call could leave the mic muted after the next unmute. Now unmute works, and an input already in the state you asked for is left alone, with its volume kept.
- **Touch Bar customizing in real time.** The Touch Bar now stays visible while Customize Touch Bar is open and follows each change as you make it. The preview matches the bar exactly, including the time when the bar falls back to it. Other apps' dialogs still make the bar step aside.
- **Lighter Touch Bar.** Buttons you removed from the bar now cost nothing. The speed test, battery, microphone, brightness, keyboard, volume and playback buttons only run while they are on the bar, which saves CPU and battery.
- **Native Dialogs stays quiet.** On a Mac without a Touch Bar, or with the Touch Bar module off, it no longer watches apps in the background.
- **Clean restart of the Touch Bar.** Turning the Touch Bar module off and on again no longer leaves the bar hidden or the speed test showing a frozen needle or an old result.
- **Clear settings without a Touch Bar.** On a Mac without a Touch Bar, the Touch Bar and Native Dialogs modules now show as Unavailable, with a short note. Your saved settings are kept and come back on a Mac with a Touch Bar.

## 1.10 — 2026-11-18

Teams unmute now works when recording starts mid-meeting, and the microphone icon stays accurate while Siri listens.

- **Teams unmute works when recording starts mid-meeting.** With "Remember my choice for Teams' unmute dialog" on, unmuting with Penknife's shortcut now works even if someone starts recording after the meeting began. Before, Teams' "recording started" notice stayed open and you stayed muted. Meetings that start already recording are unchanged, and Penknife still only answers the consent dialog that its own unmute opens.
- **Accurate mic icon with Siri.** The Touch Bar button and the menu bar dot now show the microphone as open while Siri is listening to you, also while music plays. Before, they could say muted while Siri heard you.
- **Microphone off means off.** Turning the Microphone module off now stops all of its background listening.

## 1.9 — 2026-11-18

Alerts no longer collide with Apple's notification banners.

- **Alerts at the top center.** Penknife's alerts now appear centered under the menu bar (or the notch) instead of the top right. A Teams message or another Apple banner no longer covers them, and they no longer cover it or the volume indicator. With the pointer on a second screen, the alert shows on that screen.

## 1.8 — 2026-11-18

GIFs from screen recordings look right from the first frame and are several times smaller.

- **Cleaner GIFs.** Dark backgrounds no longer turn into black patches at the start of a GIF.
- **Smaller GIFs.** Each frame now stores only what changed, so a GIF is often 5 to 7 times smaller (a 6-second clip went from 1.4 MB to 207 KB).

## 1.7 — 2026-11-17

Record your screen as a video or GIF and draw on it as you go, and your mute stays muted when "Hey Siri" opens the microphone.

- **Screen recording.** Record the full screen, an area or a window (⌃⌥R) as an MP4 video or a GIF. Switch the Mac's sound and your microphone on or off, and pause when you need to. A timer in the menu bar shows the time; click it to stop.
- **Draw while you record.** Marks appear in the recording as you make them (⌃⌥D switches between drawing and using your apps). Blur hides what's behind it in the file itself.
- **Edit your marks.** Select, move, resize and erase any mark, in the screenshot editor and in the recording, with the same tools in both. The new Line can be bent into a curve.
- **Fewer clicks.** Drag an area, press Space for a window or Return for the full screen, and a quiet countdown starts. When you finish, Trim cuts the start and end before you save as video, save as GIF or copy.
- **"Keep the microphone muted"** (Settings → Microphone, on by default). When "Hey Siri" opens the Mac's microphone because the Mac played a sound, Penknife mutes it again within a moment. Calling Siri yourself still works.

## 1.6 — 2026-11-17

Unmuting with Penknife's shortcut now works in Teams meetings that ask for recording consent.

- **Teams unmute works when consent is required.** With "Remember my choice for Teams' unmute dialog" on, Teams used to ignore its own mute shortcut until you consented, so nothing happened. Penknife still sends the shortcut first; if Teams ignores it, Penknife presses Teams' mic button for you, bringing Teams forward for a moment if it was behind and then returning to your app, so the consent dialog appears and gets answered. Normal meetings are unchanged: Teams isn't brought forward and your typing focus isn't touched. You remain responsible for consent.

## 1.5 — 2026-11-17

The mic shortcut now follows the call, and the Teams unmute setting works in any language.

- **Mic shortcut follows the call.** When the meeting's mic button can be read, each press does the opposite of the call's state, and the Mac's microphone follows. Before, if Teams muted everyone (for example when a recording starts), the first press muted your Mac instead of unmuting you in the call.
- **"Remember my choice for Teams' unmute dialog"** (Settings → Microphone, off by default) no longer depends on the dialog's wording. It works in any language and with messages customized by your organization, and only when you unmute with Penknife's shortcut. You remain responsible for consent, so check your employer's policy first.

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

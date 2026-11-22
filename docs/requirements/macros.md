# Macros — requirements (current behavior)

Source of truth for what Macros (R-35) must do TODAY. The story behind each rule (the user's words, what was rejected) stays in `docs/REQUIREMENTS.md` (R-35); technical choices in `docs/DECISIONS.md` (Macros). Where they disagree with this file, this file wins. Written 2026-11-22 when the module was built.

**How to use it.** Before changing Macros, read the rules of the parts you change. After the change run `scripts/test.sh` and check every affected rule by its Verify line.

Code abbreviations: MM = `Macros/MacroModel.swift`, MR = `Macros/MacroRunner.swift`, MO = `Macros/MacrosModule.swift`, MP = `Macros/MacroPanel.swift`, ME = `Macros/MacroEditor.swift`, SM = `App/StatusMenu.swift`, EP = `Core/EventPoster.swift`.

## 1. Rules

### A. The module
- **MAC-01** A module of its own, "Macros" (both languages), on by default, Settings tile blue with `keyboard.badge.ellipsis`, summary "Fills forms for you: text, keys, waits and files, in order, in the app in front. Stops if you switch apps, click or press Esc." While no macro runs it has no timer, observer or event monitor; the editor window and the list panel exist only while open. Needs Accessibility (already granted to Penknife); without it a run shows the permission alert (category "Macros").
- **MAC-02** Shortcuts: the list ⌃⌥M (Settings › Macros › Shortcut, and Settings › Shortcuts); each macro may have its own (recorded in the editor, stored as `KeyboardShortcuts_macro.<id>`). A deleted macro's shortcut is reset. Module off → all of them are disabled.
- **MAC-03** Settings › Macros: "New macros type text by" Pasting / Keystrokes (default Pasting, `macros.typesText`); "N macros" with "Edit Macros…"; footer "Macros are stored on this Mac, only for you. Don't use them for passwords." Alerts can be hidden under General like the others (category "Macros").

### B. A macro and its steps
- **MAC-05** A macro: name, steps, "Type as" Paste / Keystrokes, data rows, counter, apps it was used in. Steps: Type Text (with variables), Key (Tab, Return, Esc, arrows, Space from a menu, or any key/combination recorded, e.g. ⌘A), Wait (ms, 0–60 000, default 300, step 100), Wait for Me, File (paste the file, or type its path via ⌘⇧G + path + Return for Open dialogs), Pinned Item (follows one pinned clipboard text).
- **MAC-10** Variables in Type Text: `{date}`/`{fecha}`, `{time}`/`{hora}` (system formats), `{n}` (counter, +1 on each completed run), `{random}`/`{aleatorio}` (6 random digits), `{clipboard}`/`{portapapeles}` (the clipboard's text when the run starts). Verify: MAC-10 test.
- **MAC-11** Unknown names and lone braces are typed as written. Verify: test.
- **MAC-12** `{ask:Name}`/`{preguntar:Nombre}`: before the run a small glass prompt "Details for “macro”" asks each question once, prefilled with the last answer; Return runs, Esc or a click elsewhere cancels (nothing runs). Verify: test + live.
- **MAC-13** Pinned Item step: at run time the text of the pin it follows (by id, not position: copying or reordering doesn't break it). If the pin is gone (deleted, unpinned, not text, or Clipboard History off) it is asked in the same prompt, prefilled with the last value used, with the note "The pinned item is gone. Type the value for this run." Updating the pin: CB-34.

### C. Data rows
- **MAC-20** Data tab: paste a table; the first line names the columns (tabs, else semicolons, else commas). Each column is a variable `{name}` (case-insensitive). Verify: test.
- **MAC-21** Each completed run uses the next row; a stopped run keeps the same row for the next try. The panel row shows "N steps · row x of y". Verify: test.
- **MAC-22** "Repeat rows" checkbox (user, 2026-11-22): on (default) → after the last row the next run starts at row 1; off → the macro doesn't run and the alert "“macro” didn't run — No rows left. Turn on “Repeat rows” or start again in the editor." shows. "Start Again" sets the next row to 1. Verify: test.
- **MAC-23** Changing the table (columns or row count) starts again at row 1.

### D. Create from text
- **MAC-30** "Create from Text…" sheet, mode KEY=value: each line → key, Tab, value, Return (split at the first "="; blank lines skipped). Verify: test.
- **MAC-31** Mode "One text per line": each line a text, Tab between them. The sheet shows "N steps will be added"; the steps are appended. Verify: test.

### E. Storage, export, import
- **MAC-40** Saved to `~/Library/Application Support/Penknife/Macros.json`, folder 0700, file 0600, written 0.4 s after the last change (and when the editor closes). Verify: test.
- **MAC-41** A file that can't be read is moved aside as `Macros (unreadable <time>).json`, never written over. Verify: test.
- **MAC-42** Export (one macro from its context menu, or "Export All…") writes JSON with what the macros do; run state (counter, row, apps, answers, last pinned values) stays on this Mac. Verify: test.
- **MAC-43** Import: new ids; a macro with the same name asks "Keep Both" (renamed "Name 2") or "Replace" (keeps the existing id and shortcut). Verify: test.

### F. The list panel
- **MAC-45** ⌃⌥M opens a glass panel like the clipboard's (480 pt wide, rows 28 pt, height set on open, 300–680 pt and ≤ 72 % of the screen, same position setting). Search "Search Macros" (name only). Macros used in the app in front first under "In <app>" / "En <app>" (most recent first), the rest under "All" / "Todas" (headers only when the first group exists). Row: ▶, name, "N steps", its shortcut. Footer "↩ Run ⌘E Edit ⌘N New". Keys: ↑↓, Return runs, Esc closes, ⌘E edit, ⌘N new, ⌘D duplicate, ⌘⌫ delete (asks). Empty: "No Macros" + "Create one to type text and keys for you." + "New Macro". Click elsewhere closes it.
- **MAC-46** Running from the panel: it closes, the app you were in keeps the keyboard, the run starts 0.15 s later.

### G. Running
- **MAC-50..52**: clipboard rules CB-34, CB-35 (tests named MAC-50..52).
- **MAC-55** Text goes in by pasting (default): the text is put on the clipboard marked `org.nspasteboard.TransientType` (Clipboard History skips it) and ⌘V is sent; the next clipboard change waits 0.15 s so the app reads the right text. Keystrokes mode types the text as key events (16 UTF-16 units per event, newlines as Return).
- **MAC-56** The run waits (≤ 1 s) for the shortcut's modifiers to be released, then runs the steps with 40 ms between them, in the app that was in front when it started.
- **MAC-57** Stops at once (alert "Macro stopped", with the reason) when another app comes to the front, on any click, or on Esc pressed by the user (Penknife's own Esc keys are marked, EP `marker`, and ignored). Nothing more is typed.
- **MAC-58** Wait for Me: the run pauses; clicks and typing are allowed; the list shortcut or the macro's own shortcut continues it; Esc stops it. It continues only if the same app is in front, else it stops ("Another app came to the front").
- **MAC-60** The user's clipboard (every type of every item) is put back when the run ends or stops, 0.3 s after the last paste. Verify: test.
- **MAC-62** Menu bar while running (indicator A, user 2026-11-22: "el triángulo para el indicador"): the Penknife logo becomes a blue `play.fill`; while waiting, a blue `hand.raised.fill` with the tooltip "Waiting… press the shortcut to continue"; the status dots stay. VoiceOver value "Running macro <name>" / "Macro <name> is waiting. Press its shortcut to continue." A finished run shows nothing. The jiggler holds off while a macro runs.

### H. The editor
- **MAC-70** Own window "Macros" (700×540, min 620×420, position remembered; variant A, user 2026-11-22): macros on the left (+, −, ··· with Import… / Export All…; right-click: Duplicate, Export…, Delete…), the chosen macro on the right: name, Shortcut recorder, "Type as" Paste / Keystrokes, Steps / Data. Steps are 36 pt rows: drag handle, kind symbol, the step's editor, ··· (Duplicate, Delete); right-click adds Move Up / Move Down; VoiceOver actions Move up / Move down / Duplicate / Delete. "Add Step" menu and "Create from Text…" below. The {} menu inserts a variable (and data columns) at the end of the text.

## 2. Open decisions and known limits
- Variables are inserted at the end of the text, shown as plain text (no blue tokens yet).
- Web upload buttons don't take a pasted file (browser limit); Type Path works in Open dialogs.

## 3. Rejected (do not rebuild)
- Script steps and "Run an Apple Shortcut" steps (user, 2026-11-22: "sin script").
- Recording keystrokes (needs Input Monitoring, works like a keylogger).

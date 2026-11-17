# Penknife launch kit

## 1. docs/index.html (exact old -> new)

(a) Hero
OLD: <h1>Your Mac, <em>finally done right.</em></h1>
NEW: <h1>Mute the meeting you're in. <em>Find anything you copied.</em></h1>

OLD: <p class="lead">Meeting-aware mic mute, clipboard history, screenshots and music controls in one tiny menu bar app. Turn on only what you need.</p>
NEW: <p class="lead">Mark up any screenshot, control your music, keep your Mac awake. One tiny, free menu bar app. Turn on only what you need.</p>

(b)+(c) Install (replace the whole <ol> on line 99; add a Homebrew line and a reassurance line)
OLD: <ol><li>Unzip and move Penknife.app to /Applications</li><li>System Settings → Privacy &amp; Security → Open Anyway</li><li>Updates arrive by themselves (Penknife asks first)</li></ol>
NEW: <p>Prefer Homebrew? <code>brew install --cask alexl-l/tap/penknife</code></p>
  <ol><li>Unzip and move Penknife.app to /Applications</li><li>Open it once. macOS will say it can't verify it, then go to System Settings → Privacy &amp; Security → Open Anyway</li><li>Updates arrive by themselves (Penknife asks first)</li></ol>
  <p>Why the warning? Penknife isn't notarized because there's no paid Apple Developer account behind it. The code is open, so you can read it or build it yourself.</p>
(Note: if the .dl section has no style for <code>, add a tiny rule, e.g. code{font-family:ui-monospace,Menlo,monospace;font-size:.92em}. Wording "Prefer Homebrew?" goes first so brew users skip the steps.)

## 2. READMEs

README.md
OLD: 1. [Download the latest release](https://github.com/alexl-l/penknife/releases/latest), unzip it and move `Penknife.app` to `/Applications`.
NEW: Prefer Homebrew? Run `brew install --cask alexl-l/tap/penknife`. Otherwise:

1. [Download the latest release](https://github.com/alexl-l/penknife/releases/latest), unzip it and move `Penknife.app` to `/Applications`.
(Insert the "Prefer Homebrew" line + blank line before the list, i.e. directly under "## Install" blank line.)

README.es.md
OLD: 1. [Descarga la última versión](https://github.com/alexl-l/penknife/releases/latest), descomprímela y mueve `Penknife.app` a `/Aplicaciones`.
NEW: ¿Prefieres Homebrew? Ejecuta `brew install --cask alexl-l/tap/penknife`. Si no:

1. [Descarga la última versión](https://github.com/alexl-l/penknife/releases/latest), descomprímela y mueve `Penknife.app` a `/Aplicaciones`.

## 3. Posts

### Show HN (rules: title starts "Show HN", must be tryable, no vote solicitation, author discloses; no signup needed here)
Title (73): Show HN: Penknife – a free menu bar app that mutes the meeting you're in
Link: https://github.com/alexl-l/penknife

First comment:
Hi HN, I made Penknife. It's a small, free, MIT-licensed menu bar app for macOS 26+.

The part I built it for: one shortcut mutes the meeting you're actually in. It works with Teams, Google Meet, Zoom, Slack Huddles and Webex, and presses each app's own mute shortcut (editable in Settings). Only apps in a call count. With no call, the same shortcut mutes the Mac's microphone, and the icon shows the real state.

It also has clipboard history (search, pin, paste with Cmd+1-9; concealed items like passwords are never saved), a screenshot editor (arrows, text, blur, highlighter; nothing is uploaded), music keys for the player you choose, and a mouse jiggler. Each part is a module; turn one off and it uses no CPU or memory. If you have a Touch Bar, there's an optional one too, but nothing needs it.

Caveats: it isn't notarized (no paid Apple Developer account), so on first launch go to System Settings > Privacy & Security > Open Anyway. It uses some private macOS APIs (for the Touch Bar and brightness), so a macOS update can break a module; the rest keeps running. No account, no analytics.

Install: `brew install --cask alexl-l/tap/penknife` or the release zip. Site: https://alexl-l.github.io/penknife/
I'd like to hear which meeting apps or setups it gets wrong.

### r/macapps
(Couldn't read the live rules; Reddit blocked fetch. Before posting, check the sidebar for the self-promo limit and the developer disclosure rule. Flair: "Free" / "Open Source" if offered, else "Developer"/"Self-promotion"-type flair. Use "I made" wording.)
Title (80): I made a free, open-source menu bar app that mutes only the meeting you're in
Body:
Hi, I'm the developer. Penknife is free and open source (MIT), for macOS 26+.

The hook: one shortcut mutes the meeting you're in, whether that's Teams, Google Meet, Zoom, Slack Huddles or Webex. It uses each app's own shortcut, only counts apps in a call, and falls back to your Mac's microphone when there's no call.

Also included: clipboard history (search, pin, Cmd+1-9; passwords never saved), a screenshot editor, music keys for your chosen player, a mouse jiggler and a speed test. Each module can be turned off completely. It has an optional Touch Bar, but you don't need one.

Heads up: it isn't notarized (no paid developer account). Open it once, then System Settings > Privacy & Security > Open Anyway. Or: `brew install --cask alexl-l/tap/penknife`

GitHub: https://github.com/alexl-l/penknife
Site: https://alexl-l.github.io/penknife/
Feedback welcome, especially on meeting apps that don't behave.

### r/MacOS (rules vary; many such subs restrict self-promo, so check sidebar/ask mods first; frame as a share, not an ad)
Title (66): I built a free menu bar app to mute the meeting you're actually in
Body:
I'm the author. I kept fumbling for the right mute button across Teams, Meet and Zoom, so Penknife has one shortcut that mutes whichever meeting is live (Slack Huddles and Webex too) using that app's own shortcut. No call: it mutes the Mac mic.

It also has clipboard history, a screenshot editor and music keys. Free, MIT, macOS 26+, no account or analytics. Not notarized (no paid developer account), so the first launch needs Open Anyway in Privacy & Security.
https://github.com/alexl-l/penknife
(Only post if the sub allows app posts; otherwise skip.)

### PR: serhii-londar/open-source-mac-os-apps
Edit applications.json (NOT README.md), one PR per app, description short and ending with a period, alphabetical by title. Category ids: "menubar", "utilities", "productivity" (and "touch-bar" fits too). Language "swift". Needs a recent-commit, English-README, licensed repo: all true.
PR title: Add Penknife
Entry (check icon path exists; docs/screenshots/icon.png is in the repo):
{
    "short_description": "Menu bar app that mutes the meeting you're in, plus clipboard history and a screenshot editor.",
    "categories": ["menubar", "utilities"],
    "repo_url": "https://github.com/alexl-l/penknife",
    "title": "Penknife",
    "icon_url": "https://raw.githubusercontent.com/alexl-l/penknife/main/docs/screenshots/icon.png",
    "screenshots": ["https://raw.githubusercontent.com/alexl-l/penknife/main/docs/screenshots/menu.png"],
    "official_site": "https://alexl-l.github.io/penknife/",
    "languages": ["swift"]
}
(Match the sibling entries' field order; both orders exist in the file.)

### PR: jaywcjlove/awesome-mac
Edit README.md. No CONTRIBUTING.md found; follow existing lines. Section: "### Menu Bar Tools" (under Utilities), alphabetical, so after entries starting with "P" before it. Alternate: Clipboard Tools (don't double-list). Entry line (exact format of neighbours):
* [Penknife](https://alexl-l.github.io/penknife/) - Mutes the meeting you're in, with clipboard history, a screenshot editor, music keys and a mouse jiggler. [![Open-Source Software][OSS Icon]](https://github.com/alexl-l/penknife) ![Freeware][Freeware Icon]
PR title: Add Penknife to Menu Bar Tools
Check whether the repo also has README-zh/ja/ko/pt files that need the same line (they appear to be translated mirrors; ask in the PR).

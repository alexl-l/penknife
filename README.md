# Penknife

The pocket knife for your Mac: one small menu bar app that replaces several utilities. Every part is a module you can turn on or off.

- **Touch Bar**: brightness, keyboard light, volume, music, weather, CPU temperature, battery, speed test and time. Icons follow the current state, and you can choose and reorder the buttons.
- **Music**: play/pause, next and previous for the player you choose. Headphone clicks go to that player, and Apple Music no longer opens by itself.
- **Clipboard history** with pinned items and search.
- **Screenshots** with an editor: arrows, text, highlighter, shapes, pen and blur.
- **Mouse jiggler**, **microphone mute**, **lock screen**, **speed test**, **alerts**, and status dots in the menu bar.

See [CHANGELOG.md](CHANGELOG.md) for what changed in each version.

## Requirements

- macOS 26 or later.
- The Touch Bar module needs a MacBook Pro with a Touch Bar.

## Install

Penknife is not notarized (there is no paid Apple Developer account), so macOS warns the first time you open it:

1. Download the latest release and move `Penknife.app` to `/Applications`.
2. Open it. When macOS blocks it, go to **System Settings → Privacy & Security** and click **Open Anyway**.

### Build from source

1. Create a code-signing certificate named `Penknife Local Signing` in your login keychain (Keychain Access → Certificate Assistant → Create a Certificate, type *Code Signing*). A stable signature keeps the privacy permissions between builds.
2. Run `scripts/install.sh`. It builds a Release version, signs it and installs it in `/Applications`.

## Permissions

Penknife asks only for what the modules you turn on need:

- **Accessibility**: shortcuts that act on other apps, media keys and the mouse jiggler.
- **Automation (Apple Events)**: to control Spotify and Apple Music.
- **Location** (optional): local weather.
- **Screen Recording**: screenshots.

## Privacy

Penknife has no account, no analytics and no tracking.

- **Weather** sends only coordinates rounded to about 11 km to [Open-Meteo](https://open-meteo.com/). Open-Meteo sees your IP address.
- **Speed test** runs macOS's own `networkQuality` tool, which contacts Apple's test servers.
- **Clipboard history** and **screenshots** stay on your Mac. Items from password managers and concealed items are not saved.

## Private APIs

Penknife is not an App Store app. It uses some private macOS frameworks, for example to show its own Touch Bar and to set screen and keyboard brightness. A macOS update can break a module. When that happens, the module stops working and the rest of the app keeps running.

## License

[MIT](LICENSE). Third-party notices: [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).

Penknife is not affiliated with or endorsed by Apple, Spotify, Hammerspoon, MTMR, noTunes, Maccy or Lightshot. Names are used only to describe compatibility.

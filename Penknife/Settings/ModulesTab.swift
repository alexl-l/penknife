import SwiftUI

/// Every function can be turned on and off (R-15). A module that is off uses no resources.
struct ModulesTab: View {
    let manager: ModuleManager

    var body: some View {
        Form {
            Section {
                ForEach(ModuleID.allCases) { id in
                    Toggle(isOn: Binding(
                        get: { manager.isEnabled(id) },
                        set: { manager.setEnabled(id, $0) }
                    )) {
                        Label {
                            Text(id.title)
                            Text(id.summary)
                        } icon: {
                            Image(systemName: id.symbol)
                                .accessibilityHidden(true)
                        }
                    }
                    if id == .jiggler, let jiggler = manager.module(.jiggler) as? JigglerModule {
                        Toggle("Turn on when unlocking, off when locking", isOn: Binding(
                            get: { jiggler.followsLock },
                            set: { jiggler.followsLock = $0 }
                        ))
                        .padding(.leading, 28)
                        .disabled(!manager.isEnabled(.jiggler))
                        JigglerKeyPicker()
                            .padding(.leading, 28)
                            .disabled(!manager.isEnabled(.jiggler))
                    }
                    if id == .music {
                        PlayerPicker()
                            .padding(.leading, 28)
                            .disabled(!manager.isEnabled(.music))
                    }
                    if id == .blockAppleMusic {
                        BlockAppleMusicNote()
                            .padding(.leading, 28)
                            .disabled(!manager.isEnabled(.blockAppleMusic))
                    }
                    if id == .weather {
                        Text("Only an approximate location (about 11 km) is sent. [Weather data by Open-Meteo.com](https://open-meteo.com/) (CC BY 4.0).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 28)
                    }
                    if id == .touchBar {
                        AutoCloseToggle()
                            .padding(.leading, 28)
                            .disabled(!manager.isEnabled(.touchBar))
                    }
                }
            } footer: {
                Text("A module that is off uses no CPU or memory.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Sliders and the date close by themselves, or only when tapped (R-19).
private struct AutoCloseToggle: View {
    @AppStorage(TouchBarModule.autoCloseKey) private var autoClose = true

    var body: some View {
        Toggle("Close sliders and the date automatically", isOn: $autoClose)
    }
}

/// The app the music controls drive (R-5): installed known players, another app chosen by the
/// user, or "any app".
private struct PlayerPicker: View {
    @AppStorage(MusicPlayer.key) private var playerID = MusicPlayer.defaultID

    var body: some View {
        let current = MusicPlayer(id: playerID)
        Picker("Player", selection: $playerID) {
            ForEach(MusicPlayer.choices(including: current)) { Text($0.title).tag($0.id) }
        }
        Button("Choose another app…", action: chooseApp)
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = String(localized: "Choose the app you listen to music with.")
        panel.prompt = String(localized: "Choose")
        guard panel.runModal() == .OK, let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
        playerID = MusicPlayer(bundleID: bundleID).id
    }
}

/// Block Apple Music never fights the player choice (R-6): it says when it is paused.
private struct BlockAppleMusicNote: View {
    @AppStorage(MusicPlayer.key) private var playerID = MusicPlayer.defaultID

    var body: some View {
        Text(MusicPlayer(id: playerID).isAppleMusic
             ? "Paused: Apple Music is your music player."
             : "Paused automatically while Apple Music or iTunes is your music player.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

/// The key the jiggler presses so Teams and Slack see keyboard activity (R-3).
private struct JigglerKeyPicker: View {
    @AppStorage(JigglerKey.key) private var key = JigglerKey.capsLock

    var body: some View {
        Picker("Key it presses", selection: $key) {
            ForEach(JigglerKey.allCases) { Text($0.title).tag($0) }
        }
    }
}

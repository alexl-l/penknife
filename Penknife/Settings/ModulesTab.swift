import SwiftUI

/// Every function can be turned on and off (R-15). A module that is off uses no resources.
struct ModulesTab: View {
    let manager: ModuleManager

    var body: some View {
        Form {
            // One section per module, as System Settings groups its options.
            ForEach(ModuleID.allCases) { id in
                Section {
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
                        .disabled(!manager.isEnabled(.jiggler))
                        JigglerKeyPicker()
                            .disabled(!manager.isEnabled(.jiggler))
                    }
                    if id == .clipboard, let clipboard = manager.module(.clipboard) as? ClipboardModule {
                        ClipboardOptions(store: clipboard.store)
                            .disabled(!manager.isEnabled(.clipboard))
                    }
                    if id == .music {
                        PlayerPicker()
                            .disabled(!manager.isEnabled(.music))
                    }
                    if id == .blockAppleMusic {
                        BlockAppleMusicNote()
                            .disabled(!manager.isEnabled(.blockAppleMusic))
                    }
                    if id == .weather {
                        Text("Only an approximate location (about 11 km) is sent. [Weather data by Open-Meteo.com](https://open-meteo.com/) (CC BY 4.0).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if id == .touchBar {
                        AutoCloseToggle()
                            .disabled(!manager.isEnabled(.touchBar))
                    }
                } footer: {
                    if id == ModuleID.allCases.last {
                        Text("A module that is off uses no CPU or memory.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Clipboard history options (R-7): memory limit, paste or only copy, where the panel opens,
/// and clearing the history (pinned items are always kept).
private struct ClipboardOptions: View {
    let store: ClipboardStore
    @AppStorage(ClipboardStore.limitKey) private var limit = 100
    @AppStorage(ClipboardModule.pasteKey) private var paste = true
    @AppStorage(ClipboardModule.formattingKey) private var formatting = true
    @AppStorage(ClipboardModule.positionKey) private var position = ClipboardPosition.center.rawValue
    @State private var confirmClear = false

    var body: some View {
        Picker("Memory for the history", selection: $limit) {
            ForEach(ClipboardStore.limits, id: \.self) { mb in
                Text("\(mb) MB").tag(mb)
            }
        }
        .onChange(of: limit) { store.trim() }
        Toggle("Paste after choosing an item", isOn: $paste)
        Toggle(isOn: $formatting) {
            Text("Keep text formatting")
            Text("Fonts, bold and colors. ⇧↩ in the history does the opposite once.")
        }
        Picker("Open the history", selection: $position) {
            ForEach(ClipboardPosition.allCases, id: \.rawValue) { option in
                Text(option.title).tag(option.rawValue)
            }
        }
        LabeledContent {
            Button("Clear History…") { confirmClear = true }
                .disabled(store.history.isEmpty)
        } label: {
            Text("In use: \(ByteCountFormatter.string(fromByteCount: Int64(store.usedBytes), countStyle: .memory))")
            Text("Pinned items are saved on this Mac and never deleted unless you remove them.")
        }
        .confirmationDialog("Clear the clipboard history?", isPresented: $confirmClear) {
            Button("Clear", role: .destructive) { store.clearHistory() }
        } message: {
            Text("Pinned items are kept.")
        }
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

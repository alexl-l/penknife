import KeyboardShortcuts
import SwiftUI

/// The whole Settings window as one System Settings style sidebar (user, 2026-11-14):
/// General, Permissions, Shortcuts; then every module (R-15); then About.
struct SettingsView: View {
    let manager: ModuleManager
    @AppStorage("settings.selectedPage") private var selected = SettingsPage.general.rawValue

    var body: some View {
        let page = SettingsPage(rawValue: selected) ?? .general
        NavigationSplitView {
            List(selection: Binding(
                get: { SettingsPage(rawValue: selected) },
                set: { if let page = $0 { selected = page.rawValue } }
            )) {
                Section {
                    ForEach([SettingsPage.general, .permissions, .shortcuts], id: \.self) { page in
                        Label { Text(page.title) } icon: { SettingsTile(symbol: page.symbol, tint: page.tint) }
                            .tag(page)
                    }
                }
                Section {
                    ForEach(ModuleID.allCases) { id in
                        let on = manager.isEnabled(id)
                        Label {
                            // Only off modules get a style, so on ones dim with the rest of
                            // the sidebar when the window is inactive.
                            if on { Text(id.title) } else { Text(id.title).foregroundStyle(.secondary) }
                        } icon: {
                            ModuleTile(id: id, enabled: on)
                        }
                        .tag(SettingsPage.module(id))
                        .accessibilityValue(on ? Text("On") : Text("Off"))
                    }
                }
                Section {
                    Label { Text(SettingsPage.about.title) } icon: { SettingsTile(symbol: SettingsPage.about.symbol, tint: SettingsPage.about.tint) }
                        .tag(SettingsPage.about)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch page {
                case .general: GeneralPage()
                case .permissions: PermissionsPage()
                case .shortcuts: ShortcutsPage(manager: manager)
                case .about: AboutPage()
                case .module(let id): ModuleDetail(manager: manager, id: id)
                }
            }
            .id(selected)
            .navigationTitle(page.title)
        }
    }
}

/// A sidebar page; modules are stored as "module.<id>".
enum SettingsPage: Hashable {
    case general, permissions, shortcuts, about
    case module(ModuleID)

    init?(rawValue: String) {
        switch rawValue {
        case "general": self = .general
        case "permissions": self = .permissions
        case "shortcuts": self = .shortcuts
        case "about": self = .about
        default:
            guard rawValue.hasPrefix("module."),
                  let id = ModuleID(rawValue: String(rawValue.dropFirst(7))) else { return nil }
            self = .module(id)
        }
    }

    var rawValue: String {
        switch self {
        case .general: "general"
        case .permissions: "permissions"
        case .shortcuts: "shortcuts"
        case .about: "about"
        case .module(let id): "module.\(id.rawValue)"
        }
    }

    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .permissions: String(localized: "Permissions")
        case .shortcuts: String(localized: "Shortcuts")
        case .about: String(localized: "About")
        case .module(let id): id.title
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .permissions: "hand.raised.fill"
        case .shortcuts: "keyboard.fill"
        case .about: "info.circle.fill"
        case .module(let id): id.symbol
        }
    }

    /// Graphite for General and About, so they don't read as a module that is off (gray).
    var tint: Color {
        switch self {
        case .general, .about: Color(white: 0.42)
        case .permissions: .blue
        case .shortcuts: .indigo
        case .module(let id): id.tint
        }
    }
}

/// A System Settings style icon: white symbol on a color.
private struct SettingsTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 18

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(tint.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.55, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

/// A module's icon: its color while on, gray while off.
private struct ModuleTile: View {
    let id: ModuleID
    let enabled: Bool
    var size: CGFloat = 18

    var body: some View {
        SettingsTile(symbol: id.symbol, tint: enabled ? id.tint : Color.gray.opacity(0.55), size: size)
    }
}

private extension ModuleID {
    var tint: Color {
        switch self {
        case .jiggler: .blue
        case .microphone: .orange
        case .lockScreen: .indigo
        case .screenshot: .purple
        case .clipboard: .teal
        case .music: .pink
        case .blockAppleMusic: .red
        case .cpuTemperature: .orange
        case .weather: .cyan
        case .speedTest: .green
        case .touchBar: .gray
        case .dialogs: .brown
        }
    }
}

/// The right side: the module's switch with its description, then its options.
private struct ModuleDetail: View {
    let manager: ModuleManager
    let id: ModuleID

    var body: some View {
        let on = manager.isEnabled(id)
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { manager.isEnabled(id) },
                    set: { manager.setEnabled(id, $0) }
                )) {
                    Label {
                        Text(id.title).font(.headline)
                    } icon: {
                        ModuleTile(id: id, enabled: on, size: 24)
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(id.summary)
                    if !on {
                        Text("A module that is off uses no CPU or memory.")
                    }
                }
                .foregroundStyle(.secondary)
            }
            options
                .disabled(!on)
            if let actions = manager.module(id)?.actions, !actions.isEmpty {
                Section(actions.count == 1 ? "Shortcut" : "Shortcuts") {
                    ForEach(actions, id: \.shortcut) { action in
                        KeyboardShortcuts.Recorder(action.title, name: action.shortcut)
                    }
                    if id == .screenshot {
                        KeyboardShortcuts.Recorder(String(localized: "Draw While Recording"), name: .recordingDraw)
                    }
                }
                .disabled(!on)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var options: some View {
        switch id {
        case .jiggler:
            if let jiggler = manager.module(.jiggler) as? JigglerModule {
                Section {
                    Toggle("Turn on when unlocking, off when locking", isOn: Binding(
                        get: { jiggler.followsLock },
                        set: { jiggler.followsLock = $0 }
                    ))
                    JigglerIntervalPicker { jiggler.intervalChanged() }
                    JigglerKeyPicker()
                }
            }
        case .clipboard:
            if let clipboard = manager.module(.clipboard) as? ClipboardModule {
                Section { ClipboardOptions(store: clipboard.store) }
            }
        case .screenshot:
            Section { ScreenshotOptions() }
        case .music:
            Section { PlayerPicker() }
        case .blockAppleMusic:
            Section { BlockAppleMusicNote() }
        case .weather:
            Section { MenuBarToggle(kind: .weather) }
            Section {
                Text("Only an approximate location (about 11 km) is sent. [Weather data by Open-Meteo.com](https://open-meteo.com/) (CC BY 4.0).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .speedTest:
            Section { MenuBarToggle(kind: .speedTest) }
            Section {
                Text("Uses Apple's test servers. Each test takes 20–45 seconds and transfers a few hundred MB.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .touchBar:
            Section {
                AutoCloseToggle()
                BarButtonsRow(manager: manager)
            }
            Section { TouchBarColorOptions() }
        case .microphone:
            MeetingOptions()
        case .cpuTemperature:
            Section { MenuBarToggle(kind: .temperature) }
        case .lockScreen, .dialogs:
            EmptyView()
        }
    }
}

/// "Show in the menu bar" for weather, Mac temperature and speed test (R-30).
private struct MenuBarToggle: View {
    let kind: MenuBarReadings.Kind
    @AppStorage private var shown: Bool

    init(kind: MenuBarReadings.Kind) {
        self.kind = kind
        _shown = AppStorage(wrappedValue: MenuBarReadings.shownByDefault, kind.key)
    }

    var body: some View {
        Toggle("Show in the menu bar", isOn: $shown)
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
/// Screenshot options (R-8): frozen or live screen while selecting, and where Save puts files.
private struct ScreenshotOptions: View {
    @AppStorage(ScreenshotModule.modeKey) private var mode = ScreenshotMode.frozen.rawValue
    @AppStorage(ScreenshotModule.folderKey) private var folderPath: String?
    @AppStorage(ScreenshotModule.scrollKey) private var scrollUpThinner = false
    @AppStorage(CapturePalette.colorKey) private var defaultColor = 4
    @AppStorage(ScreenshotModule.copyFileKey) private var copyFile = true
    @AppStorage(PastableImage.limitKey) private var pastableLimit = 500
    @State private var pastableUsed = PastableImage.used

    var body: some View {
        Picker("Screen while selecting", selection: $mode) {
            ForEach(ScreenshotMode.allCases, id: \.rawValue) { option in
                Text(option.title).tag(option.rawValue)
            }
        }
        Picker("Default color", selection: $defaultColor) {
            ForEach(CapturePalette.colors.indices, id: \.self) { index in
                Label {
                    Text(CapturePalette.name(index))
                } icon: {
                    Image(nsImage: Self.swatch(CapturePalette.colors[index]))
                }
                .tag(index)
            }
        }
        Picker("Scrolling up makes lines and text", selection: $scrollUpThinner) {
            Text("Thicker").tag(false)
            Text("Thinner").tag(true)
        }
        Toggle(isOn: $copyFile) {
            Text("Copy also as a file")
            Text("⌘V in a Finder folder creates the PNG file; other apps paste the image.")
        }
        Picker(selection: $pastableLimit) {
            ForEach(PastableImage.limits, id: \.self) { mb in
                Text(mb >= 1000 ? "\(mb / 1000) GB" : "\(mb) MB").tag(mb)
            }
        } label: {
            Text("Space for images to paste as files")
            Text("Also holds images you paste into Finder from the clipboard history. When it fills up, the oldest are deleted; an image bigger than this space is copied only as an image. In use: \(ByteCountFormatter.string(fromByteCount: pastableUsed, countStyle: .file))")
        }
        .onChange(of: pastableLimit) {
            PastableImage.makeRoom()
            pastableUsed = PastableImage.used
        }
        Button("Delete These Files Now") {
            PastableImage.removeAll()
            pastableUsed = 0
        }
        .disabled(pastableUsed == 0)
        LabeledContent("Save to") {
            HStack {
                Text(FileManager.default.displayName(atPath: ScreenshotModule.folder.path))
                    .foregroundStyle(.secondary)
                    .id(folderPath)
                Button("Choose…", action: choose)
                    .accessibilityLabel(String(localized: "Choose the folder for screenshots"))
            }
        }
    }

    /// A small color dot for the menu (menus show images, not SwiftUI shapes).
    private static func swatch(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            NSColor.separatorColor.setStroke()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()
            return true
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = ScreenshotModule.folder
        panel.prompt = String(localized: "Choose")
        if panel.runModal() == .OK, let url = panel.url {
            folderPath = url.path
        }
    }
}

private struct AutoCloseToggle: View {
    @AppStorage(TouchBarModule.autoCloseKey) private var autoClose = true

    var body: some View {
        Toggle("Close sliders and the date automatically", isOn: $autoClose)
    }
}

/// Touch Bar icon colors (R-25): the mode (also changed by holding the battery) and the
/// monochrome color.
private struct TouchBarColorOptions: View {
    @AppStorage(TouchBarModule.colorModeKey) private var mode = BarColorMode.multicolor.rawValue
    @AppStorage(TouchBarModule.monochromeKey) private var monochrome = "FFFFFF"

    var body: some View {
        Picker("Icon colors", selection: $mode) {
            ForEach(BarColorMode.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
        }
        ColorPicker("Monochrome color", selection: Binding(
            get: { Color(nsColor: NSColor(hex: UInt32(monochrome, radix: 16) ?? 0xFFFFFF)) },
            set: { color in
                guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                let hex = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
                    .map { String(format: "%02X", Int(($0 * 255).rounded())) }.joined()
                monochrome = hex
            }
        ), supportsOpacity: false)
        Text("Holding the battery button also changes the colors, one every second.")
            .font(.caption)
            .foregroundStyle(.secondary)
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
        Button("Choose Another App…", action: chooseApp)
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

/// Time without input before the jiggler moves the mouse (R-24).
private struct JigglerIntervalPicker: View {
    @AppStorage(JigglerModule.intervalKey) private var interval = 10.0
    let changed: () -> Void

    var body: some View {
        Picker("Move the mouse after", selection: $interval) {
            ForEach(JigglerModule.intervals, id: \.self) { seconds in
                Text(Duration.seconds(seconds), format: .units(allowed: [.minutes, .seconds], width: .wide)).tag(seconds)
            }
        }
        .onChange(of: interval) { changed() }
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

/// Microphone (R-28): which meeting apps get their mute shortcut, and whether the Mac's
/// microphone is muted too. Variant B picked by the user (compact rows), 2026-11-16.
private struct MeetingOptions: View {
    @State private var enabled = Dictionary(uniqueKeysWithValues: MeetingPlatform.allCases.map { ($0, $0.isEnabled) })
    @AppStorage(MicrophoneModule.alsoMuteMacKey) private var alsoMuteMac = true
    @AppStorage(TeamsConsent.enabledKey) private var teamsConsent = false
    @AppStorage(MicrophoneModule.keepMutedKey) private var keepMuted = true
    @State private var confirmTeamsConsent = false

    var body: some View {
        Section {
            ForEach(MeetingPlatform.allCases) { platform in
                let on = enabled[platform] ?? true
                HStack(spacing: 10) {
                    MeetingIcon(platform: platform)
                    Text(platform.name)
                    Spacer()
                    KeyboardShortcuts.Recorder(for: platform.shortcut)
                        .disabled(!on)
                        .opacity(on ? 1 : 0.4)
                    Toggle(platform.name, isOn: Binding(
                        get: { on },
                        set: { enabled[platform] = $0; platform.isEnabled = $0 }
                    ))
                    .labelsHidden()
                }
            }
            Button("Restore Defaults") {
                KeyboardShortcuts.reset(MeetingPlatform.allCases.map(\.shortcut))
            }
        } header: {
            Text("Meetings")
        } footer: {
            Text("Shortcut = the keys Penknife sends to each app to mute. Match them to the app's own setting.")
        }
        Section {
            Toggle("Also mute the Mac's microphone", isOn: $alsoMuteMac)
        } footer: {
            Text("Off: only the current meeting is muted. If no meeting is found, the Mac's microphone is muted.")
        }
        // R-34 (designer + growth review, 2026-11-17): on by default; the Siri note only when
        // "Hey Siri" is on, stating the fact, with a way to change it.
        Section {
            Toggle("Keep the microphone muted", isOn: $keepMuted)
                .accessibilityHint(Text("Mutes again if another app unmutes the Mac's microphone."))
            if keepMuted && MicrophoneModule.heySiriOn {
                HStack(alignment: .firstTextBaseline) {
                    Text("“Hey Siri” is on: it opens the microphone when the Mac plays a sound, and Penknife mutes it again. When you call Siri, it still hears you.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Open Siri Settings…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.link)
                }
            }
        } footer: {
            Text("If another app unmutes the Mac's microphone while you are muted, Penknife mutes it again.")
        }
        // R-31: opt-in, confirmed once (legal-advisor, 2026-11-17); no Teams text is quoted or matched.
        Section {
            Toggle("Remember my choice for Teams' unmute dialog", isOn: Binding(
                get: { teamsConsent },
                set: { on in if on { confirmTeamsConsent = true } else { teamsConsent = false } }
            ))
            .disabled(enabled[.teams] == false)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("When you unmute with the shortcut and Teams asks for your consent, Penknife accepts it for you. You remain responsible for consent. Check your employer's policy. Not affiliated with Microsoft.")
                if enabled[.teams] == false {
                    Text("Requires Microsoft Teams in the list above.")
                }
            }
        }
        .alert("Answer Teams' unmute dialog for you?", isPresented: $confirmTeamsConsent) {
            Button("Turn On") { teamsConsent = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("In meetings that ask for consent, Teams shows a dialog when you unmute. If you turn this on, Penknife accepts it for you, only when you unmute with Penknife's shortcut. You remain responsible for consent. Check your employer's policy.")
        }
        Section("Current meeting") {
            Label("The meeting in front, or the last one you used.", systemImage: "scope")
            Label("Browser meetings count only when they are the active tab.", systemImage: "safari")
        }
    }
}

private struct MeetingIcon: View {
    let platform: MeetingPlatform

    var body: some View {
        if let url = platform.bundleIDs.lazy.compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }).first {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
        } else {
            Image(systemName: platform.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 5.5).fill(.blue))
                .accessibilityHidden(true)
        }
    }
}

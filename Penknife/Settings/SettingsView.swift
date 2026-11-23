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
                        let available = id.isAvailable(hasTouchBar: TouchBarPrivate.hasTouchBar)
                        let on = available && manager.isEnabled(id)
                        Label {
                            // Only off modules get a style, so on ones dim with the rest of
                            // the sidebar when the window is inactive.
                            if on || !available { Text(id.title) } else { Text(id.title).foregroundStyle(.secondary) }
                        } icon: {
                            ModuleTile(id: id, enabled: on)
                        }
                        .opacity(available ? 1 : 0.5) // O-7: no Touch Bar on this Mac, the whole row dims
                        .tag(SettingsPage.module(id))
                        .accessibilityValue(!available ? Text("Unavailable") : on ? Text("On") : Text("Off"))
                    }
                }
                Section {
                    Label { Text(SettingsPage.about.title) } icon: { SettingsTile(symbol: SettingsPage.about.symbol, tint: SettingsPage.about.tint) }
                        .tag(SettingsPage.about)
                }
            }
            // In this order: the width last, or removing the toggle drops it to 144 pt and the
            // names get cut (measured 2026-11-20, GN-12).
            .toolbar(removing: .sidebarToggle)
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
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
    var tint: TileColor {
        switch self {
        case .general, .about: .graphite
        case .permissions: .blue
        case .shortcuts: .indigo
        case .module(let id): id.tint
        }
    }
}

/// Tile colors as in Apple's Dock icons (2026-11-19, user: the system colors looked "chillones"):
/// lighter on top, deeper below, the hue shifting a little, measured from App Store, Mail,
/// Messages and System Settings in the Dock; the rest follow the same rule.
enum TileColor {
    case blue, green, orange, red, pink, purple, indigo, teal, cyan, brown, graphite

    private var stops: (top: UInt32, bottom: UInt32) {
        switch self {
        case .blue: (0x3AACF8, 0x2F74E4)
        case .green: (0x8DE88C, 0x55C45C)
        case .orange: (0xFFB84A, 0xF7861C)
        case .red: (0xFF7D6E, 0xE5413A)
        case .pink: (0xFF7FA0, 0xE83C6A)
        case .purple: (0xCB8EFA, 0x9752E4)
        case .indigo: (0x8C88FF, 0x5650E2)
        case .teal: (0x62DAE0, 0x26A9BE)
        case .cyan: (0x72D2FF, 0x36A0EA)
        case .brown: (0xCFA77E, 0x99714D)
        case .graphite: (0xB8B8BC, 0x828287)
        }
    }

    /// One solid color: the middle of the Dock icon's gradient (user 2026-11-19: "LOS QUIERO SÓLIDOS").
    var color: Color {
        func channel(_ shift: UInt32) -> Double { Double((stops.top >> shift & 255) + (stops.bottom >> shift & 255)) / 510 }
        return Color(.sRGB, red: channel(16), green: channel(8), blue: channel(0))
    }
}

/// The macOS 27 System Settings tile (variant A, chosen 2026-11-19) in Dock colors: one solid
/// color (no gloss, no rim: user 2026-11-19), a larger white symbol. Off: gray.
private struct SettingsTile: View {
    let symbol: String
    let tint: TileColor
    var on = true
    var size: CGFloat = 18
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
        ZStack {
            if on { shape.fill(tint.color) } else { shape.fill(Color.gray.opacity(0.45)) }
            Image(systemName: symbol)
                .font(.system(size: size * 0.62 - 2, weight: .medium))
                .foregroundStyle(.white.opacity(on ? 1 : 0.8))
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.12), radius: 0.5, y: 0.5)
        .accessibilityHidden(true)
    }
}

/// A module's icon: its color while on, gray while off.
private struct ModuleTile: View {
    let id: ModuleID
    let enabled: Bool
    var size: CGFloat = 18

    var body: some View {
        SettingsTile(symbol: id.symbol, tint: id.tint, on: enabled, size: size)
    }
}

private extension ModuleID {
    var tint: TileColor {
        switch self {
        case .jiggler: .blue
        case .microphone: .orange
        case .lockScreen: .indigo
        case .screenshot: .purple
        case .clipboard: .teal
        case .macros: .blue
        case .music: .pink
        case .blockAppleMusic: .red
        case .cpuTemperature: .orange
        case .weather: .cyan
        case .speedTest: .green
        case .touchBar: .graphite
        case .dialogs: .brown
        }
    }
}

/// The right side: the module's switch with its description, then its options.
private struct ModuleDetail: View {
    let manager: ModuleManager
    let id: ModuleID

    var body: some View {
        // O-7: without a Touch Bar, Touch Bar and Native Dialogs show off and locked; the saved
        // value is not changed (it applies again on a Mac with one).
        let available = id.isAvailable(hasTouchBar: TouchBarPrivate.hasTouchBar)
        let on = available && manager.isEnabled(id)
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { available && manager.isEnabled(id) },
                    set: { manager.setEnabled(id, $0) }
                )) {
                    Label {
                        Text(id.title).font(.headline)
                    } icon: {
                        ModuleTile(id: id, enabled: on, size: 24)
                    }
                }
                .disabled(!available)
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(id.summary)
                    if !available {
                        Label(id == .touchBar ? String(localized: "This Mac has no Touch Bar.")
                                              : String(localized: "Only useful on Macs with a Touch Bar."),
                              systemImage: "info.circle")
                    } else if !on {
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
        case .macros:
            if let macros = manager.module(.macros) as? MacrosModule {
                MacroOptions(module: macros)
            }
        case .screenshot:
            Section { ScreenshotOptions() }
        case .music:
            Section { PlayerPicker() }
        case .blockAppleMusic:
            Section { BlockAppleMusicNote() }
        case .weather:
            Section {
                MenuBarToggle(kind: .weather)
            } footer: {
                Text("Only an approximate location (about 11 km) is sent. Weather data by [Open-Meteo.com](https://open-meteo.com/) (CC BY 4.0).")
                    .foregroundStyle(.secondary)
            }
        case .speedTest:
            Section {
                MenuBarToggle(kind: .speedTest)
            } footer: {
                Text("Tests against Apple's servers. Each takes 20–45 seconds and uses a few hundred MB of data.")
                    .foregroundStyle(.secondary)
            }
        case .touchBar:
            Section {
                AutoCloseToggle()
                BarButtonsRow(manager: manager)
            }
            TouchBarColorOptions()
        case .microphone:
            MeetingOptions()
        case .cpuTemperature:
            Section { MenuBarToggle(kind: .temperature) }
        case .lockScreen, .dialogs:
            EmptyView()
        }
    }
}

/// Macros (R-35): how new macros type text, the editor, and where they are kept.
private struct MacroOptions: View {
    let module: MacrosModule
    @AppStorage(MacrosModule.typesTextKey) private var typesText = false

    var body: some View {
        Section {
            Picker("New macros type text by", selection: $typesText) {
                Text("Pasting").tag(false)
                Text("Keystrokes").tag(true)
            }
            LabeledContent("\(module.store.macros.count) macros") {
                Button("Edit Macros…") { module.openEditor() }
            }
        } footer: {
            Text("Macros are stored on this Mac, only for you. Don't use them for passwords.")
                .foregroundStyle(.secondary)
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
    @AppStorage(ClipboardModule.pinnedRowsKey) private var pinnedRows = 5
    @State private var confirmClear = false

    var body: some View {
        Picker("History size", selection: $limit) {
            ForEach(ClipboardStore.limits, id: \.self) { mb in
                Text("\(mb) MB").tag(mb)
            }
        }
        .onChange(of: limit) { store.trim() }
        Toggle("Paste when you choose", isOn: $paste)
        Toggle(isOn: $formatting) {
            Text("Keep formatting")
            Text("Fonts, bold and colors. Press ⇧↩ to do the opposite just that once.")
        }
        Picker("Where it opens", selection: $position) {
            ForEach(ClipboardPosition.allCases, id: \.rawValue) { option in
                Text(option.title).tag(option.rawValue)
            }
        }
        Picker(selection: $pinnedRows) {
            ForEach(ClipboardModule.pinnedRowChoices, id: \.self) { rows in
                if rows == 0 { Text("All").tag(rows) } else { Text(verbatim: "\(rows)").tag(rows) }
            }
        } label: {
            Text("Pinned rows shown")
            Text("Pinned scrolls beyond this and always leaves room for History.")
        }
        LabeledContent {
            Button("Clear History…") { confirmClear = true }
                .disabled(store.history.isEmpty)
        } label: {
            Text("In use: \(ByteCountFormatter.string(fromByteCount: Int64(store.usedBytes), countStyle: .memory))")
            Text("Pinned items stay on this Mac until you remove them.")
        }
        .confirmationDialog("Clear the clipboard history?", isPresented: $confirmClear) {
            Button("Clear", role: .destructive) { store.clearHistory() }
        } message: {
            Text("Pinned items are kept.")
        }
        PastableSpace(onClipboardPage: true)
    }
}

/// The space for images pasted as files (SS-47): one setting shared by screenshots, recordings
/// and the clipboard history, so it shows on both pages with the same key (O-13).
private struct PastableSpace: View {
    let onClipboardPage: Bool
    @AppStorage(PastableImage.limitKey) private var pastableLimit = 500
    @State private var pastableUsed = PastableImage.used

    var body: some View {
        let used = ByteCountFormatter.string(fromByteCount: pastableUsed, countStyle: .file)
        Picker(selection: $pastableLimit) {
            ForEach(PastableImage.limits, id: \.self) { mb in
                Text(mb >= 1000 ? "\(mb / 1000) GB" : "\(mb) MB").tag(mb)
            }
        } label: {
            Text("Space for pasted image files")
            if onClipboardPage {
                Text("Images you paste into Finder as files are stored here, along with screenshots copied as files. When full, the oldest are deleted. Larger images are copied as an image only. In use: \(used)")
            } else {
                Text("Also stores images you paste into Finder from Clipboard History. When full, the oldest are deleted. Larger images are copied as an image only. In use: \(used)")
            }
        }
        .onChange(of: pastableLimit) {
            PastableImage.makeRoom()
            pastableUsed = PastableImage.used
        }
        Button("Delete These Files") {
            PastableImage.removeAll()
            pastableUsed = 0
        }
        .disabled(pastableUsed == 0)
        .onReceive(NotificationCenter.default.publisher(for: PastableImage.changed)) { _ in
            pastableUsed = PastableImage.used
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
    @AppStorage(ScreenshotModule.holdKey) private var holdToRecord = true
    @AppStorage(ScreenshotModule.holdSecondsKey) private var holdSeconds = 2.0
    @AppStorage(RecordingPrefs.closeAfterKey) private var closeAfterSaving = false

    var body: some View {
        Picker("While selecting", selection: $mode) {
            ForEach(ScreenshotMode.allCases, id: \.rawValue) { option in
                Text(option.title).tag(option.rawValue)
            }
        }
        // O-33: hold the Screenshot shortcut or Touch Bar button to record.
        Toggle(isOn: $holdToRecord) {
            Text("Hold to record")
            Text("Hold the Screenshot shortcut or Touch Bar button to record. A short press takes a screenshot.")
        }
        Picker("Hold for", selection: $holdSeconds) {
            ForEach(ScreenshotModule.holdChoices, id: \.self) { seconds in
                Text(seconds.formatted(.number.precision(.fractionLength(0...1))) + " s").tag(seconds)
            }
        }
        .disabled(!holdToRecord)
        // REC-49: close the window after a recording once it is saved or copied.
        Toggle(isOn: $closeAfterSaving) {
            Text("Close after saving or copying")
            Text("The recording window closes when you save a video or GIF, or copy the video.")
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
            Text("Paste in a Finder folder to get a PNG file. Other apps paste the image.")
        }
        PastableSpace(onClipboardPage: false)
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
        Toggle("Close sliders and the date by themselves", isOn: $autoClose)
    }
}

/// Touch Bar icon colors (R-25): the mode (also changed by holding the battery) and the
/// monochrome color.
private struct TouchBarColorOptions: View {
    @AppStorage(TouchBarModule.colorModeKey) private var mode = BarColorMode.multicolor.rawValue
    @AppStorage(TouchBarModule.monochromeKey) private var monochrome = "FFFFFF"

    var body: some View {
        Section {
            Picker("Icon colors", selection: $mode) {
                ForEach(BarColorMode.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
            }
            // Only meaningful in monochrome mode (design audit 2026-11-22).
            if mode == BarColorMode.monochrome.rawValue { monochromePicker }
        } footer: {
            Text("Hold the battery button to switch colors: one change per second.")
                .foregroundStyle(.secondary)
        }
    }

    private var monochromePicker: some View {
        ColorPicker("Monochrome color", selection: Binding(
            get: { Color(nsColor: NSColor(hex: UInt32(monochrome, radix: 16) ?? 0xFFFFFF)) },
            set: { color in
                guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                let hex = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
                    .map { String(format: "%02X", Int(($0 * 255).rounded())) }.joined()
                monochrome = hex
            }
        ), supportsOpacity: false)
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
             ? "Off: Apple Music is your music player."
             : "Off while Apple Music or iTunes is your music player.")
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
        Picker("Also press", selection: $key) {
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
                    .accessibilityLabel(Text("\(platform.name), mute shortcut"))
                }
            }
            Button("Restore Default Shortcuts") {
                KeyboardShortcuts.reset(MeetingPlatform.allCases.map(\.shortcut))
            }
        } header: {
            Text("Meeting apps")
        } footer: {
            Text("Penknife presses these keys in each app to mute it, so they must match the app's own. If you changed them there, change them here too. In Teams: Settings › General › Keyboard shortcuts.")
        }
        Section {
            Toggle("Mute the Mac's microphone too", isOn: $alsoMuteMac)
        } footer: {
            Text("When you press the shortcut, the meeting and the Mac's microphone are muted together. Turn off to mute only the meeting. With no meeting, the Mac's microphone is muted.")
        }
        // R-34 (designer + growth review, 2026-11-17): on by default; the Siri note only when
        // "Hey Siri" is on, stating the fact, with a way to change it.
        Section {
            Toggle("Keep the microphone muted", isOn: $keepMuted)
                .accessibilityHint(Text("Mutes it again if the Mac opens the microphone on its own."))
            if keepMuted && MicrophoneModule.heySiriOn {
                HStack(alignment: .firstTextBaseline) {
                    Text("With “Hey Siri” on, macOS opens the microphone when the Mac plays a sound. Penknife mutes it again, but Siri still hears you when you call it.")
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
            Text("If the Mac opens the microphone on its own (for example, “Hey Siri” when a sound plays), Penknife mutes it again.")
        }
        // R-31: opt-in, confirmed once (legal-advisor, 2026-11-17); no Teams text is quoted or matched.
        Section {
            Toggle("Accept Teams' consent notice", isOn: Binding(
                get: { teamsConsent },
                set: { on in if on { confirmTeamsConsent = true } else { teamsConsent = false } }
            ))
            .disabled(enabled[.teams] == false)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("If Teams asks for your consent when you unmute with the shortcut, Penknife presses the main button for you. You stay responsible for consent; check your employer's policy. Not affiliated with Microsoft.")
                if enabled[.teams] == false {
                    Text("Requires Microsoft Teams in the list above.")
                }
            }
        }
        .alert("Accept Teams' consent notice for you?", isPresented: $confirmTeamsConsent) {
            Button("Turn On") { teamsConsent = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("In meetings that ask for consent, Teams shows a notice when you unmute. If you turn this on, Penknife presses its main button for you, only when you unmute with Penknife's shortcut. You stay responsible for consent; check your employer's policy.")
        }
        Section("Which meeting is muted?") {
            Label("The meeting you're talking in: the one in front or, if not, the last one you used.", systemImage: "scope")
            Label("In a browser, only the tab you're viewing counts.", systemImage: "safari")
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

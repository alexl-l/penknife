import KeyboardShortcuts

/// Global shortcuts. All customizable in Settings → Shortcuts (R-15, R-19).
/// Defaults follow the previous Hammerspoon setup.
extension KeyboardShortcuts.Name {
    static let openMenu = Self("openMenu", default: .init(.p, modifiers: [.control, .option]))
    static let toggleJiggler = Self("toggleJiggler", default: .init(.f12))
    static let toggleMicrophone = Self("toggleMicrophone", default: .init(.f5))
    static let lockScreen = Self("lockScreen", default: .init(.f6))
    static let screenshot = Self("screenshot", default: .init(.f1))
    static let clipboardHistory = Self("clipboardHistory", default: .init(.v, modifiers: [.control, .option]))
    /// Macros (R-35): the list of macros; each macro may also have its own (`macro.<id>`).
    static let macroList = Self("macroList", default: .init(.m, modifiers: [.control, .option]))
}

/// Screen recording (R-29): start and stop; drawing on/off is registered only while recording.
extension KeyboardShortcuts.Name {
    static let recordScreen = Self("recordScreen", default: .init(.r, modifiers: [.control, .option]))
    static let recordingDraw = Self("recordingDraw", default: .init(.d, modifiers: [.control, .option]))
    /// R-38: the screenshot overlay straight in the color picker; no default key.
    static let pickColor = Self("pickColor")
}

/// Music (R-5): no default keys, the user records them in Settings → Shortcuts.
extension KeyboardShortcuts.Name {
    static let playPause = Self("playPause")
    static let nextTrack = Self("nextTrack")
    static let previousTrack = Self("previousTrack")
    static let allowAppleMusic = Self("allowAppleMusic")
}

/// Speed test (R-10): no default key.
extension KeyboardShortcuts.Name {
    static let speedTest = Self("speedTest")
}

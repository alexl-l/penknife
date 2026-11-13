import KeyboardShortcuts

/// Global shortcuts. All customizable in Settings → Shortcuts (R-15, R-19).
/// Defaults follow the previous Hammerspoon setup.
extension KeyboardShortcuts.Name {
    static let openMenu = Self("openMenu", default: .init(.p, modifiers: [.control, .option]))
    static let toggleJiggler = Self("toggleJiggler", default: .init(.f12))
    static let toggleMicrophone = Self("toggleMicrophone", default: .init(.f5))
    static let lockScreen = Self("lockScreen", default: .init(.f6))
    static let screenshot = Self("screenshot", default: .init(.f1))
}

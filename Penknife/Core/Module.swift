import AppKit
import KeyboardShortcuts

/// Every Penknife function lives in a module that can be turned on and off (R-15).
/// A module that is off must hold no timers, observers or event taps.
enum ModuleID: String, CaseIterable, Identifiable {
    case jiggler
    case microphone
    case lockScreen
    case screenshot
    case dialogs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .jiggler: String(localized: "Mouse jiggler")
        case .microphone: String(localized: "Microphone")
        case .lockScreen: String(localized: "Lock screen")
        case .screenshot: String(localized: "Screenshot")
        case .dialogs: String(localized: "Native dialogs")
        }
    }

    var summary: String {
        switch self {
        case .jiggler: String(localized: "Moves the mouse after 10 seconds without activity, so you stay active.")
        case .microphone: String(localized: "Mutes and unmutes the microphone, in sync with Microsoft Teams and Google Meet.")
        case .lockScreen: String(localized: "Turns off the mouse jiggler and locks the screen.")
        case .screenshot: String(localized: "Takes a screenshot of an area and copies it to the clipboard.")
        case .dialogs: String(localized: "Detects dialogs and system prompts so the Touch Bar can show their own buttons.")
        }
    }

    /// On unless it has nothing to drive yet (dialog detection waits for the Touch Bar, phase 2).
    var defaultOn: Bool { self != .dialogs }

    var symbol: String {
        switch self {
        case .jiggler: "computermouse"
        case .microphone: "mic"
        case .lockScreen: "lock"
        case .screenshot: "camera.viewfinder"
        case .dialogs: "macwindow.on.rectangle"
        }
    }
}

/// Something the user can trigger from the menu or with a global shortcut.
struct ModuleAction {
    let shortcut: KeyboardShortcuts.Name
    let title: String
    let symbol: String
    /// Returns the checkmark state for toggles, nil for plain actions.
    var state: (() -> Bool)? = nil
    let perform: () -> Void
}

protocol Module: AnyObject {
    var id: ModuleID { get }
    var actions: [ModuleAction] { get }
    /// Whether the module needs the Accessibility permission to work.
    var needsAccessibility: Bool { get }
    func start()
    func stop()
}

extension Module {
    var needsAccessibility: Bool { false }
}

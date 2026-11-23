import AppKit
import KeyboardShortcuts

/// Every Penknife function lives in a module that can be turned on and off (R-15).
/// A module that is off must hold no timers, observers or event taps.
enum ModuleID: String, CaseIterable, Identifiable {
    case jiggler
    case keepAwake
    case microphone
    case lockScreen
    case screenshot
    case clipboard
    case macros
    case music
    case blockAppleMusic
    case cpuTemperature
    case weather
    case speedTest
    case touchBar
    case dialogs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .jiggler: String(localized: "Mouse Jiggler")
        case .keepAwake: String(localized: "Keep Awake")
        case .microphone: String(localized: "Microphone")
        case .lockScreen: String(localized: "Lock Screen")
        case .screenshot: String(localized: "Screenshot")
        case .clipboard: String(localized: "Clipboard History")
        case .macros: String(localized: "Macros")
        case .music: String(localized: "Music")
        case .blockAppleMusic: String(localized: "Block Apple Music")
        case .cpuTemperature: String(localized: "CPU Temperature")
        case .weather: String(localized: "Weather")
        case .speedTest: String(localized: "Speed Test")
        case .touchBar: String(localized: "Touch Bar")
        case .dialogs: String(localized: "Native Dialogs")
        }
    }

    var summary: String {
        switch self {
        case .jiggler: String(localized: "Keeps you shown as active by nudging the mouse when you stop for a while.")
        case .keepAwake: String(localized: "Keeps the Mac and the display awake without moving the mouse. Turns off when the Mac locks.")
        case .microphone: String(localized: "Mutes the meeting you are in with its own shortcut (Teams, Meet, Zoom, Slack, Webex), or the Mac's microphone.")
        case .lockScreen: String(localized: "Locks the screen and turns off Mouse Jiggler.")
        case .screenshot: String(localized: "Capture an area or a window (press Space). Mark it up, then copy or save it. Or record it as a video or GIF and draw as you go. Nothing leaves your Mac.")
        case .clipboard: String(localized: "Keeps what you copy (text, images, files) so you can search and paste it again. Passwords are skipped. After you quit, only pinned items remain.")
        case .macros: String(localized: "Fills forms for you: text, keys, waits and files, in order, in the app in front. Stops if you switch apps, click or press Esc.")
        case .music: String(localized: "Play, pause and skip songs. On the Touch Bar, tap once to play or pause, twice for the next song, three times for the previous one.")
        case .blockAppleMusic: String(localized: "Keeps Apple Music from opening by itself (headphones, play key). Opening it yourself still works.")
        case .cpuTemperature: String(localized: "Shows the CPU temperature on the Touch Bar and in the menu.")
        case .weather: String(localized: "Shows the current weather on the Touch Bar and in the menu, based on your approximate location.")
        case .speedTest: String(localized: "Tests your connection: download, upload, latency and responsiveness. Start it from the menu, the Touch Bar or a shortcut. Only the last result is kept.")
        case .touchBar: String(localized: "Your own Touch Bar: brightness, volume, music, weather, battery, time and more, plus one-tap actions. Choose which buttons show and in what order.")
        case .dialogs: String(localized: "When a dialog or system prompt appears, the Touch Bar shows its buttons for it.")
        }
    }

    var defaultOn: Bool { true }

    /// Touch Bar and Native Dialogs do nothing without a Touch Bar: there Settings shows them as
    /// unavailable, off and locked, without changing what is saved (O-7, variant A).
    var needsTouchBar: Bool { self == .touchBar || self == .dialogs }
    func isAvailable(hasTouchBar: Bool) -> Bool { !needsTouchBar || hasTouchBar }

    var symbol: String {
        switch self {
        case .jiggler: "computermouse"
        case .keepAwake: "cup.and.saucer"
        case .microphone: "mic"
        case .lockScreen: "lock"
        case .screenshot: "camera.viewfinder"
        case .clipboard: "list.clipboard"
        case .macros: "keyboard.badge.ellipsis"
        case .music: "music.note"
        case .blockAppleMusic: "nosign"
        case .cpuTemperature: "thermometer.medium"
        case .weather: "cloud.sun"
        case .speedTest: "speedometer"
        case .touchBar: "rectangle.split.3x1"
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
    /// False → the menu item is dimmed (no microphone, O-1); the shortcut still runs and explains.
    var isAvailable: (() -> Bool)? = nil
    /// Holding the shortcut this long runs `onHold` instead of `perform` (O-33); nil = no hold.
    var holdDelay: (() -> TimeInterval?)? = nil
    var onHold: (() -> Void)? = nil
    /// The release after `onHold` ran (R-41 hold to talk); nil = the release does nothing.
    var onHoldEnd: (() -> Void)? = nil
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

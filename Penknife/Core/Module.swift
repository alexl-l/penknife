import AppKit
import KeyboardShortcuts

/// Every Penknife function lives in a module that can be turned on and off (R-15).
/// A module that is off must hold no timers, observers or event taps.
enum ModuleID: String, CaseIterable, Identifiable {
    case jiggler
    case microphone
    case lockScreen
    case screenshot
    case clipboard
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
        case .jiggler: String(localized: "Mouse jiggler")
        case .microphone: String(localized: "Microphone")
        case .lockScreen: String(localized: "Lock screen")
        case .screenshot: String(localized: "Screenshot")
        case .clipboard: String(localized: "Clipboard history")
        case .music: String(localized: "Music")
        case .blockAppleMusic: String(localized: "Block Apple Music")
        case .cpuTemperature: String(localized: "CPU temperature")
        case .weather: String(localized: "Weather")
        case .speedTest: String(localized: "Speed test")
        case .touchBar: String(localized: "Touch Bar")
        case .dialogs: String(localized: "Native dialogs")
        }
    }

    var summary: String {
        switch self {
        case .jiggler: String(localized: "Moves the mouse after 10 seconds without activity, so you stay active.")
        case .microphone: String(localized: "Mutes and unmutes the microphone, in sync with Microsoft Teams and Google Meet.")
        case .lockScreen: String(localized: "Turns off the mouse jiggler and locks the screen.")
        case .screenshot: String(localized: "Select an area or, with Space, a window. Mark it with arrows, text, highlighter, rectangles, circles, pen or blur, then copy or save it. Nothing is uploaded.")
        case .clipboard: String(localized: "Remembers what you copy (text, images and files) so you can search it and paste it again. Passwords are skipped. Only pinned items are kept after quitting.")
        case .music: String(localized: "Play, pause and skip songs. On the Touch Bar: one tap plays or pauses, two go to the next song, three to the previous one.")
        case .blockAppleMusic: String(localized: "Closes Apple Music when it opens by itself (headphones, play key). Opening it yourself works.")
        case .cpuTemperature: String(localized: "Shows the CPU temperature on the Touch Bar and in the menu.")
        case .weather: String(localized: "Shows the current weather on the Touch Bar and in the menu, using your approximate location.")
        case .speedTest: String(localized: "Measures download, upload, latency and responsiveness with macOS networkQuality, from the menu, the Touch Bar or a shortcut. Keeps only the last result.")
        case .touchBar: String(localized: "Penknife's own Touch Bar: battery, brightness, keyboard light, actions, music, weather, CPU temperature, volume and time.")
        case .dialogs: String(localized: "While a dialog or system prompt is in front, the Touch Bar shows its own buttons.")
        }
    }

    var defaultOn: Bool { true }

    var symbol: String {
        switch self {
        case .jiggler: "computermouse"
        case .microphone: "mic"
        case .lockScreen: "lock"
        case .screenshot: "camera.viewfinder"
        case .clipboard: "list.clipboard"
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

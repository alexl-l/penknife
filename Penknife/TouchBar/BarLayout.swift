import AppKit

/// The Touch Bar buttons, in their default order (R-26).
enum BarItem: String, CaseIterable, Identifiable {
    case battery, brightness, keyboardLight, jiggler, microphone, screenshot, lock, music, weather, cpu, volume, speedTest, time

    var id: String { rawValue }

    var title: String {
        switch self {
        case .battery: String(localized: "Battery")
        case .brightness: String(localized: "Brightness")
        case .keyboardLight: String(localized: "Keyboard backlight")
        case .jiggler: String(localized: "Mouse Jiggler")
        case .microphone: String(localized: "Microphone")
        case .screenshot: String(localized: "Screenshot")
        case .lock: String(localized: "Lock Screen")
        case .music: String(localized: "Music")
        case .weather: String(localized: "Weather")
        case .cpu: String(localized: "CPU Temperature")
        case .volume: String(localized: "Volume")
        case .speedTest: String(localized: "Speed Test")
        case .time: String(localized: "Time")
        }
    }

    /// The symbol shown in Settings (the bar itself shows live values).
    var symbol: String {
        switch self {
        case .battery: "battery.75percent"
        case .brightness: "sun.max.fill"
        case .keyboardLight: "light.max"
        case .jiggler: "cursorarrow.motionlines"
        case .microphone: "mic.fill"
        case .screenshot: "camera.viewfinder"
        case .lock: "lock.fill"
        case .music: "music.note"
        case .weather: "cloud.sun.fill"
        case .cpu: "thermometer.medium"
        case .volume: "speaker.wave.2.fill"
        case .speedTest: "speedometer"
        case .time: "clock"
        }
    }

    /// The button's own color in the multicolor mode.
    var hex: UInt32 {
        switch self {
        case .battery, .time: 0xFFFFFF
        case .brightness: 0xFFDB00
        case .keyboardLight: 0x4AD1E6
        case .jiggler: 0x0099FF
        case .microphone: 0xFF5D49
        case .screenshot: 0xCC77F4
        case .lock: 0x7176EB
        case .music: 0x08DA73
        case .weather: 0x75DAD8
        case .cpu, .volume: 0xFFAE02
        case .speedTest: 0x34C759
        }
    }

    /// The module the button belongs to; nil for the bar's own buttons.
    var module: ModuleID? {
        switch self {
        case .jiggler: .jiggler
        case .microphone: .microphone
        case .screenshot: .screenshot
        case .lock: .lockScreen
        case .music: .music
        case .weather: .weather
        case .cpu: .cpuTemperature
        case .speedTest: .speedTest
        case .battery, .brightness, .keyboardLight, .volume, .time: nil
        }
    }
}

/// Order and hidden buttons, stored in UserDefaults. Hiding only affects the bar; the module
/// keeps working from the menu and its shortcut.
enum BarLayout {
    static let orderKey = "touchBar.order"
    static let hiddenKey = "touchBar.hidden"

    static var order: [BarItem] {
        decode(savedOrder: UserDefaults.standard.stringArray(forKey: orderKey), savedHidden: nil).order
    }

    static var hidden: Set<BarItem> {
        decode(savedOrder: nil, savedHidden: UserDefaults.standard.stringArray(forKey: hiddenKey)).hidden
    }

    static func save(order: [BarItem], hidden: Set<BarItem>) {
        let saved = encode(order: order, hidden: hidden)
        UserDefaults.standard.set(saved.order, forKey: orderKey)
        UserDefaults.standard.set(saved.hidden, forKey: hiddenKey)
    }

    static func restoreDefaults() {
        UserDefaults.standard.removeObject(forKey: orderKey)
        UserDefaults.standard.removeObject(forKey: hiddenKey)
    }

    static func visible(isOn: (ModuleID) -> Bool) -> [BarItem] {
        visible(order: order, hidden: hidden, isOn: isOn)
    }

    // MARK: Rules (pure; TB-36, TB-37, TB-38)

    /// The saved names as buttons: unknown names are dropped and buttons added in a later
    /// version go at the end, in default order; unknown hidden names are ignored.
    static func decode(savedOrder: [String]?, savedHidden: [String]?) -> (order: [BarItem], hidden: Set<BarItem>) {
        let saved = (savedOrder ?? []).compactMap(BarItem.init(rawValue:))
        return (saved + BarItem.allCases.filter { !saved.contains($0) },
                Set((savedHidden ?? []).compactMap(BarItem.init(rawValue:))))
    }

    /// What is saved: every button's name in the user's order, and the hidden ones in default order.
    static func encode(order: [BarItem], hidden: Set<BarItem>) -> (order: [String], hidden: [String]) {
        (order.map(\.rawValue), BarItem.allCases.filter(hidden.contains).map(\.rawValue))
    }

    /// The buttons on the bar: saved order, not hidden, module on. Never empty: if the user's
    /// last visible button belongs to a module that was then turned off, the time stays.
    static func visible(order: [BarItem], hidden: Set<BarItem>, isOn: (ModuleID) -> Bool) -> [BarItem] {
        let items = order.filter { !hidden.contains($0) && ($0.module.map(isOn) ?? true) }
        return items.isEmpty ? [.time] : items
    }
}

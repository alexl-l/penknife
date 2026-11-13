import AppKit
import KeyboardShortcuts

/// Menu bar icon (R-14: only the logo) and its menu. The menu is rebuilt only when it opens.
final class StatusMenu: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let manager: ModuleManager
    private let openSettings: () -> Void
    private var actions: [ModuleAction] = []

    init(manager: ModuleManager, openSettings: @escaping () -> Void) {
        self.manager = manager
        self.openSettings = openSettings
        super.init()

        if let button = item.button {
            let image = NSImage(systemSymbolName: "wrench.and.screwdriver", accessibilityDescription: "Penknife")
            image?.isTemplate = true
            button.image = image
            button.setAccessibilityLabel("Penknife")
        }
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
    }

    /// Opens the menu from the keyboard shortcut.
    func open() {
        item.button?.performClick(nil)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        actions = manager.enabledActions

        for (index, action) in actions.enumerated() {
            let entry = NSMenuItem(title: action.title, action: #selector(runAction(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = index
            entry.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)
            if let state = action.state {
                entry.state = state() ? .on : .off
            }
            entry.setShortcut(for: action.shortcut)
            menu.addItem(entry)
        }
        if !actions.isEmpty {
            menu.addItem(.separator())
        }

        // Touch Bar readings, also reachable from the menu (R-19).
        var readings: [NSMenuItem] = []
        if manager.isEnabled(.weather), let report = (manager.module(.weather) as? WeatherModule)?.report {
            readings.append(reading(String(localized: "Weather: \(report.summary), \(TemperatureText.short(celsius: report.celsius))"),
                                    symbol: report.symbol))
        }
        if manager.isEnabled(.cpuTemperature), let celsius = (manager.module(.cpuTemperature) as? CPUTemperatureModule)?.read() {
            readings.append(reading(String(localized: "CPU temperature: \(TemperatureText.short(celsius: Double(celsius)))"),
                                    symbol: "thermometer.medium"))
        }
        if !readings.isEmpty {
            readings.forEach(menu.addItem)
            menu.addItem(.separator())
        }

        let settings = NSMenuItem(title: String(localized: "Settings…"), action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(NSMenuItem(title: String(localized: "Quit Penknife"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    /// An informative line: enabled so VoiceOver reads it normally, does nothing when chosen.
    private func reading(_ title: String, symbol: String) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return entry
    }

    // Global hotkeys would be buffered while the menu tracks; pause them meanwhile.
    func menuWillOpen(_ menu: NSMenu) { manager.pauseShortcuts(true) }
    func menuDidClose(_ menu: NSMenu) { manager.pauseShortcuts(false) }

    @objc private func runAction(_ sender: NSMenuItem) {
        guard actions.indices.contains(sender.tag) else { return }
        let action = actions[sender.tag]
        // Run after the menu has closed (the screenshot must not capture the menu).
        DispatchQueue.main.async { action.perform() }
    }

    @objc private func showSettings() {
        openSettings()
    }
}

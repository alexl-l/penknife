import AppKit
import SwiftUI

/// Settings window (R-12) with the native toolbar tabs: General · Modules · Shortcuts.
/// Keyboard: ⌘1–⌘3 switch tabs, Tab moves between controls, Esc or ⌘W closes.
final class SettingsWindowController: NSWindowController {
    private let tabs = NSTabViewController()

    init(manager: ModuleManager) {
        tabs.tabStyle = .toolbar
        let window = SettingsWindow(contentViewController: tabs)
        super.init(window: window)

        add(GeneralTab(), title: String(localized: "General"), symbol: "gearshape")
        add(ModulesTab(manager: manager), title: String(localized: "Modules"), symbol: "square.grid.2x2")
        add(ShortcutsTab(manager: manager), title: String(localized: "Shortcuts"), symbol: "keyboard")

        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.onSelectTab = { [weak self] index in
            guard let self, self.tabs.tabViewItems.indices.contains(index) else { return }
            self.tabs.selectedTabViewItemIndex = index
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func add(_ view: some View, title: String, symbol: String) {
        let host = NSHostingController(rootView: view.frame(width: 520))
        host.sizingOptions = .preferredContentSize
        let item = NSTabViewItem(viewController: host)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        tabs.addTabViewItem(item)
    }

    func show() {
        guard let window else { return }
        Permissions.shared.refresh()
        if !window.isVisible { window.center() }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

final class SettingsWindow: NSWindow {
    var onSelectTab: ((Int) -> Void)?

    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }

    /// Window menu → General / Modules / Shortcuts (⌘1–⌘3).
    @objc func selectSettingsTab(_ sender: NSMenuItem) {
        onSelectTab?(sender.tag)
    }
}

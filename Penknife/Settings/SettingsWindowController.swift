import AppKit
import SwiftUI

/// Settings window (R-12) with the native toolbar tabs: General · Modules · Shortcuts.
/// Keyboard: ⌘1–⌘3 switch tabs, Tab moves between controls, Esc or ⌘W closes.
final class SettingsWindowController: NSWindowController {
    private let tabs = NSTabViewController()
    private static let frameName = "PenknifeSettings"
    private var hasSavedFrame = false

    init(manager: ModuleManager) {
        tabs.tabStyle = .toolbar
        let window = SettingsWindow(contentViewController: tabs)
        super.init(window: window)

        add(GeneralTab(), title: String(localized: "General"), symbol: "gearshape")
        add(ModulesTab(manager: manager), title: String(localized: "Modules"), symbol: "square.grid.2x2", minWidth: 680)
        add(ShortcutsTab(manager: manager), title: String(localized: "Shortcuts"), symbol: "keyboard")

        // Resizable; long tabs scroll. Size and position are remembered between openings.
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 680, height: 420)
        hasSavedFrame = window.setFrameUsingName(Self.frameName)
        if !hasSavedFrame { window.setContentSize(NSSize(width: 720, height: 560)) }
        // Frames saved before the Modules sidebar (2026-11-14) are too narrow for it.
        if let size = window.contentView?.frame.size, size.width < 680 || size.height < 420 {
            window.setContentSize(NSSize(width: max(size.width, 720), height: max(size.height, 560)))
        }
        window.setFrameAutosaveName(Self.frameName)
        window.onSelectTab = { [weak self] index in
            guard let self, self.tabs.tabViewItems.indices.contains(index) else { return }
            self.tabs.selectedTabViewItemIndex = index
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func add(_ view: some View, title: String, symbol: String, minWidth: CGFloat = 480) {
        let host = NSHostingController(rootView: view.frame(minWidth: minWidth, maxWidth: .infinity,
                                                            minHeight: 300, maxHeight: .infinity))
        // The user sets the size; tabs don't resize the window when switching.
        host.sizingOptions = []
        let item = NSTabViewItem(viewController: host)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        tabs.addTabViewItem(item)
    }

    func show() {
        guard let window else { return }
        Permissions.shared.refresh()
        if !window.isVisible, !hasSavedFrame {
            window.center()
            hasSavedFrame = true
        }
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

import AppKit
import SwiftUI

/// Settings window (R-12): one System Settings style sidebar (General, Permissions, Shortcuts,
/// the modules, About). Keyboard: arrows move in the sidebar, Tab moves to the controls,
/// Esc or ⌘W closes.
final class SettingsWindowController: NSWindowController {
    private static let frameName = "PenknifeSettings"
    private var hasSavedFrame = false

    init(manager: ModuleManager) {
        let host = NSHostingController(rootView: SettingsView(manager: manager)
            .frame(minWidth: 680, maxWidth: .infinity, minHeight: 420, maxHeight: .infinity))
        // The user sets the size; changing pages doesn't resize the window.
        host.sizingOptions = []
        let window = SettingsWindow(contentViewController: host)
        super.init(window: window)

        window.title = String(localized: "Penknife Settings")
        window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 680, height: 420)
        hasSavedFrame = window.setFrameUsingName(Self.frameName)
        if !hasSavedFrame { window.setContentSize(NSSize(width: 760, height: 560)) }
        // Frames saved before the sidebar (2026-11-14) are too small for it.
        if let size = window.contentView?.frame.size, size.width < 680 || size.height < 420 {
            window.setContentSize(NSSize(width: max(size.width, 760), height: max(size.height, 560)))
        }
        window.setFrameAutosaveName(Self.frameName)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        guard let window else { return }
        Permissions.shared.refresh()
        if !window.isVisible, !hasSavedFrame {
            window.center()
            hasSavedFrame = true
        }
        // The cooperative `activate()` can be refused for a menu bar app: the window then opened
        // inactive and its sidebar jumped ~10 pt on the first click (user, 2026-11-14).
        // Opening Settings is always the user's request, so take focus.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

final class SettingsWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }
}

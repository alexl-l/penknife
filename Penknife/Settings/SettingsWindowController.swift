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

        // The page's title from the start: SwiftUI's navigationTitle reaches the window only when
        // the page changes, so a fixed title stayed until another page was picked (GN-13).
        let page = UserDefaults.standard.string(forKey: "settings.selectedPage").flatMap(SettingsPage.init(rawValue:))
        window.title = (page ?? .general).title
        window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 680, height: 420)
        hasSavedFrame = window.setFrameUsingName(Self.frameName)
        if !hasSavedFrame {
            window.setContentSize(Self.startSize(saved: nil)!)
        } else if let saved = window.contentView?.frame.size, let size = Self.startSize(saved: saved) {
            window.setContentSize(size)
        }
        window.setFrameAutosaveName(Self.frameName)
    }

    /// GN-11: 760×560 the first time; a saved size under 680×420 (frames saved before the
    /// sidebar, 2026-11-14) grows to at least 760×560; any other saved size is kept (nil).
    static func startSize(saved: NSSize?) -> NSSize? {
        guard let saved else { return NSSize(width: 760, height: 560) }
        guard saved.width < 680 || saved.height < 420 else { return nil }
        return NSSize(width: max(saved.width, 760), height: max(saved.height, 560))
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

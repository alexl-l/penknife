import AppKit
import ObjectiveC

/// Penknife's alerts show their buttons on the Touch Bar (user, 2026-11-22: "no salen los botones
/// en el Touch Bar de Cancel o Delete"). Penknife's own bar steps aside for them (TB-43), but an
/// NSAlert of a menu bar app brings no Touch Bar of its own, so the bar went black. Call
/// `alert.addTouchBar()` before `runModal()` or `beginSheetModal`.
extension NSAlert {
    func addTouchBar() {
        layout()
        let provider = AlertTouchBar(alert: self)
        window.touchBar = provider.makeTouchBar()
        // The bar's delegate is weak: the window keeps the provider for as long as it lives.
        objc_setAssociatedObject(window, &AlertTouchBar.key, provider, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}

@MainActor
private final class AlertTouchBar: NSObject, NSTouchBarDelegate {
    nonisolated(unsafe) static var key: UInt8 = 0
    private static let group = NSTouchBarItem.Identifier("penknife.alert.buttons")
    private weak var alert: NSAlert?

    init(alert: NSAlert) {
        self.alert = alert
    }

    func makeTouchBar() -> NSTouchBar {
        let bar = NSTouchBar()
        bar.delegate = self
        bar.defaultItemIdentifiers = [Self.group]
        bar.principalItemIdentifier = Self.group
        return bar
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        guard identifier == Self.group, let alert else { return nil }
        // As in system alerts: Cancel on the left, the default action on the right.
        let items = alert.buttons.enumerated().reversed().map { index, source -> NSTouchBarItem in
            let item = NSCustomTouchBarItem(identifier: .init("penknife.alert.\(index)"))
            let button = NSButton(title: source.title, target: self, action: #selector(press(_:)))
            button.tag = index
            if source.hasDestructiveAction {
                button.bezelColor = .systemRed
            } else if index == 0 {
                button.bezelColor = .controlAccentColor
            }
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
            item.view = button
            return item
        }
        return NSGroupTouchBarItem(identifier: identifier, items: items)
    }

    @objc private func press(_ sender: NSButton) {
        guard let alert, alert.buttons.indices.contains(sender.tag) else { return }
        alert.buttons[sender.tag].performClick(nil)
    }
}

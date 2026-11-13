import AppKit

/// Short on-screen confirmation ("Microphone muted"), also announced to VoiceOver.
/// One reused panel; it costs nothing while hidden. How long it stays is a setting (R-19).
final class HUD {
    static let shared = HUD()

    static let durationKey = "hud.duration"
    static let durations: [Double] = [2, 4, 8, 15]
    static var duration: Double {
        let value = UserDefaults.standard.double(forKey: durationKey)
        return value > 0 ? value : 4
    }

    private var panel: NSPanel?
    /// Display options the panel was built with, to rebuild it when they change.
    private var builtFor: (reduceTransparency: Bool, increaseContrast: Bool)?
    private let label = NSTextField(labelWithString: "")
    private var hideWork: DispatchWorkItem?

    func show(_ message: String) {
        let panel = currentPanel()
        label.stringValue = message
        label.setAccessibilityLabel(message)
        let size = label.fittingSize
        let frame = NSRect(x: 0, y: 0, width: size.width + 32, height: size.height + 20)
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrame(frame.offsetBy(dx: screen.midX - frame.width / 2, dy: screen.minY + screen.height * 0.18), display: true)
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        NSAccessibility.post(
            element: label,
            notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.duration, execute: work)
    }

    private func hide() {
        guard let panel else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            panel.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        }
    }

    private func currentPanel() -> NSPanel {
        let workspace = NSWorkspace.shared
        let options = (workspace.accessibilityDisplayShouldReduceTransparency, workspace.accessibilityDisplayShouldIncreaseContrast)
        if let panel, let builtFor, builtFor == options { return panel }
        panel?.orderOut(nil)
        builtFor = options
        let panel = makePanel(reduceTransparency: options.0, increaseContrast: options.1)
        self.panel = panel
        return panel
    }

    private func makePanel(reduceTransparency: Bool, increaseContrast: Bool) -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]

        let background: NSView
        if reduceTransparency || increaseContrast {
            background = NSView()
            background.wantsLayer = true
            background.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        } else {
            let effect = NSVisualEffectView()
            effect.material = .hudWindow
            effect.state = .active
            background = effect
        }
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        if increaseContrast {
            background.layer?.borderWidth = 1
            background.layer?.borderColor = NSColor.labelColor.cgColor
        }
        background.setAccessibilityElement(true)
        background.setAccessibilityRole(.group)

        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.setAccessibilityElement(true)
        label.removeFromSuperview()
        label.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: background.centerYAnchor),
        ])
        panel.contentView = background
        return panel
    }
}

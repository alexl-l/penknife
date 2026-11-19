import AppKit

/// Which feature an alert belongs to; each type can be hidden in Settings (R-20).
enum AlertCategory: String, CaseIterable, Identifiable {
    case jiggler, microphone, screenshot, clipboard, music, speedTest

    var id: String { rawValue }
    var key: String { "alerts.\(rawValue)" }

    var title: String {
        switch self {
        case .jiggler: String(localized: "Mouse Jiggler")
        case .microphone: String(localized: "Microphone")
        case .screenshot: String(localized: "Screenshots")
        case .clipboard: String(localized: "Clipboard")
        case .music: String(localized: "Music")
        case .speedTest: String(localized: "Speed Test")
        }
    }

    var isShown: Bool { isShown(in: .standard) }
    func isShown(in defaults: UserDefaults) -> Bool { defaults.object(forKey: key) as? Bool ?? true }
}

/// What the alert says, which sets the symbol color. State is also in the text, never only in color (R-19).
enum AlertKind {
    case on, off, error, permission

    var color: NSColor {
        switch self {
        case .on, .permission: .systemBlue
        case .off: .secondaryLabelColor
        case .error: .systemYellow
        }
    }
}

/// Short confirmation in a Liquid Glass capsule at the top center, under the menu bar or the notch,
/// clear of Apple's notification banners and the volume indicator at the top right (R-20). Always
/// announced to VoiceOver, even when the alert type is hidden. The panel exists only while an alert
/// is on screen.
final class HUD {
    static let shared = HUD()

    static let durationKey = "hud.duration"
    static let durations: [Double] = [1, 2, 4, 8, 15]
    static var duration: Double { duration(in: .standard) }
    static func duration(in defaults: UserDefaults) -> Double {
        let value = defaults.double(forKey: durationKey)
        return value > 0 ? value : 4
    }

    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?
    /// Bumped on every show, so a fade-out that finishes late doesn't close a newer alert.
    private var generation = 0

    private static let singleHeight: CGFloat = 44
    private static let doubleHeight: CGFloat = 56
    private static let minWidth: CGFloat = 120
    private static let maxWidth: CGFloat = 360
    /// Slides down this far when it appears, and up this far when it goes.
    private static let slideIn: CGFloat = 10
    private static let slideOut: CGFloat = 6

    func show(_ title: String, detail: String? = nil, symbol: String, kind: AlertKind, category: AlertCategory) {
        let spoken = [title, detail].compactMap { $0 }.joined(separator: ". ")
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: spoken, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
        guard category.isShown else { return }

        generation += 1
        let content = makeContent(title: title, detail: detail, symbol: symbol, kind: kind, spoken: spoken)
        let size = Self.size(hasDetail: detail != nil, fittingWidth: content.fittingSize.width)
        let background = makeBackground(content: content, cornerRadius: detail == nil ? size.height / 2 : 16)

        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else { return }
        let frame = Self.frame(size: size, screen: screen.frame, visible: screen.visibleFrame,
                               safeTop: screen.safeAreaInsets.top)

        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = background
        // Also while fading out: the new alert takes over in place, without sliding in again.
        let wasVisible = panel.isVisible
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if wasVisible || reduceMotion {
            panel.setFrame(frame, display: true)
        } else {
            panel.setFrame(frame.offsetBy(dx: 0, dy: Self.slideIn), display: true)
        }
        if !wasVisible { panel.alphaValue = 0 }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0.15 : 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            // Also when it takes over: this replaces a fade-out's slide that is still running.
            if !reduceMotion { panel.animator().setFrame(frame, display: true) }
        }

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.duration, execute: work)
    }

    private func hide() {
        guard let panel else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.orderOut(nil)
            self.panel = nil
            return
        }
        let shown = generation
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
            panel.animator().setFrame(panel.frame.offsetBy(dx: 0, dy: Self.slideOut), display: true)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == shown else { return }
                panel.orderOut(nil)
                self.panel = nil
            }
        }
    }

    /// GN-17: 44 pt high with one line, 56 pt with two; the text's width kept within 120–360 pt.
    static func size(hasDetail: Bool, fittingWidth: CGFloat) -> NSSize {
        NSSize(width: min(max(minWidth, fittingWidth), maxWidth), height: hasDetail ? doubleHeight : singleHeight)
    }

    /// GN-17: centered, 8 pt under the menu bar or the notch, whichever is lower. With no menu bar
    /// (full screen, auto-hidden) and no notch: 12 pt under the top edge.
    static func frame(size: NSSize, screen: NSRect, visible: NSRect, safeTop: CGFloat) -> NSRect {
        let menuBar = screen.maxY - visible.maxY
        let top = max(menuBar, safeTop)
        let gap: CGFloat = top > 0 ? 8 : 12
        return NSRect(x: screen.midX - size.width / 2, y: screen.maxY - top - gap - size.height,
                      width: size.width, height: size.height)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        return panel
    }

    private func makeContent(title: String, detail: String?, symbol: String, kind: AlertKind, spoken: String) -> NSView {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 18, weight: .medium)
        icon.contentTintColor = kind.color

        let titleLabel = label(title, font: .systemFont(ofSize: 13, weight: .medium), color: .labelColor)
        let texts = NSStackView(views: [titleLabel])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 1
        if let detail {
            texts.addArrangedSubview(label(detail, font: .systemFont(ofSize: 11), color: .secondaryLabelColor))
        }

        // Center gravity: short messages stay centered in the minimum width.
        let row = NSStackView()
        row.addView(icon, in: .center)
        row.addView(texts, in: .center)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 16)
        row.setAccessibilityElement(true)
        row.setAccessibilityRole(.staticText)
        row.setAccessibilityLabel(spoken)
        return row
    }

    private func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setAccessibilityElement(false)
        return field
    }

    /// Glass by default; an opaque capsule under Reduce Transparency, outlined under Increase Contrast.
    private func makeBackground(content: NSView, cornerRadius: CGFloat) -> NSView {
        let workspace = NSWorkspace.shared
        let increaseContrast = workspace.accessibilityDisplayShouldIncreaseContrast
        if !workspace.accessibilityDisplayShouldReduceTransparency && !increaseContrast {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            glass.contentView = content
            return glass
        }
        let solid = NSView()
        solid.wantsLayer = true
        solid.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        solid.layer?.cornerRadius = cornerRadius
        solid.layer?.masksToBounds = true
        if increaseContrast {
            solid.layer?.borderWidth = 1
            solid.layer?.borderColor = NSColor.labelColor.cgColor
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        solid.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: solid.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: solid.trailingAnchor),
            content.topAnchor.constraint(equalTo: solid.topAnchor),
            content.bottomAnchor.constraint(equalTo: solid.bottomAnchor),
        ])
        return solid
    }
}

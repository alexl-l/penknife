import AppKit
import KeyboardShortcuts

/// Menu bar icon (R-14: only the logo) and its menu. The menu is rebuilt only when it opens.
/// Beside the logo, two status dots (R-20): microphone on top (orange, filled = open, ring = muted)
/// and mouse jiggler below (blue, filled = on, ring = off). Each shows only while its module is on.
final class StatusMenu: NSObject, NSMenuDelegate {
    static let dotsKey = "menuBar.statusDots"

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let manager: ModuleManager
    private let openSettings: () -> Void
    private let updater: Updater
    private var actions: [ModuleAction] = []
    private let glyph: NSImage? = {
        let image = NSImage(named: "MenuBarIcon")
        image?.isTemplate = true
        image?.accessibilityDescription = "Penknife"
        return image
    }()
    private lazy var micWatcher = MicrophoneWatcher(followsSiri: true) { [weak self] in self?.updateIcon() }
    private var defaultsObserver: NSObjectProtocol?
    private var lastDotsOn: Bool?
    /// What the icon shows now (nil = no dot), to redraw only on a real change.
    private var shown: (mic: Bool?, jiggler: Bool?, recording: String?, paused: Bool)?
    private let recording = RecordingIndicator.shared
    /// While recording (R-29): a red record symbol and the time; a click stops.
    private let recordGlyph: NSImage? = {
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            .applying(.init(paletteColors: [.white, .systemRed]))
        let image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        image?.isTemplate = false
        return image
    }()

    init(manager: ModuleManager, updater: Updater, openSettings: @escaping () -> Void) {
        self.manager = manager
        self.updater = updater
        self.openSettings = openSettings
        super.init()

        item.button?.setAccessibilityLabel("Penknife")
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu

        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // Any defaults write lands here; only the dots setting matters.
                guard let self, self.dotsOn != self.lastDotsOn else { return }
                self.updateIcon()
            }
        }
        trackState()
    }

    // MARK: Status dots

    private var jiggler: JigglerModule? { manager.module(.jiggler) as? JigglerModule }
    private var microphone: MicrophoneModule? { manager.module(.microphone) as? MicrophoneModule }
    private var dotsOn: Bool { Self.dotsOn(in: .standard) }
    static func dotsOn(in defaults: UserDefaults) -> Bool { defaults.object(forKey: dotsKey) as? Bool ?? true }

    /// Redraws when the jiggler turns on or off, or a module is switched on or off. Event-driven, no timer.
    private func trackState() {
        withObservationTracking {
            _ = jiggler?.isActive
            _ = manager.enabled
            _ = recording.time
            _ = recording.paused
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.updateIcon()
                    self?.trackState()
                }
            }
        }
        updateIcon()
    }

    private func updateIcon() {
        guard let button = item.button, let glyph else { return }
        lastDotsOn = dotsOn
        let showMic = dotsOn && manager.isEnabled(.microphone)
        // No input device: no mic dot (it would claim an open mic).
        let hasMic = showMic && MicrophoneModule.defaultInputDevice() != nil
        let showJiggler = dotsOn && manager.isEnabled(.jiggler)

        // The microphone is watched only while its dot is shown.
        if showMic { micWatcher.start() } else { micWatcher.stop() }

        let micOpen = hasMic ? !(microphone?.showsMuted ?? false) : nil
        let jigglerOn = showJiggler ? (jiggler?.isActive ?? false) : nil
        let time = recording.time
        if let shown, shown.mic == micOpen, shown.jiggler == jigglerOn, shown.recording == time, shown.paused == recording.paused { return }
        let wasRecording = shown?.recording != nil
        shown = (micOpen, jigglerOn, time, recording.paused)

        if let time, let recordGlyph {
            showRecording(time, glyph: recordGlyph, micOpen: micOpen, jigglerOn: jigglerOn)
            return
        }
        if wasRecording {
            item.menu = menu
            button.action = nil
            button.target = nil
            button.title = ""
            button.imagePosition = .imageOnly
            button.setAccessibilityLabel("Penknife")
        }

        guard micOpen != nil || jigglerOn != nil else {
            item.length = NSStatusItem.squareLength
            button.image = glyph
            button.setAccessibilityValue(nil)
            return
        }
        item.length = NSStatusItem.variableLength
        button.image = Self.icon(glyph: glyph, micOpen: micOpen, jigglerOn: jigglerOn)

        var states: [String] = []
        if let jigglerOn {
            states.append(jigglerOn ? String(localized: "Mouse jiggler on") : String(localized: "Mouse jiggler off"))
        }
        if let micOpen {
            states.append(micOpen ? String(localized: "Microphone on") : String(localized: "Microphone muted"))
        }
        button.setAccessibilityValue(states.joined(separator: ", "))
        // State can change from elsewhere (Touch Bar, Teams, Control Center): tell VoiceOver.
        NSAccessibility.post(element: button, notification: .valueChanged)
    }

    /// The red record symbol and the time instead of the logo; the dots stay; a click stops.
    private func showRecording(_ time: String, glyph: NSImage, micOpen: Bool?, jigglerOn: Bool?) {
        guard let button = item.button else { return }
        item.menu = nil
        button.target = self
        button.action = #selector(stopRecording)
        item.length = NSStatusItem.variableLength
        button.image = micOpen == nil && jigglerOn == nil ? glyph : Self.icon(glyph: glyph, tinted: false, micOpen: micOpen, jigglerOn: jigglerOn)
        button.imagePosition = .imageLeading
        button.attributedTitle = NSAttributedString(string: " " + time, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
        ])
        button.setAccessibilityLabel(recording.paused
            ? String(localized: "Recording paused at \(time). Click to stop.")
            : String(localized: "Recording, \(time). Click to stop."))
    }

    @objc private func stopRecording() {
        recording.stop()
    }

    /// The logo in the menu bar text color plus a fixed 6 pt column for the dots, so the icon keeps
    /// its width. 4 pt dots, 2 pt apart, 3 pt from the logo. Drawn when the menu bar draws, so it
    /// follows light, dark and tinted menu bars. `tinted` false keeps the glyph's own colors.
    private static func icon(glyph: NSImage, tinted: Bool = true, micOpen: Bool?, jigglerOn: Bool?) -> NSImage {
        let glyphSize = glyph.size
        let dot: CGFloat = 4, gap: CGFloat = 2, spacing: CGFloat = 3, column: CGFloat = 6, trailing: CGFloat = 2
        let size = NSSize(width: glyphSize.width + spacing + column + trailing, height: glyphSize.height)
        let image = NSImage(size: size, flipped: false) { _ in
            let glyphRect = NSRect(origin: .zero, size: glyphSize)
            glyph.draw(in: glyphRect)
            if tinted {
                NSColor.labelColor.set()
                glyphRect.fill(using: .sourceAtop)
            }

            let x = glyphSize.width + spacing + (column - dot) / 2
            let mid = size.height / 2
            let marks: [(Bool?, NSRect, NSColor)] = [
                (micOpen, NSRect(x: x, y: mid + gap / 2, width: dot, height: dot), .systemOrange),
                (jigglerOn, NSRect(x: x, y: mid - gap / 2 - dot, width: dot, height: dot), .systemBlue),
            ]
            for case let (on?, rect, color) in marks {
                if on {
                    color.setFill()
                    NSBezierPath(ovalIn: rect).fill()
                } else {
                    color.setStroke()
                    let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
                    ring.lineWidth = 1
                    ring.stroke()
                }
            }
            return true
        }
        image.accessibilityDescription = "Penknife"
        return image
    }

    /// Opens the menu from the keyboard shortcut.
    /// While recording the item has no menu (a click stops, REC-31); the shortcut still opens
    /// the menu then (O-17): it is attached for that click only. Stopping stays on ⌃⌥R and the item.
    func open() {
        guard item.menu == nil else {
            item.button?.performClick(nil)
            return
        }
        item.menu = menu
        item.button?.performClick(nil)   // returns when the menu closes
        if recording.time != nil { item.menu = nil }
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
        if manager.isEnabled(.speedTest), let speed = manager.module(.speedTest) as? SpeedTestModule {
            for line in SpeedTestModule.menuLines(isRunning: speed.isRunning, failed: speed.failed, result: speed.result) {
                readings.append(reading(line.title, symbol: line.symbol))
            }
        }
        if !readings.isEmpty {
            readings.forEach(menu.addItem)
            menu.addItem(.separator())
        }

        // Next to Settings, as in the app menu of most Mac apps (R-17). No icon, like its neighbors.
        let updates = NSMenuItem(title: String(localized: "Check for Updates…"), action: #selector(checkForUpdates), keyEquivalent: "")
        updates.target = self
        updates.isEnabled = updater.canCheck
        menu.addItem(updates)

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

    @objc private func checkForUpdates() {
        updater.checkForUpdates()
    }

    @objc private func showSettings() {
        openSettings()
    }
}

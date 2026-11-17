import AppKit

/// Weather, Mac temperature and speed test as their own menu bar items (R-30), for Macs without
/// a Touch Bar. Each item exists only while its module is on and its switch in Settings is on
/// (default: on without a Touch Bar, off with one). One style, chosen in Settings, for all three.
/// Event-driven: weather and speed test notify their changes; the temperature is read every
/// ~10 s only while its item exists and the screens are awake.
final class MenuBarReadings: NSObject, NSMenuDelegate {
    enum Kind: String, CaseIterable {
        case weather, temperature, speedTest

        var module: ModuleID {
            switch self {
            case .weather: .weather
            case .temperature: .cpuTemperature
            case .speedTest: .speedTest
            }
        }

        var key: String { "menuBar.show.\(rawValue)" }
    }

    /// The three looks of the live demo (user, 2026-11-17: the user picks one).
    enum Style: String, CaseIterable, Identifiable {
        case sober, color, bold
        var id: String { rawValue }

        var title: String {
            switch self {
            case .sober: String(localized: "menuBarStyle.sober", defaultValue: "Simple")
            case .color: String(localized: "menuBarStyle.color", defaultValue: "Color")
            case .bold: String(localized: "menuBarStyle.bold", defaultValue: "Bold")
            }
        }
    }

    static let styleKey = "menuBar.readingStyle"
    /// On by default only where there is no Touch Bar to show these readings.
    static var shownByDefault: Bool { !TouchBarPrivate.hasTouchBar }
    /// Celsius from which the temperature turns orange (Color style only).
    private static let hot = 85

    static func isShown(_ kind: Kind) -> Bool {
        UserDefaults.standard.object(forKey: kind.key) as? Bool ?? shownByDefault
    }

    static var style: Style {
        Style(rawValue: UserDefaults.standard.string(forKey: styleKey) ?? "") ?? .sober
    }

    private let manager: ModuleManager
    private var items: [Kind: NSStatusItem] = [:]
    private var menus: [Kind: NSMenu] = [:]
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    /// What decides the items: which exist and their style. Redrawn only when it changes.
    private var lastSetup: (Set<Kind>, Style)?
    private var screensAsleep = false
    private var cpuTimer: Timer?
    private var speedTimer: Timer?
    private enum SpeedPhase { case normal, testing, download, upload, failed }
    private var speedPhase = SpeedPhase.normal
    private var needleStep = 0
    private static let needles = ["gauge.with.dots.needle.0percent", "gauge.with.dots.needle.33percent",
                                  "gauge.with.dots.needle.67percent", "gauge.with.dots.needle.100percent"]

    private var weather: WeatherModule? { manager.module(.weather) as? WeatherModule }
    private var cpu: CPUTemperatureModule? { manager.module(.cpuTemperature) as? CPUTemperatureModule }
    private var speedTest: SpeedTestModule? { manager.module(.speedTest) as? SpeedTestModule }

    init(manager: ModuleManager) {
        self.manager = manager
        super.init()
        let center = NotificationCenter.default
        func observe(_ name: Notification.Name, _ action: @escaping @Sendable @MainActor (MenuBarReadings) -> Void) {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { action(self) } }
            })
        }
        observe(ModuleManager.didChangeNotification) { $0.update() }
        // Any defaults write lands here; `update` only acts when the switches or style changed.
        observe(UserDefaults.didChangeNotification) { $0.update() }
        observe(WeatherModule.didChangeNotification) { $0.drawWeather() }
        observe(SpeedTestModule.didChangeNotification) { $0.speedTestChanged() }
        update()
    }

    // MARK: Items

    private func update() {
        let wanted = Set(Kind.allCases.filter { manager.isEnabled($0.module) && Self.isShown($0) })
        let style = Self.style
        if let lastSetup, lastSetup.0 == wanted, lastSetup.1 == style { return }
        let hadSpeedTest = items[.speedTest] != nil
        lastSetup = (wanted, style)

        // Right to left: a new item goes left of the existing ones, so create in reverse.
        for kind in Kind.allCases.reversed() {
            if wanted.contains(kind), items[kind] == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                item.autosaveName = "penknife.\(kind.rawValue)"
                let menu = NSMenu()
                menu.delegate = self
                menu.autoenablesItems = false
                item.menu = menu
                items[kind] = item
                menus[kind] = menu
            } else if !wanted.contains(kind), let item = items[kind] {
                NSStatusBar.system.removeStatusItem(item)
                items[kind] = nil
                menus[kind] = nil
            }
        }
        drawWeather()
        // A style change only redraws the speed test; it doesn't restart its animation.
        if (items[.speedTest] != nil) != hadSpeedTest { speedTestChanged() } else if hadSpeedTest { drawSpeedTest() }
        updateTemperatureWatch()
    }

    /// Symbol + optional text in the chosen style. Template (follows the menu bar) except in Color.
    private func draw(_ kind: Kind, symbol: String, text: String?, label: String, hot: Bool = false) {
        guard let button = items[kind]?.button else { return }
        let style = Self.style
        var name = symbol
        if style == .sober, name.hasSuffix(".fill") { name.removeLast(5) }
        var config = NSImage.SymbolConfiguration(pointSize: 13, weight: style == .bold ? .medium : .regular)
        if style == .color, kind == .weather { config = config.applying(.preferringMulticolor()) }
        let image = (NSImage(systemSymbolName: name, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: symbol, accessibilityDescription: nil))?.withSymbolConfiguration(config)
        image?.isTemplate = !(style == .color && kind == .weather)
        button.image = image
        button.imagePosition = text == nil ? .imageOnly : .imageLeading
        if let text {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: style == .bold ? .medium : .regular),
            ]
            if hot, style == .color { attributes[.foregroundColor] = NSColor.systemOrange }
            button.attributedTitle = NSAttributedString(string: " " + text, attributes: attributes)
        } else {
            button.title = ""
        }
        button.setAccessibilityLabel(label)
        button.toolTip = label
    }

    // MARK: Weather

    private func drawWeather() {
        guard items[.weather] != nil, let weather else { return }
        if let report = weather.report {
            draw(.weather, symbol: report.symbol, text: TemperatureText.short(celsius: report.celsius),
                 label: String(localized: "Weather: \(report.summary), \(TemperatureText.long(celsius: report.celsius))"))
        } else if weather.status == .noLocation {
            draw(.weather, symbol: "location.slash", text: nil,
                 label: String(localized: "Weather: location not allowed"))
        } else {
            draw(.weather, symbol: "cloud", text: nil, label: String(localized: "Weather: no data yet"))
        }
    }

    // MARK: Temperature

    /// The 10 s reading runs only while the item exists and the screens are awake.
    private func updateTemperatureWatch() {
        let watching = items[.temperature] != nil
        if watching, workspaceObservers.isEmpty {
            // The flag may be stale from an earlier watch; start from the real state.
            screensAsleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0
            let center = NSWorkspace.shared.notificationCenter
            for (name, asleep) in [(NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.screensDidWakeNotification, false)] {
                workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.screensAsleep = asleep
                        self?.readTemperature()
                    }
                })
            }
        } else if !watching {
            workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
            workspaceObservers = []
        }
        readTemperature()
    }

    private func readTemperature() {
        cpuTimer?.invalidate()
        cpuTimer = nil
        guard items[.temperature] != nil, !screensAsleep, let cpu else { return }
        let symbol = Self.style == .color ? "cpu" : "thermometer.medium"
        if let celsius = cpu.read() {
            let isHot = celsius >= Self.hot
            var label = String(localized: "Mac temperature: \(TemperatureText.long(celsius: Double(celsius)))")
            if isHot { label += ", " + String(localized: "temperature.hot", defaultValue: "hot") }
            draw(.temperature, symbol: symbol, text: TemperatureText.short(celsius: Double(celsius)), label: label, hot: isHot)
        } else {
            draw(.temperature, symbol: symbol, text: "—", label: String(localized: "CPU temperature not available"))
        }
        let timer = Timer(timeInterval: 10, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.readTemperature() }
        }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        cpuTimer = timer
    }

    // MARK: Speed test

    /// As on the Touch Bar (R-10): the needle sweeps while testing (one change every 0.6 s),
    /// then download for 3 s, upload for 3 s, and back to the plain symbol.
    private func speedTestChanged() {
        speedTimer?.invalidate()
        speedTimer = nil
        guard items[.speedTest] != nil, let speedTest else { return }
        if speedTest.isRunning {
            needleStep = 0
            setSpeedPhase(.testing)
            speedTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.needleStep = (self.needleStep + 1) % Self.needles.count
                    self.drawSpeedTest()
                }
            }
        } else if speedTest.failed, speedPhase == .testing {
            setSpeedPhase(.failed, then: [(6, .normal)])
        } else if speedTest.result != nil, speedPhase == .testing {
            setSpeedPhase(.download, then: [(3, .upload), (6, .normal)])
        } else {
            setSpeedPhase(.normal)
        }
    }

    private func setSpeedPhase(_ phase: SpeedPhase, then steps: [(TimeInterval, SpeedPhase)] = []) {
        speedPhase = phase
        drawSpeedTest()
        guard let (delay, next) = steps.first else { return }
        let rest = steps.dropFirst().map { ($0.0 - delay, $0.1) }
        speedTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.speedTimer = nil
                self?.setSpeedPhase(next, then: rest)
            }
        }
    }

    private func drawSpeedTest() {
        let result = speedTest?.result
        switch speedPhase {
        case .testing:
            draw(.speedTest, symbol: Self.needles[needleStep], text: nil, label: String(localized: "Speed test: testing…"))
        case .download where result != nil:
            let speed = SpeedText(mbps: result!.download)
            draw(.speedTest, symbol: "arrow.down", text: "\(speed.number) \(speed.unit)",
                 label: String(localized: "Download \(speed.spoken)"))
        case .upload where result != nil:
            let speed = SpeedText(mbps: result!.upload)
            draw(.speedTest, symbol: "arrow.up", text: "\(speed.number) \(speed.unit)",
                 label: String(localized: "Upload \(speed.spoken)"))
        case .failed:
            draw(.speedTest, symbol: "wifi.exclamationmark", text: nil, label: String(localized: "Speed test failed"))
        default:
            draw(.speedTest, symbol: "speedometer", text: nil, label: String(localized: "Speed Test"))
        }
    }

    // MARK: Menus

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let kind = menus.first(where: { $0.value === menu })?.key else { return }
        switch kind {
        case .weather:
            guard let weather else { return }
            if let report = weather.report {
                menu.addItem(reading(String(localized: "Weather: \(report.summary), \(TemperatureText.short(celsius: report.celsius))"),
                                     symbol: report.symbol))
            }
            if weather.status == .noLocation {
                menu.addItem(button(String(localized: "Allow Location…"), #selector(refreshWeather)))
            } else {
                menu.addItem(button(String(localized: "Update Now"), #selector(refreshWeather)))
            }
        case .temperature:
            if let celsius = cpu?.read() {
                menu.addItem(reading(String(localized: "CPU temperature: \(TemperatureText.short(celsius: Double(celsius)))"),
                                     symbol: "thermometer.medium"))
            } else {
                menu.addItem(reading(String(localized: "CPU temperature not available"), symbol: "thermometer.medium"))
            }
        case .speedTest:
            guard let speedTest else { return }
            if speedTest.isRunning {
                menu.addItem(reading(String(localized: "Speed test: testing…"), symbol: "speedometer"))
            } else {
                if speedTest.failed {
                    menu.addItem(reading(String(localized: "Speed test failed. Check the internet connection."), symbol: "wifi.exclamationmark"))
                }
                if let result = speedTest.result {
                    let time = result.date.formatted(date: Calendar.current.isDateInToday(result.date) ? .omitted : .abbreviated, time: .shortened)
                    menu.addItem(reading(String(localized: "Speed (\(time)): \(result.speeds)"), symbol: "speedometer"))
                    menu.addItem(reading(result.details, symbol: "timer"))
                    menu.addItem(.separator())
                }
                menu.addItem(button(String(localized: "Test Speed Now"), #selector(runSpeedTest)))
            }
        }
    }

    func menuWillOpen(_ menu: NSMenu) { manager.pauseShortcuts(true) }
    func menuDidClose(_ menu: NSMenu) { manager.pauseShortcuts(false) }

    private func reading(_ title: String, symbol: String) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return entry
    }

    private func button(_ title: String, _ action: Selector) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        return entry
    }

    @objc private func refreshWeather() { weather?.refresh() }
    @objc private func runSpeedTest() { speedTest?.run() }
}

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
    static var shownByDefault: Bool { shownByDefault(hasTouchBar: TouchBarPrivate.hasTouchBar) }
    static func shownByDefault(hasTouchBar: Bool) -> Bool { !hasTouchBar }
    /// Celsius from which the temperature turns orange (Color style only).
    static let hot = 85

    /// What the temperature item shows (CT-07): symbol by style, "54°" or "—", VoiceOver label.
    struct TemperatureLook: Equatable {
        let symbol: String, text: String, label: String, hot: Bool
    }

    static func temperatureLook(celsius: Int?, style: Style) -> TemperatureLook {
        let symbol = style == .color ? "cpu" : "thermometer.medium"
        guard let celsius else {
            return TemperatureLook(symbol: symbol, text: "—", label: String(localized: "CPU temperature not available"), hot: false)
        }
        let isHot = celsius >= hot
        var label = String(localized: "Mac temperature: \(TemperatureText.long(celsius: Double(celsius)))")
        if isHot { label += ", " + String(localized: "temperature.hot", defaultValue: "hot") }
        return TemperatureLook(symbol: symbol, text: TemperatureText.short(celsius: Double(celsius)), label: label, hot: isHot)
    }

    static func isShown(_ kind: Kind) -> Bool { isShown(kind, in: .standard, hasTouchBar: TouchBarPrivate.hasTouchBar) }
    static func isShown(_ kind: Kind, in defaults: UserDefaults, hasTouchBar: Bool) -> Bool {
        defaults.object(forKey: kind.key) as? Bool ?? shownByDefault(hasTouchBar: hasTouchBar)
    }

    static var style: Style { style(in: .standard) }
    /// Nothing stored or an unknown value → Simple (MB-12).
    static func style(in defaults: UserDefaults) -> Style {
        Style(rawValue: defaults.string(forKey: styleKey) ?? "") ?? .sober
    }

    /// The items that exist (MB-10): module on and its switch on.
    static func wanted(isEnabled: (ModuleID) -> Bool, isShown: (Kind) -> Bool) -> Set<Kind> {
        Set(Kind.allCases.filter { isEnabled($0.module) && isShown($0) })
    }

    /// Symbol name, weight and template look in a style (MB-12): Simple drops `.fill`; Bold is
    /// medium weight; Color keeps weather in its own colors (multicolor, not template).
    static func symbolLook(_ symbol: String, kind: Kind, style: Style) -> (name: String, medium: Bool, multicolor: Bool) {
        var name = symbol
        if style == .sober, name.hasSuffix(".fill") { name.removeLast(5) }
        return (name, style == .bold, style == .color && kind == .weather)
    }

    /// What the weather item shows (WX-11): the report's symbol and "18°"; else location refused
    /// or no data yet, symbol only.
    static func weatherLook(report: WeatherModule.Report?, status: WeatherModule.Status) -> (symbol: String, text: String?, label: String) {
        if let report {
            return (report.symbol, TemperatureText.short(celsius: report.celsius),
                    String(localized: "Weather: \(report.summary), \(TemperatureText.long(celsius: report.celsius))"))
        }
        if status == .noLocation {
            return ("location.slash", nil, String(localized: "Weather: location access is off"))
        }
        return ("cloud", nil, String(localized: "Weather: no data yet"))
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
    private var speedPhase = BarLooks.SpeedPhase.idle
    private var needleStep = 0

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
        let wanted = Self.wanted(isEnabled: manager.isEnabled, isShown: Self.isShown)
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
        let look = Self.symbolLook(symbol, kind: kind, style: style)
        var config = NSImage.SymbolConfiguration(pointSize: 13, weight: look.medium ? .medium : .regular)
        if look.multicolor { config = config.applying(.preferringMulticolor()) }
        let image = (NSImage(systemSymbolName: look.name, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: symbol, accessibilityDescription: nil))?.withSymbolConfiguration(config)
        image?.isTemplate = !look.multicolor
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
        let look = Self.weatherLook(report: weather.report, status: weather.status)
        draw(.weather, symbol: look.symbol, text: look.text, label: look.label)
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
        let look = Self.temperatureLook(celsius: cpu.read(), style: Self.style)
        draw(.temperature, symbol: look.symbol, text: look.text, label: look.label, hot: look.hot)
        let timer = Timer(timeInterval: 10, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.readTemperature() }
        }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        cpuTimer = timer
    }

    // MARK: Speed test

    /// As on the Touch Bar (R-10, TB-27), but a result or a failure plays only right after a
    /// test this item saw running (a new item shows the plain symbol).
    static func speedSteps(isRunning: Bool, failed: Bool, hasResult: Bool, wasTesting: Bool) -> [BarLooks.SpeedStep] {
        guard isRunning || wasTesting else { return [BarLooks.SpeedStep(at: 0, phase: .idle)] }
        return BarLooks.speedSteps(isRunning: isRunning, failed: failed, hasResult: hasResult)
    }

    /// The item's symbol, text ("245 Mbps", on one line) and VoiceOver label for each phase.
    static func speedLook(phase: BarLooks.SpeedPhase, needleStep: Int,
                          result: SpeedTestModule.Result?) -> (symbol: String, text: String?, label: String) {
        switch phase {
        case .testing:
            return (BarLooks.needle(step: needleStep), nil, String(localized: "Speed test: testing…"))
        case .download where result != nil:
            let speed = SpeedText(mbps: result!.download)
            return ("arrow.down", "\(speed.number) \(speed.unit)", String(localized: "Download \(speed.spoken)"))
        case .upload where result != nil:
            let speed = SpeedText(mbps: result!.upload)
            return ("arrow.up", "\(speed.number) \(speed.unit)", String(localized: "Upload \(speed.spoken)"))
        case .failed:
            return ("wifi.exclamationmark", nil, String(localized: "Couldn't test the speed"))
        default:
            return ("speedometer", nil, String(localized: "Speed Test"))
        }
    }

    /// The needle sweeps while testing (one change every 0.6 s), then download for 3 s, upload
    /// for 3 s, and back to the plain symbol.
    private func speedTestChanged() {
        speedTimer?.invalidate()
        speedTimer = nil
        guard items[.speedTest] != nil, let speedTest else { return }
        let steps = Self.speedSteps(isRunning: speedTest.isRunning, failed: speedTest.failed,
                                    hasResult: speedTest.result != nil, wasTesting: speedPhase == .testing)
        guard steps[0].phase == .testing else {
            setSpeedPhase(steps[0].phase, then: Array(steps.dropFirst()))
            return
        }
        needleStep = 0
        setSpeedPhase(.testing)
        speedTimer = Timer.scheduledTimer(withTimeInterval: BarLooks.needleInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.needleStep = (self.needleStep + 1) % BarLooks.needles.count
                self.drawSpeedTest()
            }
        }
    }

    /// Shows `phase` now and the next ones at their times (counted from now).
    private func setSpeedPhase(_ phase: BarLooks.SpeedPhase, then steps: [BarLooks.SpeedStep] = []) {
        speedPhase = phase
        drawSpeedTest()
        guard let next = steps.first else { return }
        let rest = steps.dropFirst().map { BarLooks.SpeedStep(at: $0.at - next.at, phase: $0.phase) }
        speedTimer = Timer.scheduledTimer(withTimeInterval: next.at, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.speedTimer = nil
                self?.setSpeedPhase(next.phase, then: rest)
            }
        }
    }

    private func drawSpeedTest() {
        let look = Self.speedLook(phase: speedPhase, needleStep: needleStep, result: speedTest?.result)
        draw(.speedTest, symbol: look.symbol, text: look.text, label: look.label)
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
                menu.addItem(button(String(localized: "Update Weather"), #selector(refreshWeather)))
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
            for line in SpeedTestModule.menuLines(isRunning: speedTest.isRunning, failed: speedTest.failed, result: speedTest.result) {
                menu.addItem(reading(line.title, symbol: line.symbol))
            }
            if !speedTest.isRunning {
                if speedTest.result != nil { menu.addItem(.separator()) }
                menu.addItem(button(String(localized: "Run Speed Test"), #selector(runSpeedTest)))
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

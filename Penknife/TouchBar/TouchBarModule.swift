import AppKit
import CoreAudio
import IOKit.ps
import os

/// Touch Bar (R-1): Penknife's own bar over the whole Touch Bar, written from scratch
/// (MTMR only showed which private calls exist). Steps aside while a dialog is in front (R-4).
/// Everything is event-driven: battery and microphone notifications, a clock timer aligned
/// to the minute. Nothing runs while the module is off or on Macs without a Touch Bar.
final class TouchBarModule: NSObject, Module, NSTouchBarDelegate {
    let id = ModuleID.touchBar
    let actions: [ModuleAction] = []

    weak var manager: ModuleManager?
    private let jiggler: JigglerModule
    private let microphone: MicrophoneModule
    private let dialogs: DialogsModule
    private let music: MusicModule
    private let cpu: CPUTemperatureModule
    private let weather: WeatherModule
    private let log = Logger(subsystem: "Penknife", category: "TouchBar")

    private var bar: NSTouchBar?
    private var barView: BarView?
    private var running = false
    private var stepAside = false
    private var observers: [NSObjectProtocol] = []
    private var batterySource: CFRunLoopSource?
    private var clockTimer: Timer?
    private var dateTimer: Timer?
    private var showingDate = false
    private lazy var micWatcher = MicrophoneWatcher { [weak self] in self?.updateMicrophone() }
    private var cpuTimer: Timer?
    private var screensAsleep = false

    private static let barItemID = NSTouchBarItem.Identifier("io.github.alexl-l.Penknife.bar")
    private static let trayItemID = NSTouchBarItem.Identifier("io.github.alexl-l.Penknife.tray")
    private static let colorModeKey = "touchBar.colorMode"
    static let autoCloseKey = "touchBar.autoClose"

    /// Sliders and the date close by themselves; off means only a tap closes them (R-19).
    static var autoClose: Bool {
        get { UserDefaults.standard.object(forKey: autoCloseKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: autoCloseKey) }
    }

    init(jiggler: JigglerModule, microphone: MicrophoneModule, dialogs: DialogsModule,
         music: MusicModule, cpu: CPUTemperatureModule, weather: WeatherModule) {
        self.jiggler = jiggler
        self.microphone = microphone
        self.dialogs = dialogs
        self.music = music
        self.cpu = cpu
        self.weather = weather
        super.init()
    }

    // MARK: Module

    func start() {
        guard !running, TouchBarPrivate.hasTouchBar else { return }
        guard TouchBarPrivate.isAvailable else {
            log.error("Private Touch Bar calls not found")
            return
        }
        running = true

        let view = BarView(width: 1004)
        view.colorMode = BarColorMode(rawValue: UserDefaults.standard.integer(forKey: Self.colorModeKey)) ?? .own
        barView = view
        let bar = NSTouchBar()
        bar.delegate = self
        bar.defaultItemIdentifiers = [Self.barItemID]
        self.bar = bar

        let tray = NSCustomTouchBarItem(identifier: Self.trayItemID)
        tray.view = NSButton(image: NSImage(named: "MenuBarIcon") ?? NSImage(),
                             target: self, action: #selector(present))
        tray.view.setAccessibilityLabel("Penknife")
        TouchBarPrivate.addTrayItem(tray)

        rebuildButtons()
        startSources()

        dialogs.onChange = { [weak self] open in
            guard let self else { return }
            self.stepAside = open
            open ? self.minimize() : self.present()
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didWakeNotification] {
            let isWake = name == NSWorkspace.didWakeNotification
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if isWake { self?.updateClock() }
                    self?.present()
                }
            })
        }
        // The CPU temperature isn't read while the screens sleep (the Touch Bar is off too).
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification] {
            let asleep = name == NSWorkspace.screensDidSleepNotification
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.screensAsleep = asleep
                    self?.updateTemperature()
                }
            })
        }
        weather.onChange = { [weak self] in self?.updateWeather() }
        // Turning another module on or off changes which buttons exist.
        observers.append(NotificationCenter.default.addObserver(forName: ModuleManager.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildButtons() }
        })
        present()
        #if DEBUG
        // Development only: `-easterEgg` plays the animation at launch, for screenshots.
        if ProcessInfo.processInfo.arguments.contains("-easterEgg") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.barView?.playEasterEgg() }
        }
        #endif
    }

    func stop() {
        guard running else { return }
        running = false
        dialogs.onChange = nil
        weather.onChange = nil
        observers.forEach {
            NSWorkspace.shared.notificationCenter.removeObserver($0)
            NotificationCenter.default.removeObserver($0)
        }
        observers = []
        stopSources()
        barView?.closeSlider()
        if let bar { TouchBarPrivate.minimize(bar) }
        TouchBarPrivate.removeTrayItem(Self.trayItemID)
        bar = nil
        barView = nil
    }

    @objc private func present() {
        guard running, !stepAside, let bar else { return }
        TouchBarPrivate.present(bar, trayIdentifier: Self.trayItemID)
    }

    private func minimize() {
        guard let bar else { return }
        barView?.closeSlider()
        TouchBarPrivate.minimize(bar)
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        guard identifier == Self.barItemID, let barView else { return nil }
        let item = NSCustomTouchBarItem(identifier: identifier)
        item.view = barView
        return item
    }

    // MARK: Buttons

    private enum Item: String {
        case battery, brightness, keyboardLight, jiggler, microphone, screenshot, lock, music, weather, cpu, volume, time
    }

    private func isOn(_ module: ModuleID) -> Bool { manager?.isEnabled(module) ?? false }

    /// 12 equal buttons in the order of the previous MTMR setup; buttons of modules that are off
    /// are left out.
    private func rebuildButtons() {
        guard let barView else { return }
        var buttons: [BarButton] = []
        func add(_ item: Item, _ hex: UInt32, _ press: @escaping (BarButton) -> Void) {
            let button = BarButton(itemID: item.rawValue, color: NSColor(hex: hex))
            button.onPress = press
            buttons.append(button)
        }
        add(.battery, 0xFFFFFF) { [weak self] _ in self?.nextColorMode() }
        add(.brightness, 0xFFDB00) { [weak self] in self?.openSlider($0, DisplayBrightness(), String(localized: "Brightness")) }
        add(.keyboardLight, 0x4AD1E6) { [weak self] in self?.openSlider($0, KeyboardBrightness(), String(localized: "Keyboard backlight")) }
        if isOn(.jiggler) {
            add(.jiggler, 0x0099FF) { [weak self] _ in self?.run(.jiggler) }
        }
        if isOn(.microphone) {
            add(.microphone, 0xFF5D49) { [weak self] _ in self?.run(.microphone) }
        }
        if isOn(.screenshot) {
            add(.screenshot, 0xCC77F4) { [weak self] _ in self?.run(.screenshot) }
        }
        if isOn(.lockScreen) {
            add(.lock, 0x7176EB) { [weak self] _ in self?.run(.lockScreen) }
        }
        if isOn(.music) {
            add(.music, 0x08DA73) { [weak self] _ in self?.music.tap() }
        }
        if isOn(.weather) {
            add(.weather, 0x75DAD8) { [weak self] _ in self?.weather.refresh(ifOlderThan: 60) }
        }
        if isOn(.cpuTemperature) {
            add(.cpu, 0xFFAE02) { [weak self] _ in self?.updateTemperature() }
        }
        add(.volume, 0xFFAE02) { [weak self] in self?.openSlider($0, OutputVolume(), String(localized: "Volume")) }
        add(.time, 0xFFFFFF) { [weak self] _ in self?.toggleDate() }
        barView.setButtons(buttons)
        if let time = barView.button(Item.time.rawValue) {
            let press = NSPressGestureRecognizer(target: self, action: #selector(timeLongPressed(_:)))
            press.allowedTouchTypes = .direct
            press.minimumPressDuration = 0.8
            time.addGestureRecognizer(press)
        }

        barView.button(Item.brightness.rawValue)?.show(symbol: "sun.max.fill", label: String(localized: "Brightness"))
        barView.button(Item.keyboardLight.rawValue)?.show(symbol: "light.min", label: String(localized: "Keyboard backlight"))
        barView.button(Item.screenshot.rawValue)?.show(symbol: "camera.viewfinder", label: String(localized: "Screenshot"))
        barView.button(Item.lock.rawValue)?.show(symbol: "lock.fill", label: String(localized: "Lock screen"))
        barView.button(Item.volume.rawValue)?.show(symbol: "speaker.wave.2.fill", label: String(localized: "Volume"))
        barView.button(Item.music.rawValue)?.show(
            symbol: "music.note",
            label: String(localized: "Music. One tap plays or pauses, two go to the next song, three to the previous one."))
        updateBattery()
        updateJiggler()
        updateMicrophone()
        updateClock()
        updateWeather()
        updateTemperature()
    }

    private func run(_ module: ModuleID) {
        guard let manager, let action = manager.module(module)?.actions.first else { return }
        manager.run(action)
        if module == .microphone { updateMicrophone() }
    }

    private func openSlider(_ button: BarButton, _ control: LevelControl, _ label: String) {
        barView?.openSlider(from: button, control: control, label: label, autoClose: Self.autoClose)
    }

    private func nextColorMode() {
        guard let barView else { return }
        barView.colorMode = barView.colorMode.next
        UserDefaults.standard.set(barView.colorMode.rawValue, forKey: Self.colorModeKey)
    }

    // MARK: Sources

    private func startSources() {
        // Battery: the system notifies when any power source changes.
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let module = Unmanaged<TouchBarModule>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { module.updateBattery() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            batterySource = source
        }
        micWatcher.start()
        trackJiggler()
    }

    private func stopSources() {
        if let batterySource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), batterySource, .defaultMode)
        }
        batterySource = nil
        clockTimer?.invalidate()
        clockTimer = nil
        dateTimer?.invalidate()
        dateTimer = nil
        showingDate = false
        cpuTimer?.invalidate()
        cpuTimer = nil
        micWatcher.stop()
    }

    // MARK: Weather and CPU

    private func updateWeather() {
        guard let button = barView?.button(Item.weather.rawValue) else { return }
        if let report = weather.report {
            let text = TemperatureText.short(celsius: report.celsius)
            button.show(symbol: report.symbol, text: text,
                        label: String(localized: "Weather: \(report.summary), \(TemperatureText.long(celsius: report.celsius))"))
        } else if weather.status == .noLocation {
            button.show(symbol: "location.slash", label: String(localized: "Weather: location not allowed. Tap to open the settings."))
        } else {
            button.show(symbol: "cloud", label: String(localized: "Weather: no data yet"))
        }
    }

    /// Reads the CPU temperature now and again in ~10 s, only while its button is on screen.
    private func updateTemperature() {
        cpuTimer?.invalidate()
        cpuTimer = nil
        guard running, !screensAsleep, let button = barView?.button(Item.cpu.rawValue) else { return }
        if let celsius = cpu.read() {
            button.show(symbol: "thermometer.medium", text: TemperatureText.short(celsius: Double(celsius)),
                        label: String(localized: "CPU temperature: \(TemperatureText.long(celsius: Double(celsius)))"))
        } else {
            button.show(symbol: "thermometer.medium", text: "—", label: String(localized: "CPU temperature not available"))
        }
        let timer = Timer(timeInterval: 10, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateTemperature() }
        }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        cpuTimer = timer
    }

    private func updateBattery() {
        guard let button = barView?.button(Item.battery.rawValue) else { return }
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let list = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        let percent = list.lazy.compactMap { source -> Int? in
            let description = IOPSGetPowerSourceDescription(info, source).takeUnretainedValue() as? [String: Any]
            return description?[kIOPSCurrentCapacityKey] as? Int
        }.first
        let text = percent.map { "\($0)%" } ?? "—"
        button.show(symbol: nil, text: text,
                    label: String(localized: "Battery \(text). Tap to change the icon colors."))
    }

    /// The jiggler is @Observable: re-arm the tracking after every change.
    private func trackJiggler() {
        guard running else { return }
        withObservationTracking {
            _ = jiggler.isActive
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.updateJiggler()
                    self?.trackJiggler()
                }
            }
        }
    }

    private func updateJiggler() {
        // State is shown by the symbol, not only by color (R-19).
        let on = jiggler.isActive
        barView?.button(Item.jiggler.rawValue)?.show(
            symbol: on ? "cursorarrow.motionlines" : "cursorarrow",
            label: on ? String(localized: "Mouse jiggler, on") : String(localized: "Mouse jiggler, off"))
    }

    private func updateMicrophone() {
        let muted = microphone.isMuted
        barView?.button(Item.microphone.rawValue)?.show(
            symbol: muted ? "mic.slash.fill" : "mic.fill",
            label: muted ? String(localized: "Microphone, muted") : String(localized: "Microphone, on"))
    }

    // MARK: Clock

    private static let timeFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mm"
        return formatter
    }()

    private static let dateFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd/MM/yy"
        return formatter
    }()

    /// Shows the time and sleeps until the next minute starts (one wakeup per minute).
    private func updateClock() {
        clockTimer?.invalidate()
        guard running, let button = barView?.button(Item.time.rawValue) else { return }
        let now = Date()
        if showingDate {
            let date = Self.dateFormat.string(from: now)
            button.show(symbol: nil, text: date, label: now.formatted(date: .complete, time: .omitted))
        } else {
            button.show(symbol: nil, text: Self.timeFormat.string(from: now),
                        label: now.formatted(date: .omitted, time: .shortened))
        }
        let next = Calendar.current.nextDate(after: now, matching: DateComponents(second: 0), matchingPolicy: .nextTime) ?? now.addingTimeInterval(60)
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateClock() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        clockTimer = timer
    }

    /// When the long press ended, so the release that ends it doesn't also toggle the date.
    private var longPressEnded = Date.distantPast
    private var longPressing = false

    @objc private func timeLongPressed(_ recognizer: NSPressGestureRecognizer) {
        switch recognizer.state {
        case .began:
            longPressing = true
            barView?.playEasterEgg()
        case .ended, .cancelled, .failed:
            longPressing = false
            longPressEnded = Date()
        default: break
        }
    }

    /// Tap shows the date (DD/MM/YY) for 4 s; tapping again hides it.
    private func toggleDate() {
        if longPressing || Date().timeIntervalSince(longPressEnded) < 0.5 { return }
        dateTimer?.invalidate()
        dateTimer = nil
        showingDate.toggle()
        if showingDate, Self.autoClose {
            dateTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.showingDate = false
                    self?.updateClock()
                }
            }
        }
        updateClock()
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

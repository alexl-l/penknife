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
    private let speedTest: SpeedTestModule
    /// Needle sweep while testing, then the download → upload → normal sequence.
    private var speedTimer: Timer?
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
    private lazy var brightnessWatcher = BrightnessWatcher { [weak self] in self?.levelChanged(.brightness) }
    private lazy var keyboardWatcher = KeyboardLightWatcher { [weak self] in self?.levelChanged(.keyboardLight) }
    private lazy var volumeWatcher = VolumeWatcher { [weak self] in self?.levelChanged(.volume) }
    /// Levels changed since the last update; a burst of key presses or a drag becomes one read.
    private var pendingLevels: Set<Item> = []
    private var refreshScheduled = false
    private lazy var playbackWatcher = PlaybackWatcher { [weak self] in self?.updateMusic() }
    private var playerID = ""
    private var cpuTimer: Timer?
    private var screensAsleep = false

    private static let barItemID = NSTouchBarItem.Identifier("io.github.alexl-l.Penknife.bar")
    private static let trayItemID = NSTouchBarItem.Identifier("io.github.alexl-l.Penknife.tray")
    static let colorModeKey = "touchBar.colorMode"
    static let monochromeKey = "touchBar.monochromeColor"
    static let batteryIconKey = "touchBar.batteryIcon"
    static let autoCloseKey = "touchBar.autoClose"

    /// Monochrome color as "RRGGBB" (R-25); white until the user picks another.
    static var monochromeColor: NSColor {
        let hex = UserDefaults.standard.string(forKey: monochromeKey).flatMap { UInt32($0, radix: 16) }
        return NSColor(hex: hex ?? 0xFFFFFF)
    }

    private static var storedColorMode: BarColorMode {
        BarColorMode(rawValue: UserDefaults.standard.integer(forKey: colorModeKey)) ?? .multicolor
    }

    /// Sliders and the date close by themselves; off means only a tap closes them (R-19).
    static var autoClose: Bool {
        get { UserDefaults.standard.object(forKey: autoCloseKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: autoCloseKey) }
    }

    init(jiggler: JigglerModule, microphone: MicrophoneModule, dialogs: DialogsModule,
         music: MusicModule, cpu: CPUTemperatureModule, weather: WeatherModule, speedTest: SpeedTestModule) {
        self.jiggler = jiggler
        self.microphone = microphone
        self.dialogs = dialogs
        self.music = music
        self.cpu = cpu
        self.weather = weather
        self.speedTest = speedTest
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
        view.onSliderClose = { [weak self] in
            guard let self, !self.pendingLevels.isEmpty else { return }
            self.refreshLevels()
        }
        // The hold that opened the game may never report its end (the button was hidden).
        view.onGameEnd = { [weak self] in self?.jigglerLongPressing = false }
        view.monochromeColor = Self.monochromeColor
        view.colorMode = Self.storedColorMode
        playerID = MusicPlayer.current.id
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

        TapSound.prepare()
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
                    if asleep { self?.barView?.closeGame() }
                    self?.updateTemperature()
                    if !asleep { self?.refreshLevels() }
                }
            })
        }
        weather.onChange = { [weak self] in self?.updateWeather() }
        speedTest.onChange = { [weak self] in self?.speedTestChanged() }
        // Turning another module on or off changes which buttons exist.
        observers.append(NotificationCenter.default.addObserver(forName: ModuleManager.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildButtons() }
        })
        // Settings: color mode, monochrome color, music player. Other writes change nothing here.
        observers.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsChanged() }
        })
        // The game never keeps running behind the lock screen.
        lockObserver = DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.barView?.closeGame() }
        }
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
        speedTest.onChange = nil
        speedTimer?.invalidate()
        speedTimer = nil
        observers.forEach {
            NSWorkspace.shared.notificationCenter.removeObserver($0)
            NotificationCenter.default.removeObserver($0)
        }
        observers = []
        if let lockObserver { DistributedNotificationCenter.default().removeObserver(lockObserver) }
        lockObserver = nil
        barView?.closeGame()
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
        barView?.closeGame()
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
        case battery, brightness, keyboardLight, jiggler, microphone, screenshot, lock, music, weather, cpu, volume, speedTest, time
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
        add(.battery, 0xFFFFFF) { [weak self] _ in self?.toggleBatteryIcon() }
        add(.brightness, 0xFFDB00) { [weak self] in self?.openSlider($0, DisplayBrightness(), String(localized: "Brightness")) }
        add(.keyboardLight, 0x4AD1E6) { [weak self] in self?.openSlider($0, KeyboardBrightness(), String(localized: "Keyboard backlight")) }
        if isOn(.jiggler) {
            add(.jiggler, 0x0099FF) { [weak self] _ in self?.jigglerTapped() }
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
        if isOn(.speedTest) {
            add(.speedTest, 0x34C759) { [weak self] _ in self?.speedTest.run() }
        }
        add(.time, 0xFFFFFF) { [weak self] _ in self?.toggleDate() }
        barView.setButtons(buttons)
        if let time = barView.button(Item.time.rawValue) {
            let press = NSPressGestureRecognizer(target: self, action: #selector(timeLongPressed(_:)))
            press.allowedTouchTypes = .direct
            press.minimumPressDuration = 0.8
            time.addGestureRecognizer(press)
        }
        if let jiggler = barView.button(Item.jiggler.rawValue) {
            let press = NSPressGestureRecognizer(target: self, action: #selector(jigglerLongPressed(_:)))
            press.allowedTouchTypes = .direct
            press.minimumPressDuration = 3
            jiggler.addGestureRecognizer(press)
        }
        // A hold on the old battery or jiggler button may never report its end.
        endBatteryHold()
        jigglerLongPressing = false
        if let battery = barView.button(Item.battery.rawValue) {
            let press = NSPressGestureRecognizer(target: self, action: #selector(batteryLongPressed(_:)))
            press.allowedTouchTypes = .direct
            press.minimumPressDuration = 1
            battery.addGestureRecognizer(press)
        }

        barView.button(Item.screenshot.rawValue)?.show(symbol: "camera.viewfinder", label: String(localized: "Screenshot"))
        barView.button(Item.lock.rawValue)?.show(symbol: "lock.fill", label: String(localized: "Lock screen"))
        isOn(.music) ? playbackWatcher.start() : playbackWatcher.stop()
        updateBrightness()
        updateKeyboardLight()
        updateVolume()
        updateMusic()
        updateBattery()
        updateJiggler()
        updateMicrophone()
        updateClock()
        updateWeather()
        updateTemperature()
        updateSpeedTest()
    }

    private func run(_ module: ModuleID) {
        guard let manager, let action = manager.module(module)?.actions.first else { return }
        manager.run(action)
        if module == .microphone { updateMicrophone() }
    }

    private func openSlider(_ button: BarButton, _ control: LevelControl, _ label: String) {
        barView?.openSlider(from: button, control: control, label: label, autoClose: Self.autoClose)
    }

    /// Long press on the battery: next color mode, remembered (R-25).
    private func nextColorMode() {
        guard let barView else { return }
        barView.colorMode = barView.colorMode.next
        UserDefaults.standard.set(barView.colorMode.rawValue, forKey: Self.colorModeKey)
        if let battery = barView.button(Item.battery.rawValue) {
            NSAccessibility.post(element: battery, notification: .announcementRequested, userInfo: [
                .announcement: barView.colorMode.title, .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
        }
    }

    private func settingsChanged() {
        guard let barView else { return }
        let mode = Self.storedColorMode
        if mode != barView.colorMode { barView.colorMode = mode }
        let mono = Self.monochromeColor
        if mono != barView.monochromeColor { barView.monochromeColor = mono }
        let player = MusicPlayer.current.id
        if player != playerID {
            playerID = player
            playbackWatcher.reset()
        }
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
        brightnessWatcher.start()
        keyboardWatcher.start()
        volumeWatcher.start()
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
        endBatteryHold()
        micWatcher.stop()
        brightnessWatcher.stop()
        keyboardWatcher.stop()
        volumeWatcher.stop()
        playbackWatcher.stop()
    }

    // MARK: Speed test (R-10)

    private enum SpeedPhase { case normal, testing, download, upload, failed }
    private var speedPhase = SpeedPhase.normal
    private var needleStep = 0
    private static let needles = ["gauge.with.dots.needle.0percent", "gauge.with.dots.needle.33percent",
                                  "gauge.with.dots.needle.67percent", "gauge.with.dots.needle.100percent"]

    /// Design chosen by the user (variant 4, 2026-11-14): while testing the needle sweeps
    /// (one symbol change every 0.6 s); then download for 3 s, upload for 3 s, back to normal.
    private func speedTestChanged() {
        speedTimer?.invalidate()
        speedTimer = nil
        if speedTest.isRunning {
            needleStep = 0
            setSpeedPhase(.testing)
            speedTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.needleStep = (self.needleStep + 1) % Self.needles.count
                    self.updateSpeedTest()
                }
            }
        } else if speedTest.failed {
            setSpeedPhase(.failed, then: [(6, .normal)])
        } else if speedTest.result != nil {
            setSpeedPhase(.download, then: [(3, .upload), (6, .normal)])
        } else {
            setSpeedPhase(.normal)
        }
    }

    /// Shows `phase` now and the next ones after the given seconds (counted from now).
    private func setSpeedPhase(_ phase: SpeedPhase, then steps: [(TimeInterval, SpeedPhase)] = []) {
        speedPhase = phase
        updateSpeedTest()
        guard let (delay, next) = steps.first else { return }
        let rest = steps.dropFirst().map { ($0.0 - delay, $0.1) }
        speedTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.speedTimer = nil
                self?.setSpeedPhase(next, then: rest)
            }
        }
    }

    private func updateSpeedTest() {
        guard let button = barView?.button(Item.speedTest.rawValue) else { return }
        let result = speedTest.result
        switch speedPhase {
        case .testing:
            button.show(symbol: Self.needles[needleStep], label: String(localized: "Speed test: testing…"))
        case .download where result != nil:
            button.show(symbol: "arrow.down", text: "\(Int(result!.download.rounded()))",
                        label: String(localized: "Download \(Int(result!.download.rounded())) megabits per second"))
        case .upload where result != nil:
            button.show(symbol: "arrow.up", text: "\(Int(result!.upload.rounded()))",
                        label: String(localized: "Upload \(Int(result!.upload.rounded())) megabits per second"))
        case .failed:
            button.show(symbol: "wifi.exclamationmark", label: String(localized: "Speed test failed. Tap to try again."))
        default:
            button.show(symbol: "speedometer", label: String(localized: "Speed test"))
        }
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
            let symbol = celsius < 50 ? "thermometer.low" : celsius < 75 ? "thermometer.medium" : "thermometer.high"
            button.show(symbol: symbol, text: TemperatureText.short(celsius: Double(celsius)),
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

    /// Tap on the battery: percentage ↔ icon, remembered (R-25).
    private func toggleBatteryIcon() {
        if batteryLongPressing || Date().timeIntervalSince(batteryLongPressEnded) < 0.5 { return }
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: Self.batteryIconKey), forKey: Self.batteryIconKey)
        updateBattery()
    }

    private func updateBattery() {
        guard let barView, let button = barView.button(Item.battery.rawValue) else { return }
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let list = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        let description = list.lazy.compactMap {
            IOPSGetPowerSourceDescription(info, $0).takeUnretainedValue() as? [String: Any]
        }.first { $0[kIOPSCurrentCapacityKey] != nil }
        let percent = description?[kIOPSCurrentCapacityKey] as? Int
        let charging = description?[kIOPSIsChargingKey] as? Bool ?? false
        let text = percent.map { "\($0)%" } ?? "—"
        let label = charging
            ? String(localized: "Battery \(text), charging. Tap to switch between percentage and icon; hold to change the colors.")
            : String(localized: "Battery \(text). Tap to switch between percentage and icon; hold to change the colors.")

        // Level colors only in multicolor mode, on the icon (green > 50 %, yellow 20–50 %, red < 20 %).
        let showIcon = UserDefaults.standard.bool(forKey: Self.batteryIconKey) && percent != nil
        let stateColor: NSColor? = switch (showIcon, percent) {
        case (true, let p?) where p > 50: .systemGreen
        case (true, let p?) where p >= 20: .systemYellow
        case (true, _?): .systemRed
        default: nil
        }
        if stateColor != button.stateColor {
            button.stateColor = stateColor
            barView.applyColors()
        }
        if showIcon, let percent {
            button.show(drawing: { BatteryIcon.image(fraction: CGFloat(percent) / 100, charging: charging, color: $0) },
                        key: "\(percent)\(charging)", label: label)
        } else {
            button.show(symbol: nil, text: text, label: label)
        }
    }

    // MARK: Levels and music

    /// Coalesces level notifications (~0.1 s). Nothing is read while the screens sleep;
    /// they are read again on wake.
    private func levelChanged(_ item: Item) {
        guard running, !screensAsleep else { return }
        pendingLevels.insert(item)
        // While a slider is open the buttons are hidden: read once when it closes, so dragging
        // never waits for CoreAudio / DisplayServices reads.
        if barView?.isSliderOpen == true { return }
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshScheduled = false
                self?.refreshLevels()
            }
        }
    }

    /// Reads the pending levels, or all of them when none is pending (after wake).
    private func refreshLevels() {
        let items: Set<Item> = pendingLevels.isEmpty ? [.brightness, .keyboardLight, .volume] : pendingLevels
        pendingLevels = []
        if items.contains(.brightness) { updateBrightness() }
        if items.contains(.keyboardLight) { updateKeyboardLight() }
        if items.contains(.volume) { updateVolume() }
    }

    private func updateBrightness() {
        let level = DisplayBrightness().level ?? 1
        barView?.button(Item.brightness.rawValue)?.show(
            symbol: level < 0.5 ? "sun.min.fill" : "sun.max.fill",
            label: String(localized: "Brightness \(Self.percent(level))"))
    }

    private func updateKeyboardLight() {
        let level = KeyboardBrightness().level ?? 0
        barView?.button(Item.keyboardLight.rawValue)?.show(
            symbol: level < 0.5 ? "light.min" : "light.max",
            label: String(localized: "Keyboard backlight \(Self.percent(level))"))
    }

    private func updateVolume() {
        let output = OutputVolume()
        // Outputs without volume control (HDMI, some DACs) have no level: not shown as muted.
        let level = output.level ?? 0.5
        let muted = output.isMuted || level == 0
        let symbol = muted ? "speaker.slash.fill"
            : level < 0.34 ? "speaker.wave.1.fill" : level < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        barView?.button(Item.volume.rawValue)?.show(
            symbol: symbol,
            label: muted ? String(localized: "Volume, muted") : String(localized: "Volume \(Self.percent(level))"))
    }

    private func updateMusic() {
        let playing = playbackWatcher.isPlaying
        let hint = String(localized: "One tap plays or pauses, two go to the next song, three to the previous one.")
        barView?.button(Item.music.rawValue)?.show(
            symbol: playing ? "music.quarternote.3" : "music.note",
            label: (playing ? String(localized: "Music, playing.") : String(localized: "Music, paused.")) + " " + hint)
    }

    private static func percent(_ level: Float) -> String {
        Double(level).formatted(.percent.precision(.fractionLength(0)))
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

    /// Hold on the jiggler for 3 s opens the game (R-23); the release must not toggle the jiggler.
    private var jigglerLongPressEnded = Date.distantPast
    private var jigglerLongPressing = false
    private var lockObserver: NSObjectProtocol?

    private func jigglerTapped() {
        if jigglerLongPressing || Date().timeIntervalSince(jigglerLongPressEnded) < 0.5 { return }
        run(.jiggler)
    }

    @objc private func jigglerLongPressed(_ recognizer: NSPressGestureRecognizer) {
        switch recognizer.state {
        case .began:
            jigglerLongPressing = true
            barView?.playGame()
        case .ended, .cancelled, .failed:
            jigglerLongPressing = false
            jigglerLongPressEnded = Date()
        default: break
        }
    }

    private var batteryLongPressEnded = Date.distantPast
    private var batteryLongPressing = false
    private var batteryRepeatTimer: Timer?

    private func endBatteryHold() {
        batteryRepeatTimer?.invalidate()
        batteryRepeatTimer = nil
        batteryLongPressing = false
    }

    @objc private func batteryLongPressed(_ recognizer: NSPressGestureRecognizer) {
        switch recognizer.state {
        case .began:
            batteryLongPressing = true
            nextColorMode()
            // Still held: the next mode every second, until the finger lifts.
            batteryRepeatTimer?.invalidate()
            batteryRepeatTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.nextColorMode() }
            }
        case .ended, .cancelled, .failed:
            endBatteryHold()
            batteryLongPressEnded = Date()
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

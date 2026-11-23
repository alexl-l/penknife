import AppKit
import CoreAudio
import IOKit.ps
import os

/// Touch Bar (R-1): Penknife's own bar over the whole Touch Bar, written from scratch
/// (MTMR only showed which private calls exist). Steps aside while a dialog is in front (R-4).
/// Event-driven (TB-61): notifications for the battery, levels, microphone, music and jiggler;
/// the only timers are the clock (once a minute), the CPU temperature (10 s, while shown), the
/// date, the speed test sequence, the battery hold and the game. Each button's watcher or timer
/// runs only while it is on the bar (B-6). Nothing runs while the module is off or on Macs
/// without a Touch Bar (Native Dialogs then watches nothing either, B-5).
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
    private let presenter: any BarPresenter
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
    private lazy var micWatcher = MicrophoneWatcher(followsSiri: true) { [weak self] in self?.updateMicrophone() }
    private lazy var brightnessWatcher = BrightnessWatcher { [weak self] in self?.levelChanged(.brightness) }
    private lazy var keyboardWatcher = KeyboardLightWatcher { [weak self] in self?.levelChanged(.keyboardLight) }
    private lazy var volumeWatcher = VolumeWatcher { [weak self] in self?.levelChanged(.volume) }
    /// Levels changed since the last update; a burst of key presses or a drag becomes one read.
    private var pendingLevels: Set<Item> = []
    private var refreshScheduled = false
    private lazy var playbackWatcher = PlaybackWatcher { [weak self] in self?.updateMusic() }
    private var playerID = ""
    /// The buttons on the bar now, to rebuild only when the layout really changes.
    private var shownItems: [BarItem] = []
    private var cpuTimer: Timer?
    private var screensAsleep = false

    private static let barItemID = NSTouchBarItem.Identifier("io.github.alexl-l.Penknife.bar")
    private static let trayItemID = NSTouchBarItem.Identifier("io.github.alexl-l.Penknife.tray")
    static let colorModeKey = "touchBar.colorMode"
    static let monochromeKey = "touchBar.monochromeColor"
    static let batteryIconKey = "touchBar.batteryIcon"
    static let autoCloseKey = "touchBar.autoClose"

    /// Monochrome color as "RRGGBB" (R-25); white until the user picks another.
    static var monochromeColor: NSColor { NSColor(hex: monochromeHex(in: .standard)) }
    static func monochromeHex(in defaults: UserDefaults) -> UInt32 {
        defaults.string(forKey: monochromeKey).flatMap { UInt32($0, radix: 16) } ?? 0xFFFFFF
    }

    private static var storedColorMode: BarColorMode { colorMode(in: .standard) }
    static func colorMode(in defaults: UserDefaults) -> BarColorMode {
        BarColorMode(rawValue: defaults.integer(forKey: colorModeKey)) ?? .multicolor
    }

    /// Sliders and the date close by themselves; off means only a tap closes them (R-19).
    static var autoClose: Bool {
        get { autoClose(in: .standard) }
        set { UserDefaults.standard.set(newValue, forKey: autoCloseKey) }
    }
    static func autoClose(in defaults: UserDefaults) -> Bool { defaults.object(forKey: autoCloseKey) as? Bool ?? true }

    /// The battery shows a drawn icon instead of its percentage (R-25); off by default.
    static func showsBatteryIcon(in defaults: UserDefaults) -> Bool { defaults.bool(forKey: batteryIconKey) }

    init(jiggler: JigglerModule, microphone: MicrophoneModule, dialogs: DialogsModule,
         music: MusicModule, cpu: CPUTemperatureModule, weather: WeatherModule, speedTest: SpeedTestModule,
         presenter: any BarPresenter = SystemBarPresenter()) {
        self.jiggler = jiggler
        self.microphone = microphone
        self.dialogs = dialogs
        self.music = music
        self.cpu = cpu
        self.weather = weather
        self.speedTest = speedTest
        self.presenter = presenter
        super.init()
    }

    /// True while anything the module started still exists (TB-60): observers, sources, timers,
    /// watchers, callbacks set on other modules, the bar itself.
    var holdsObservers: Bool {
        !observers.isEmpty || lockObserver != nil || batterySource != nil
            || [clockTimer, dateTimer, cpuTimer, speedTimer, batteryRepeatTimer].contains { $0?.isValid == true }
            || micWatcher.isWatching || brightnessWatcher.isWatching || keyboardWatcher.isWatching
            || volumeWatcher.isWatching || playbackWatcher.isWatching
            || dialogs.onChange != nil || weather.onChange != nil || speedTest.onChange != nil
            || bar != nil || barView != nil
    }

    // MARK: Module

    func start() {
        guard !running, presenter.hasTouchBar else { return }
        guard presenter.isAvailable else {
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
        presenter.addTrayItem(tray)

        GameSound.prepare()
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
        // Settings: color mode, monochrome color, music player, button layout. Other writes change nothing here.
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
        // B-7: a step-aside is not kept for the next start; Native Dialogs tells again then.
        stepAside = false
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
        if let bar { presenter.minimize(bar) }
        presenter.removeTrayItem(Self.trayItemID)
        bar = nil
        barView = nil
    }

    @objc private func present() {
        guard running, !stepAside, let bar else { return }
        presenter.present(bar, trayIdentifier: Self.trayItemID)
    }

    private func minimize() {
        guard let bar else { return }
        barView?.closeSlider()
        barView?.closeGame()
        presenter.minimize(bar)
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        guard identifier == Self.barItemID, let barView else { return nil }
        let item = NSCustomTouchBarItem(identifier: identifier)
        item.view = barView
        return item
    }

    // MARK: Buttons

    private typealias Item = BarItem

    private func isOn(_ module: ModuleID) -> Bool { manager?.isEnabled(module) ?? false }

    /// The buttons the user chose, in their order (R-26); buttons of modules that are off are
    /// left out. Equal widths, so the others widen when one is hidden.
    private func rebuildButtons() {
        guard let barView else { return }
        let items = BarLayout.visible(isOn: isOn)
        shownItems = items
        let buttons = items.map { item in
            let button = BarButton(itemID: item.rawValue, color: NSColor(hex: item.hex))
            button.onPress = press(for: item)
            return button
        }
        barView.setButtons(buttons)
        if let time = barView.button(Item.time.rawValue) {
            let press = NSPressGestureRecognizer(target: self, action: #selector(timeLongPressed(_:)))
            press.allowedTouchTypes = .direct
            press.minimumPressDuration = 0.8
            time.addGestureRecognizer(press)
            time.showsHold(0.8)
        }
        if let jiggler = barView.button(Item.jiggler.rawValue) {
            let press = NSPressGestureRecognizer(target: self, action: #selector(jigglerLongPressed(_:)))
            press.allowedTouchTypes = .direct
            press.minimumPressDuration = 3
            jiggler.addGestureRecognizer(press)
            jiggler.showsHold(3)
        }
        // A hold on the old battery or jiggler button may never report its end.
        endBatteryHold()
        jigglerLongPressing = false
        if let battery = barView.button(Item.battery.rawValue) {
            let press = NSPressGestureRecognizer(target: self, action: #selector(batteryLongPressed(_:)))
            press.allowedTouchTypes = .direct
            press.minimumPressDuration = 1
            battery.addGestureRecognizer(press)
            battery.showsHold(1)
        }

        screenshotLongPressing = false
        if let screenshot = barView.button(Item.screenshot.rawValue) {
            screenshot.show(symbol: "camera.viewfinder", label: String(localized: "Screenshot"))
        }
        screenshotHold = nil
        updateScreenshotHold()
        barView.button(Item.lock.rawValue)?.show(symbol: "lock.fill", label: String(localized: "Lock Screen"))
        updateSources()
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
        syncSpeedTest()
    }

    private func press(for item: Item) -> (BarButton) -> Void {
        switch item {
        case .battery: { [weak self] _ in self?.toggleBatteryIcon() }
        case .brightness: { [weak self] in self?.openSlider($0, DisplayBrightness(), String(localized: "Brightness")) }
        case .keyboardLight: { [weak self] in self?.openSlider($0, KeyboardBrightness(), String(localized: "Keyboard backlight")) }
        case .jiggler: { [weak self] _ in self?.jigglerTapped() }
        case .microphone: { [weak self] _ in self?.run(.microphone) }
        case .screenshot: { [weak self] _ in self?.screenshotTapped() }
        case .lock: { [weak self] _ in self?.run(.lockScreen) }
        case .music: { [weak self] _ in self?.music.tap() }
        case .weather: { [weak self] _ in self?.weather.refresh(ifOlderThan: 60) }
        case .cpu: { [weak self] _ in self?.updateTemperature() }
        case .volume: { [weak self] in self?.openSlider($0, OutputVolume(), String(localized: "Volume")) }
        case .speedTest: { [weak self] _ in self?.speedTest.run(repeatAlert: false) }
        case .time: { [weak self] _ in self?.toggleDate() }
        }
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
        if BarLayout.visible(isOn: isOn) != shownItems { rebuildButtons() }
        updateScreenshotHold()
        let player = MusicPlayer.current.id
        if player != playerID {
            playerID = player
            playbackWatcher.reset()
        }
    }

    // MARK: Sources

    /// The buttons with their own watcher (battery source, CoreAudio, DisplayServices,
    /// CoreBrightness, music notifications) or timer (the speed test's needle and results).
    /// Each runs only while its button is on the bar (B-6); the clock and the CPU temperature
    /// already stop by themselves when their button isn't there.
    static let watchedButtons: Set<BarItem> = [.battery, .microphone, .brightness, .keyboardLight, .volume, .music, .speedTest]
    static func watched(shown: [BarItem]) -> Set<BarItem> { watchedButtons.intersection(shown) }

    private func startSources() {
        trackJiggler()
    }

    /// Starts the watchers of the buttons on the bar and stops the others (rebuilt buttons).
    private func updateSources() {
        let watched = Self.watched(shown: shownItems)
        setBatterySource(watched.contains(.battery))
        watched.contains(.microphone) ? micWatcher.start() : micWatcher.stop()
        watched.contains(.brightness) ? brightnessWatcher.start() : brightnessWatcher.stop()
        watched.contains(.keyboardLight) ? keyboardWatcher.start() : keyboardWatcher.stop()
        watched.contains(.volume) ? volumeWatcher.start() : volumeWatcher.stop()
        watched.contains(.music) ? playbackWatcher.start() : playbackWatcher.stop()
    }

    /// Battery: the system notifies when any power source changes.
    private func setBatterySource(_ on: Bool) {
        if on, batterySource == nil {
            let context = Unmanaged.passUnretained(self).toOpaque()
            if let source = IOPSNotificationCreateRunLoopSource({ context in
                guard let context else { return }
                let module = Unmanaged<TouchBarModule>.fromOpaque(context).takeUnretainedValue()
                MainActor.assumeIsolated { module.updateBattery() }
            }, context)?.takeRetainedValue() {
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
                batterySource = source
            }
        } else if !on, let batterySource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), batterySource, .defaultMode)
            self.batterySource = nil
        }
    }

    private func stopSources() {
        setBatterySource(false)
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

    private var speedPhase = BarLooks.SpeedPhase.idle
    private var needleStep = 0

    /// Design chosen by the user (variant 4, 2026-11-14): while testing the needle sweeps
    /// (one symbol change every 0.6 s); then download for 3 s, upload for 3 s, back to idle.
    private func speedTestChanged() {
        speedTimer?.invalidate()
        speedTimer = nil
        // B-6: no timer for a button that isn't on the bar.
        guard Self.watched(shown: shownItems).contains(.speedTest) else {
            speedPhase = .idle
            return
        }
        let steps = BarLooks.speedSteps(isRunning: speedTest.isRunning, failed: speedTest.failed,
                                        hasResult: speedTest.result != nil)
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
                self.updateSpeedTest()
            }
        }
    }

    /// Shows `phase` now and the next ones at their times (counted from now).
    private func setSpeedPhase(_ phase: BarLooks.SpeedPhase, then steps: [BarLooks.SpeedStep] = []) {
        speedPhase = phase
        updateSpeedTest()
        guard let next = steps.first else { return }
        let rest = steps.dropFirst().map { BarLooks.SpeedStep(at: $0.at - next.at, phase: $0.phase) }
        speedTimer = Timer.scheduledTimer(withTimeInterval: next.at, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.speedTimer = nil
                self?.setSpeedPhase(next.phase, then: rest)
            }
        }
    }

    /// After a rebuild: a speed test button that left the bar stops its timers; one that came
    /// back during a test starts the needle, otherwise it shows the idle look (B-6).
    private func syncSpeedTest() {
        switch Self.speedAfterRebuild(shown: Self.watched(shown: shownItems).contains(.speedTest),
                                      sequenceRunning: speedTimer?.isValid == true, testRunning: speedTest.isRunning) {
        case .idle:
            speedTimer?.invalidate()
            speedTimer = nil
            speedPhase = .idle
        case .startNeedle:
            speedTestChanged()
            return
        case .keep:
            break
        }
        updateSpeedTest()
    }

    enum SpeedRebuild: Equatable { case idle, startNeedle, keep }

    /// Every phase but idle has its timer, and `stop` ends it, so with no sequence running the
    /// button can only show the needle (a test runs) or idle: never a phase left from before the
    /// module was turned off, or a result that came while it was off (B-6, B-7).
    static func speedAfterRebuild(shown: Bool, sequenceRunning: Bool, testRunning: Bool) -> SpeedRebuild {
        guard shown else { return .idle }
        if sequenceRunning { return .keep }
        return testRunning ? .startNeedle : .idle
    }

    private func updateSpeedTest() {
        guard let button = barView?.button(Item.speedTest.rawValue) else { return }
        button.show(BarLooks.speedTest(phase: speedPhase, needleStep: needleStep, result: speedTest.result))
    }

    // MARK: Weather and CPU

    private func updateWeather() {
        guard let button = barView?.button(Item.weather.rawValue) else { return }
        button.show(BarLooks.weather(report: weather.report, noLocation: weather.status == .noLocation))
    }

    /// Reads the CPU temperature now and again in ~10 s, only while its button is on screen.
    private func updateTemperature() {
        cpuTimer?.invalidate()
        cpuTimer = nil
        guard running, !screensAsleep, let button = barView?.button(Item.cpu.rawValue) else { return }
        button.show(BarLooks.cpu(celsius: cpu.read()))
        let timer = Timer(timeInterval: 10, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateTemperature() }
        }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        cpuTimer = timer
    }

    /// Tap on the battery: percentage ↔ icon, remembered (R-25).
    private func toggleBatteryIcon() {
        guard Self.tapAllowed(holding: batteryLongPressing, holdEnded: batteryLongPressEnded, now: Date()) else { return }
        UserDefaults.standard.set(!Self.showsBatteryIcon(in: .standard), forKey: Self.batteryIconKey)
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
        let look = BarLooks.battery(percent: percent, charging: charging, showIcon: Self.showsBatteryIcon(in: .standard))

        // Level colors only in multicolor mode (applyColors), on the icon.
        let stateColor = look.level?.color
        if stateColor != button.stateColor {
            button.stateColor = stateColor
            barView.applyColors()
        }
        if look.icon, let percent {
            button.show(drawing: { BatteryIcon.image(fraction: CGFloat(percent) / 100, charging: charging, color: $0) },
                        key: "\(percent)\(charging)", label: look.label)
        } else {
            button.show(symbol: nil, text: look.text, label: look.label)
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

    /// The pending levels, or all three when none is pending (after wake, TB-33).
    static func levelsToRead(pending: Set<BarItem>) -> Set<BarItem> {
        pending.isEmpty ? [.brightness, .keyboardLight, .volume] : pending
    }

    /// Reads the pending levels, or all of them when none is pending (after wake).
    private func refreshLevels() {
        let items = Self.levelsToRead(pending: pendingLevels)
        pendingLevels = []
        if items.contains(.brightness) { updateBrightness() }
        if items.contains(.keyboardLight) { updateKeyboardLight() }
        if items.contains(.volume) { updateVolume() }
    }

    private func updateBrightness() {
        guard let button = barView?.button(Item.brightness.rawValue) else { return } // B-6: no read for a hidden button
        button.show(BarLooks.brightness(DisplayBrightness().level))
    }

    private func updateKeyboardLight() {
        guard let button = barView?.button(Item.keyboardLight.rawValue) else { return }
        button.show(BarLooks.keyboardLight(KeyboardBrightness().level))
    }

    private func updateVolume() {
        guard let button = barView?.button(Item.volume.rawValue) else { return }
        let output = OutputVolume()
        button.show(BarLooks.volume(level: output.level, muted: output.isMuted))
    }

    private func updateMusic() {
        barView?.button(Item.music.rawValue)?.show(BarLooks.music(playing: playbackWatcher.isPlaying))
    }

    /// Armed jiggler trackings not fired yet. A tracking can't be cancelled, so one left armed by
    /// `stop` is reused by the next start: never more than one (B-7).
    private(set) var jigglerTrackings = 0

    /// The jiggler is @Observable: re-arm the tracking after every change.
    private func trackJiggler() {
        guard running, jigglerTrackings == 0 else { return }
        jigglerTrackings += 1
        withObservationTracking {
            _ = jiggler.isActive
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.jigglerTrackings -= 1
                    guard self.running else { return }
                    self.updateJiggler()
                    self.trackJiggler()
                }
            }
        }
    }

    private func updateJiggler() {
        // State is shown by the symbol, not only by color (R-19).
        barView?.button(Item.jiggler.rawValue)?.show(BarLooks.jiggler(on: jiggler.isActive))
    }

    /// Follows the real microphone (R-28), open while a called Siri hears the user (B-2).
    private func updateMicrophone() {
        guard let button = barView?.button(Item.microphone.rawValue) else { return }
        button.show(BarLooks.microphone(muted: microphone.showsMuted, available: microphone.hasInput))
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

    /// TB-28: 12-hour "h:mm" with no AM/PM, whatever the Mac's region.
    static func timeText(_ date: Date) -> String { timeFormat.string(from: date) }
    /// TB-28: the date as DD/MM/YY.
    static func dateText(_ date: Date) -> String { dateFormat.string(from: date) }
    /// TB-28 / TB-31: the date hides after 4 s with auto-close on, else at the next tap.
    static func dateHideDelay(autoClose: Bool) -> TimeInterval? { autoClose ? 4 : nil }
    /// When the clock next redraws: the start of the next minute (one wake-up per minute).
    static func nextMinute(after now: Date) -> Date {
        Calendar.current.nextDate(after: now, matching: DateComponents(second: 0), matchingPolicy: .nextTime) ?? now.addingTimeInterval(60)
    }

    /// Shows the time and sleeps until the next minute starts (one wakeup per minute).
    private func updateClock() {
        clockTimer?.invalidate()
        guard running, let button = barView?.button(Item.time.rawValue) else { return }
        let now = Date()
        if showingDate {
            button.show(symbol: nil, text: Self.dateText(now), label: now.formatted(date: .complete, time: .omitted))
        } else {
            button.show(symbol: nil, text: Self.timeText(now), label: now.formatted(date: .omitted, time: .shortened))
        }
        let timer = Timer(fire: Self.nextMinute(after: now), interval: 0, repeats: false) { [weak self] _ in
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
            barView?.button(Item.time.rawValue)?.holdFired()
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
        guard Self.tapAllowed(holding: jigglerLongPressing, holdEnded: jigglerLongPressEnded, now: Date()) else { return }
        run(.jiggler)
    }

    @objc private func jigglerLongPressed(_ recognizer: NSPressGestureRecognizer) {
        switch recognizer.state {
        case .began:
            jigglerLongPressing = true
            barView?.button(Item.jiggler.rawValue)?.holdFired()
            barView?.playGame()
        case .ended, .cancelled, .failed:
            jigglerLongPressing = false
            jigglerLongPressEnded = Date()
        default: break
        }
    }

    /// The hold-to-record gesture on the Screenshot button and the hold time it uses (O-33).
    private var screenshotHold: NSPressGestureRecognizer?

    /// O-33: hold = record (the area picker in record mode); a tap is the screenshot. Follows
    /// Settings at once: the switch and the hold time.
    private func updateScreenshotHold() {
        guard let screenshot = barView?.button(Item.screenshot.rawValue) else { return }
        let seconds = ScreenshotModule.holdSeconds(in: .standard)
        guard seconds != screenshotHold?.minimumPressDuration else { return }
        if let screenshotHold { screenshot.removeGestureRecognizer(screenshotHold) }
        screenshotHold = nil
        screenshotLongPressing = false
        screenshot.setAccessibilityHelp(nil)
        screenshot.showsHold(seconds)
        guard let seconds else { return }
        let press = NSPressGestureRecognizer(target: self, action: #selector(screenshotLongPressed(_:)))
        press.allowedTouchTypes = .direct
        press.minimumPressDuration = seconds
        screenshot.addGestureRecognizer(press)
        screenshot.setAccessibilityHelp(String(localized: "Hold to record the screen"))
        screenshotHold = press
    }

    private var screenshotLongPressEnded = Date.distantPast
    private var screenshotLongPressing = false

    private func screenshotTapped() {
        guard Self.tapAllowed(holding: screenshotLongPressing, holdEnded: screenshotLongPressEnded, now: Date()) else { return }
        run(.screenshot)
    }

    @objc private func screenshotLongPressed(_ recognizer: NSPressGestureRecognizer) {
        let button = barView?.button(Item.screenshot.rawValue)
        switch recognizer.state {
        case .began:
            screenshotLongPressing = true
            button?.holdFired()
            button?.show(symbol: "record.circle", label: String(localized: "Record Screen"))
            if let manager, let action = manager.module(.screenshot)?.actions.first { action.onHold?() }
        case .ended, .cancelled, .failed:
            screenshotLongPressing = false
            screenshotLongPressEnded = Date()
            button?.show(symbol: "camera.viewfinder", label: String(localized: "Screenshot"))
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
            barView?.button(Item.battery.rawValue)?.holdFired()
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

    /// A hold on the battery, the jiggler or the time ends with a release that must not also count
    /// as a tap: taps are ignored while held and for 0.5 s after (TB-12, TB-28, TB-47).
    static func tapAllowed(holding: Bool, holdEnded: Date, now: Date) -> Bool {
        !holding && now.timeIntervalSince(holdEnded) >= 0.5
    }

    /// Tap shows the date (DD/MM/YY) for 4 s; tapping again hides it.
    private func toggleDate() {
        guard Self.tapAllowed(holding: longPressing, holdEnded: longPressEnded, now: Date()) else { return }
        dateTimer?.invalidate()
        dateTimer = nil
        showingDate.toggle()
        if showingDate, let delay = Self.dateHideDelay(autoClose: Self.autoClose) {
            dateTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
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

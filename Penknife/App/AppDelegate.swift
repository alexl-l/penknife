import AppKit
import KeyboardShortcuts
import ServiceManagement

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    /// Unit tests run inside the app (the test host): it then starts nothing, so no menu bar item,
    /// shortcuts, login item, updater or file cleanup competes with the installed Penknife.
    static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    private(set) var manager: ModuleManager!
    private var statusMenu: StatusMenu!
    private var readings: MenuBarReadings!
    private let updater = Updater()
    /// Built on open and released on close, so Settings costs no memory while closed (R-11).
    private var settings: SettingsWindowController?
    private var settingsCloseObserver: NSObjectProtocol?

    private func releaseSettings() {
        if let settingsCloseObserver {
            NotificationCenter.default.removeObserver(settingsCloseObserver)
        }
        settingsCloseObserver = nil
        settings = nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isRunningTests else { return }
        let jiggler = JigglerModule()
        let microphone = MicrophoneModule()
        let dialogs = DialogsModule()
        let music = MusicModule()
        let cpu = CPUTemperatureModule()
        let weather = WeatherModule()
        let speedTest = SpeedTestModule()
        let screenshot = ScreenshotModule()
        let clipboard = ClipboardModule()
        let macros = MacrosModule()
        macros.clipboard = clipboard
        jiggler.holdsOff = { [weak screenshot, weak clipboard] in
            screenshot?.session != nil || screenshot?.recording != nil || clipboard?.isPanelOpen == true
                || MacroRunner.shared.isBusy
        }
        let touchBar = TouchBarModule(jiggler: jiggler, microphone: microphone, dialogs: dialogs,
                                      music: music, cpu: cpu, weather: weather, speedTest: speedTest)
        manager = ModuleManager(modules: [
            jiggler,
            microphone,
            LockScreenModule(jiggler: jiggler),
            screenshot,
            clipboard,
            macros,
            music,
            BlockAppleMusicModule(music: music),
            cpu,
            weather,
            speedTest,
            touchBar,
            dialogs,
        ])
        touchBar.manager = manager
        manager.startEnabledModules()

        NSApp.mainMenu = MainMenu.make()
        updater.start()
        statusMenu = StatusMenu(manager: manager, updater: updater) { [weak self] in self?.showSettings() }
        readings = MenuBarReadings(manager: manager)
        KeyboardShortcuts.onKeyUp(for: .openMenu) { [weak self] in self?.statusMenu.open() }

        LaunchAtLogin.apply()
        DispatchQueue.global(qos: .utility).async { RecordingSession.removeLeftovers() }
    }

    /// An unsaved recording is never deleted by quitting without asking (B-14): each end window
    /// that holds one asks first, as closing it does.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        var now: Bool?, later = false
        RecordingEndWindow.confirmQuit { quit in
            if later { NSApp.reply(toApplicationShouldTerminate: quit) } else { now = quit }
        }
        if let now { return now ? .terminateNow : .terminateCancel }
        later = true   // a question is open: its answer replies
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !Self.isRunningTests else { return }
        RecordingSession.removeLeftovers()
    }

    /// Opening the app again (Finder, Spotlight) shows Settings, since there is no Dock icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    @objc func showSettings() {
        if settings == nil {
            let controller = SettingsWindowController(manager: manager)
            settingsCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: controller.window, queue: .main
            ) { [weak self] _ in
                // Let the close finish before dropping the views.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.releaseSettings() }
                }
            }
            settings = controller
        }
        settings?.show()
    }
}

/// Launch at login (R-16): on by default, can be turned off in Settings → General.
/// Only the copy in /Applications registers itself, so development builds never become the
/// login item; if the app moved since it registered, the registration is renewed. Removing it
/// in System Settings › Login Items turns the choice off (B-25): the system has the last word.
enum LaunchAtLogin {
    private static let wantedKey = "launchAtLogin.enabled"
    private static let pathKey = "launchAtLogin.registeredPath"

    private static var isInstalled: Bool {
        Bundle.main.bundlePath.hasPrefix("/Applications/")
    }

    /// What the user chose (default on), after `apply()` has taken in a removal in System Settings.
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: wantedKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: wantedKey)
            apply()
        }
    }

    enum Step: Equatable { case none, register, reregister, unregister, forget }

    /// GN-23: what brings the login item in line with the choice. Only the /Applications copy
    /// acts; a registration from another path is renewed. Registered from this path but no
    /// longer in the system = the user removed it in System Settings: forget, never re-add (B-25).
    static func step(installed: Bool, wanted: Bool, enabled: Bool, registeredHere: Bool) -> Step {
        guard installed else { return .none }
        if wanted {
            if !enabled { return registeredHere ? .forget : .register }
            return registeredHere ? .none : .reregister
        }
        return enabled ? .unregister : .none
    }

    /// Brings the system login item in line with the user's choice. Called at launch.
    static func apply() {
        guard isInstalled else { return }
        let service = SMAppService.mainApp
        let path = Bundle.main.bundlePath
        let registeredHere = UserDefaults.standard.string(forKey: pathKey) == path
        // Waiting for the user's approval still counts as there: not a removal.
        let enabled = service.status == .enabled || service.status == .requiresApproval
        do {
            switch step(installed: true, wanted: isEnabled, enabled: enabled, registeredHere: registeredHere) {
            case .none:
                return
            case .forget:
                UserDefaults.standard.set(false, forKey: wantedKey)
                UserDefaults.standard.removeObject(forKey: pathKey)
            case .register, .reregister:
                if service.status == .enabled { try? service.unregister() }
                try service.register()
                UserDefaults.standard.set(path, forKey: pathKey)
            case .unregister:
                try service.unregister()
                UserDefaults.standard.removeObject(forKey: pathKey)
            }
        } catch {
            NSLog("Penknife: launch at login: \(error.localizedDescription)")
        }
    }
}

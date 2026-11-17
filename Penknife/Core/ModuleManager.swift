import AppKit
import KeyboardShortcuts
import Observation

/// Owns the modules, persists which ones are on and wires their shortcuts.
@Observable
final class ModuleManager {
    /// Posted after a module is turned on or off.
    static let didChangeNotification = Notification.Name("PenknifeModulesDidChange")

    let modules: [any Module]
    private(set) var enabled: Set<ModuleID> = []

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let fnKeys = FnHotKeys()
    @ObservationIgnored private var paused = false
    @ObservationIgnored private var defaultsObserver: NSObjectProtocol?
    /// Last hotkey run per shortcut: which twin (plain or Fn) and when.
    @ObservationIgnored private var lastHotKey: [String: (fn: Bool, at: Date)] = [:]

    init(modules: [any Module]) {
        self.modules = modules
        for module in modules {
            for action in module.actions {
                KeyboardShortcuts.onKeyUp(for: action.shortcut) { [weak self, weak module] in
                    guard let self, let module, self.isEnabled(module.id) else { return }
                    self.runHotKey(action, fn: false)
                }
            }
        }
        // A shortcut recorded in Settings is saved to UserDefaults: refresh the Fn twins.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshFnKeys() }
        }
    }

    func module(_ id: ModuleID) -> (any Module)? {
        modules.first { $0.id == id }
    }

    func isEnabled(_ id: ModuleID) -> Bool {
        enabled.contains(id)
    }

    /// Starts the modules that are on. Called once at launch.
    func startEnabledModules() {
        for module in modules {
            let on = defaults.object(forKey: key(module.id)) as? Bool ?? module.id.defaultOn
            if on {
                enabled.insert(module.id)
                module.start()
            } else {
                setShortcuts(of: module, active: false)
            }
        }
        refreshFnKeys()
    }

    func setEnabled(_ id: ModuleID, _ on: Bool) {
        guard let module = module(id), on != isEnabled(id) else { return }
        defaults.set(on, forKey: key(id))
        if on {
            enabled.insert(id)
            setShortcuts(of: module, active: true)
            module.start()
        } else {
            enabled.remove(id)
            setShortcuts(of: module, active: false)
            module.stop()
        }
        refreshFnKeys()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    /// Enabled actions, in module order, for the menu.
    var enabledActions: [ModuleAction] {
        modules.filter { isEnabled($0.id) }.flatMap(\.actions)
    }

    /// Unregisters (or registers back) the hotkeys so a module that is off doesn't grab keys.
    private func setShortcuts(of module: any Module, active: Bool) {
        for action in module.actions {
            active ? KeyboardShortcuts.enable(action.shortcut) : KeyboardShortcuts.disable(action.shortcut)
        }
    }

    /// Pauses every global hotkey while a menu is tracking, as KeyboardShortcuts requires.
    func pauseShortcuts(_ paused: Bool) {
        var names: [KeyboardShortcuts.Name] = [.openMenu]
        for module in modules where isEnabled(module.id) {
            names += module.actions.map(\.shortcut)
        }
        for name in names {
            paused ? KeyboardShortcuts.disable(name) : KeyboardShortcuts.enable(name)
        }
        self.paused = paused
        refreshFnKeys()
    }

    /// Runs an action from the Touch Bar or the menu: every press counts.
    func run(_ action: ModuleAction) {
        action.perform()
    }

    /// Runs an action from a shortcut (on key release, so holding a key runs it once). A bare F
    /// key is registered twice, plain and with Fn (see FnHotKeys), and one press can arrive
    /// through both: the second twin of the same press is dropped. Presses through the same
    /// twin always run, however fast they come.
    private func runHotKey(_ action: ModuleAction, fn: Bool) {
        let now = Date()
        let name = action.shortcut.rawValue
        if let last = lastHotKey[name], last.fn != fn, now.timeIntervalSince(last.at) < 0.1 { return }
        lastHotKey[name] = (fn, now)
        action.perform()
    }

    /// F-key shortcuts also fire with Fn (Touch Bar F keys), see FnHotKeys.
    private func refreshFnKeys() {
        guard !paused else {
            fnKeys.removeAll()
            return
        }
        fnKeys.set(enabledActions.map { action in (action.shortcut, { [weak self] in self?.runHotKey(action, fn: true) }) })
    }

    private func key(_ id: ModuleID) -> String { "module.\(id.rawValue).enabled" }
}

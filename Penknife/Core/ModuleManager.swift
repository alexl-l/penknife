import AppKit
import os
import KeyboardShortcuts
import Observation

/// Owns the modules, persists which ones are on and wires their shortcuts.
@Observable
final class ModuleManager {
    /// Posted after a module is turned on or off.
    static let didChangeNotification = Notification.Name("PenknifeModulesDidChange")

    let modules: [any Module]
    private(set) var enabled: Set<ModuleID> = []

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let fnKeys = FnHotKeys()
    @ObservationIgnored private var paused = false
    @ObservationIgnored private var defaultsObserver: NSObjectProtocol?
    /// Last hotkey run per shortcut: which twin (plain or Fn) and when.
    @ObservationIgnored private var holdTimers: [String: Timer] = [:]
    @ObservationIgnored private var held: Set<String> = []
    @ObservationIgnored private var lastHotKey: [String: (fn: Bool, at: Date)] = [:]

    /// The app passes `.standard`; tests pass a suite in memory (GN-06).
    init(modules: [any Module], defaults: UserDefaults = .standard) {
        self.modules = modules
        self.defaults = defaults
        for module in modules {
            for action in module.actions {
                KeyboardShortcuts.onKeyUp(for: action.shortcut) { [weak self, weak module] in
                    guard let self, let module, self.isEnabled(module.id) else { return }
                    self.runHotKey(action, fn: false)
                }
                if action.onHold != nil {
                    KeyboardShortcuts.onKeyDown(for: action.shortcut) { [weak self, weak module] in
                        guard let self, let module, self.isEnabled(module.id) else { return }
                        self.pressHotKey(action)
                    }
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
            if Self.isOn(module.id, in: defaults) {
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
        defaults.set(on, forKey: Self.key(id))
        if on {
            enabled.insert(id)
            setShortcuts(of: module, active: true)
            module.start()
        } else {
            enabled.remove(id)
            endHolds(of: module.actions)
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
        // MIC-92: a paused shortcut never reports its release, so a hold ends now.
        if paused { endHolds(of: enabledActions) }
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
        holdTimers.removeValue(forKey: name)?.invalidate()
        if held.remove(name) != nil {
            // O-33: the hold already ran; this release (and its Fn twin) only ends it (R-41).
            lastHotKey[name] = (fn, now)
            action.onHoldEnd?()
            return
        }
        guard Self.shouldRun(last: lastHotKey[name], fn: fn, now: now) else { return }
        lastHotKey[name] = (fn, now)
        action.perform()
    }

    /// O-33: a press starts the hold timer (one per press, both twins share it); reaching it
    /// runs the hold action and the release is then ignored. A short press runs on release.
    private func pressHotKey(_ action: ModuleAction) {
        let name = action.shortcut.rawValue
        guard holdTimers[name] == nil, action.onHold != nil, let delay = action.holdDelay?() else { return }
        held.remove(name)
        holdTimers[name] = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.holdReached(action) }
        }
    }

    /// Ends the holds of these actions as if released (R-41: never leave the mic open).
    private func endHolds(of actions: [ModuleAction]) {
        for action in actions {
            let name = action.shortcut.rawValue
            holdTimers.removeValue(forKey: name)?.invalidate()
            if held.remove(name) != nil {
                Logger(subsystem: "Penknife", category: "Shortcuts").notice("Hold ended without its release: \(name, privacy: .public)")
                action.onHoldEnd?()
            }
        }
    }

    private func holdReached(_ action: ModuleAction) {
        let name = action.shortcut.rawValue
        holdTimers[name] = nil
        held.insert(name)
        action.onHold?()
    }

    /// False only for the other twin of the same press: it arrives < 0.1 s after the last run.
    static func shouldRun(last: (fn: Bool, at: Date)?, fn: Bool, now: Date) -> Bool {
        guard let last else { return true }
        return last.fn == fn || now.timeIntervalSince(last.at) >= 0.1
    }

    /// F-key shortcuts also fire with Fn (Touch Bar F keys), see FnHotKeys.
    private func refreshFnKeys() {
        guard !paused else {
            fnKeys.removeAll()
            return
        }
        fnKeys.set(enabledActions.map { action in
            (action.shortcut, { [weak self] in self?.runHotKey(action, fn: true) },
             action.onHold == nil ? nil : { [weak self] in self?.pressHotKey(action) })
        })
    }

    /// Whether a module is on at launch: the user's choice, else its default.
    static func isOn(_ id: ModuleID, in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key(id)) as? Bool ?? id.defaultOn
    }

    private static func key(_ id: ModuleID) -> String { "module.\(id.rawValue).enabled" }
}

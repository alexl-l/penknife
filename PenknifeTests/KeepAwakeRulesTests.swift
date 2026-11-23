import Foundation
import KeyboardShortcuts
import Testing
@testable import Penknife

/// Keep Awake rules (docs/requirements/keepawake.md). Spanish (KA-08) is checked by MIC-71 over the whole catalog. Nothing here takes a real power assertion,
/// listens for the real screen lock or shows an alert.
@MainActor
@Suite("Keep Awake rules")
struct KeepAwakeRulesTests {

    /// A fake Mac: counts assertions and lock observers, records alerts.
    @MainActor final class FakeMac {
        var refuses = false
        private(set) var holds = 0
        private(set) var releases = 0
        private(set) var observers = 0
        private(set) var alerts: [(title: String, kind: AlertKind)] = []
        private(set) var locked: (@MainActor () -> Void)?

        var env: KeepAwakeEnvironment {
            KeepAwakeEnvironment(
                holdAwake: { [self] in
                    guard !refuses else { return nil }
                    holds += 1
                    return { [self] in releases += 1 }
                },
                hud: { [self] title, _, kind in alerts.append((title, kind)) },
                observeLock: { [self] handler in
                    observers += 1
                    locked = handler
                    return { [self] in observers -= 1; locked = nil }
                })
        }
    }

    @Test("KA-01 the module, its action and no default shortcut")
    func module() {
        let module = KeepAwakeModule(env: FakeMac().env)
        #expect(module.id == .keepAwake)
        #expect(!module.needsAccessibility)
        #expect(module.actions.count == 1)
        #expect(module.actions[0].shortcut == .toggleKeepAwake)
        #expect(KeyboardShortcuts.Name.toggleKeepAwake.defaultShortcut == nil)
        #expect(module.actions[0].state?() == false)
    }

    @Test("KA-02 KA-03 toggle: on holds one assertion and alerts; off releases it and alerts")
    func toggle() {
        let mac = FakeMac()
        let module = KeepAwakeModule(env: mac.env)
        module.start()
        #expect(!module.isActive && mac.holds == 0, "off at launch (KA-04)")
        module.toggle()
        #expect(module.isActive && module.isHolding && mac.holds == 1)
        #expect(mac.alerts.last?.title == String(localized: "Keep Awake on") && mac.alerts.last?.kind == .on)
        module.toggle()
        #expect(!module.isActive && !module.isHolding && mac.releases == 1)
        #expect(mac.alerts.last?.title == String(localized: "Keep Awake off") && mac.alerts.last?.kind == .off)
    }

    @Test("KA-03 macOS refuses: stays off, one error alert")
    func refused() {
        let mac = FakeMac()
        mac.refuses = true
        let module = KeepAwakeModule(env: mac.env)
        module.toggle()
        #expect(!module.isActive && !module.isObservingLock)
        #expect(mac.alerts.count == 1 && mac.alerts[0].kind == .error)
    }

    @Test("KA-05 locking turns it off silently; the lock is observed only while on")
    func lock() {
        let mac = FakeMac()
        let module = KeepAwakeModule(env: mac.env)
        module.start()
        #expect(mac.observers == 0)
        module.toggle()
        #expect(mac.observers == 1)
        let alerts = mac.alerts.count
        mac.locked?()
        #expect(!module.isActive && mac.releases == 1 && mac.observers == 0)
        #expect(mac.alerts.count == alerts, "no alert when the lock turns it off")
    }

    @Test("KA-06 the module going off releases everything, silently")
    func moduleOff() {
        let mac = FakeMac()
        let module = KeepAwakeModule(env: mac.env)
        module.start()
        module.toggle()
        let alerts = mac.alerts.count
        module.stop()
        #expect(!module.isActive && !module.isHolding && !module.isObservingLock)
        #expect(mac.releases == 1 && mac.observers == 0 && mac.alerts.count == alerts)
        module.stop()
        #expect(mac.releases == 1, "stopping twice releases once")
    }
}

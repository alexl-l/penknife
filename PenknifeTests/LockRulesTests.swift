import CoreGraphics
import KeyboardShortcuts
import Testing
@testable import Penknife

/// Lock Screen rules (docs/requirements/lock.md). Each test names the rule it checks.
/// Nothing here locks the Mac, presses keys or asks for Accessibility: the lock call, the
/// permission and the keys are fakes. (JG-09, the jiggler before the lock, is in JigglerRulesTests.)
@MainActor
@Suite("Lock Screen rules")
struct LockRulesTests {

    @Test("LK-01 module on by default with its symbol, one action on F6, no Touch Bar needed")
    func module() throws {
        #expect(ModuleID.lockScreen.symbol == "lock" && ModuleID.lockScreen.defaultOn)
        #expect(!ModuleID.lockScreen.needsTouchBar)
        let jiggler = JigglerModule(env: JigglerRulesTests.FakeMac([JigglerModule.followsLockKey: false]).env)
        let module = LockScreenModule(jiggler: jiggler, lock: {})
        let action = try #require(module.actions.first)
        #expect(module.actions.count == 1 && action.shortcut == .lockScreen && action.symbol == "lock")
        #expect(!module.needsAccessibility)
        // The F6 default and the Touch Bar button's module are checked in TouchBarRulesTests (TB-58, TB-08).
    }

    @Test("LK-02 the system call this macOS still has; ⌃⌘Q is the fallback")
    func systemCall() {
        #expect(ScreenLocker.hasSystemLock)
        #expect(ScreenLocker.fallbackKey == 12 && ScreenLocker.fallbackFlags == [.maskControl, .maskCommand])
    }

    @Test("LK-02 order: system call first; keys only when it is missing or fails, and only with Accessibility",
          arguments: [
              // (system call result, nil = missing; Accessibility) → keys pressed, permission asked
              (Int32?(0), true, false, false),
              (Int32?(0), false, false, false),
              (Int32?(1), true, true, true),
              (Int32?(1), false, false, true),
              (Int32?.none, true, true, true),
              (Int32?.none, false, false, true),
          ])
    func order(system: Int32?, granted: Bool, pressed: Bool, asked: Bool) {
        var calls: [String] = []
        ScreenLocker.lock(system: system.map { value in { calls.append("system"); return value } },
                          accessibility: { calls.append("permission"); return granted },
                          pressKeys: { calls.append("keys") })
        #expect(calls.contains("keys") == pressed)
        #expect(calls.contains("permission") == asked)
        if system != nil { #expect(calls.first == "system") }
    }
}

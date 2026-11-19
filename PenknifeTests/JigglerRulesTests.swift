import AppKit
import Foundation
import Testing
@testable import Penknife

/// Mouse Jiggler rules (docs/requirements/jiggler.md). Each test names the rule it checks.
/// Nothing here moves the pointer, presses keys, asks for Accessibility, starts a real timer,
/// listens for the real screen lock, shows an alert or writes the user's settings.
@MainActor
@Suite("Mouse Jiggler rules")
struct JigglerRulesTests {

    // MARK: Helpers

    /// Settings that only live in memory: nothing is written to disk or to the user's settings.
    final class MemoryDefaults: UserDefaults {
        var values: [String: Any] = [:]

        convenience init(_ values: [String: Any] = [:]) {
            self.init(suiteName: "PenknifeTests.memory.\(UUID().uuidString)")!
            self.values = values
        }

        override func object(forKey key: String) -> Any? { values[key] }
        override func string(forKey key: String) -> String? { values[key] as? String }
        override func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
        override func double(forKey key: String) -> Double { values[key] as? Double ?? 0 }
        override func set(_ value: Any?, forKey key: String) { values[key] = value }
    }

    /// A fake Mac: a lock center that posts on demand, a scheduler with no real timer, a poster
    /// with no real events, and a record of every alert.
    @MainActor final class FakeMac {
        let defaults: MemoryDefaults
        var permission = true
        private(set) var alerts: [(title: String, detail: String?, kind: AlertKind)] = []
        private(set) var lockHandlers: (locked: @MainActor () -> Void, unlocked: @MainActor () -> Void)?
        private(set) var timers: [(seconds: TimeInterval, fire: @MainActor () -> Void)] = []
        var idle: TimeInterval = 0
        var pointer = CGPoint(x: 100, y: 100)
        private(set) var posted: [String] = []

        init(_ values: [String: Any] = [:]) { defaults = MemoryDefaults(values) }

        var env: JigglerEnvironment {
            JigglerEnvironment(
                defaults: defaults,
                ensurePermission: { [self] in permission },
                hud: { [self] title, detail, _, kind in alerts.append((title, detail, kind)) },
                observeLock: { [self] locked, unlocked in
                    lockHandlers = (locked, unlocked)
                    return { [self] in lockHandlers = nil }
                },
                schedule: { [self] seconds, fire in
                    timers.append((seconds, fire))
                    let index = timers.count - 1
                    return { [self] in cancelled.insert(index) }
                },
                idleSeconds: { [self] in idle },
                mouseLocation: { [self] in pointer },
                moveMouse: { [self] in pointer = $0; posted.append("move \(Int($0.x)),\(Int($0.y))") },
                key: { [self] in posted.append("key \($0)") })
        }

        private(set) var cancelled: Set<Int> = []
        /// Timers scheduled and not cancelled.
        var liveTimers: [TimeInterval] { timers.indices.filter { !cancelled.contains($0) }.map { timers[$0].seconds } }

        func lock() { lockHandlers?.locked() }
        func unlock() { lockHandlers?.unlocked() }
        func clearAlerts() { alerts = [] }
    }

    // MARK: B. Moving the mouse

    @Test("JG-05 jiggle only after the interval; otherwise wait the rest, at least 0.5 s")
    func timing() {
        #expect(JigglerTiming.next(idle: 12, interval: 10) == (true, 10))
        #expect(JigglerTiming.next(idle: 10, interval: 10) == (true, 10))
        #expect(JigglerTiming.next(idle: 3, interval: 10) == (false, 7))
        #expect(JigglerTiming.next(idle: 9.8, interval: 10) == (false, 0.5))
        #expect(JigglerTiming.next(idle: 0, interval: 30) == (false, 30))
    }

    @Test("JG-06 a 3 px square from where the pointer is, back to the start")
    func motion() {
        #expect(JigglerMotion.steps(from: CGPoint(x: 100, y: 100)) ==
                [CGPoint(x: 103, y: 100), CGPoint(x: 100, y: 103), CGPoint(x: 97, y: 100),
                 CGPoint(x: 100, y: 97), CGPoint(x: 100, y: 100)])
    }

    @Test("JG-17 O-23 no jiggle while Penknife holds off (recording, overlay, clipboard panel); the wait goes on")
    func holdsOff() async {
        let mac = FakeMac([JigglerModule.intervalKey: 10.0])
        let jiggler = JigglerModule(env: mac.env)
        jiggler.toggle()
        var busy = true
        jiggler.holdsOff = { busy }
        mac.idle = 30
        mac.timers.last!.fire()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(mac.posted.isEmpty && jiggler.isScheduled)
        busy = false
        mac.timers.last!.fire()
        try? await Task.sleep(for: .milliseconds(600))
        #expect(!mac.posted.isEmpty)
    }

    @Test("B-19 the square stops as soon as the user moves the mouse")
    func motionStopsWhenUserMoves() async {
        var pointer = CGPoint(x: 100, y: 100)
        var moves: [CGPoint] = []
        let untouched = await JigglerMotion.perform(from: pointer, location: { pointer },
                                                    move: { pointer = $0; moves.append($0) }, pause: {})
        #expect(untouched && moves == JigglerMotion.steps(from: CGPoint(x: 100, y: 100)))

        pointer = CGPoint(x: 100, y: 100)
        moves = []
        let grabbed = await JigglerMotion.perform(from: pointer, location: { pointer },
                                                  move: { moves.append($0); pointer = CGPoint(x: 300, y: 250) },
                                                  pause: {})
        #expect(!grabbed && moves == [CGPoint(x: 103, y: 100)])
        #expect(!JigglerMotion.userMoved(expected: CGPoint(x: 103, y: 100), actual: CGPoint(x: 103.6, y: 99.5)))

        // At the right edge every step right is clamped: still the whole square.
        pointer = CGPoint(x: 1919, y: 500)
        moves = []
        let edge = await JigglerMotion.perform(from: pointer, location: { pointer },
                                               move: { moves.append($0); pointer = CGPoint(x: min($0.x, 1919), y: $0.y) },
                                               pause: {})
        #expect(edge && moves.count == 5)
    }

    @Test("JG-07 keys that type nothing, Caps Lock by default and pressed twice")
    func keys() {
        #expect(JigglerKey.allCases == [.capsLock, .shift, .control, .option, .f18, .none])
        #expect(JigglerKey.allCases.map(\.keyCode) == [57, 56, 59, 58, 79, nil])
        #expect(JigglerKey.allCases.map(\.presses) == [2, 1, 1, 1, 1, 1])
        #expect(JigglerKey.current(in: MemoryDefaults()) == .capsLock)
        #expect(JigglerKey.current(in: MemoryDefaults([JigglerKey.key: "x"])) == .capsLock)
        #expect(JigglerKey.current(in: MemoryDefaults([JigglerKey.key: "f18"])) == .f18)
        #expect(JigglerKey.current(in: MemoryDefaults([JigglerKey.key: "none"])) == JigglerKey.none)
    }

    // MARK: C. Interval, lock and Lock Screen

    @Test("JG-10 intervals offered; anything else means 10 s")
    func intervals() {
        #expect(JigglerModule.intervals == [10, 30, 60, 120, 300])
        #expect(JigglerModule.interval(in: MemoryDefaults()) == 10)
        #expect(JigglerModule.interval(in: MemoryDefaults([JigglerModule.intervalKey: 0.0])) == 10)
        #expect(JigglerModule.interval(in: MemoryDefaults([JigglerModule.intervalKey: 45.0])) == 10)
        #expect(JigglerModule.interval(in: MemoryDefaults([JigglerModule.intervalKey: 120.0])) == 120)
    }

    @Test("JG-10 the timer waits the chosen interval; a new interval counts from now")
    func intervalTimer() {
        let mac = FakeMac([JigglerModule.intervalKey: 30.0])
        let jiggler = JigglerModule(env: mac.env)
        jiggler.start()
        #expect(mac.liveTimers == [30])
        mac.defaults.values[JigglerModule.intervalKey] = 10.0
        jiggler.intervalChanged()
        #expect(mac.liveTimers == [10])
        jiggler.stop()
    }

    @Test("JG-08 follows the lock by default")
    func followsLockDefault() {
        #expect(JigglerModule.followsLock(in: MemoryDefaults()))
        #expect(!JigglerModule.followsLock(in: MemoryDefaults([JigglerModule.followsLockKey: false])))
        #expect(JigglerModule(env: FakeMac().env).followsLock)
    }

    @Test("JG-08 on at launch and unlock, off at lock; option off: the lock changes nothing")
    func followsLock() {
        let mac = FakeMac()
        let jiggler = JigglerModule(env: mac.env)
        jiggler.start()
        #expect(jiggler.isActive && jiggler.isObservingLock)
        mac.lock()
        #expect(!jiggler.isActive && !jiggler.isScheduled)
        mac.unlock()
        #expect(jiggler.isActive && jiggler.isScheduled)

        jiggler.followsLock = false
        #expect(!jiggler.isObservingLock)
        #expect(mac.defaults.values[JigglerModule.followsLockKey] as? Bool == false)
        jiggler.stop()

        let off = FakeMac([JigglerModule.followsLockKey: false])
        let manual = JigglerModule(env: off.env)
        manual.start()
        #expect(!manual.isActive && !manual.isObservingLock)
        manual.stop()
    }

    @Test("JG-09 Lock Screen turns the jiggler off first only when it follows the lock")
    func lockScreen() throws {
        for follows in [true, false] {
            let mac = FakeMac([JigglerModule.followsLockKey: follows])
            let jiggler = JigglerModule(env: mac.env)
            jiggler.start()
            if !follows { jiggler.toggle() }
            #expect(jiggler.isActive)
            var activeWhenLocking: Bool?
            let module = LockScreenModule(jiggler: jiggler, lock: { activeWhenLocking = jiggler.isActive })
            let action = try #require(module.actions.first)
            action.perform()
            #expect(activeWhenLocking == !follows)
            jiggler.stop()
        }
    }

    // MARK: A. The module

    @Test("JG-03 turning it on needs Accessibility; one alert each way, none when deactivated")
    func permission() {
        let mac = FakeMac([JigglerModule.followsLockKey: false])
        mac.permission = false
        let jiggler = JigglerModule(env: mac.env)
        jiggler.start()
        jiggler.toggle()
        #expect(!jiggler.isActive && !jiggler.isScheduled)
        #expect(mac.alerts.map(\.kind) == [.permission])
        #expect(mac.alerts.first?.detail == "Permission needed: open Settings › Permissions")

        mac.clearAlerts()
        mac.permission = true
        jiggler.toggle()
        #expect(jiggler.isActive)
        #expect(mac.alerts.map(\.title) == ["Mouse jiggler on"])

        mac.clearAlerts()
        jiggler.deactivate()
        #expect(!jiggler.isActive && mac.alerts.isEmpty)

        jiggler.toggle()
        mac.clearAlerts()
        jiggler.toggle()
        #expect(mac.alerts.map(\.title) == ["Mouse jiggler off"])
        jiggler.stop()
    }

    @Test("JG-05 a wakeup before the interval waits the rest; after it, jiggles and waits a full interval")
    func tick() async {
        let mac = FakeMac([JigglerModule.followsLockKey: false, JigglerKey.key: "none"])
        let jiggler = JigglerModule(env: mac.env)
        jiggler.start()
        jiggler.toggle()
        mac.idle = 3
        mac.timers.last?.fire()
        #expect(mac.liveTimers.last == 7)
        #expect(mac.posted.isEmpty)
        mac.idle = 12
        mac.timers.last?.fire()
        #expect(mac.liveTimers.last == 10)
        for _ in 0..<60 where mac.posted.count < 5 { try? await Task.sleep(for: .milliseconds(50)) }
        #expect(mac.posted == ["move 103,100", "move 100,103", "move 97,100", "move 100,97", "move 100,100"])
        jiggler.stop()
    }

    @Test("JG-12 turning the module off stops the timer, the lock notifications and the jiggler, silently")
    func moduleOff() {
        let mac = FakeMac()
        let jiggler = JigglerModule(env: mac.env)
        jiggler.start()
        mac.clearAlerts()
        jiggler.stop()
        #expect(!jiggler.isActive && !jiggler.isScheduled && !jiggler.isObservingLock)
        #expect(mac.liveTimers.isEmpty && mac.alerts.isEmpty)
        mac.unlock()
        #expect(!jiggler.isActive)
    }
}

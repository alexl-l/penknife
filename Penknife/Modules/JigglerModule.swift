import AppKit

/// The key the jiggler presses after moving the mouse, so Teams and Slack also see keyboard
/// activity (R-3). Only keys that type nothing; Caps Lock is pressed twice so its state stays.
enum JigglerKey: String, CaseIterable, Identifiable {
    case capsLock, shift, control, option, f18, none

    var id: String { rawValue }
    static let key = "jiggler.key"

    static var current: JigglerKey { current(in: .standard) }
    static func current(in defaults: UserDefaults) -> JigglerKey {
        defaults.string(forKey: key).flatMap(JigglerKey.init) ?? .capsLock
    }

    var title: String {
        switch self {
        case .capsLock: String(localized: "Caps Lock (twice)")
        case .shift: String(localized: "Shift")
        case .control: String(localized: "Control")
        case .option: String(localized: "Option")
        case .f18: "F18"
        case .none: String(localized: "None (mouse only)")
        }
    }

    var keyCode: CGKeyCode? {
        switch self {
        case .capsLock: 57
        case .shift: 56
        case .control: 59
        case .option: 58
        case .f18: 79
        case .none: nil
        }
    }

    var presses: Int { self == .capsLock ? 2 : 1 }
}

/// When the next jiggle is due (JG-05): with `idle` seconds since the last input, jiggle now if
/// the interval has passed; then sleep until the earliest moment the next one could be due.
enum JigglerTiming {
    static let floor: TimeInterval = 0.5

    static func next(idle: TimeInterval, interval: TimeInterval) -> (jiggle: Bool, wait: TimeInterval) {
        idle >= interval ? (true, interval) : (false, max(interval - idle, floor))
    }
}

/// The jiggle's path (JG-06): a 3 px square from `origin` (right, down, left, up, back to the start).
enum JigglerMotion {
    static func steps(from origin: CGPoint) -> [CGPoint] {
        [(3, 0), (0, 3), (-3, 0), (0, -3), (0, 0)].map { CGPoint(x: origin.x + $0.0, y: origin.y + $0.1) }
    }

    /// The user moved the mouse if the pointer is more than 3 px (one step) from where the last
    /// move put it. A step clamped at a screen edge lands at most 3 px off, so it doesn't count.
    static func userMoved(expected: CGPoint, actual: CGPoint) -> Bool {
        abs(actual.x - expected.x) > 3 || abs(actual.y - expected.y) > 3
    }

    /// Posts the square from `origin`, waiting `pause` before each next move; stops as soon as the
    /// user moves the mouse (B-19), so the pointer is never pulled back. Returns whether it finished.
    static func perform(from origin: CGPoint, location: () -> CGPoint, move: (CGPoint) -> Void,
                        pause: () async -> Void) async -> Bool {
        var last = origin
        for step in steps(from: origin) {
            if userMoved(expected: last, actual: location()) { return false }
            move(step)
            last = step
            await pause()
        }
        return true
    }
}

/// The daily turn-off time (JG-18): the next moment the clock reads `minutes` after midnight,
/// strictly after `now` (so turning it on after that time keeps it on until the next day).
enum JigglerStop {
    static let enabledKey = "jiggler.stopEnabled"
    static let minutesKey = "jiggler.stopMinutes"
    static let defaultMinutes = 18 * 60

    /// Minutes after midnight when the jiggler turns itself off, or nil when the option is off.
    static func minutes(in defaults: UserDefaults) -> Int? {
        guard defaults.bool(forKey: enabledKey) else { return nil }
        let value = defaults.object(forKey: minutesKey) as? Int ?? defaultMinutes
        return (0..<24 * 60).contains(value) ? value : defaultMinutes
    }

    static func deadline(after now: Date, minutes: Int, calendar: Calendar = .current) -> Date {
        let time = DateComponents(hour: minutes / 60, minute: minutes % 60)
        return calendar.nextDate(after: now, matching: time, matchingPolicy: .nextTime)
            ?? now.addingTimeInterval(24 * 3600)
    }
}

/// Everything the jiggler touches outside itself (S3): `live` is the real Mac; tests pass fakes.
struct JigglerEnvironment {
    var defaults: UserDefaults
    var ensurePermission: () -> Bool
    var hud: (_ title: String, _ detail: String?, _ symbol: String, _ kind: AlertKind) -> Void
    /// Starts listening for the screen lock; the returned closure stops it.
    var observeLock: (_ locked: @escaping @MainActor () -> Void, _ unlocked: @escaping @MainActor () -> Void) -> () -> Void
    /// A one-shot wakeup after `seconds`; the returned closure cancels it.
    var schedule: (_ seconds: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> () -> Void
    var idleSeconds: () -> TimeInterval
    var now: () -> Date = { Date() }
    /// Calls `woke` after the Mac wakes or its clock changes (a timer doesn't count sleep time);
    /// the returned closure stops it.
    var observeWake: (_ woke: @escaping @MainActor () -> Void) -> () -> Void = { _ in {} }
    var mouseLocation: () -> CGPoint
    var moveMouse: (CGPoint) -> Void
    var key: (CGKeyCode) -> Void

    static var live: Self {
        Self(defaults: .standard,
             ensurePermission: { Permissions.shared.ensureAccessibility() },
             hud: { HUD.shared.show($0, detail: $1, symbol: $2, kind: $3, category: .jiggler) },
             observeLock: { locked, unlocked in
                 let center = DistributedNotificationCenter.default()
                 let observers = [
                     center.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
                         MainActor.assumeIsolated { locked() }
                     },
                     center.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
                         MainActor.assumeIsolated { unlocked() }
                     },
                 ]
                 return { observers.forEach(center.removeObserver) }
             },
             schedule: { seconds, fire in
                 let timer = Timer(timeInterval: seconds, repeats: false) { _ in
                     MainActor.assumeIsolated { fire() }
                 }
                 timer.tolerance = 1
                 RunLoop.main.add(timer, forMode: .common)
                 return { timer.invalidate() }
             },
             idleSeconds: {
                 CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
             },
             observeWake: { woke in
                 let workspace = NSWorkspace.shared.notificationCenter
                 let wake = workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
                     MainActor.assumeIsolated { woke() }
                 }
                 let clock = NotificationCenter.default.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main) { _ in
                     MainActor.assumeIsolated { woke() }
                 }
                 return {
                     workspace.removeObserver(wake)
                     NotificationCenter.default.removeObserver(clock)
                 }
             },
             mouseLocation: { EventPoster.mouseLocation },
             moveMouse: { EventPoster.moveMouse(to: $0) },
             key: { EventPoster.key($0) })
    }
}

/// Mouse jiggler (R-3): while active, nudges the mouse after a chosen time without input (R-24).
/// Optionally follows the screen lock: off when the Mac locks, on when it unlocks (and at launch).
/// No event tap and no 1 s polling: it reads the system idle time and sleeps until the
/// earliest moment the next jiggle could be due (at most one wakeup per interval).
@Observable
final class JigglerModule: Module {
    let id = ModuleID.jiggler
    var needsAccessibility: Bool { true }

    private(set) var isActive = false
    @ObservationIgnored private let env: JigglerEnvironment
    /// True while Penknife itself is waiting for the user (a recording, the capture overlay, the
    /// clipboard panel): a jiggle then would be recorded or move the pointer under them (O-23, JG-17).
    @ObservationIgnored var holdsOff: () -> Bool = { false }
    @ObservationIgnored private var cancelTimer: (() -> Void)?
    @ObservationIgnored private var isJiggling = false
    @ObservationIgnored private var stopObservingLock: (() -> Void)?
    @ObservationIgnored private var running = false
    /// The turn-off time while it is set and the jiggler is on (JG-18), its timer and wake observer.
    @ObservationIgnored private(set) var stopAt: Date?
    @ObservationIgnored private var cancelStop: (() -> Void)?
    @ObservationIgnored private var stopObservingWake: (() -> Void)?

    static let followsLockKey = "jiggler.followsLock"
    static func followsLock(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: followsLockKey) as? Bool ?? true
    }

    /// Turn on when unlocking, off when locking. On by default.
    var followsLock: Bool {
        didSet {
            env.defaults.set(followsLock, forKey: Self.followsLockKey)
            updateLockObservers()
        }
    }

    static let intervalKey = "jiggler.interval"
    static let intervals: [TimeInterval] = [10, 30, 60, 120, 300]

    /// Seconds without input before the mouse moves (R-24). Anything not offered in Settings means 10 s.
    static func interval(in defaults: UserDefaults) -> TimeInterval {
        let value = defaults.double(forKey: intervalKey)
        return intervals.contains(value) ? value : 10
    }

    private var idleThreshold: TimeInterval { Self.interval(in: env.defaults) }

    /// Whether a timer or the lock notifications are live (for tests of JG-12, JG-14).
    var isScheduled: Bool { cancelTimer != nil }
    var isObservingLock: Bool { stopObservingLock != nil }

    init(env: JigglerEnvironment = .live) {
        self.env = env
        followsLock = Self.followsLock(in: env.defaults)
    }

    /// Settings changed the interval: count again from now, so a shorter time applies at once.
    func intervalChanged() {
        if isActive { schedule(after: idleThreshold) }
    }

    /// Settings changed the turn-off time or switched it: plan it again from now.
    func stopTimeChanged() {
        if isActive { scheduleStop() }
    }

    var actions: [ModuleAction] {
        [ModuleAction(shortcut: .toggleJiggler, title: String(localized: "Mouse Jiggler"), symbol: id.symbol,
                      state: { [weak self] in self?.isActive ?? false },
                      perform: { [weak self] in self?.toggle() })]
    }

    func start() {
        running = true
        updateLockObservers()
        // Launching (at login) counts as unlocking.
        if followsLock { activate() }
    }

    func stop() {
        running = false
        updateLockObservers()
        deactivate()
    }

    func toggle() {
        if isActive {
            deactivate()
            env.hud(String(localized: "Mouse Jiggler off"), nil, "cursorarrow", .off)
        } else {
            activate()
        }
    }

    private func activate() {
        guard !isActive else { return }
        guard env.ensurePermission() else {
            env.hud(String(localized: "Mouse Jiggler"), String(localized: "Open Settings › Permissions to allow it"),
                    "lock.fill", .permission)
            return
        }
        isActive = true
        schedule(after: idleThreshold)
        scheduleStop()
        env.hud(String(localized: "Mouse Jiggler on"), nil, "cursorarrow.motionlines", .on)
    }

    /// Lock notifications are observed only while the module is on and the option is set (R-15).
    private func updateLockObservers() {
        let wanted = running && followsLock
        guard wanted != isObservingLock else { return }
        if wanted {
            stopObservingLock = env.observeLock({ [weak self] in self?.deactivate() },
                                                { [weak self] in self?.activate() })
        } else {
            stopObservingLock?()
            stopObservingLock = nil
        }
    }

    func deactivate() {
        cancelTimer?()
        cancelTimer = nil
        cancelStopTimer()
        isActive = false
    }

    /// One timer for the turn-off time, plus a wake observer: a timer stops counting while the Mac
    /// sleeps, so after waking it is checked against the clock (asleep at that time → off on wake).
    private func scheduleStop() {
        cancelStopTimer()
        guard let minutes = JigglerStop.minutes(in: env.defaults) else { return }
        let deadline = JigglerStop.deadline(after: env.now(), minutes: minutes)
        stopAt = deadline
        armStop()
        stopObservingWake = env.observeWake { [weak self] in self?.checkStop() }
    }

    private func armStop() {
        guard let stopAt else { return }
        cancelStop?()
        cancelStop = env.schedule(stopAt.timeIntervalSince(env.now())) { [weak self] in self?.checkStop() }
    }

    private func checkStop() {
        guard isActive, let stopAt else { return }
        if env.now() >= stopAt.addingTimeInterval(-1) {
            deactivate()
            env.hud(String(localized: "Mouse Jiggler off"), String(localized: "Scheduled time"), "cursorarrow", .off)
        } else {
            armStop()
        }
    }

    private func cancelStopTimer() {
        cancelStop?()
        cancelStop = nil
        stopObservingWake?()
        stopObservingWake = nil
        stopAt = nil
    }

    private func schedule(after seconds: TimeInterval) {
        cancelTimer?()
        cancelTimer = env.schedule(max(seconds, JigglerTiming.floor)) { [weak self] in self?.tick() }
    }

    private func tick() {
        guard isActive else { return }
        let next = JigglerTiming.next(idle: env.idleSeconds(), interval: idleThreshold)
        if next.jiggle && !holdsOff() { jiggle() }
        schedule(after: next.wait)
    }

    /// Same movement as the old Hammerspoon script: a 3 px square, then the chosen key
    /// (Caps Lock by default, pressed twice so its state doesn't change) for keyboard activity.
    private func jiggle() {
        guard !isJiggling else { return }
        isJiggling = true
        let origin = env.mouseLocation()
        let key = JigglerKey.current(in: env.defaults)
        Task {
            let finished = await JigglerMotion.perform(from: origin, location: env.mouseLocation,
                                                       move: env.moveMouse,
                                                       pause: { try? await Task.sleep(for: .milliseconds(80)) })
            // The user took the mouse: they are active, so no key either.
            if finished, let code = key.keyCode {
                for press in 0..<key.presses {
                    if press > 0 { try? await Task.sleep(for: .milliseconds(100)) }
                    env.key(code)
                }
            }
            isJiggling = false
        }
    }
}

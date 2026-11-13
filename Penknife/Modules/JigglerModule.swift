import AppKit

/// The key the jiggler presses after moving the mouse, so Teams and Slack also see keyboard
/// activity (R-3). Only keys that type nothing; Caps Lock is pressed twice so its state stays.
enum JigglerKey: String, CaseIterable, Identifiable {
    case capsLock, shift, control, option, f18, none

    var id: String { rawValue }
    static let key = "jiggler.key"

    static var current: JigglerKey {
        UserDefaults.standard.string(forKey: key).flatMap(JigglerKey.init) ?? .capsLock
    }

    var title: String {
        switch self {
        case .capsLock: String(localized: "Caps Lock (twice)")
        case .shift: "Shift"
        case .control: "Control"
        case .option: "Option"
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

/// Mouse jiggler (R-3): while active, nudges the mouse after a chosen time without input (R-24).
/// Optionally follows the screen lock: off when the Mac locks, on when it unlocks (and at launch).
/// No event tap and no 1 s polling: it reads the system idle time and sleeps until the
/// earliest moment the next jiggle could be due (at most one wakeup per interval).
@Observable
final class JigglerModule: Module {
    let id = ModuleID.jiggler
    var needsAccessibility: Bool { true }

    private(set) var isActive = false
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var isJiggling = false
    @ObservationIgnored private var lockObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var running = false

    private static let followsLockKey = "jiggler.followsLock"

    /// Turn on when unlocking, off when locking. On by default.
    var followsLock: Bool = UserDefaults.standard.object(forKey: JigglerModule.followsLockKey) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(followsLock, forKey: Self.followsLockKey)
            updateLockObservers()
        }
    }

    static let intervalKey = "jiggler.interval"
    static let intervals: [TimeInterval] = [10, 30, 60, 120, 300]

    /// Seconds without input before the mouse moves (R-24). Anything not offered in Settings means 10 s.
    private var idleThreshold: TimeInterval {
        let value = UserDefaults.standard.double(forKey: Self.intervalKey)
        return Self.intervals.contains(value) ? value : 10
    }

    /// Settings changed the interval: count again from now, so a shorter time applies at once.
    func intervalChanged() {
        if isActive { schedule(after: idleThreshold) }
    }

    var actions: [ModuleAction] {
        [ModuleAction(shortcut: .toggleJiggler, title: String(localized: "Mouse jiggler"), symbol: id.symbol,
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
            HUD.shared.show(String(localized: "Mouse jiggler off"), symbol: "cursorarrow", kind: .off, category: .jiggler)
        } else {
            activate()
        }
    }

    private func activate() {
        guard !isActive else { return }
        guard Permissions.shared.ensureAccessibility() else {
            HUD.shared.show(String(localized: "Mouse jiggler"), detail: String(localized: "Needs the Accessibility permission"),
                             symbol: "lock.fill", kind: .permission, category: .jiggler)
            return
        }
        isActive = true
        schedule(after: idleThreshold)
        HUD.shared.show(String(localized: "Mouse jiggler on"), symbol: "cursorarrow.motionlines", kind: .on, category: .jiggler)
    }

    /// Lock notifications are observed only while the module is on and the option is set (R-15).
    private func updateLockObservers() {
        let center = DistributedNotificationCenter.default()
        let wanted = running && followsLock
        guard wanted != !lockObservers.isEmpty else { return }
        if !wanted {
            lockObservers.forEach(center.removeObserver)
            lockObservers = []
            return
        }
        lockObservers = [
            center.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.deactivate() }
            },
            center.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.activate() }
            },
        ]
    }

    func deactivate() {
        timer?.invalidate()
        timer = nil
        isActive = false
    }

    private func schedule(after seconds: TimeInterval) {
        timer?.invalidate()
        let timer = Timer(timeInterval: max(seconds, 0.5), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard isActive else { return }
        let anyInput = CGEventType(rawValue: ~0)!
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        if idle >= idleThreshold {
            jiggle()
            schedule(after: idleThreshold)
        } else {
            schedule(after: idleThreshold - idle)
        }
    }

    /// Same movement as the old Hammerspoon script: a 3 px square, then the chosen key
    /// (Caps Lock by default, pressed twice so its state doesn't change) for keyboard activity.
    private func jiggle() {
        guard !isJiggling else { return }
        isJiggling = true
        let origin = EventPoster.mouseLocation
        let key = JigglerKey.current
        let steps: [CGPoint] = [.init(x: 3, y: 0), .init(x: 0, y: 3), .init(x: -3, y: 0), .init(x: 0, y: -3), .zero]
        Task {
            for step in steps {
                EventPoster.moveMouse(to: CGPoint(x: origin.x + step.x, y: origin.y + step.y))
                try? await Task.sleep(for: .milliseconds(80))
            }
            if let code = key.keyCode {
                for press in 0..<key.presses {
                    if press > 0 { try? await Task.sleep(for: .milliseconds(100)) }
                    EventPoster.key(code)
                }
            }
            isJiggling = false
        }
    }
}

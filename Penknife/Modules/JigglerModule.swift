import AppKit

/// Mouse jiggler (R-3): while active, nudges the mouse after 10 s without input.
/// Optionally follows the screen lock: off when the Mac locks, on when it unlocks (and at launch).
/// No event tap and no 1 s polling: it reads the system idle time and sleeps until the
/// earliest moment the next jiggle could be due (at most one wakeup every ~10 s).
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

    private let idleThreshold: TimeInterval = 10

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
            HUD.shared.show(String(localized: "Mouse jiggler off"))
        } else {
            activate()
        }
    }

    private func activate() {
        guard !isActive else { return }
        guard Permissions.shared.ensureAccessibility() else {
            HUD.shared.show(String(localized: "Mouse jiggler needs the Accessibility permission"))
            return
        }
        isActive = true
        schedule(after: idleThreshold)
        HUD.shared.show(String(localized: "Mouse jiggler on"))
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

    /// Same movement as the old Hammerspoon script: a 3 px square, then Caps Lock twice
    /// (pressed and released back, so its state doesn't change) to register keyboard activity.
    private func jiggle() {
        guard !isJiggling else { return }
        isJiggling = true
        let origin = EventPoster.mouseLocation
        let steps: [CGPoint] = [.init(x: 3, y: 0), .init(x: 0, y: 3), .init(x: -3, y: 0), .init(x: 0, y: -3), .zero]
        Task {
            for step in steps {
                EventPoster.moveMouse(to: CGPoint(x: origin.x + step.x, y: origin.y + step.y))
                try? await Task.sleep(for: .milliseconds(80))
            }
            EventPoster.key(CGKeyCode(57))
            try? await Task.sleep(for: .milliseconds(100))
            EventPoster.key(CGKeyCode(57))
            isJiggling = false
        }
    }
}

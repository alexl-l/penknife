import AppKit
import IOKit.pwr_mgt

/// Everything Keep Awake touches outside itself (KA rules): `live` is the real Mac; tests pass fakes.
struct KeepAwakeEnvironment {
    /// Holds the Mac and the display awake; returns the release, or nil if macOS refused.
    var holdAwake: () -> (() -> Void)?
    var hud: (_ title: String, _ symbol: String, _ kind: AlertKind) -> Void
    /// Starts listening for the screen lock; the returned closure stops it.
    var observeLock: (_ locked: @escaping @MainActor () -> Void) -> () -> Void

    static var live: Self {
        Self(holdAwake: {
                 // The same assertion `caffeinate -d` takes: no idle display sleep, so no idle
                 // system sleep either. Released by macOS if Penknife quits or crashes.
                 var id = IOPMAssertionID(0)
                 let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                          IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                          "Penknife Keep Awake" as CFString, &id)
                 guard result == kIOReturnSuccess else { return nil }
                 return { IOPMAssertionRelease(id) }
             },
             hud: { HUD.shared.show($0, symbol: $1, kind: $2, category: .keepAwake) },
             observeLock: { locked in
                 let center = DistributedNotificationCenter.default()
                 let observer = center.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil,
                                                   queue: .main) { _ in
                     MainActor.assumeIsolated { locked() }
                 }
                 return { center.removeObserver(observer) }
             })
    }
}

/// Keep Awake (R-39): while on, the Mac doesn't sleep and the display stays on, without moving
/// the mouse. One power assertion, no timer. Off at launch, when the Mac locks, and when the
/// module is turned off; the lock is listened to only while it is on.
@Observable
final class KeepAwakeModule: Module {
    let id = ModuleID.keepAwake

    private(set) var isActive = false
    @ObservationIgnored private let env: KeepAwakeEnvironment
    @ObservationIgnored private var release: (() -> Void)?
    @ObservationIgnored private var stopObservingLock: (() -> Void)?

    /// For tests of KA-04/KA-06: whether the assertion or the lock observer are live.
    var isHolding: Bool { release != nil }
    var isObservingLock: Bool { stopObservingLock != nil }

    init(env: KeepAwakeEnvironment = .live) {
        self.env = env
    }

    var actions: [ModuleAction] {
        [ModuleAction(shortcut: .toggleKeepAwake, title: String(localized: "Keep Awake"), symbol: id.symbol,
                      state: { [weak self] in self?.isActive ?? false },
                      perform: { [weak self] in self?.toggle() })]
    }

    func start() {}

    func stop() { deactivate() }

    func toggle() {
        if isActive {
            deactivate()
            env.hud(String(localized: "Keep Awake off"), "cup.and.saucer", .off)
        } else {
            activate()
        }
    }

    private func activate() {
        guard !isActive else { return }
        guard let release = env.holdAwake() else {
            env.hud(String(localized: "Couldn't keep the Mac awake"), "exclamationmark.triangle", .error)
            return
        }
        self.release = release
        isActive = true
        stopObservingLock = env.observeLock { [weak self] in self?.deactivate() }
        env.hud(String(localized: "Keep Awake on"), "cup.and.saucer.fill", .on)
    }

    /// Silent: used by the lock and by the module going off.
    func deactivate() {
        release?()
        release = nil
        stopObservingLock?()
        stopObservingLock = nil
        isActive = false
    }
}

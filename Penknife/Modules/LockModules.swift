import AppKit

/// Locks the screen at once. Uses the system's own lock call (what the Apple menu's
/// "Lock Screen" does); if it is ever unavailable, falls back to pressing ⌃⌘Q.
enum ScreenLocker {
    private typealias LockFunction = @convention(c) () -> Int32

    private static let lockFunction: LockFunction? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
              let symbol = dlsym(handle, "SACLockScreenImmediate") else { return nil }
        return unsafeBitCast(symbol, to: LockFunction.self)
    }()

    /// The fallback: ⌃⌘Q, the system's own Lock Screen shortcut (key code 12 = Q).
    static let fallbackKey = CGKeyCode(12)
    static let fallbackFlags: CGEventFlags = [.maskControl, .maskCommand]

    /// Whether this macOS still has the system's lock call (LK-02).
    static var hasSystemLock: Bool { lockFunction != nil }

    static func lock() {
        lock(system: lockFunction.map { function in { function() } },
             accessibility: { Permissions.shared.ensureAccessibility() },
             pressKeys: { EventPoster.key(fallbackKey, flags: fallbackFlags) })
    }

    /// The order (LK-02, S1): the system call first; the keys only if it is missing or fails,
    /// and only with Accessibility.
    static func lock(system: (() -> Int32)?, accessibility: () -> Bool, pressKeys: () -> Void) {
        if let system, system() == 0 { return }
        guard accessibility() else { return }
        pressKeys()
    }
}

/// Lock screen (R-3): turns the jiggler off first when it follows the lock (setting), so it
/// doesn't run while locked.
final class LockScreenModule: Module {
    let id = ModuleID.lockScreen
    private weak var jiggler: JigglerModule?
    private let lock: @MainActor () -> Void

    /// `lock` locks the Mac; tests pass a fake (S4).
    init(jiggler: JigglerModule, lock: @escaping @MainActor () -> Void = { ScreenLocker.lock() }) {
        self.jiggler = jiggler
        self.lock = lock
    }

    var actions: [ModuleAction] {
        [ModuleAction(shortcut: .lockScreen, title: String(localized: "Lock Screen"), symbol: id.symbol,
                      perform: { [weak self] in
                          if let jiggler = self?.jiggler, jiggler.followsLock { jiggler.deactivate() }
                          self?.lock()
                      })]
    }

    func start() {}
    func stop() {}
}

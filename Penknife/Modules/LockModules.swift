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

    static func lock() {
        if let lockFunction, lockFunction() == 0 { return }
        guard Permissions.shared.ensureAccessibility() else { return }
        EventPoster.key(CGKeyCode(12), flags: [.maskControl, .maskCommand]) // Q
    }
}

/// Lock screen (R-3): turns the jiggler off first when it follows the lock (setting), so it
/// doesn't run while locked.
final class LockScreenModule: Module {
    let id = ModuleID.lockScreen
    private weak var jiggler: JigglerModule?

    init(jiggler: JigglerModule) {
        self.jiggler = jiggler
    }

    var actions: [ModuleAction] {
        [ModuleAction(shortcut: .lockScreen, title: String(localized: "Lock screen"), symbol: id.symbol,
                      perform: { [weak self] in
                          if let jiggler = self?.jiggler, jiggler.followsLock { jiggler.deactivate() }
                          ScreenLocker.lock()
                      })]
    }

    func start() {}
    func stop() {}
}

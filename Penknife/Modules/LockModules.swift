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

/// Lock screen (R-3): turns the jiggler off first, so it never runs while locked.
final class LockScreenModule: Module {
    let id = ModuleID.lockScreen
    private weak var jiggler: JigglerModule?

    init(jiggler: JigglerModule) {
        self.jiggler = jiggler
    }

    var actions: [ModuleAction] {
        [ModuleAction(shortcut: .lockScreen, title: String(localized: "Lock screen"), symbol: id.symbol,
                      perform: { [weak self] in
                          self?.jiggler?.deactivate()
                          ScreenLocker.lock()
                      })]
    }

    func start() {}
    func stop() {}
}

/// Screenshot shortcut (R-3). Until the editor (R-8) exists it uses the system's interactive
/// area capture and copies the result to the clipboard. One short-lived process per press.
final class ScreenshotModule: Module {
    let id = ModuleID.screenshot

    var actions: [ModuleAction] {
        [ModuleAction(shortcut: .screenshot, title: String(localized: "Screenshot"), symbol: id.symbol,
                      perform: { Self.capture() })]
    }

    func start() {}
    func stop() {}

    private static func capture() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-c"]
        try? process.run()
    }
}

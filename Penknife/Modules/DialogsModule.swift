import AppKit
import ApplicationServices
import os

/// Native dialogs (R-4): knows when a sheet, modal window or system prompt is in front, so the
/// Touch Bar can step aside. Event-driven: it only checks when the front app, its focused window
/// or focused element changes, or a window or sheet appears. It watches only while the module is
/// on AND the Touch Bar listens (`onChange` set), so it costs nothing without a Touch Bar (B-5).
@Observable
final class DialogsModule: Module {
    let id = ModuleID.dialogs
    var needsAccessibility: Bool { true }
    let actions: [ModuleAction] = []

    private(set) var isDialogOpen = false
    /// Called when `isDialogOpen` changes. Only the running Touch Bar sets it.
    @ObservationIgnored var onChange: ((Bool) -> Void)? {
        didSet { updateWatching() }
    }

    @ObservationIgnored private var enabled = false // the module's switch
    @ObservationIgnored private var running = false // watching
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    @ObservationIgnored private var observer: AXObserver?
    @ObservationIgnored private var observedApp: AXUIElement?
    @ObservationIgnored private var pendingCheck: DispatchWorkItem?
    @ObservationIgnored private let log = Logger(subsystem: "Penknife", category: "Dialogs")

    private static let systemPromptApps: Set<String> = [
        "com.apple.SecurityAgent",
        "com.apple.UserNotificationCenter",
        "com.apple.coreservices.uiagent",
        "com.apple.LocalAuthentication.UIAgent",
        "com.apple.CoreLocationAgent",
        "com.apple.accessibility.universalAccessAuthWarn",
    ]

    private static let notifications = [
        kAXFocusedWindowChangedNotification,
        kAXFocusedUIElementChangedNotification,
        kAXWindowCreatedNotification,
        "AXSheetCreated",
    ]

    init() {
        Permissions.shared.onChange.append { [weak self] in
            guard let self, self.running else { return }
            self.observe(NSWorkspace.shared.frontmostApplication)
        }
    }

    func start() {
        enabled = true
        updateWatching()
    }

    func stop() {
        enabled = false
        updateWatching()
    }

    /// B-5: watch only while the module is on and someone listens.
    static func shouldWatch(enabled: Bool, hasListener: Bool) -> Bool { enabled && hasListener }

    /// True while any observer exists (for tests: nothing is held while not watching).
    var isWatching: Bool { activationObserver != nil || observer != nil }

    private func updateWatching() {
        let watch = Self.shouldWatch(enabled: enabled, hasListener: onChange != nil)
        if watch, !running { beginWatching() } else if !watch, running { endWatching() }
    }

    private func beginWatching() {
        running = true
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.observe(app) }
        }
        observe(NSWorkspace.shared.frontmostApplication)
    }

    /// Turning the module off while a dialog shows brings the bar back at once (the listener is
    /// still set); losing the listener just resets the state.
    private func endWatching() {
        running = false
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
        removeObserver()
        pendingCheck?.cancel()
        pendingCheck = nil
        setOpen(false)
    }

    // MARK: Observing

    private func observe(_ app: NSRunningApplication?) {
        removeObserver()
        guard let app, AXIsProcessTrusted() else {
            scheduleCheck()
            return
        }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.2) // unresponsive apps must not block us

        var newObserver: AXObserver?
        guard AXObserverCreate(app.processIdentifier, Self.callback, &newObserver) == .success, let newObserver else {
            scheduleCheck()
            return
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in Self.notifications {
            AXObserverAddNotification(newObserver, element, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(newObserver), .defaultMode)
        observer = newObserver
        observedApp = element
        scheduleCheck()
    }

    private func removeObserver() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
            if let observedApp {
                for name in Self.notifications {
                    AXObserverRemoveNotification(observer, observedApp, name as CFString)
                }
            }
        }
        observer = nil
        observedApp = nil
    }

    private static let callback: AXObserverCallback = { _, _, _, refcon in
        guard let refcon else { return }
        let module = Unmanaged<DialogsModule>.fromOpaque(refcon).takeUnretainedValue()
        MainActor.assumeIsolated { module.scheduleCheck() }
    }

    /// Bursts of AX notifications collapse into one check 0.15 s after the last one.
    private func scheduleCheck() {
        pendingCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.running else { return }
            self.setOpen(self.dialogIsOpen())
        }
        pendingCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func setOpen(_ open: Bool) {
        guard open != isDialogOpen else { return }
        isDialogOpen = open
        log.debug("Dialog open: \(open)")
        onChange?(open)
    }

    // MARK: Detection

    /// True while Penknife's own "Customize Touch Bar" sheet is open: it is not a dialog for the
    /// bar, so the real bar stays and follows each change (O-8). Penknife's other alerts and panels
    /// still count (the bar shows their native buttons).
    static var customizingBar = false

    /// O-8: Penknife in front with the Customize sheet open is never a dialog.
    static func ignoresFront(isPenknife: Bool, customizingBar: Bool) -> Bool { isPenknife && customizingBar }

    private func dialogIsOpen() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        if Self.ignoresFront(isPenknife: app.processIdentifier == ProcessInfo.processInfo.processIdentifier,
                             customizingBar: Self.customizingBar) { return false }
        if Self.systemPromptApps.contains(app.bundleIdentifier ?? "") { return true }
        guard AXIsProcessTrusted() else { return false }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.2)

        guard let window: AXUIElement = Self.attribute(appElement, kAXFocusedWindowAttribute) else { return false }
        if Self.isDialog(window) { return true }

        // A sheet attached to the focused window.
        let children: [AXUIElement] = Self.attribute(window, kAXChildrenAttribute) ?? []
        if children.contains(where: Self.isDialog) { return true }

        // Focus inside a dialog (e.g. on its default button).
        var element: AXUIElement? = Self.attribute(appElement, kAXFocusedUIElementAttribute)
        for _ in 0..<12 {
            guard let current = element, !CFEqual(current, window) else { break }
            if Self.isDialog(current) { return true }
            element = Self.attribute(current, kAXParentAttribute)
        }
        return false
    }

    /// Only real dialogs count: sheets, system dialogs and modal windows. Plain "AXDialog"
    /// windows don't (apps such as Warp keep hidden ones around).
    private static func isDialog(_ element: AXUIElement) -> Bool {
        let role: String? = attribute(element, kAXRoleAttribute)
        let subrole: String? = attribute(element, kAXSubroleAttribute)
        let modal: Bool? = attribute(element, kAXModalAttribute)
        return role == kAXSheetRole || subrole == kAXSystemDialogSubrole || modal == true
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else { return nil }
        if T.self == AXUIElement.self {
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! T)
        }
        return value as? T
    }
}

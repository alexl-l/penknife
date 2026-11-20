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
    /// The dialog on screen, watched until it goes (TB-64).
    @ObservationIgnored private var watchedDialog: AXUIElement?
    @ObservationIgnored private var pendingCheck: DispatchWorkItem?
    @ObservationIgnored private let log = Logger(subsystem: "Penknife", category: "Dialogs")

    static let systemPromptApps: Set<String> = [
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
        unwatchDialog()
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
        let dialog = Self.openDialog(in: DialogAXNode.app(app.processIdentifier))
        watchDialog(dialog?.element)
        return dialog != nil
    }

    /// TB-64: a dialog can close with no focus or app change (a tap on its Touch Bar button
    /// while the app keeps no other window), so its own "destroyed" notification is watched.
    private func watchDialog(_ element: AXUIElement?) {
        if let element, let watchedDialog, CFEqual(element, watchedDialog) { return }
        unwatchDialog()
        guard let element, let observer else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        if AXObserverAddNotification(observer, element, kAXUIElementDestroyedNotification as CFString, refcon) == .success {
            watchedDialog = element
        }
    }

    private func unwatchDialog() {
        if let observer, let watchedDialog {
            AXObserverRemoveNotification(observer, watchedDialog, kAXUIElementDestroyedNotification as CFString)
        }
        watchedDialog = nil
    }

    /// TB-44: a system prompt app in front counts even without Accessibility; otherwise, with it,
    /// the focused window, a direct child of it (an attached sheet), or the focused element or
    /// one of its parents below that window (12 elements at most) is a dialog. Each value is read
    /// only when needed, in this order.
    static func dialogIsOpen<Node: DialogNode>(frontBundleID: String?, trusted: @autoclosure () -> Bool,
                                               app: @autoclosure () -> Node) -> Bool {
        if systemPromptApps.contains(frontBundleID ?? "") { return true }
        guard trusted() else { return false }
        return openDialog(in: app()) != nil
    }

    /// The dialog element `dialogIsOpen` finds with Accessibility, or nil.
    static func openDialog<Node: DialogNode>(in app: Node) -> Node? {
        guard let window = app.focusedWindow else { return nil }
        if isDialog(window) { return window }

        // A sheet attached to the focused window.
        if let sheet = window.children.first(where: isDialog) { return sheet }

        // Focus inside a dialog (e.g. on its default button).
        var element = app.focusedElement
        for _ in 0..<12 {
            guard let current = element, !current.isSame(as: window) else { break }
            if isDialog(current) { return current }
            element = current.parent
        }
        return nil
    }

    static func isDialog<Node: DialogNode>(_ node: Node) -> Bool {
        let role = node.role
        let subrole = node.subrole
        let modal = node.modal
        return isDialog(role: role, subrole: subrole, modal: modal)
    }

    /// Only real dialogs count: sheets, system dialogs and modal windows. Plain "AXDialog"
    /// windows don't (apps such as Warp keep hidden ones around).
    static func isDialog(role: String?, subrole: String?, modal: Bool?) -> Bool {
        role == kAXSheetRole || subrole == kAXSystemDialogSubrole || modal == true
    }

    fileprivate static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else { return nil }
        if T.self == AXUIElement.self {
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! T)
        }
        return value as? T
    }
}

/// What dialog detection reads from an Accessibility element (S4): `DialogAXNode` in the app, a
/// plain tree in PenknifeTests. Each property is read only when a rule asks.
protocol DialogNode {
    var role: String? { get }
    var subrole: String? { get }
    var modal: Bool? { get }
    var children: [Self] { get }
    var parent: Self? { get }
    /// On the app element.
    var focusedWindow: Self? { get }
    var focusedElement: Self? { get }
    func isSame(as other: Self) -> Bool
}

/// An Accessibility element, read at each access (0.2 s timeout set on the app element).
struct DialogAXNode: DialogNode {
    let element: AXUIElement

    static func app(_ pid: pid_t) -> DialogAXNode {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.2) // unresponsive apps must not block us
        return DialogAXNode(element: element)
    }

    var role: String? { DialogsModule.attribute(element, kAXRoleAttribute) }
    var subrole: String? { DialogsModule.attribute(element, kAXSubroleAttribute) }
    var modal: Bool? { DialogsModule.attribute(element, kAXModalAttribute) }
    var children: [DialogAXNode] {
        let children: [AXUIElement] = DialogsModule.attribute(element, kAXChildrenAttribute) ?? []
        return children.map(DialogAXNode.init)
    }
    var parent: DialogAXNode? { node(kAXParentAttribute) }
    var focusedWindow: DialogAXNode? { node(kAXFocusedWindowAttribute) }
    var focusedElement: DialogAXNode? { node(kAXFocusedUIElementAttribute) }
    func isSame(as other: DialogAXNode) -> Bool { CFEqual(element, other.element) }

    private func node(_ name: String) -> DialogAXNode? {
        let value: AXUIElement? = DialogsModule.attribute(element, name)
        return value.map(DialogAXNode.init)
    }
}

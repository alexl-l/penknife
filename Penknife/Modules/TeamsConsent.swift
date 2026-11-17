import AppKit
import os

/// R-31: Teams' consent alert, which shows when the user unmutes in a meeting that asks for
/// consent to record. With the option on,
/// Penknife presses the alert's main button only when ITS OWN unmute shortcut opened it.
/// No text is matched (user, 2026-11-17: texts change; admins can customize it, and it's
/// localized). Measured 2026-11-17 on Teams 2: an alert is a Fluent UI web dialog
/// (AXGroup / AXApplicationDialog) whose two action buttons are its last ones, main one last
/// ("Cancel", "Stop"; the consent alert is "No", "Yes"); while it's open, the rest of that
/// window (the mic button too) is hidden from Accessibility. One Accessibility session:
/// 1. find the call's window (the one with the mic button) and its state; not muted, or not
///    found → just send the shortcut (this press doesn't unmute, or can't be told);
/// 2. no alert open in that window, and the window fully read → send the shortcut;
/// 3. for up to 1.5 s: if the mic shows open, the unmute went through without consent → stop;
///    if exactly one new alert shows in that window, with a two-button action row, before the
///    mic ever showed open → press its last button (focus + Space; AXPress does nothing in
///    Teams). Anything else = nothing pressed.
/// Never camera, screen sharing or background presses. Only the outcome is logged, never text.
nonisolated enum TeamsConsent {
    static let enabledKey = "microphone.teamsConsent"
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    private static let log = Logger(subsystem: "Penknife", category: "Microphone")

    /// Presses Teams' mute shortcut through `send`, then calls `sent` with the call's mic state
    /// read before the press (nil = unreadable), both on the main thread, right away; the alert
    /// is watched after that.
    @MainActor static func press(_ app: NSRunningApplication, send: @escaping @MainActor () -> Void,
                                 sent: @escaping @MainActor (Bool?) -> Void) {
        let pid = app.processIdentifier
        let chromium = MeetingTracker.isChromium(app)
        DispatchQueue.global(qos: .userInitiated).async {
            let start = Date()
            var didSend = false
            var appMuted: Bool?
            let outcome = MeetingTracker.withWebTree(pid: pid, chromium: chromium) { ax, freshTree -> String? in
                func sendNow() {
                    let muted = appMuted
                    DispatchQueue.main.sync { MainActor.assumeIsolated { send(); sent(muted) } }
                    didSend = true
                }
                // 1. The call's window; a tree that was just turned on is built within ~1 s.
                var call = callWindow(in: MeetingTracker.meetingWindows(ax, onlyFocused: false))
                var tries = 0
                while call == nil, freshTree, tries < 5 {
                    Thread.sleep(forTimeInterval: 0.2)
                    tries += 1
                    call = callWindow(in: MeetingTracker.meetingWindows(ax, onlyFocused: false))
                }
                appMuted = call?.muted
                guard let call else { sendNow(); return "mic unreadable: not watched" }
                guard call.muted else { sendNow(); return "muting: not watched" }
                // 2. Nothing open before the press.
                let before = dialogs(in: [call.window], budget: 0.3)
                sendNow()
                guard before.complete else { return "window too large to check: not watched" }
                guard before.found.isEmpty else { return "an alert was already open: not touched" }
                // 3. Watch what the press opens.
                let deadline = Date().addingTimeInterval(1.5)
                while Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.1)
                    let now = dialogs(in: [call.window], budget: 0.3)
                    if now.found.isEmpty {
                        if MeetingTracker.micState(in: call.window) == false { return "unmuted without an alert" }
                        continue
                    }
                    guard now.found.count == 1 else { return "\(now.found.count) alerts: not touched" }
                    let (dialog, kind) = now.found[0]
                    guard let main = mainButton(in: dialog) else { continue }  // still rendering
                    return activate(main, app: ax, pid: pid)
                        ? "pressed the main button (\(kind))" : "couldn't focus the main button (\(kind)): not touched"
                }
                return nil
            }
            if !didSend {
                let muted = appMuted
                DispatchQueue.main.async { MainActor.assumeIsolated { send(); sent(muted) } }
            }
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            log.notice("Teams dialog: \(outcome ?? "no alert shown", privacy: .public) (\(ms) ms)")
        }
    }

    /// Presses a button as a keyboard user would: focus it, check that Teams' focus really is on
    /// it, then send Space to Teams. AXPress doesn't work there (measured 2026-11-17: it reports
    /// success and the alert stays; focus + Space closed it). Focus elsewhere = nothing sent.
    private static func activate(_ button: AXUIElement, app: AXUIElement, pid: pid_t) -> Bool {
        AXUIElementSetAttributeValue(button, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        for _ in 0..<5 {
            Thread.sleep(forTimeInterval: 0.05)
            var focused: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
                  let focused, CFGetTypeID(focused) == AXUIElementGetTypeID(),
                  CFEqual(focused, button) else { continue }
            DispatchQueue.main.sync { MainActor.assumeIsolated { EventPoster.key(49, toPid: pid) } }  // Space
            return true
        }
        return false
    }

    /// The window holding the call's mic button, and whether it's muted.
    private static func callWindow(in windows: [AXUIElement]) -> (window: AXUIElement, muted: Bool)? {
        for window in windows {
            if let muted = MeetingTracker.micState(in: window) { return (window, muted) }
        }
        return nil
    }

    /// Web dialogs (role="dialog" / "alertdialog") reach macOS as AXGroup with these subroles.
    private static let dialogSubroles: Set<String> = ["AXApplicationDialog", "AXApplicationAlertDialog"]

    /// The open web dialogs, with their subrole; `complete` = the whole tree was read within the
    /// node and time budget. Dialogs aren't searched inside.
    private static func dialogs(in roots: [AXUIElement], budget: TimeInterval)
        -> (found: [(AXUIElement, String)], complete: Bool) {
        let deadline = Date().addingTimeInterval(budget)
        var found: [(AXUIElement, String)] = []
        var queue = roots
        var index = 0
        while index < queue.count {
            guard index < 4000, Date() < deadline else { return (found, false) }
            let element = queue[index]
            index += 1
            if let subrole = string(element, kAXSubroleAttribute), dialogSubroles.contains(subrole) {
                found.append((element, subrole))
                continue
            }
            queue.append(contentsOf: children(element))
        }
        return (found, true)
    }

    /// The last button of the dialog's action row, when that row (the last button's siblings)
    /// has exactly two labelled buttons. A close "X" in the title sits in another row.
    private static func mainButton(in dialog: AXUIElement) -> AXUIElement? {
        var queue: [(element: AXUIElement, parent: Int)] = [(dialog, -1)]
        var buttons: [(element: AXUIElement, parent: Int)] = []
        var index = 0
        while index < queue.count, index < 400 {
            let (element, _) = queue[index]
            if string(element, kAXRoleAttribute) == kAXButtonRole { buttons.append(queue[index]) }
            queue.append(contentsOf: children(element).map { ($0, index) })
            index += 1
        }
        guard let last = buttons.last else { return nil }
        let row = buttons.filter { $0.parent == last.parent }
        guard row.count == 2, row.allSatisfy({ hasLabel($0.element) }) else { return nil }
        return last.element
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value as? String : nil
    }

    private static func hasLabel(_ element: AXUIElement) -> Bool {
        [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].contains { string(element, $0)?.isEmpty == false }
    }
}

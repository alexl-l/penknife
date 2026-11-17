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
/// 2. no alert open in that window, and the window fully read → send the shortcut, which Teams
///    ignores while it waits for consent: then, after 0.6 s, Teams comes forward and its mic
///    button is pressed (see `press`);
/// 3. for up to 1.5 s: if the mic shows open, the unmute went through without consent → stop;
///    if exactly one new alert shows in that window, with a two-button action row, before the
///    mic ever showed open → press its last button (focus + Space; AXPress does nothing in
///    Teams). Anything else = nothing pressed.
/// Never camera or screen sharing. Only the outcome is logged, never text.
nonisolated enum TeamsConsent {
    static let enabledKey = "microphone.teamsConsent"
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    private static let log = Logger(subsystem: "Penknife", category: "Microphone")

    /// Unmutes the call so that Teams' consent alert, when the meeting asks for one, shows and is
    /// answered. Teams ignores its mute shortcut while a meeting waits for consent and opens the
    /// alert only for its own mic button (measured on the work Mac, 2026-11-17: 5 shortcut presses,
    /// no alert, still muted; once accepted, the shortcut works again). The button can be pressed
    /// only while Teams is the active app (behind, Teams reports no focus: measured 2026-11-17).
    /// So (user's choice, 2026-11-17): always the shortcut, which leaves the focus alone; if 0.6 s
    /// later the mic is still muted and no alert showed (Teams ignored it: a consent meeting, once
    /// per meeting), Teams comes forward with the call's window, the button is pressed, the alert
    /// answered, and the user's app, Teams window and focused element come back. Pressing the
    /// button on every unmute was dropped: while it holds the focus (~0.3 s), fast typing in the
    /// chat lost letters (user, 2026-11-17). Normal meetings never move Teams or its focus.
    /// `sent` gets the call's mic state read before the press (nil = unreadable), on the main
    /// thread, right after the first press.
    @MainActor static func press(_ app: NSRunningApplication, send: @escaping @MainActor () -> Void,
                                 sent: @escaping @MainActor (Bool?) -> Void) {
        let pid = app.processIdentifier
        let chromium = MeetingTracker.isChromium(app)
        let previousApp = NSWorkspace.shared.frontmostApplication?.processIdentifier
        DispatchQueue.global(qos: .userInitiated).async {
            let start = Date()
            var didSend = false
            var appMuted: Bool?
            var via = "shortcut"
            var broughtForward = false
            var previousWindow: AXUIElement?
            var restoreFocus: AXUIElement?
            let outcome = MeetingTracker.withWebTree(pid: pid, chromium: chromium) { ax, freshTree -> String? in
                // Put Teams back as the user had it (window, then the focused element, e.g. the
                // chat box: left on the mic button, their next Space would toggle the mic). Inside
                // the session: web elements die when the web tree is turned off.
                defer {
                    if !broughtForward, previousWindow != nil || restoreFocus != nil {
                        Thread.sleep(forTimeInterval: 0.15)  // Teams handles the Space first
                        if let previousWindow { raise(previousWindow) }
                        if let restoreFocus {
                            AXUIElementSetAttributeValue(restoreFocus, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                        }
                    }
                }
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
                // 3. Watch what the press opens; a shortcut Teams ignored gets the button.
                var why = ""
                var buttonAt: Date? = Date().addingTimeInterval(0.6)
                var deadline = Date().addingTimeInterval(1.5)
                while Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.1)
                    let now = dialogs(in: [call.window], budget: 0.3)
                    if now.found.isEmpty {
                        let state = MeetingTracker.micState(in: call.window)
                        if state == false { return "unmuted without an alert" }
                        guard let at = buttonAt, Date() >= at, state == true else { continue }
                        buttonAt = nil
                        if !isFrontmost(pid) {
                            guard bringForward(pid) else { return "shortcut ignored; Teams didn't come forward" }
                            broughtForward = true
                        } else {
                            restoreFocus = focusedElement(ax).flatMap { CFEqual($0, call.button) ? nil : $0 }
                        }
                        if let focused = focusedWindow(ax), !CFEqual(focused, call.window) {
                            previousWindow = focused
                            raise(call.window)
                        }
                        // Read again right before the Space: a late shortcut must not be undone.
                        guard activate(call.button, app: ax, pid: pid, why: &why,
                                       onlyIf: { MeetingTracker.micState(in: call.window) == true }) else {
                            if why == changedMeanwhile { continue }
                            return "shortcut ignored; mic button not focused (\(why))"
                        }
                        via = "shortcut ignored, then mic button"
                        deadline = Date().addingTimeInterval(1.5)
                        continue
                    }
                    guard now.found.count == 1 else { return "\(now.found.count) alerts: not touched" }
                    let (dialog, kind) = now.found[0]
                    guard let main = mainButton(in: dialog) else { continue }  // still rendering
                    if !isFrontmost(pid) {
                        guard bringForward(pid) else { return "alert (\(kind)) shown; Teams didn't come forward: not touched" }
                        broughtForward = true
                    }
                    return activate(main, app: ax, pid: pid, why: &why)
                        ? "pressed the main button (\(kind))" : "couldn't focus the main button (\(kind), \(why)): not touched"
                }
                return nil
            }
            if !didSend {
                let muted = appMuted
                DispatchQueue.main.async { MainActor.assumeIsolated { send(); sent(muted) } }
            }
            // Give the user back the app they had in front, once Teams has handled the Space.
            if broughtForward, let previousApp {
                Thread.sleep(forTimeInterval: 0.15)
                DispatchQueue.main.sync {
                    MainActor.assumeIsolated {
                        // Only if the user hasn't moved on to another app meanwhile.
                        if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
                            _ = NSRunningApplication(processIdentifier: previousApp)?.activate()
                        }
                    }
                }
            }
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            log.notice("Teams dialog: \(outcome ?? "no alert shown", privacy: .public) via \(via, privacy: .public)\(broughtForward ? ", Teams brought forward" : "", privacy: .public) (\(ms) ms)")
        }
    }

    private static func isFrontmost(_ pid: pid_t) -> Bool {
        DispatchQueue.main.sync {
            MainActor.assumeIsolated { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid }
        }
    }

    /// Activates Teams and waits (≤ 1 s) until it is in front.
    private static func bringForward(_ pid: pid_t) -> Bool {
        DispatchQueue.main.sync {
            MainActor.assumeIsolated { _ = NSRunningApplication(processIdentifier: pid)?.activate() }
        }
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.05)
            if isFrontmost(pid) {
                Thread.sleep(forTimeInterval: 0.1)  // its key window settles
                return true
            }
        }
        return false
    }

    private static func focusedElement(_ app: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func focusedWindow(_ app: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// Makes a Teams window its front, key window.
    private static func raise(_ window: AXUIElement) {
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        Thread.sleep(forTimeInterval: 0.1)
    }

    /// Presses a button as a keyboard user would: focus it, check that Teams' focus really is on
    /// it, then send Space to Teams. AXPress doesn't work there (measured 2026-11-17: it reports
    /// success and the alert stays; focus + Space closed it). Focus elsewhere = nothing sent.
    /// `why`: on failure, the set's AX result and where Teams' focus was (role/subrole only), or
    /// `changedMeanwhile` when `onlyIf`, checked right before the Space, says no.
    private static let changedMeanwhile = "changed meanwhile"

    private static func activate(_ button: AXUIElement, app: AXUIElement, pid: pid_t, why: inout String,
                                 onlyIf: (() -> Bool)? = nil) -> Bool {
        let set = AXUIElementSetAttributeValue(button, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        var focusOn = "nothing"
        for _ in 0..<5 {
            Thread.sleep(forTimeInterval: 0.05)
            var focused: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
                  let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { focusOn = "nothing"; continue }
            let element = focused as! AXUIElement
            guard CFEqual(element, button) else {
                focusOn = [string(element, kAXRoleAttribute), string(element, kAXSubroleAttribute)]
                    .compactMap { $0 }.joined(separator: "/")
                continue
            }
            if let onlyIf, !onlyIf() {
                why = changedMeanwhile
                return false
            }
            DispatchQueue.main.sync { MainActor.assumeIsolated { EventPoster.key(49, toPid: pid) } }  // Space
            return true
        }
        why = "set \(set.rawValue), focus on \(focusOn.isEmpty ? "unnamed" : focusOn)"
        return false
    }

    /// The window holding the call's mic button, the button, and whether it's muted.
    private static func callWindow(in windows: [AXUIElement])
        -> (window: AXUIElement, button: AXUIElement, muted: Bool)? {
        for window in windows {
            if let found = MeetingTracker.micButton(in: window) { return (window, found.element, found.muted) }
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

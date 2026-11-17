import AppKit
import os

/// R-31: Teams' "Do you agree to the use of your audio and video?" dialog, which shows when the
/// user unmutes in a meeting with recording consent. With the option on, Penknife presses "Yes"
/// only right after ITS OWN unmute shortcut was sent to Teams (the dialog says unmuting = agreeing),
/// only when the dialog's text matches exactly, and never "No", the camera or screen sharing.
/// Nothing is stored or logged but whether it was found.
nonisolated enum TeamsConsent {
    static let enabledKey = "microphone.teamsConsent"
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// Teams' question, exactly as it shows (user, 2026-11-17; English Teams). Compared
    /// lowercased with spaces trimmed; any other text = do nothing.
    static let questions: Set<String> = ["do you agree to the use of your audio and video?"]
    /// Its explanation must be in the same container (security review: a lone question could be
    /// a chat message or a card someone sent).
    static let bodyPrefixes = ["by unmuting, turning on your camera, or sharing your screen, you agree"]
    static let yesLabels: Set<String> = ["yes"]
    static let noLabels: Set<String> = ["no"]

    private static let log = Logger(subsystem: "Penknife", category: "Microphone")

    /// Looks for the dialog in Teams for up to ~2 s after the unmute shortcut (it takes a moment
    /// to show) and presses "Yes" if it's there. Off the main thread; runs only at that press.
    @MainActor static func answerAfterUnmute(_ app: NSRunningApplication) {
        guard isEnabled else { return }
        let pid = app.processIdentifier
        let chromium = MeetingTracker.isChromium(app)
        DispatchQueue.global(qos: .userInitiated).async {
            let start = Date()
            let deadline = start.addingTimeInterval(2.5)
            var proof = ""
            let pressed = MeetingTracker.withWebTree(pid: pid, chromium: chromium) { app, _ -> Bool? in
                var first = true
                while Date() < deadline {
                    if !first { Thread.sleep(forTimeInterval: 0.17) }
                    first = false
                    let windows = MeetingTracker.meetingWindows(app, onlyFocused: false)
                    if let (yes, how) = findYes(in: windows, deadline: deadline) {
                        proof = how
                        return AXUIElementPerformAction(yes, kAXPressAction as CFString) == .success
                    }
                }
                return nil
            }
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            switch pressed {
            case true?: log.notice("Teams dialog: pressed Yes (\(proof, privacy: .public), \(ms) ms)")
            case false?: log.error("Teams dialog: found (\(proof, privacy: .public)), but pressing Yes failed (\(ms) ms)")
            case nil: log.notice("Teams dialog: not shown (\(ms) ms)")
            }
        }
    }

    /// Breadth-first walk, bounded in nodes and time. When the question is found, its nearest
    /// ancestors (up to 8 levels) are searched for the smallest container with exactly one "Yes"
    /// and one "No" button that is either the alert itself (a dialog to Accessibility; user,
    /// 2026-11-17: it's an alert) or holds Teams' default explanation (in case the alert isn't
    /// exposed as one). The organizer's admin can replace that explanation (Microsoft docs), so
    /// the dialog check is what makes custom texts work. More buttons, or the dialog's edge
    /// reached without a match = nothing.
    private static func findYes(in roots: [AXUIElement], deadline: Date) -> (AXUIElement, String)? {
        var queue: [(element: AXUIElement, parent: Int)] = roots.map { ($0, -1) }
        var index = 0
        while index < queue.count, index < 3000, Date() < deadline {
            let (element, _) = queue[index]
            if let text = text(of: element), questions.contains(normalized(text)) {
                var ancestor = queue[index].parent
                for _ in 0..<8 where ancestor >= 0 {
                    switch dialogButtons(under: queue[ancestor].element) {
                    case .found(let yes, let how): return (yes, how)
                    case .tooWide: return nil
                    case .notYet: ancestor = queue[ancestor].parent
                    }
                }
                return nil
            }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
               let children = children as? [AXUIElement] {
                queue.append(contentsOf: children.map { ($0, index) })
            }
            index += 1
        }
        return nil
    }

    /// `how` names the proof for the log: the dialog's role/subrole, or "default text".
    private enum Container { case found(AXUIElement, how: String), notYet, tooWide }

    private static func dialogButtons(under root: AXUIElement) -> Container {
        let dialog = dialogKind(root)
        let isDialog = dialog != nil
        var yes: [AXUIElement] = []
        var noCount = 0
        var hasBody = false
        var queue = [root]
        var index = 0
        while index < queue.count, index < 400 {
            let element = queue[index]
            index += 1
            if let label = text(of: element).map(normalized) {
                if role(of: element) == kAXButtonRole {
                    if yesLabels.contains(label) { yes.append(element) }
                    if noLabels.contains(label) { noCount += 1 }
                } else if bodyPrefixes.contains(where: label.hasPrefix) {
                    hasBody = true
                }
            }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
               let children = children as? [AXUIElement] {
                queue.append(contentsOf: children)
            }
        }
        if yes.count > 1 || noCount > 1 { return .tooWide }
        if yes.count == 1, noCount == 1, let how = dialog ?? (hasBody ? "default text" : nil) {
            return .found(yes[0], how: how)
        }
        return isDialog ? .tooWide : .notYet
    }

    /// Web dialogs (role="dialog" / "alertdialog") reach macOS as AXGroup with these subroles;
    /// a native sheet or dialog window keeps its own role or subrole.
    private static let dialogRoles: Set<String> = ["AXSheet", "AXDialog"]
    private static let dialogSubroles: Set<String> = ["AXApplicationAlertDialog", "AXApplicationDialog",
                                                      "AXDialog", "AXSystemDialog"]

    private static func dialogKind(_ element: AXUIElement) -> String? {
        if let role = role(of: element), dialogRoles.contains(role) { return role }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &value) == .success,
              let subrole = value as? String, dialogSubroles.contains(subrole) else { return nil }
        return subrole
    }

    private static func role(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success ? value as? String : nil
    }

    /// Title, value or description: web text shows up in any of them.
    private static func text(of element: AXUIElement) -> String? {
        let names = [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute] as CFArray
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, names, [], &values) == .success,
              let values = values as? [Any] else { return nil }
        return values.lazy.compactMap { $0 as? String }.first { !$0.isEmpty }
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

import AppKit
import CoreAudio
import KeyboardShortcuts
import os

/// Meeting platforms whose mute shortcut Penknife can press (R-28). The shortcut is the one the
/// user set inside that app; it's recorded in Settings and only sent, never registered globally.
nonisolated enum MeetingPlatform: String, CaseIterable, Identifiable {
    case teams, meet, zoom, slack, webex

    var id: String { rawValue }

    /// Brand names, not translated.
    var name: String {
        switch self {
        case .teams: "Microsoft Teams"
        case .meet: "Google Meet"
        case .zoom: "Zoom"
        case .slack: "Slack Huddles"
        case .webex: "Cisco Webex"
        }
    }

    @MainActor var shortcut: KeyboardShortcuts.Name {
        switch self {
        case .teams: .meetingTeams
        case .meet: .meetingMeet
        case .zoom: .meetingZoom
        case .slack: .meetingSlack
        case .webex: .meetingWebex
        }
    }

    /// Desktop apps. Meet has none.
    var bundleIDs: [String] {
        switch self {
        case .teams: ["com.microsoft.teams2", "com.microsoft.teams"]
        case .meet: []
        case .zoom: ["us.zoom.xos"]
        case .slack: ["com.tinyspeck.slackmacgap"]
        case .webex: ["Cisco-Systems.Spark", "com.webex.meetingmanager"]
        }
    }

    /// Meeting pages, told by the browser window's title (the active tab's title), the one signal
    /// every browser gives: Firefox has no AppleScript for tabs and Opera's is unreliable
    /// (user, 2026-11-16: Chrome, Chrome Dev, Opera, Safari and Firefox). Only checked for a
    /// browser that is using the microphone.
    func matches(title: String) -> Bool {
        // The brand must be a whole part of the title ("Meet - abc-defg-hij", "Chat | Microsoft
        // Teams"), not any word in it, so a tab called "Slack tips" doesn't count.
        let parts = title.lowercased()
            .components(separatedBy: CharacterSet(charactersIn: "-–—|·"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let names: Set<String> = switch self {
        case .teams: ["microsoft teams"]
        case .meet: ["meet", "google meet"]
        case .zoom: ["zoom", "zoom meeting", "zoom workplace"]
        case .slack: ["slack"]
        case .webex: ["webex", "cisco webex"]
        }
        if parts.contains(where: names.contains) { return true }
        // A Meet call's title is often only its code, "abc-defg-hij", split above by the dashes.
        return self == .meet && title.range(of: #"\b[a-z]{3}-[a-z]{4}-[a-z]{3}\b"#, options: .regularExpression) != nil
    }

    private var enabledKey: String { "meeting.\(rawValue).enabled" }

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Fallback symbol when the app isn't installed (Meet has no app).
    var symbol: String {
        switch self {
        case .teams: "person.2.fill"
        case .meet: "video.fill"
        case .zoom: "video.circle.fill"
        case .slack: "number"
        case .webex: "globe"
        }
    }

    static func forApp(_ bundleID: String?) -> MeetingPlatform? {
        guard let bundleID else { return nil }
        return allCases.first { $0.bundleIDs.contains(bundleID) }
    }
}

/// Default mute shortcuts of each app.
extension KeyboardShortcuts.Name {
    static let meetingTeams = Self("meetingTeams", default: .init(.m, modifiers: [.command, .shift]))
    static let meetingMeet = Self("meetingMeet", default: .init(.d, modifiers: [.command]))
    static let meetingZoom = Self("meetingZoom", default: .init(.a, modifiers: [.command, .shift]))
    static let meetingSlack = Self("meetingSlack", default: .init(.space, modifiers: [.command, .shift]))
    static let meetingWebex = Self("meetingWebex", default: .init(.m, modifiers: [.command, .shift]))
}

/// Finds the current meeting: the meeting app or meeting tab in front, else the last one that
/// was in front. Remembers recently activated apps with one workspace notification (no polling).
final class MeetingTracker {
    struct Target: @unchecked Sendable {
        let platform: MeetingPlatform
        let app: NSRunningApplication
        let isBrowser: Bool
    }

    private let log = Logger(subsystem: "Penknife", category: "Microphone")
    private var observer: NSObjectProtocol?
    /// Recently activated meeting apps and browsers, most recent first.
    private var recent: [NSRunningApplication] = []

    nonisolated static let browsers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.dev", "com.google.Chrome.beta", "com.google.Chrome.canary",
        "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser",
        "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "com.operasoftware.Opera", "com.operasoftware.OperaGX",
        "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly",
    ]

    func start() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.remember(app) }
        }
    }

    func stop() {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
        recent = []
    }

    private func remember(_ app: NSRunningApplication) {
        guard Self.isCandidate(app) else { return }
        recent.removeAll { $0.processIdentifier == app.processIdentifier }
        recent.insert(app, at: 0)
        if recent.count > 6 { recent.removeLast() }
    }

    private static func isCandidate(_ app: NSRunningApplication) -> Bool {
        guard let id = app.bundleIdentifier else { return false }
        return browsers.contains(id) || MeetingPlatform.forApp(id) != nil
    }

    /// Calls `completion` on the main thread with the current meeting, or nil. Only an app that is
    /// IN A CALL counts (user, 2026-11-16: an open Teams is not a meeting): it must be using the
    /// microphone right now (what lights macOS's orange dot). With several calls, the one in front
    /// or the last one used wins. Reading a browser's active tab uses Apple Events, so this runs
    /// off the main thread.
    func findCurrent(_ completion: @escaping @MainActor @Sendable (Target?) -> Void) {
        let usingMic = Self.appsUsingMicrophone()
        var candidates = recent.filter { !$0.isTerminated }
        if let front = NSWorkspace.shared.frontmostApplication, Self.isCandidate(front) {
            candidates.removeAll { $0.processIdentifier == front.processIdentifier }
            candidates.insert(front, at: 0)
        }
        // Calls in apps that were never in front still count, after the recent ones.
        for app in NSWorkspace.shared.runningApplications where Self.isCandidate(app)
            && !candidates.contains(where: { $0.processIdentifier == app.processIdentifier }) {
            candidates.append(app)
        }
        let callPIDs = Set(usingMic.map(\.appPID))
        candidates = candidates.filter { callPIDs.contains($0.processIdentifier) }
        let log = log
        let calls = candidates
        log.notice("Recording: \(usingMic.map(\.bundleID).joined(separator: ", "), privacy: .public); in a call: \(candidates.compactMap(\.bundleIdentifier).joined(separator: ", "), privacy: .public)")
        DispatchQueue.global(qos: .userInitiated).async {
            var found: Target?
            for app in calls {
                guard let id = app.bundleIdentifier else { continue }
                if let platform = MeetingPlatform.forApp(id) {
                    if platform.isEnabled { found = Target(platform: platform, app: app, isBrowser: false); break }
                    continue
                }
                guard let title = Self.windowTitle(pid: app.processIdentifier, log: log),
                      let platform = MeetingPlatform.allCases.first(where: { $0.isEnabled && $0.matches(title: title) }) else { continue }
                found = Target(platform: platform, app: app, isBrowser: true)
                break
            }
            let result = found
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// A process recording from a microphone, and the app it works for.
    struct MicUser: Sendable {
        let bundleID: String
        let appPID: pid_t
    }

    /// The processes recording from any microphone now (CoreAudio process objects, macOS 14.2+).
    /// They are often helpers whose bundle ID doesn't name the app (measured 2026-11-16: Chrome
    /// Dev records as "com.google.Chrome.helper", Safari as "com.apple.WebKit.GPU", which Mail and
    /// Teams also use), so each is mapped to its responsible app, as macOS's privacy checks do.
    static func appsUsingMicrophone() -> [MicUser] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &processes) == noErr else { return [] }
        return processes.compactMap { process in
            guard let running: UInt32 = property(process, kAudioProcessPropertyIsRunningInput), running != 0,
                  let pid: pid_t = property(process, kAudioProcessPropertyPID) else { return nil }
            var bundleID: Unmanaged<CFString>?
            var idSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var idAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
                                                       mScope: kAudioObjectPropertyScopeGlobal,
                                                       mElement: kAudioObjectPropertyElementMain)
            let id = AudioObjectGetPropertyData(process, &idAddress, 0, nil, &idSize, &bundleID) == noErr
                ? (bundleID?.takeRetainedValue() as String?) ?? "" : ""
            return MicUser(bundleID: id, appPID: responsiblePID(pid))
        }
    }

    private static func property<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer) == noErr else { return nil }
        return pointer.pointee
    }

    /// libsystem's responsibility lookup (private, stable since macOS 10.14; what TCC uses to
    /// charge a helper's access to its app). Without it, a process stands for itself.
    private typealias ResponsibleFunction = @convention(c) (pid_t) -> pid_t
    nonisolated(unsafe) private static let responsible: ResponsibleFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: ResponsibleFunction.self)
    }()

    private static func responsiblePID(_ pid: pid_t) -> pid_t {
        guard let responsible else { return pid }
        let owner = responsible(pid)
        return owner > 0 ? owner : pid
    }

    /// Title of the browser's focused window = its active tab's title. Accessibility, which the
    /// shortcut already needs; works in every browser. Never logged (it can name the meeting).
    nonisolated private static func windowTitle(pid: pid_t, log: Logger) -> String? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var window: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, attribute as CFString, &window) == .success,
                  let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { continue }
            var title: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title)
            if status == .success, let title = title as? String, !title.isEmpty { return title }
        }
        log.error("No window title for browser pid \(pid, privacy: .public)")
        return nil
    }

    // MARK: Reading the meeting's own mic button (R-28, option A)

    /// Calls `completion` on the main thread with whether the meeting's microphone is muted in the
    /// app, read once from its mic button through Accessibility; nil when it can't be read
    /// (unknown language, changed UI, Firefox…), and the caller then sends the shortcut blind.
    /// Never watched between presses (user, 2026-11-16: no constant watching).
    func readMuted(_ target: Target, _ completion: @escaping @MainActor @Sendable (Bool?) -> Void) {
        let pid = target.app.processIdentifier
        let onlyFocused = target.isBrowser
        let chromium = Self.isChromium(target.app)
        let log = log
        DispatchQueue.global(qos: .userInitiated).async {
            let start = Date()
            var stats = (windows: 0, nodes: 0, roles: Set<String>())
            let muted = Self.micButtonState(pid: pid, onlyFocusedWindow: onlyFocused, chromium: chromium, stats: &stats)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            log.notice("App mic: \(muted.map { $0 ? "muted" : "open" } ?? "unreadable", privacy: .public) (\(ms) ms, \(stats.windows) windows, \(stats.nodes) elements; roles: \(stats.roles.sorted().joined(separator: " "), privacy: .public))")
            DispatchQueue.main.async { completion(muted) }
        }
    }

    /// Chromium and Electron apps (Teams, Slack) only build the accessibility tree of their web
    /// content when asked with `AXManualAccessibility`.
    static func isChromium(_ app: NSRunningApplication) -> Bool {
        guard let id = app.bundleIdentifier else { return false }
        if id.hasPrefix("org.mozilla.") || id.hasPrefix("com.apple.") { return false }
        return browsers.contains(id) || MeetingPlatform.forApp(id) != nil
    }

    nonisolated private static let manualAccessibility = "AXManualAccessibility"
    nonisolated private static let enhancedUserInterface = "AXEnhancedUserInterface"

    nonisolated private static func micButtonState(pid: pid_t, onlyFocusedWindow: Bool, chromium: Bool,
                                                   stats: inout (windows: Int, nodes: Int, roles: Set<String>)) -> Bool? {
        withWebTree(pid: pid, chromium: chromium) { app, freshTree in
            let windows = meetingWindows(app, onlyFocused: onlyFocusedWindow)
            stats.windows = windows.count
            // Chrome builds its web tree when a client asks for an element's attribute names (what
            // the probe that worked did), not on a plain walk.
            for window in windows {
                var names: CFArray?
                AXUIElementCopyAttributeNames(window, &names)
            }
            if let found = search(windows, nodes: &stats.nodes, roles: &stats.roles) { return found.muted }
            // A tree that was just turned on is built asynchronously: look again for up to ~1 s.
            guard freshTree else { return nil }
            for _ in 0..<5 {
                Thread.sleep(forTimeInterval: 0.2)
                if let found = search(windows, nodes: &stats.nodes, roles: &stats.roles) { return found.muted }
            }
            return nil
        }
    }

    /// Runs `body` with the app's web accessibility tree on, and turns it off after, unless
    /// someone (VoiceOver) had it on already: it costs the app CPU and RAM while it's on
    /// (measured: +80 MB, freed after). Electron apps (Teams, Slack) open their web tree with
    /// AXManualAccessibility; Chrome ignores that one and opens it with AXEnhancedUserInterface
    /// (what VoiceOver sets). Both answer the set with an error yet act on it (measured), so each
    /// one that wasn't on is set and cleared after: left on, the tree costs RAM and Chrome
    /// animates windows worse. `body` gets whether the tree was just turned on (built async).
    nonisolated static func withWebTree<T>(pid: pid_t, chromium: Bool, _ body: (AXUIElement, Bool) -> T?) -> T? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var enabledHere: [String] = []
        if chromium {
            for attribute in [manualAccessibility, enhancedUserInterface] {
                var current: CFTypeRef?
                let wasOn = AXUIElementCopyAttributeValue(app, attribute as CFString, &current) == .success
                    && (current as? Bool) == true
                guard !wasOn else { continue }
                AXUIElementSetAttributeValue(app, attribute as CFString, kCFBooleanTrue)
                enabledHere.append(attribute)
            }
        }
        defer {
            for attribute in enabledHere { AXUIElementSetAttributeValue(app, attribute as CFString, kCFBooleanFalse) }
        }
        // Chrome also builds it when a client asks for the focused element.
        var focused: CFTypeRef?
        AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused)
        return body(app, !enabledHere.isEmpty)
    }

    /// The meeting's mic state read in one window (true = muted), nil when its button isn't
    /// there (another window, or hidden behind a modal alert, which hides the rest of the page).
    nonisolated static func micState(in window: AXUIElement) -> Bool? {
        micButton(in: window)?.muted
    }

    /// The meeting's mic button in one window and its state (true = muted); nil as `micState`.
    nonisolated static func micButton(in window: AXUIElement) -> (element: AXUIElement, muted: Bool)? {
        var names: CFArray?
        AXUIElementCopyAttributeNames(window, &names)
        var nodes = 0
        var roles = Set<String>()
        return search([window], nodes: &nodes, roles: &roles)
    }

    /// A browser: only its focused window (the meeting tab, told by its title). An app: the
    /// focused window first, then the others (a Teams call can live in its own window).
    nonisolated static func meetingWindows(_ app: AXUIElement, onlyFocused: Bool) -> [AXUIElement] {
        func element(_ attribute: String) -> AXUIElement? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, attribute as CFString, &value) == .success,
                  let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement)
        }
        let focused = element(kAXFocusedWindowAttribute) ?? element(kAXMainWindowAttribute)
        if onlyFocused { return focused.map { [$0] } ?? [] }
        var all: CFTypeRef?
        let windows = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &all) == .success
            ? (all as? [AXUIElement]) ?? [] : []
        guard let focused else { return windows }
        return [focused] + windows.filter { !CFEqual($0, focused) }
    }

    /// Breadth-first look for the mic button, one Accessibility call per element, bounded so an
    /// unexpected page can't make a press slow. Only buttons inside the web content count: Safari's
    /// own toolbar has a "microphone in use" button whose name matches the labels and always says
    /// open, which hid Meet's button (measured 2026-11-17: the walk stopped at element 40).
    nonisolated private static func search(_ roots: [AXUIElement], nodes: inout Int, roles: inout Set<String>)
        -> (element: AXUIElement, muted: Bool)? {
        let names = [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute] as CFArray
        var queue = roots.map { ($0, 0, false) }
        var index = 0
        while index < queue.count, index < 6000 {
            let (element, depth, inWeb) = queue[index]
            index += 1
            nodes = index
            var values: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(element, names, [], &values) == .success,
                  let values = values as? [Any], values.count == 3 else { continue }
            let role = values[0] as? String
            let label = (values[1] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? values[2] as? String
            let inside = inWeb || role == "AXWebArea"
            if inside, role == kAXButtonRole || role == kAXCheckBoxRole, let label, let state = state(fromLabel: label) {
                return (element, state)
            }
            if let role { roles.insert(role) }
            // Children one by one (Chrome's web area doesn't hand them out in a multi-value call;
            // the probe that worked read them this way).
            var children: CFTypeRef?
            if depth < 40, AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
               let children = children as? [AXUIElement] {
                queue.append(contentsOf: children.map { ($0, depth + 1, inside) })
            }
        }
        return nil
    }

    /// The button names the action it will do: "Mute mic" means the mic is open now. Spanish and
    /// English (measured: Teams "Mute mic" / "Unmute mic", Meet "Desactivar micrófono" /
    /// "Activar micrófono", "Turn off microphone" / "Turn on microphone"). True = muted.
    nonisolated static func state(fromLabel label: String) -> Bool? {
        let text = label.lowercased().trimmingCharacters(in: .whitespaces)
        let muted = ["unmute mic", "unmute microphone", "turn on microphone", "activar micrófono",
                     "activar el micrófono", "reactivar micrófono", "reactivar el micrófono"]
        let open = ["mute mic", "mute microphone", "turn off microphone", "desactivar micrófono",
                    "desactivar el micrófono", "silenciar micrófono", "silenciar el micrófono"]
        if muted.contains(where: text.hasPrefix) { return true }
        if open.contains(where: text.hasPrefix) { return false }
        return nil
    }

    /// Presses the platform's mute shortcut in the meeting. Desktop apps get it in the background;
    /// a browser is brought to the front for a moment so the shortcut reaches the meeting tab.
    func send(to target: Target) {
        guard let shortcut = KeyboardShortcuts.getShortcut(for: target.platform.shortcut),
              let keyCode = CGKeyCode(exactly: shortcut.carbonKeyCode) else { return }
        let flags = Self.flags(shortcut.modifiers)
        let pid = target.app.processIdentifier
        let previous = NSWorkspace.shared.frontmostApplication
        guard target.isBrowser, previous?.processIdentifier != pid else {
            EventPoster.key(keyCode, flags: flags, toPid: pid)
            return
        }
        target.app.activate()
        Self.whenFrontmost(pid, tries: 20) { inFront in
            // Never type into another app: if the browser didn't come forward, give up.
            guard inFront else { return }
            EventPoster.key(keyCode, flags: flags, toPid: pid)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                // Return focus only if the user hasn't moved on to another app meanwhile.
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { previous?.activate() }
            }
        }
    }

    /// Checks every 50 ms (up to `tries` times) until the app is in front.
    private static func whenFrontmost(_ pid: pid_t, tries: Int, _ body: @escaping @MainActor (Bool) -> Void) {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { return body(true) }
        guard tries > 0 else { return body(false) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            MainActor.assumeIsolated { whenFrontmost(pid, tries: tries - 1, body) }
        }
    }

    private static func flags(_ modifiers: NSEvent.ModifierFlags) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        return flags
    }
}

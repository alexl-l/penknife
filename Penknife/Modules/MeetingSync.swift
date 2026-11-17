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

    /// Meeting pages in a browser tab.
    func matches(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        switch self {
        case .teams: return ["teams.microsoft.com", "teams.live.com", "teams.cloud.microsoft"].contains(host)
        case .meet: return host == "meet.google.com"
        case .zoom: return host.hasSuffix("zoom.us") && url.path().contains("/wc/")
        case .slack: return host == "app.slack.com"
        case .webex: return host == "webex.com" || host.hasSuffix(".webex.com")
        }
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
        candidates = candidates.filter { app in
            guard let id = app.bundleIdentifier else { return false }
            return usingMic.contains { $0 == id || $0.hasPrefix(id + ".") }
        }
        let log = log
        let calls = candidates
        log.notice("In a call (using the mic): \(candidates.compactMap(\.bundleIdentifier).joined(separator: ", "), privacy: .public)")
        DispatchQueue.global(qos: .userInitiated).async {
            var found: Target?
            for app in calls {
                guard let id = app.bundleIdentifier else { continue }
                if let platform = MeetingPlatform.forApp(id) {
                    if platform.isEnabled { found = Target(platform: platform, app: app, isBrowser: false); break }
                    continue
                }
                guard let url = Self.activeTabURL(bundleID: id, log: log),
                      let platform = MeetingPlatform.allCases.first(where: { $0.isEnabled && $0.matches(url) }) else { continue }
                found = Target(platform: platform, app: app, isBrowser: true)
                break
            }
            let result = found
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Bundle IDs of the processes recording from any microphone now (CoreAudio process objects,
    /// macOS 14.2+). Browser and Teams helpers report their own IDs, e.g. "com.google.Chrome.dev.helper".
    static func appsUsingMicrophone() -> [String] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &processes) == noErr else { return [] }
        return processes.compactMap { process in
            var running: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            var runningAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput,
                                                            mScope: kAudioObjectPropertyScopeGlobal,
                                                            mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(process, &runningAddress, 0, nil, &runningSize, &running) == noErr,
                  running != 0 else { return nil }
            var bundleID: Unmanaged<CFString>?
            var idSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var idAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
                                                       mScope: kAudioObjectPropertyScopeGlobal,
                                                       mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(process, &idAddress, 0, nil, &idSize, &bundleID) == noErr,
                  let id = bundleID?.takeRetainedValue() as String?, !id.isEmpty else { return nil }
            return id
        }
    }

    /// URL of the active tab of the browser's front window. Never launches the browser.
    nonisolated private static func activeTabURL(bundleID: String, log: Logger) -> URL? {
        guard browsers.contains(bundleID) else { return nil }
        let tab = bundleID.hasPrefix("com.apple.Safari") ? "current tab" : "active tab"
        let source = """
        tell application id "\(bundleID)"
          if (count of windows) is 0 then return ""
          return URL of \(tab) of front window
        end tell
        """
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            log.error("Active tab of \(bundleID, privacy: .public): error \(code)")
        }
        return result.flatMap { URL(string: $0) }
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

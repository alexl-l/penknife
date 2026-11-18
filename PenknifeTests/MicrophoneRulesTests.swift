import AppKit
import Foundation
import KeyboardShortcuts
import Testing
@testable import Penknife

/// Microphone rules that can be checked as the code is today (docs/requirements/microphone.md).
/// Each test names the rule it checks. Nothing here changes the microphone, presses keys, uses
/// Accessibility or writes the user's settings.
@MainActor
@Suite("Microphone rules")
struct MicrophoneRulesTests {

    // MIC-11: desktop meeting apps are told by bundle ID; Meet has no app.
    @Test("MIC-11 meeting apps by bundle ID", arguments: [
        ("com.microsoft.teams2", MeetingPlatform.teams),
        ("com.microsoft.teams", .teams),
        ("us.zoom.xos", .zoom),
        ("com.tinyspeck.slackmacgap", .slack),
        ("Cisco-Systems.Spark", .webex),
        ("com.webex.meetingmanager", .webex),
    ])
    func meetingAppByBundleID(bundleID: String, platform: MeetingPlatform) {
        #expect(MeetingPlatform.forApp(bundleID) == platform)
    }

    @Test("MIC-11 other apps are not meeting apps")
    func otherAppsAreNotMeetingApps() {
        #expect(MeetingPlatform.forApp("com.apple.Safari") == nil)
        #expect(MeetingPlatform.forApp("com.google.Chrome") == nil)
        #expect(MeetingPlatform.forApp(nil) == nil)
        #expect(MeetingPlatform.meet.bundleIDs.isEmpty)
    }

    // MIC-17: each platform's default mute shortcut is the app's own standard one.
    @Test("MIC-17 default meeting shortcuts")
    func defaultMeetingShortcuts() {
        let expected: [MeetingPlatform: KeyboardShortcuts.Shortcut] = [
            .teams: .init(.m, modifiers: [.command, .shift]),
            .meet: .init(.d, modifiers: [.command]),
            .zoom: .init(.a, modifiers: [.command, .shift]),
            .slack: .init(.space, modifiers: [.command, .shift]),
            .webex: .init(.m, modifiers: [.command, .shift]),
        ]
        #expect(expected.count == MeetingPlatform.allCases.count)
        for platform in MeetingPlatform.allCases {
            #expect(platform.shortcut.defaultShortcut == expected[platform], "\(platform)")
        }
    }

    // MIC-69 (with MIC-18, MIC-37, MIC-43): what a Mac that never opened Settings gets. Read from an
    // empty suite, never the user's settings (this Mac has hud.duration, teamsConsent and
    // recording.microphone changed, so a leak would fail here).
    @Test("MIC-69 MIC-18 MIC-37 MIC-43 defaults on a fresh Mac")
    func freshDefaults() throws {
        let empty = try #require(UserDefaults(suiteName: "PenknifeTests.empty.\(UUID().uuidString)"))
        let keys = ["module.microphone.enabled", MicrophoneModule.alsoMuteMacKey, MicrophoneModule.keepMutedKey,
                    TeamsConsent.enabledKey, StatusMenu.dotsKey, AlertCategory.microphone.key, HUD.durationKey,
                    RecordingPrefs.micKey] + MeetingPlatform.allCases.map { "meeting.\($0.rawValue).enabled" }
        for key in keys { #expect(empty.object(forKey: key) == nil, "\(key) leaked into the empty suite") }

        #expect(ModuleManager.isOn(.microphone, in: empty))
        #expect(KeyboardShortcuts.Name.toggleMicrophone.defaultShortcut == .init(.f5))
        for platform in MeetingPlatform.allCases { #expect(platform.isEnabled(in: empty), "\(platform)") }
        #expect(MicrophoneModule.alsoMuteMac(in: empty))
        #expect(MicrophoneModule.keepMuted(in: empty))
        #expect(!TeamsConsent.isEnabled(in: empty))
        #expect(StatusMenu.dotsOn(in: empty))
        #expect(AlertCategory.microphone.isShown(in: empty))
        #expect(HUD.duration(in: empty) == 4)
        #expect(!RecordingPrefs.microphone(in: empty))
    }

    // MIC-02: one press = one action. A bare F key also arrives through its Fn twin; only that
    // second twin of the same press is dropped, never a real second press.
    @Test("MIC-02 one press runs once", arguments: [
        (false, 0.05, true),   // same twin again: a real press, however fast
        (true, 0.05, false),   // the other twin right after: the same press
        (true, 0.2, true),     // the other twin later: a new press
    ])
    func onePressRunsOnce(fn: Bool, after seconds: Double, runs: Bool) {
        let press = Date()
        #expect(ModuleManager.shouldRun(last: nil, fn: fn, now: press))
        #expect(ModuleManager.shouldRun(last: (fn: false, at: press), fn: fn, now: press + seconds) == runs)
    }

    // MIC-20: a desktop meeting app gets the recorded modifiers with the key.
    @Test("MIC-20 the shortcut's modifiers are sent")
    func shortcutModifiers() {
        #expect(MeetingTracker.flags([.command, .shift]) == [.maskCommand, .maskShift])
        #expect(MeetingTracker.flags([.option, .control]) == [.maskAlternate, .maskControl])
        #expect(MeetingTracker.flags([.command, .shift, .option, .control])
                == [.maskCommand, .maskShift, .maskAlternate, .maskControl])
        #expect(MeetingTracker.flags([]) == [])
    }

    // MIC-78: the web accessibility tree is on only during the read; one already on (VoiceOver)
    // is never set nor cleared.
    @Test("MIC-78 the web tree is turned on only for the read", arguments: [
        ([], true),
        (["AXManualAccessibility"], true),
        (["AXManualAccessibility", "AXEnhancedUserInterface"], false),
    ] as [(Set<String>, Bool)])
    func webTreeOnlyForTheRead(alreadyOn: Set<String>, fresh: Bool) {
        let all: Set = ["AXManualAccessibility", "AXEnhancedUserInterface"]
        var on = alreadyOn
        var writes: [String] = []
        var duringRead: Set<String> = []
        var sawFresh: Bool?
        let result = MeetingTracker.withWebTreeAttributes(chromium: true, isOn: { on.contains($0) }, set: { attribute, value in
            writes.append(attribute)
            if value { on.insert(attribute) } else { on.remove(attribute) }
        }) { freshTree in
            duringRead = on
            sawFresh = freshTree
            return 7
        }
        #expect(result == 7)
        #expect(duringRead == all)
        #expect(on == alreadyOn)
        #expect(sawFresh == fresh)
        #expect(writes.count == 2 * all.subtracting(alreadyOn).count)
        #expect(Set(writes).isDisjoint(with: alreadyOn))
    }

    @Test("MIC-78 a non-Chromium app's tree is not touched")
    func webTreeNotChromium() {
        var touched = false
        let fresh = MeetingTracker.withWebTreeAttributes(chromium: false, isOn: { _ in touched = true; return false },
                                                          set: { _, _ in touched = true }) { $0 }
        #expect(fresh == false)
        #expect(!touched)
    }

    // MIC-22: IT MUST WORK IN CHROME, CHROME DEV, OPERA, SAFARI AND FIREFOX (user, 2026-11-16).
    @Test("MIC-22 the five required browsers are known")
    func requiredBrowsersAreKnown() {
        for id in ["com.google.Chrome", "com.google.Chrome.dev", "com.operasoftware.Opera",
                   "com.apple.Safari", "org.mozilla.firefox"] {
            #expect(MeetingTracker.browsers.contains(id), "\(id)")
        }
    }

    // MIC-24: a browser tab is a meeting when a whole part of its title is the brand, or the
    // title holds a Meet code; a word inside another phrase ("Slack tips") doesn't count.
    nonisolated static let titles: [(title: String, platforms: Set<MeetingPlatform>)] = [
        ("Meet - abc-defg-hij", [.meet]),
        ("abc-defg-hij", [.meet]),
        ("Google Meet", [.meet]),
        ("Chat | Microsoft Teams", [.teams]),
        ("Zoom Workplace", [.zoom]),
        ("Zoom Meeting", [.zoom]),
        ("Huddle - Slack", [.slack]),
        ("Cisco Webex", [.webex]),
        ("Slack tips", []),
        ("Inbox - Gmail", []),
        ("Teams", []),
    ]

    @Test("MIC-24 meeting told by the tab title", arguments: titles)
    func meetingByTitle(case: (title: String, platforms: Set<MeetingPlatform>)) {
        let matched = Set(MeetingPlatform.allCases.filter { $0.matches(title: `case`.title) })
        #expect(matched == `case`.platforms, "\(`case`.title)")
    }

    // MIC-30: the call's mic button is read by its label, English and Spanish, case-insensitive
    // prefix (true = muted).
    @Test("MIC-30 mic state from the button label", arguments: [
        ("Unmute mic", true as Bool?),
        ("Unmute mic (⌘⇧M)", true),
        ("Unmute microphone", true),
        ("Turn on microphone", true),
        ("Activar micrófono", true),
        ("ACTIVAR EL MICRÓFONO", true),
        ("Reactivar micrófono", true),
        ("Mute mic", false),
        ("Mute microphone", false),
        ("Turn off microphone (ctrl + d)", false),
        ("Desactivar micrófono", false),
        ("Silenciar el micrófono", false),
        ("Mic settings", nil),
        ("Microphone", nil),
        ("", nil),
    ])
    func micStateFromLabel(label: String, muted: Bool?) {
        #expect(MeetingTracker.state(fromLabel: label) == muted)
    }

    // MIC-71: every visible string has a Spanish translation (checked over the whole catalog).
    @Test("MIC-71 every string has Spanish", arguments: ["Localizable.xcstrings", "InfoPlist.xcstrings"])
    func everyStringHasSpanish(catalog: String) throws {
        let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Penknife/Resources/\(catalog)")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let strings = try #require(json["strings"] as? [String: [String: Any]])
        #expect(!strings.isEmpty)
        var missing: [String] = []
        for (key, entry) in strings where entry["shouldTranslate"] as? Bool != false {
            let spanish = (entry["localizations"] as? [String: Any])?["es"] as? [String: Any]
            let unit = spanish?["stringUnit"] as? [String: Any]
            let translated = (unit?["state"] as? String) == "translated" && !((unit?["value"] as? String) ?? "").isEmpty
            if !translated && spanish?["variations"] == nil { missing.append(key) }
        }
        #expect(missing.isEmpty, "No Spanish: \(missing.sorted().prefix(10))")
    }

    // MARK: S1 press routing

    typealias Mic = MicrophoneModule
    nonisolated static let meetings: [(platform: MeetingPlatform, isBrowser: Bool)] =
        MeetingPlatform.allCases.flatMap { [($0, false), ($0, true)] }

    // MIC-03 / MIC-07: no call → the Mac toggles, whatever the settings, and Accessibility is
    // never asked for (the system prompt would show on a plain F5).
    @Test("MIC-03 MIC-07 no call toggles the Mac without asking for Accessibility",
          arguments: [false, true], [false, true])
    func noCallTogglesTheMac(alsoMac: Bool, teamsConsent: Bool) {
        var asked = false
        func ask() -> Bool { asked = true; return true }
        // Outside #expect: the macro evaluates call arguments on its own, which would ask.
        let route = Mic.route(meeting: nil, axGranted: ask(), alsoMac: alsoMac, teamsConsent: teamsConsent)
        #expect(route == .mac)
        #expect(!asked)
        #expect(Mic.newMacMuted(appMuted: nil, macMuted: true) == false)
        #expect(Mic.newMacMuted(appMuted: nil, macMuted: false) == true)
    }

    // MIC-36: a call but no Accessibility → nothing (only the system prompt).
    @Test("MIC-36 a call without Accessibility does nothing", arguments: meetings)
    func callWithoutAccessibility(meeting: (platform: MeetingPlatform, isBrowser: Bool)) {
        for alsoMac in [false, true] {
            for consent in [false, true] {
                #expect(Mic.route(meeting: meeting, axGranted: false, alsoMac: alsoMac, teamsConsent: consent) == .nothing)
            }
        }
    }

    // MIC-28 / MIC-35: "Also mute the Mac" on → read the call, then send; off → send only.
    // MIC-53: the consent flow only for Teams DESKTOP with its option on.
    @Test("MIC-28 MIC-35 MIC-53 how a meeting is pressed", arguments: meetings)
    func howAMeetingIsPressed(meeting: (platform: MeetingPlatform, isBrowser: Bool)) {
        let teamsDesktop = meeting.platform == .teams && !meeting.isBrowser
        for alsoMac in [false, true] {
            let plain: Mic.MeetingPress = alsoMac ? .readAndSend : .sendOnly
            #expect(Mic.route(meeting: meeting, axGranted: true, alsoMac: alsoMac, teamsConsent: false) == .meeting(plain))
            #expect(Mic.route(meeting: meeting, axGranted: true, alsoMac: alsoMac, teamsConsent: true)
                    == .meeting(teamsDesktop ? .teamsConsent : plain))
        }
    }

    // MIC-29: the Mac follows the CALL read before the press; unreadable → opposite of the Mac.
    @Test("MIC-29 the Mac follows the call", arguments: [
        (true as Bool?, false, false),   // call muted, Mac open → Mac unmuted (stays open)
        (true, true, false),             // call muted, Mac muted → Mac unmuted
        (false, true, true),             // call open, Mac muted → Mac muted (stays muted)
        (false, false, true),            // call open, Mac open → Mac muted
        (nil, true, false),              // unreadable → opposite of the Mac
        (nil, false, true),
    ])
    func macFollowsTheCall(appMuted: Bool?, macMuted: Bool, newMuted: Bool) {
        #expect(Mic.newMacMuted(appMuted: appMuted, macMuted: macMuted) == newMuted)
        #expect(Mic.afterSend(alsoMac: true, appMuted: appMuted, macMuted: macMuted) == .setMac(muted: newMuted))
    }

    // MIC-35: "Also mute the Mac" off → the Mac is never written, also in the Teams consent flow.
    @Test("MIC-35 setting off leaves the Mac alone", arguments: [true as Bool?, false, nil], [false, true])
    func settingOffLeavesTheMac(appMuted: Bool?, macMuted: Bool) {
        #expect(Mic.afterSend(alsoMac: false, appMuted: appMuted, macMuted: macMuted) == .showToggled)
    }

    // MIC-56 / MIC-57 / B-3: after an unmute press, a dialog is answered only while it hides the
    // mic button (modal, as the consent alert) and it is the only new one. While the button shows,
    // dialogs are notices (Teams' "recording started" one stays open for minutes) and are ignored.
    // MIC-57: still muted 0.6 s after the shortcut (`buttonDue`) → Teams ignored it: the mic
    // button is pressed, once (after it, `buttonDue` is false again).
    @Test("MIC-56 MIC-57 B-3 what the consent watch does", arguments: [
        (false as Bool?, 0, false, TeamsConsent.Watch.unmuted),
        (false, 1, true, .unmuted),
        (true, 0, false, .wait),           // before 0.6 s, or after the button was pressed
        (true, 0, true, .pressMicButton),
        (true, 1, false, .wait),           // B-3: a notice while the mic shows muted is never answered
        (true, 1, true, .pressMicButton),  // B-3: … and the button is still pressed
        (true, 2, true, .pressMicButton),
        (nil, 0, true, .wait),             // button hidden, the alert still rendering
        (nil, 1, false, .answer),
        (nil, 1, true, .answer),
        (nil, 2, false, .tooMany),
        (nil, 3, true, .tooMany),
    ])
    func consentWatch(micState: Bool?, newDialogs: Int, buttonDue: Bool, step: TeamsConsent.Watch) {
        #expect(TeamsConsent.watch(micState: micState, newDialogs: newDialogs, buttonDue: buttonDue) == step)
    }

    /// An Accessibility element as the consent rules see it.
    struct Node: ConsentNode, Equatable {
        var name = ""
        var role: String?
        var subrole: String?
        var hasLabel = false
        var children: [Node] = []

        static func button(_ name: String, label: Bool = true) -> Node { Node(name: name, role: "AXButton", hasLabel: label) }
        static func group(_ children: [Node], subrole: String? = nil, name: String = "") -> Node {
            Node(name: name, role: "AXGroup", subrole: subrole, children: children)
        }
        static let text = Node(role: "AXStaticText", hasLabel: true)
    }

    // MIC-56: the main button is the last one of the dialog's action row, only when that row has
    // exactly two labelled buttons; a close "X" sits in another row. No text is read.
    @Test("MIC-56 the alert's main button")
    func mainButton() {
        let row = Node.group([.button("No"), .button("Yes")])
        let consent = Node.group([.text, .group([.button("Close")]), row], subrole: "AXApplicationDialog")
        #expect(TeamsConsent.mainButton(in: consent)?.name == "Yes")
        // The action row deeper than the close button.
        #expect(TeamsConsent.mainButton(in: Node.group([.group([row]), .button("Close")]))?.name == "Yes")
        // Not a two-button choice → nothing.
        #expect(TeamsConsent.mainButton(in: Node.group([.group([.button("A"), .button("B"), .button("C")])])) == nil)
        #expect(TeamsConsent.mainButton(in: Node.group([.group([.button("OK")])])) == nil)
        #expect(TeamsConsent.mainButton(in: Node.group([.group([.button("No"), .button("", label: false)])])) == nil)
        #expect(TeamsConsent.mainButton(in: Node.group([.text])) == nil)
    }

    // MIC-56: at most 400 elements of a dialog are read.
    @Test("MIC-56 a dialog is read up to 400 elements")
    func mainButtonBudget() {
        let row = Node.group([.button("No"), .button("Yes")])
        #expect(TeamsConsent.mainButton(in: Node.group(Array(repeating: .text, count: 390) + [row]))?.name == "Yes")
        #expect(TeamsConsent.mainButton(in: Node.group(Array(repeating: .text, count: 450) + [row])) == nil)
    }

    // MIC-56: web dialogs are told by subrole and not searched inside; other groups are.
    @Test("MIC-56 the open dialogs in the call's window")
    func openDialogs() {
        let inner = Node.group([], subrole: "AXApplicationAlertDialog", name: "inner")
        let window = Node.group([
            .group([.group([inner], subrole: "AXApplicationDialog", name: "dialog")], subrole: "AXLandmarkMain"),
            .group([.button("Stop")], subrole: "AXApplicationAlertDialog", name: "alert"),
        ])
        let result = TeamsConsent.dialogs(in: [window], expired: { false })
        #expect(result.complete)
        #expect(result.found.map(\.0.name) == ["alert", "dialog"])
        #expect(result.found.map(\.1) == ["AXApplicationAlertDialog", "AXApplicationDialog"])
    }

    // MIC-55: a call window that can't be read whole (4000 elements or the time budget) isn't
    // complete, and then nothing is watched.
    @Test("MIC-55 a window too large to check")
    func windowTooLarge() {
        let small = Node.group(Array(repeating: .text, count: 3998))
        #expect(TeamsConsent.dialogs(in: [small], expired: { false }).complete)
        let large = Node.group(Array(repeating: .text, count: 4000))
        #expect(!TeamsConsent.dialogs(in: [large], expired: { false }).complete)
        var reads = 0
        let slow = TeamsConsent.dialogs(in: [small], expired: { reads += 1; return reads > 10 })
        #expect(!slow.complete)
    }

    // MIC-55 / B-3: a dialog open before the press stays "the same" even as a new element when it
    // keeps its place and size (Teams re-renders); the consent alert elsewhere counts as new.
    @Test("MIC-55 B-3 a dialog open before the press is told apart")
    func sameDialogBeforeThePress() {
        let notice = CGRect(x: 300, y: 80, width: 420, height: 56)
        let alert = CGRect(x: 380, y: 260, width: 440, height: 220)
        #expect(TeamsConsent.isSameDialog(sameElement: true, frame: nil, before: nil))
        #expect(TeamsConsent.isSameDialog(sameElement: false, frame: notice, before: notice))
        #expect(TeamsConsent.isSameDialog(sameElement: false, frame: notice.offsetBy(dx: 1.5, dy: -1), before: notice))
        #expect(!TeamsConsent.isSameDialog(sameElement: false, frame: alert, before: notice))
        #expect(!TeamsConsent.isSameDialog(sameElement: false, frame: notice.insetBy(dx: 0, dy: -10), before: notice))
        #expect(!TeamsConsent.isSameDialog(sameElement: false, frame: nil, before: notice))
        #expect(!TeamsConsent.isSameDialog(sameElement: false, frame: notice, before: nil))
    }

    // MIC-39 / MIC-06: Siri listening → ignored (checked first); no input device → "No microphone found".
    @Test("MIC-39 MIC-06 when the Mac's microphone can be written")
    func macGate() {
        #expect(Mic.macGate(siriListening: true, device: 42) == .siriListening)
        #expect(Mic.macGate(siriListening: true, device: nil) == .siriListening)
        #expect(Mic.macGate(siriListening: false, device: nil) == .noDevice)
        #expect(Mic.macGate(siriListening: false, device: 42) == .write(42))
    }

    // MARK: S2 keep muted and Siri

    nonisolated static let siri = "com.apple.CoreSpeech"
    nonisolated static let teams = "com.microsoft.teams2"
    nonisolated static let penknife = "io.github.alexl-l.Penknife"

    // MIC-38 / MIC-85: Siri listens only when it is the ONLY one recording.
    @Test("MIC-38 MIC-85 Siri listening", arguments: [
        ([siri], true),
        ([siri, siri], true),
        ([siri, teams], false),     // Siri records alongside every call
        ([siri, penknife], false),  // Penknife's own recording with the mic on
        ([teams], false),
        ([], false),
    ])
    func siriListening(recorders: [String], listening: Bool) {
        #expect(Mic.isSiriListening(recorders: recorders) == listening)
    }

    /// A mute cleared at `now`; the sound started `soundAgo` seconds before; Penknife's own change
    /// protection ended `ownAgo` seconds before (negative = still on).
    func remute(wasMuted: Bool = true, isMuted: Bool = false, soundAgo: TimeInterval = 0.05,
                ownAgo: TimeInterval = 5, recorders: [String] = [siri]) -> Bool {
        let now = Date()
        return Mic.shouldRemute(wasMuted: wasMuted, isMuted: isMuted, now: now,
                                ownChangeUntil: now.addingTimeInterval(-ownAgo),
                                outputStarted: now.addingTimeInterval(-soundAgo), recorders: recorders)
    }

    // MIC-44: muted → open right after a sound started, not by Penknife, only Siri recording
    // (or nobody) → muted again.
    @Test("MIC-44 a mute cleared by a sound is put back")
    func clearedBySoundIsPutBack() {
        #expect(remute())
        #expect(remute(recorders: []))
        #expect(remute(soundAgo: 0.49))
    }

    // MIC-42 / MIC-49: no sound in the previous 0.5 s = the user called Siri → left alone. The
    // accepted limit: a sound just before calling Siri mutes that call.
    @Test("MIC-42 MIC-49 called Siri still hears you")
    func calledSiriHearsYou() {
        #expect(!remute(soundAgo: 0.5))
        #expect(!remute(soundAgo: 30))
        #expect(!remute(soundAgo: .infinity))  // nothing played since launch (distantPast)
        #expect(remute(soundAgo: 0.3))          // MIC-49: accepted limit
    }

    // MIC-46: Penknife's own unmute (1 s window) is never undone.
    @Test("MIC-46 Penknife's own unmute is kept")
    func ownUnmuteIsKept() {
        #expect(!remute(ownAgo: -0.5))
        #expect(!remute(ownAgo: 0))
        #expect(remute(ownAgo: 0.01))
    }

    // MIC-47 / MIC-85: another app recording (a call, Penknife's recording with the mic on) → left alone.
    @Test("MIC-47 MIC-85 no re-mute while another app records", arguments: [[teams], [siri, teams], [penknife]])
    func otherRecorderIsLeftAlone(recorders: [String]) {
        #expect(!remute(recorders: recorders))
    }

    // MIC-44: only the change muted → open counts; the recorder list isn't even read otherwise.
    @Test("MIC-44 only a cleared mute counts", arguments: [(false, false), (false, true), (true, true)])
    func onlyAClearedMuteCounts(wasMuted: Bool, isMuted: Bool) {
        var read = false
        func recorders() -> [String] { read = true; return [] }
        let now = Date()
        // Outside #expect: the macro evaluates call arguments on its own, which would read them.
        let remuted = Mic.shouldRemute(wasMuted: wasMuted, isMuted: isMuted, now: now, ownChangeUntil: .distantPast,
                                       outputStarted: now, recorders: recorders())
        #expect(!remuted)
        #expect(!read)
    }

    // MARK: S3 meeting picker

    typealias Tracker = MeetingTracker

    struct FakeApp: PickerApp, Equatable, CustomStringConvertible {
        let processIdentifier: pid_t
        let bundleIdentifier: String?
        var isTerminated = false
        var description: String { "\(bundleIdentifier ?? "nil")#\(processIdentifier)" }
    }

    nonisolated static let chrome = "com.google.Chrome"
    nonisolated static let zoom = "us.zoom.xos"
    nonisolated static let finder = "com.apple.finder"

    // MIC-09: an open meeting app or meeting page without the microphone is not a meeting.
    @Test("MIC-09 only apps recording now are in a call")
    func onlyRecordingAppsAreCalls() {
        let teamsApp = FakeApp(processIdentifier: 10, bundleIdentifier: Self.teams)
        let chromeApp = FakeApp(processIdentifier: 20, bundleIdentifier: Self.chrome)
        let running = [teamsApp, chromeApp]
        #expect(Tracker.orderCandidates(front: teamsApp, recent: running, running: running, micPIDs: []).isEmpty)
        #expect(Tracker.orderCandidates(front: teamsApp, recent: running, running: running, micPIDs: [20]) == [chromeApp])
        // A recording app that is neither a meeting app nor a known browser never counts.
        let finderApp = FakeApp(processIdentifier: 30, bundleIdentifier: Self.finder)
        #expect(Tracker.orderCandidates(front: finderApp, recent: [], running: [finderApp], micPIDs: [30]).isEmpty)
    }

    // MIC-13 / MIC-14: the frontmost candidate first, then the recent ones (most recent first, quit
    // apps dropped), then other running candidates; each app once.
    @Test("MIC-13 MIC-14 candidate order")
    func candidateOrder() {
        let teamsApp = FakeApp(processIdentifier: 10, bundleIdentifier: Self.teams)
        let chromeApp = FakeApp(processIdentifier: 20, bundleIdentifier: Self.chrome)
        let zoomApp = FakeApp(processIdentifier: 30, bundleIdentifier: Self.zoom)
        let quit = FakeApp(processIdentifier: 40, bundleIdentifier: Self.chrome, isTerminated: true)
        let finderApp = FakeApp(processIdentifier: 50, bundleIdentifier: Self.finder)
        let all: Set<pid_t> = [10, 20, 30, 40, 50]
        let running = [zoomApp, finderApp, teamsApp, chromeApp]

        // Chrome in front: it goes first, even though Teams was used last (MIC-14).
        #expect(Tracker.orderCandidates(front: chromeApp, recent: [teamsApp, chromeApp], running: running, micPIDs: all)
                == [chromeApp, teamsApp, zoomApp])
        // Finder in front: the last meeting app used goes first; Zoom (never in front) still counts.
        #expect(Tracker.orderCandidates(front: finderApp, recent: [teamsApp, quit, chromeApp], running: running, micPIDs: all)
                == [teamsApp, chromeApp, zoomApp])
        // Nothing in front, nothing recent: running candidates in their order.
        #expect(Tracker.orderCandidates(front: nil as FakeApp?, recent: [], running: running, micPIDs: all)
                == [zoomApp, teamsApp, chromeApp])
    }

    // MIC-16: an activated candidate goes first, once; other apps are ignored; at most 6 kept.
    @Test("MIC-16 recent apps")
    func recentApps() {
        let apps = (1...7).map { FakeApp(processIdentifier: pid_t($0), bundleIdentifier: Self.chrome) }
        var recent: [FakeApp] = []
        for app in apps { recent = Tracker.remember(recent, app) }
        #expect(recent == Array(apps.reversed().prefix(6)))
        #expect(Tracker.remember(recent, apps[3]) == [apps[3], apps[6], apps[5], apps[4], apps[2], apps[1]])
        let finderApp = FakeApp(processIdentifier: 99, bundleIdentifier: Self.finder)
        #expect(Tracker.remember(recent, finderApp) == recent)
        #expect(Tracker.remember(recent, FakeApp(processIdentifier: 98, bundleIdentifier: nil)) == recent)
    }

    nonisolated static let allPlatforms = Set(MeetingPlatform.allCases)

    /// `pickTarget` over `ids` with these titles; also returns which titles were read.
    func pick(_ ids: [String?], titles: [Int: String] = [:], enabled: Set<MeetingPlatform> = allPlatforms)
        -> (pick: (platform: MeetingPlatform, index: Int, isBrowser: Bool)?, read: [Int]) {
        var read: [Int] = []
        let pick = Tracker.pickTarget(bundleIDs: ids, enabled: enabled) { read.append($0); return titles[$0] }
        return (pick, read)
    }

    // MIC-15: a meeting app whose platform is off is skipped; none left → nil (the Mac toggles, MIC-03).
    @Test("MIC-15 platforms turned off are skipped")
    func platformsOffAreSkipped() {
        let first = pick([Self.teams, Self.zoom])
        #expect(first.pick?.platform == .teams && first.pick?.index == 0 && first.pick?.isBrowser == false)
        let noTeams = pick([Self.teams, Self.zoom], enabled: Self.allPlatforms.subtracting([.teams]))
        #expect(noTeams.pick?.platform == .zoom && noTeams.pick?.index == 1)
        #expect(pick([Self.teams, Self.zoom], enabled: [.meet]).pick == nil)
        // A Meet tab with Meet off: not a meeting.
        #expect(pick([Self.chrome], titles: [0: "Meet - abc-defg-hij"], enabled: [.teams]).pick == nil)
        #expect(pick([]).pick == nil)
    }

    // MIC-25: a browser is a meeting by its title; unreadable or not a meeting → next candidate.
    // Titles are read only for browsers, and only until a meeting is found.
    @Test("MIC-25 browsers by title, read only when needed")
    func browsersByTitle() {
        let meet = pick([Self.chrome], titles: [0: "Meet - abc-defg-hij"])
        #expect(meet.pick?.platform == .meet && meet.pick?.isBrowser == true && meet.read == [0])
        let unreadable = pick([Self.chrome, Self.teams])
        #expect(unreadable.pick?.platform == .teams && unreadable.pick?.index == 1 && unreadable.read == [0])
        let notMeeting = pick([Self.chrome, "com.apple.Safari"], titles: [0: "Slack tips - YouTube", 1: "Chat | Microsoft Teams"])
        #expect(notMeeting.pick?.platform == .teams && notMeeting.pick?.index == 1 && notMeeting.read == [0, 1])
        let appFirst = pick([Self.zoom, Self.chrome], titles: [1: "Meet - abc-defg-hij"])
        #expect(appFirst.pick?.platform == .zoom && appFirst.read.isEmpty)
    }

    // MARK: S4 device control

    /// A default input as CoreAudio reports it; nil = the property is missing or unreadable.
    struct FakeControls: MicControls {
        var muteSettable = false
        var volumeSettable = false
        var mute: UInt32?
        var volume: Float32?
    }

    // MIC-64: the state is read from the control a press writes (D: Mic state bug).
    @Test("MIC-64 the state is read from the control a press writes", arguments: [
        (FakeControls(muteSettable: true, mute: 1, volume: 0.7), true),
        (FakeControls(muteSettable: true, mute: 0, volume: 0), false),     // the mute wins over volume 0
        (FakeControls(muteSettable: false, mute: 1, volume: 0.7), false),  // a mute nobody can set is ignored
        (FakeControls(muteSettable: false, mute: 0, volume: 0), true),     // volume 0 = muted
        (FakeControls(muteSettable: true, mute: nil, volume: 0), true),    // settable but unreadable → volume
        (FakeControls(mute: 1), true),                                     // only a read-only mute → that one
        (FakeControls(mute: 0), false),
        (FakeControls(), false),                                           // nothing readable → open
    ])
    func readMuted(input: FakeControls, muted: Bool) {
        #expect(Mic.readMuted(input) == muted)
    }

    // MIC-64 / O-1: no input device reads as open (the Touch Bar shows the mic open).
    @Test("MIC-64 O-1 no input device reads as open")
    func noDeviceReadsOpen() {
        #expect(!Mic.readMuted(nil as FakeControls?))
    }

    // MIC-04 / MIC-48: a settable mute is what gets written; the remembered volume stays as it was.
    @Test("MIC-04 MIC-48 a settable mute is written", arguments: [true, false], [nil, 0.4] as [Float32?])
    func settableMuteIsWritten(mute: Bool, saved: Float32?) {
        let input = FakeControls(muteSettable: true, volumeSettable: true, mute: 0, volume: 0.8)
        let plan = Mic.writePlan(input, mute: mute, savedVolume: saved)
        #expect(plan.write == .mute(mute ? 1 : 0))
        #expect(plan.savedVolume == saved)
    }

    // MIC-04: no settable mute → the input volume. Muting remembers it and writes 0; unmuting
    // writes it back, or 1.0 when nothing is remembered (after a relaunch).
    @Test("MIC-04 the input volume when the mute can't be set")
    func volumeFallback() {
        let muted = Mic.writePlan(FakeControls(volumeSettable: true, mute: 0, volume: 0.6), mute: true, savedVolume: nil)
        #expect(muted.write == .volume(0) && muted.savedVolume == 0.6)
        let atZero = FakeControls(volumeSettable: true, volume: 0)
        let unmuted = Mic.writePlan(atZero, mute: false, savedVolume: muted.savedVolume)
        #expect(unmuted.write == .volume(0.6) && unmuted.savedVolume == 0.6)
        #expect(Mic.writePlan(atZero, mute: false, savedVolume: nil).write == .volume(1))
        // Unreadable volume: muted anyway, the remembered volume kept.
        let unreadable = Mic.writePlan(FakeControls(volumeSettable: true), mute: true, savedVolume: 0.6)
        #expect(unreadable.write == .volume(0) && unreadable.savedVolume == 0.6)
    }

    // B-4: a call press makes the Mac follow the call even when it already matches (MIC-29). An
    // input volume already as asked is left alone: muting at 0 used to remember 0, so the next
    // unmute left the mic muted; unmuting an open input overwrote its volume.
    @Test("B-4 an input volume already as asked is left alone")
    func volumeAlreadyAsAsked() {
        let again = Mic.writePlan(FakeControls(volumeSettable: true, volume: 0), mute: true, savedVolume: 0.6)
        #expect(again.write == .unchanged && again.savedVolume == 0.6)
        let open = Mic.writePlan(FakeControls(volumeSettable: true, volume: 0.5), mute: false, savedVolume: 0.6)
        #expect(open.write == .unchanged && open.savedVolume == 0.6)
        // The reported case: mute (0.6 → 0), mute again, unmute → back to 0.6.
        var device = FakeControls(volumeSettable: true, volume: 0.6)
        var saved: Float32?
        for mute in [true, true, false] {
            let plan = Mic.writePlan(device, mute: mute, savedVolume: saved)
            saved = plan.savedVolume
            if case .volume(let value) = plan.write { device.volume = value }
        }
        #expect(device.volume == 0.6 && !Mic.readMuted(device))
    }

    // MIC-04 / O-2: neither control can be set → nothing is written.
    @Test("MIC-04 O-2 a device that can't be muted", arguments: [true, false])
    func cantBeMuted(mute: Bool) {
        let plan = Mic.writePlan(FakeControls(mute: 0, volume: 0.5), mute: mute, savedVolume: 0.3)
        #expect(plan.write == .nothing && plan.savedVolume == 0.3)
    }

    // MIC-04 / MIC-64 (D: Mic state bug): on every kind of device, each press reads back what it
    // wrote, so the next press goes the other way (a read-only mute stuck on made every press mute).
    @Test("MIC-04 MIC-64 a press reads back what it wrote", arguments: [
        FakeControls(muteSettable: true, volumeSettable: true, mute: 0, volume: 0.8),
        FakeControls(volumeSettable: true, mute: 1, volume: 0.8),
        FakeControls(volumeSettable: true, volume: 0.8),
    ])
    func readsBackWhatItWrote(device: FakeControls) {
        var device = device
        var saved: Float32?
        for mute in [true, false, true, false] {
            let plan = Mic.writePlan(device, mute: mute, savedVolume: saved)
            saved = plan.savedVolume
            switch plan.write {
            case .mute(let value): device.mute = value
            case .volume(let value): device.volume = value
            case .unchanged, .nothing: break
            }
            #expect(Mic.readMuted(device) == mute)
        }
        #expect(device.volume == 0.8)  // the volume comes back where it was
    }

    // MARK: B-2 Siri's panel shows the mic open

    // MIC-40: Siri hears the user while its panel is on screen and it records; a Mac sound makes
    // Siri record without a panel (stays muted); "Type to Siri" shows the panel without recording.
    @Test("MIC-40 Siri hears you while its panel shows and it records", arguments: [
        (true, [siri], true),
        (true, [siri, teams], true),   // Siri called during a call still hears you
        (false, [siri], false),        // a Mac sound woke Siri (R-34: stays muted)
        (true, [], false),             // Type to Siri
        (true, [teams], false),
        (false, [], false),
    ])
    func siriHearsYou(panelShown: Bool, recorders: [String], hears: Bool) {
        #expect(Mic.siriHears(panelShown: panelShown, recorders: recorders) == hears)
    }

    // MIC-40 / MIC-63: the icon shows open while Siri hears the user; otherwise the device.
    @Test("MIC-40 MIC-63 what the icon shows", arguments: [
        (true, false, true),
        (true, true, false),
        (false, false, false),
        (false, true, false),
    ])
    func whatTheIconShows(deviceMuted: Bool, siriHears: Bool, shownMuted: Bool) {
        #expect(Mic.shownMuted(deviceMuted: deviceMuted, siriHears: siriHears) == shownMuted)
    }

    // MIC-08 / MIC-80 (R-15): a module that is off holds no observers or listeners, also after
    // turning it off and on again (B-1: the Mac-sound listener used to stay behind). Starting the
    // module only adds listeners for a moment; it changes nothing. Depends on the user's "Keep the
    // microphone muted" being on (the default): off, no listeners are made and this passes anyway.
    @Test("MIC-80 module off holds nothing")
    func moduleOffHoldsNothing() {
        let module = MicrophoneModule()
        module.start()
        module.stop()
        #expect(!module.holdsObservers)
        module.start()
        module.stop()
        #expect(!module.holdsObservers)
    }
}

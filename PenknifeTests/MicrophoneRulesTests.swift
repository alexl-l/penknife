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

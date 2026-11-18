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

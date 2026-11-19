import AppKit
import AVFoundation
import CoreLocation
import KeyboardShortcuts
import Testing
@testable import Penknife

/// General rules (docs/requirements/general.md). Each test names the rule it checks.
/// Nothing here changes the login item, shows an alert, opens Settings, registers a shortcut or
/// writes the user's settings: only the pure rules the app calls, and a manager on fake modules
/// with no actions over settings kept in memory. (The Spanish catalog check, GN-27, is in
/// MicrophoneRulesTests; the Fn twins, GN-10, in TouchBarRulesTests TB-58.)
@MainActor
@Suite("General rules")
struct GeneralRulesTests {

    /// A module that only counts its starts and stops; no actions, so no hotkey is registered.
    final class FakeModule: Module {
        let id: ModuleID
        let actions: [ModuleAction] = []
        private(set) var starts = 0
        private(set) var stops = 0
        init(_ id: ModuleID) { self.id = id }
        func start() { starts += 1 }
        func stop() { stops += 1 }
    }

    @Test("GN-05 GN-08 every module is on when nothing is saved; the order of the sidebar and the menu")
    func modules() throws {
        let empty = try TouchBarRulesTests.emptySuite(keys: ModuleID.allCases.map { "module.\($0.rawValue).enabled" })
        for id in ModuleID.allCases {
            #expect(ModuleManager.isOn(id, in: empty), "\(id)")
        }
        #expect(ModuleID.allCases == [.jiggler, .microphone, .lockScreen, .screenshot, .clipboard, .music,
                                      .blockAppleMusic, .cpuTemperature, .weather, .speedTest, .touchBar, .dialogs])
    }

    @Test("GN-05 GN-06 a manager starts what is on, saves each switch and ignores a switch to the same state")
    func switching() {
        let defaults = JigglerRulesTests.MemoryDefaults(["module.music.enabled": false])
        let weather = FakeModule(.weather), music = FakeModule(.music)
        let manager = ModuleManager(modules: [weather, music], defaults: defaults)
        manager.startEnabledModules()
        #expect(weather.starts == 1 && music.starts == 0)
        #expect(manager.isEnabled(.weather) && !manager.isEnabled(.music))

        manager.setEnabled(.music, true)
        #expect(music.starts == 1 && defaults.values["module.music.enabled"] as? Bool == true)
        manager.setEnabled(.music, true)
        #expect(music.starts == 1)

        manager.setEnabled(.weather, false)
        #expect(weather.stops == 1 && !manager.isEnabled(.weather))
        #expect(defaults.values["module.weather.enabled"] as? Bool == false)
        manager.setEnabled(.weather, false)
        #expect(weather.stops == 1)
        // A module the manager doesn't hold: nothing happens, nothing is saved.
        manager.setEnabled(.jiggler, false)
        #expect(defaults.values["module.jiggler.enabled"] == nil)
    }

    @Test("GN-09 the default shortcuts")
    func shortcuts() {
        typealias N = KeyboardShortcuts.Name
        #expect(N.openMenu.defaultShortcut == .init(.p, modifiers: [.control, .option]))
        #expect(N.toggleJiggler.defaultShortcut == .init(.f12))
        #expect(N.toggleMicrophone.defaultShortcut == .init(.f5))
        #expect(N.lockScreen.defaultShortcut == .init(.f6))
        #expect(N.screenshot.defaultShortcut == .init(.f1))
        #expect(N.recordScreen.defaultShortcut == .init(.r, modifiers: [.control, .option]))
        #expect(N.recordingDraw.defaultShortcut == .init(.d, modifiers: [.control, .option]))
        #expect(N.clipboardHistory.defaultShortcut == .init(.v, modifiers: [.control, .option]))
        for name in [N.playPause, .nextTrack, .previousTrack, .allowAppleMusic, .speedTest] {
            #expect(name.defaultShortcut == nil, "\(name.rawValue)")
        }
    }

    @Test("GN-11 Settings starts at 760×560; a saved size under 680×420 grows; others are kept")
    func settingsSize() {
        typealias W = SettingsWindowController
        #expect(W.startSize(saved: nil) == NSSize(width: 760, height: 560))
        #expect(W.startSize(saved: NSSize(width: 500, height: 600)) == NSSize(width: 760, height: 600))
        #expect(W.startSize(saved: NSSize(width: 900, height: 300)) == NSSize(width: 900, height: 560))
        #expect(W.startSize(saved: NSSize(width: 650, height: 500)) == NSSize(width: 760, height: 560))
        #expect(W.startSize(saved: NSSize(width: 680, height: 420)) == nil)
        #expect(W.startSize(saved: NSSize(width: 1000, height: 800)) == nil)
    }

    @Test("GN-13 the page shown is remembered; an unknown value opens General")
    func pages() {
        let pages: [SettingsPage] = [.general, .permissions, .shortcuts, .about] + ModuleID.allCases.map { .module($0) }
        for page in pages {
            #expect(SettingsPage(rawValue: page.rawValue) == page, "\(page.rawValue)")
        }
        #expect(SettingsPage.module(.weather).rawValue == "module.weather")
        #expect(SettingsPage(rawValue: "module.nothing") == nil)
        #expect(SettingsPage(rawValue: "modules") == nil)
        #expect(SettingsPage(rawValue: "") == nil)
    }

    @Test("GN-16 alerts last 1, 2, 4, 8 or 15 s; nothing, zero or less reads as 4")
    func durations() {
        #expect(HUD.durations == [1, 2, 4, 8, 15])
        #expect(HUD.duration(in: JigglerRulesTests.MemoryDefaults()) == 4)
        #expect(HUD.duration(in: JigglerRulesTests.MemoryDefaults([HUD.durationKey: 0.0])) == 4)
        #expect(HUD.duration(in: JigglerRulesTests.MemoryDefaults([HUD.durationKey: -2.0])) == 4)
        #expect(HUD.duration(in: JigglerRulesTests.MemoryDefaults([HUD.durationKey: 15.0])) == 15)
    }

    @Test("GN-17 the alert's size: one or two lines, width within 120–360 pt")
    func alertSize() {
        #expect(HUD.size(hasDetail: false, fittingWidth: 200) == NSSize(width: 200, height: 44))
        #expect(HUD.size(hasDetail: true, fittingWidth: 200) == NSSize(width: 200, height: 56))
        #expect(HUD.size(hasDetail: false, fittingWidth: 40).width == 120)
        #expect(HUD.size(hasDetail: false, fittingWidth: 900).width == 360)
    }

    @Test("GN-17 the alert sits centered, 8 pt under the menu bar or the notch, else 12 pt under the top")
    func alertFrame() {
        let screen = NSRect(x: 0, y: 0, width: 1512, height: 982)
        let size = NSSize(width: 200, height: 44)
        // Menu bar of 24 pt, no notch.
        let menuBar = HUD.frame(size: size, screen: screen, visible: NSRect(x: 0, y: 0, width: 1512, height: 958), safeTop: 0)
        #expect(menuBar == NSRect(x: 656, y: 982 - 24 - 8 - 44, width: 200, height: 44))
        // A notch (32 pt) lower than the menu bar (24 pt): under the notch.
        let notch = HUD.frame(size: size, screen: screen, visible: NSRect(x: 0, y: 0, width: 1512, height: 958), safeTop: 32)
        #expect(notch.origin.y == CGFloat(982 - 32 - 8 - 44))
        // No menu bar, no notch (full screen): 12 pt under the top edge.
        let bare = HUD.frame(size: size, screen: screen, visible: screen, safeTop: 0)
        #expect(bare.origin.y == CGFloat(982 - 12 - 44))
        // A second screen to the left: centered on that screen.
        let left = NSRect(x: -1920, y: 0, width: 1920, height: 1080)
        let other = HUD.frame(size: size, screen: left, visible: NSRect(x: -1920, y: 0, width: 1920, height: 1055), safeTop: 0)
        #expect(other.origin.x == CGFloat(-960 - 100) && other.origin.y == CGFloat(1080 - 25 - 8 - 44))
    }

    @Test("GN-18 six alert types, each shown when nothing is saved")
    func alertTypes() {
        #expect(AlertCategory.allCases == [.jiggler, .microphone, .screenshot, .clipboard, .music, .speedTest])
        let empty = JigglerRulesTests.MemoryDefaults()
        for category in AlertCategory.allCases {
            #expect(category.key == "alerts.\(category.rawValue)")
            #expect(category.isShown(in: empty), "\(category)")
        }
        #expect(!AlertCategory.music.isShown(in: JigglerRulesTests.MemoryDefaults(["alerts.music": false])))
    }

    @Test("GN-21 O-31 the five permissions with macOS's names; a state only when it can be read")
    func permissions() {
        typealias P = PrivacyPermission
        #expect(P.allCases == [.deviceControl, .screenRecording, .microphone, .location, .automation])
        #expect(P.allCases.map(\.title) == ["Device Control and Data Access", "Screen & System Audio Recording",
                                            "Microphone", "Location Services", "Automation"])
        #expect(P.allCases.map { $0.settingsURL.query ?? "" } == ["Privacy_Accessibility", "Privacy_ScreenCapture",
                                                                 "Privacy_Microphone", "Privacy_LocationServices", "Privacy_Automation"])
        #expect(P.control(for: .granted) == .granted)
        #expect(P.control(for: .notAsked) == .allow)
        #expect(P.control(for: .denied) == .openSettings)
        #expect(P.control(for: .unknown) == .openSettings)
        // Automation can't be read: never shown as granted.
        #expect(P.automation.access == .unknown)
        #expect(P.microphoneAccess(.authorized) == .granted)
        #expect(P.microphoneAccess(.notDetermined) == .notAsked)
        #expect(P.microphoneAccess(.denied) == .denied && P.microphoneAccess(.restricted) == .denied)
        #expect(P.locationAccess(.authorizedAlways) == .granted)
        #expect(P.locationAccess(.notDetermined) == .notAsked)
        #expect(P.locationAccess(.denied) == .denied && P.locationAccess(.restricted) == .denied)
        #expect(P.screenAccess(granted: true, asked: false) == .granted)
        #expect(P.screenAccess(granted: false, asked: false) == .notAsked)
        #expect(P.screenAccess(granted: false, asked: true) == .denied)
    }

    @Test("GN-23 B-25 the login item: only from /Applications, registered once per path, removed when off, a removal in System Settings is kept")
    func loginItem() {
        typealias L = LaunchAtLogin
        for wanted in [true, false] {
            for enabled in [true, false] {
                for here in [true, false] {
                    #expect(L.step(installed: false, wanted: wanted, enabled: enabled, registeredHere: here) == .none)
                }
            }
        }
        #expect(L.step(installed: true, wanted: true, enabled: false, registeredHere: false) == .register)
        #expect(L.step(installed: true, wanted: true, enabled: false, registeredHere: true) == .forget)
        #expect(L.step(installed: true, wanted: true, enabled: true, registeredHere: true) == .none)
        #expect(L.step(installed: true, wanted: true, enabled: true, registeredHere: false) == .reregister)
        #expect(L.step(installed: true, wanted: false, enabled: true, registeredHere: true) == .unregister)
        #expect(L.step(installed: true, wanted: false, enabled: true, registeredHere: false) == .unregister)
        #expect(L.step(installed: true, wanted: false, enabled: false, registeredHere: false) == .none)
    }

    @Test("GN-26 About shows the version and the build, or only the version")
    func version() {
        #expect(AboutPage.version(short: "1.11", build: "186") == "1.11 (186)")
        #expect(AboutPage.version(short: "1.11", build: "") == "1.11")
    }
}

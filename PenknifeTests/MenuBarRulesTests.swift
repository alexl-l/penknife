import Foundation
import KeyboardShortcuts
import Testing
@testable import Penknife

/// Menu bar rules (docs/requirements/menubar.md). Each test names the rule it checks.
/// Nothing here creates a status item, opens a menu or writes the user's settings: only the
/// pure rules the items and the menu call. (Each reading's own look is in its module's tests:
/// CT-07, ST-08, ST-09; the readings' defaults in TouchBarRulesTests, R-30.)
@MainActor
@Suite("Menu bar rules")
struct MenuBarRulesTests {

    @Test("MB-01 the menu shortcut ⌃⌥P; the dots and the style have their defaults")
    func defaults() throws {
        #expect(KeyboardShortcuts.Name.openMenu.defaultShortcut == .init(.p, modifiers: [.control, .option]))
        let empty = try TouchBarRulesTests.emptySuite(keys: [StatusMenu.dotsKey, MenuBarReadings.styleKey])
        #expect(StatusMenu.dotsOn(in: empty))
        #expect(MenuBarReadings.style(in: empty) == .sober)
    }

    @Test("MB-04 a dot only while dots are on, its module is on and (mic) an input exists")
    func dots() {
        typealias S = StatusMenu
        // Dots off: nothing, whatever the modules say.
        let off = S.dots(shown: false, microphone: (true, false), jiggler: true)
        #expect(off.mic == nil && off.jiggler == nil)
        // Mic: open = filled (true), muted = ring (false), no input device = no dot.
        #expect(S.dots(shown: true, microphone: (true, false), jiggler: nil).mic == true)
        #expect(S.dots(shown: true, microphone: (true, true), jiggler: nil).mic == false)
        #expect(S.dots(shown: true, microphone: (false, false), jiggler: nil).mic == nil)
        #expect(S.dots(shown: true, microphone: nil, jiggler: nil).mic == nil)
        // Jiggler: on = filled, off = ring, module off = no dot.
        #expect(S.dots(shown: true, microphone: nil, jiggler: true).jiggler == true)
        #expect(S.dots(shown: true, microphone: nil, jiggler: false).jiggler == false)
        #expect(S.dots(shown: true, microphone: (true, false), jiggler: nil).jiggler == nil)
    }

    @Test("MB-05 VoiceOver value: microphone, then jiggler, as on screen (O-30)")
    func dotsValue() {
        let both = StatusMenu.dotsValue(mic: false, jiggler: true)
        #expect(both == "\(String(localized: "Microphone muted")), \(String(localized: "Mouse jiggler on"))")
        #expect(StatusMenu.dotsValue(mic: true, jiggler: nil) == String(localized: "Microphone on"))
        #expect(StatusMenu.dotsValue(mic: nil, jiggler: false) == String(localized: "Mouse jiggler off"))
        #expect(StatusMenu.dotsValue(mic: nil, jiggler: nil).isEmpty)
    }

    @Test("MB-06 the recording indicator's label says how to stop, paused or not")
    func recordingLabel() {
        let running = StatusMenu.recordingLabel(time: "0:05", paused: false)
        let paused = StatusMenu.recordingLabel(time: "0:05", paused: true)
        #expect(running.contains("0:05") && paused.contains("0:05") && running != paused)
    }

    @Test("MB-08 readings in order weather, CPU temperature, speed test; missing ones leave no line")
    func readings() {
        let report = WeatherModule.Report(celsius: 18.2, code: 0, isDay: true, date: .now)
        let speed = [(title: "Speed (14:05): ↓ 245 Mbps", symbol: "timer")]
        let all = StatusMenu.readingLines(weather: report, celsius: 54, speed: speed)
        #expect(all.map(\.symbol) == ["sun.max.fill", "thermometer.medium", "timer"])
        #expect(all[0].title.contains(report.summary) && all[0].title.contains(TemperatureText.short(celsius: 18.2)))
        #expect(all[1].title.contains(TemperatureText.short(celsius: 54)))
        #expect(StatusMenu.readingLines(weather: nil, celsius: nil, speed: []).isEmpty)
        #expect(StatusMenu.readingLines(weather: nil, celsius: 54, speed: []).map(\.symbol) == ["thermometer.medium"])
        #expect(StatusMenu.readingLines(weather: report, celsius: nil, speed: speed).map(\.symbol) == ["sun.max.fill", "timer"])
    }

    @Test("MB-10 an item exists only while its module is on and its switch is on")
    func wanted() {
        typealias R = MenuBarReadings
        #expect(R.wanted(isEnabled: { _ in true }, isShown: { _ in true }) == Set(R.Kind.allCases))
        #expect(R.wanted(isEnabled: { _ in false }, isShown: { _ in true }).isEmpty)
        #expect(R.wanted(isEnabled: { _ in true }, isShown: { _ in false }).isEmpty)
        #expect(R.wanted(isEnabled: { $0 != .weather }, isShown: { $0 != .speedTest }) == [.temperature])
        #expect(R.Kind.allCases.map(\.module) == [.weather, .cpuTemperature, .speedTest])
        #expect(R.Kind.allCases.map(\.key) == ["menuBar.show.weather", "menuBar.show.temperature", "menuBar.show.speedTest"])
    }

    @Test("MB-12 styles: Simple drops .fill, Bold is medium, Color keeps weather in color; unknown → Simple")
    func styles() throws {
        typealias R = MenuBarReadings
        #expect(R.Style.allCases == [.sober, .color, .bold])
        #expect(R.symbolLook("cloud.sun.fill", kind: .weather, style: .sober) == ("cloud.sun", false, false))
        #expect(R.symbolLook("cloud.sun.fill", kind: .weather, style: .bold) == ("cloud.sun.fill", true, false))
        #expect(R.symbolLook("cloud.sun.fill", kind: .weather, style: .color) == ("cloud.sun.fill", false, true))
        #expect(R.symbolLook("cpu", kind: .temperature, style: .color) == ("cpu", false, false))
        #expect(R.symbolLook("speedometer", kind: .speedTest, style: .sober).name == "speedometer")
        let stored = InMemoryDefaults()
        #expect(R.style(in: stored) == .sober)
        stored.set("bold", forKey: R.styleKey)
        #expect(R.style(in: stored) == .bold)
        stored.set("neon", forKey: R.styleKey)
        #expect(R.style(in: stored) == .sober)
    }

    @Test("WX-11 the weather item: report, location refused, no data yet")
    func weatherLook() {
        typealias R = MenuBarReadings
        let report = WeatherModule.Report(celsius: 18.2, code: 3, isDay: true, date: .now)
        let shown = R.weatherLook(report: report, status: .noLocation)
        #expect(shown.symbol == "cloud.fill" && shown.text == TemperatureText.short(celsius: 18.2))
        #expect(shown.label.contains(report.summary))
        #expect(R.weatherLook(report: nil, status: .noLocation).symbol == "location.slash")
        #expect(R.weatherLook(report: nil, status: .noLocation).text == nil)
        for status in [WeatherModule.Status.idle, .failed] {
            #expect(R.weatherLook(report: nil, status: status).symbol == "cloud")
        }
    }
}

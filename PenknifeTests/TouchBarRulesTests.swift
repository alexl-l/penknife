import AppKit
import Foundation
import KeyboardShortcuts
import Testing
@testable import Penknife

/// Touch Bar rules (docs/requirements/touchbar.md). Each test names the rule it checks.
/// Nothing here presents the bar (this Mac has a Touch Bar: never call `TouchBarModule.start()`
/// or `TouchBarPrivate.present`), presses keys, uses Accessibility or writes the user's settings.
@MainActor
@Suite("Touch Bar rules")
struct TouchBarRulesTests {

    static let defaultOrder: [BarItem] = [
        .battery, .brightness, .keyboardLight, .jiggler, .microphone, .screenshot, .lock,
        .music, .weather, .cpu, .volume, .speedTest, .time,
    ]

    // MARK: As-is

    // TB-07: thirteen buttons in this default order.
    @Test("TB-07 the thirteen buttons in default order")
    func defaultOrder() {
        #expect(BarItem.allCases == Self.defaultOrder)
    }

    // TB-36 / TB-37: the names are what `touchBar.order` and `touchBar.hidden` store, so they
    // must never change (a renamed button would drop out of every saved layout).
    @Test("TB-36 TB-37 the stored button names")
    func storedNames() {
        #expect(BarItem.allCases.map(\.rawValue) == [
            "battery", "brightness", "keyboardLight", "jiggler", "microphone", "screenshot", "lock",
            "music", "weather", "cpu", "volume", "speedTest", "time",
        ])
    }

    // TB-08: which module each button belongs to; the bar's own buttons belong to none.
    @Test("TB-08 each button's module")
    func buttonModules() {
        let expected: [BarItem: ModuleID] = [
            .jiggler: .jiggler, .microphone: .microphone, .screenshot: .screenshot, .lock: .lockScreen,
            .music: .music, .weather: .weather, .cpu: .cpuTemperature, .speedTest: .speedTest,
        ]
        for item in BarItem.allCases { #expect(item.module == expected[item], "\(item)") }
    }

    // TB-09: each button's own color in the multicolor mode.
    @Test("TB-09 each button's own color")
    func buttonColors() {
        let expected: [BarItem: UInt32] = [
            .battery: 0xFFFFFF, .time: 0xFFFFFF, .brightness: 0xFFDB00, .keyboardLight: 0x4AD1E6,
            .jiggler: 0x0099FF, .microphone: 0xFF5D49, .screenshot: 0xCC77F4, .lock: 0x7176EB,
            .music: 0x08DA73, .weather: 0x75DAD8, .cpu: 0xFFAE02, .volume: 0xFFAE02, .speedTest: 0x34C759,
        ]
        for item in BarItem.allCases { #expect(item.hex == expected[item], "\(item)") }
    }

    // TB-12: holding the battery goes multicolor → monochrome → rainbow → multicolor; the raw
    // values are stored in `touchBar.colorMode`, so they stay 0 / 1 / 2.
    @Test("TB-12 the color modes cycle")
    func colorModesCycle() {
        #expect(BarColorMode.multicolor.next == .monochrome)
        #expect(BarColorMode.monochrome.next == .rainbow)
        #expect(BarColorMode.rainbow.next == .multicolor)
        #expect(BarColorMode.allCases.map(\.rawValue) == [0, 1, 2])
    }

    // TB-58: the default F keys, and only a bare F key (F1–F20, no modifiers) gets an Fn twin.
    @Test("TB-58 default F keys")
    func defaultFKeys() {
        #expect(KeyboardShortcuts.Name.screenshot.defaultShortcut == .init(.f1))
        #expect(KeyboardShortcuts.Name.toggleMicrophone.defaultShortcut == .init(.f5))
        #expect(KeyboardShortcuts.Name.lockScreen.defaultShortcut == .init(.f6))
        #expect(KeyboardShortcuts.Name.toggleJiggler.defaultShortcut == .init(.f12))
    }

    @Test("TB-58 which shortcuts get an Fn twin")
    func fnTwins() {
        let cases: [(KeyboardShortcuts.Shortcut, Bool)] = [
            (.init(.f1), true),
            (.init(.f12), true),
            (.init(.f20), true),
            (.init(.f12, modifiers: [.shift]), false),
            (.init(.f5, modifiers: [.command]), false),
            (.init(.f6, modifiers: [.option, .control]), false),
            (.init(.m, modifiers: [.command, .shift]), false),
            (.init(.a), false),
            (.init(.space), false),
        ]
        for (shortcut, twin) in cases {
            #expect(FnHotKeys.needsTwin(carbonKeyCode: shortcut.carbonKeyCode, carbonModifiers: shortcut.carbonModifiers) == twin,
                    "\(shortcut)")
        }
    }

    // MARK: S1 layout, presence and settings

    // TB-01: Apple silicon by the "dispdfr" node (the model is then not read); Intel by name.
    @Test("TB-01 a display node means a Touch Bar, without reading the model")
    func displayNode() {
        var modelReads = 0
        func model() -> String { modelReads += 1; return "MacBookAir10,1" }
        let result = TouchBarPrivate.hasTouchBar(dispdfr: true, model: model())
        #expect(result)
        #expect(modelReads == 0)
    }

    @Test("TB-01 Intel models by name", arguments: [
        ("MacBookPro15,1", true), ("MacBookPro15,4", true), ("MacBookPro16,1", true),
        ("MacBookPro16,2", true), ("MacBookPro16,4", true),
        ("MacBookPro16,3", false), ("MacBookPro17,1", false), ("MacBookPro14,3", false),
        ("MacBookAir10,1", false), ("Mac14,2", false), ("", false),
    ])
    func intelModels(model: String, touchBar: Bool) {
        #expect(TouchBarPrivate.hasTouchBar(dispdfr: false, model: model) == touchBar)
    }

    // TB-06: the menu bar readings are off by default on a Mac with a Touch Bar, on without one.
    @Test("TB-06 menu bar readings by default", arguments: [true, false])
    func menuBarReadingsDefault(hasTouchBar: Bool) throws {
        let empty = try Self.emptySuite(keys: MenuBarReadings.Kind.allCases.map(\.key))
        #expect(MenuBarReadings.shownByDefault(hasTouchBar: hasTouchBar) == !hasTouchBar)
        for kind in MenuBarReadings.Kind.allCases {
            #expect(MenuBarReadings.isShown(kind, in: empty, hasTouchBar: hasTouchBar) == !hasTouchBar, "\(kind)")
        }
    }

    // TB-36: what is saved: all names in the user's order, the hidden ones in default order.
    @Test("TB-36 what a layout saves")
    func encodeLayout() {
        let order: [BarItem] = [.music, .time] + Self.defaultOrder.filter { $0 != .music && $0 != .time }
        let saved = BarLayout.encode(order: order, hidden: [.time, .weather, .battery])
        #expect(saved.order == order.map(\.rawValue))
        #expect(saved.hidden == ["battery", "weather", "time"])
        #expect(BarLayout.encode(order: Self.defaultOrder, hidden: []).hidden == [])
    }

    // TB-36 / TB-37: a saved layout reads back as it was (the order survives a relaunch).
    @Test("TB-36 TB-37 a saved layout reads back")
    func layoutRoundTrip() {
        let order = Self.defaultOrder.reversed() as [BarItem]
        let hidden: Set<BarItem> = [.cpu, .lock]
        let saved = BarLayout.encode(order: order, hidden: hidden)
        let read = BarLayout.decode(savedOrder: saved.order, savedHidden: saved.hidden)
        #expect(read.order == order)
        #expect(read.hidden == hidden)
    }

    // TB-37: unknown names are dropped, missing buttons appended in default order, unknown hidden
    // names ignored; nothing saved = default order, nothing hidden.
    @Test("TB-37 reading a saved layout")
    func decodeLayout() {
        let read = BarLayout.decode(savedOrder: ["time", "bogus", "music"], savedHidden: ["bogus", "weather"])
        #expect(read.order == [.time, .music] + Self.defaultOrder.filter { $0 != .time && $0 != .music })
        #expect(read.hidden == [.weather])

        let fresh = BarLayout.decode(savedOrder: nil, savedHidden: nil)
        #expect(fresh.order == Self.defaultOrder)
        #expect(fresh.hidden.isEmpty)
        #expect(BarLayout.decode(savedOrder: ["bogus"], savedHidden: ["bogus"]).hidden.isEmpty)
    }

    // TB-38 / TB-08: saved order, minus hidden, minus buttons whose module is off.
    @Test("TB-38 TB-08 the buttons on the bar")
    func visibleButtons() {
        let allOn: (ModuleID) -> Bool = { _ in true }
        #expect(BarLayout.visible(order: Self.defaultOrder, hidden: [], isOn: allOn) == Self.defaultOrder)

        let musicOff = BarLayout.visible(order: Self.defaultOrder, hidden: [], isOn: { $0 != .music })
        #expect(musicOff == Self.defaultOrder.filter { $0 != .music })

        // The bar's own buttons belong to no module, so they show with every module off.
        let allOff = BarLayout.visible(order: Self.defaultOrder, hidden: [], isOn: { _ in false })
        #expect(allOff == [.battery, .brightness, .keyboardLight, .volume, .time])

        let custom: [BarItem] = [.time, .music] + Self.defaultOrder.filter { $0 != .time && $0 != .music }
        let shown = BarLayout.visible(order: custom, hidden: [.battery, .volume], isOn: allOn)
        #expect(shown == custom.filter { $0 != .battery && $0 != .volume })
    }

    // TB-38: never empty: when nothing would show, the time shows, even if hidden.
    @Test("TB-38 the bar is never empty")
    func neverEmpty() {
        let allButJiggler = Set(Self.defaultOrder).subtracting([.jiggler])
        #expect(BarLayout.visible(order: Self.defaultOrder, hidden: allButJiggler, isOn: { $0 != .jiggler }) == [.time])
        #expect(BarLayout.visible(order: Self.defaultOrder, hidden: Set(Self.defaultOrder), isOn: { _ in true }) == [.time])
        #expect(BarLayout.visible(order: Self.defaultOrder, hidden: allButJiggler, isOn: { _ in true }) == [.jiggler])
    }

    // TB-59: what a Mac that never opened Settings gets. Read from an empty suite, never the
    // user's settings (a leak of the user's real values would fail the first check).
    @Test("TB-59 defaults on a fresh Mac")
    func freshDefaults() throws {
        let empty = try Self.emptySuite(keys: [
            "module.touchBar.enabled", "module.dialogs.enabled", TouchBarModule.autoCloseKey,
            TouchBarModule.colorModeKey, TouchBarModule.monochromeKey, TouchBarModule.batteryIconKey,
            BarLayout.orderKey, BarLayout.hiddenKey, SliceGameView.styleKey, SliceGameView.bestKey,
        ])
        #expect(ModuleManager.isOn(.touchBar, in: empty))
        #expect(ModuleManager.isOn(.dialogs, in: empty))
        #expect(TouchBarModule.autoClose(in: empty))
        #expect(TouchBarModule.colorMode(in: empty) == .multicolor)
        #expect(TouchBarModule.monochromeHex(in: empty) == 0xFFFFFF)
        #expect(!TouchBarModule.showsBatteryIcon(in: empty))
        let layout = BarLayout.decode(savedOrder: empty.stringArray(forKey: BarLayout.orderKey),
                                      savedHidden: empty.stringArray(forKey: BarLayout.hiddenKey))
        #expect(layout.order == Self.defaultOrder)
        #expect(layout.hidden.isEmpty)
        #expect(SliceGameView.style(in: empty) == .glossy)
        #expect(SliceGameView.best(in: empty) == 0)
        for kind in MenuBarReadings.Kind.allCases {
            #expect(!MenuBarReadings.isShown(kind, in: empty, hasTouchBar: true), "\(kind)")
        }
    }

    // MARK: S2 button looks

    // TB-16: the level color only on the icon (green above 50 %, yellow 20–50 %, red below 20 %);
    // text mode has none; no reading shows "—" as text, even with the icon chosen.
    @Test("TB-16 battery look", arguments: [
        (100, true, true, "100%", BarLooks.BatteryLevel?.some(.green)),
        (51, true, true, "51%", .green),
        (50, true, true, "50%", .yellow),
        (20, true, true, "20%", .yellow),
        (19, true, true, "19%", .red),
        (0, true, true, "0%", .red),
        (85, false, false, "85%", nil),
        (10, false, false, "10%", nil),
        (nil, true, false, "—", nil),
        (nil, false, false, "—", nil),
    ] as [(Int?, Bool, Bool, String, BarLooks.BatteryLevel?)])
    func batteryLook(percent: Int?, showIcon: Bool, icon: Bool, text: String, level: BarLooks.BatteryLevel?) {
        for charging in [false, true] {
            let look = BarLooks.battery(percent: percent, charging: charging, showIcon: showIcon)
            #expect(look.icon == icon)
            #expect(look.text == text)
            #expect(look.level == level)
        }
        #expect(BarLooks.battery(percent: percent, charging: true, showIcon: showIcon).label
                != BarLooks.battery(percent: percent, charging: false, showIcon: showIcon).label)
    }

    // TB-17: the small sun below half; unreadable counts as full.
    @Test("TB-17 brightness symbol", arguments: [
        (Float?.some(0), "sun.min.fill"), (0.49, "sun.min.fill"), (0.5, "sun.max.fill"), (1, "sun.max.fill"), (nil, "sun.max.fill"),
    ] as [(Float?, String)])
    func brightnessSymbol(level: Float?, symbol: String) {
        #expect(BarLooks.brightness(level).symbol == symbol)
    }

    // TB-18: the small light below half; unreadable counts as off.
    @Test("TB-18 keyboard light symbol", arguments: [
        (Float?.some(0), "light.min"), (0.49, "light.min"), (0.5, "light.max"), (1, "light.max"), (nil, "light.min"),
    ] as [(Float?, String)])
    func keyboardSymbol(level: Float?, symbol: String) {
        #expect(BarLooks.keyboardLight(level).symbol == symbol)
    }

    // TB-19: crossed speaker when muted or at 0; 1/2/3 waves below 34 %, below 67 %, from 67 %;
    // an output with no volume control counts as 50 %, not muted.
    @Test("TB-19 volume symbol", arguments: [
        (Float?.some(0.33), false, "speaker.wave.1.fill"),
        (0.01, false, "speaker.wave.1.fill"),
        (0.34, false, "speaker.wave.2.fill"),
        (0.66, false, "speaker.wave.2.fill"),
        (0.67, false, "speaker.wave.3.fill"),
        (1, false, "speaker.wave.3.fill"),
        (0.8, true, "speaker.slash.fill"),
        (0, false, "speaker.slash.fill"),
        (nil, false, "speaker.wave.2.fill"),
        (nil, true, "speaker.slash.fill"),
    ] as [(Float?, Bool, String)])
    func volumeSymbol(level: Float?, muted: Bool, symbol: String) {
        #expect(BarLooks.volume(level: level, muted: muted).symbol == symbol)
    }

    // TB-20 / MIC-65 / TB-24: the state is in the symbol (and the words), never in color alone.
    @Test("TB-20 MIC-65 TB-24 state symbols")
    func stateSymbols() {
        #expect(BarLooks.jiggler(on: true).symbol == "cursorarrow.motionlines")
        #expect(BarLooks.jiggler(on: false).symbol == "cursorarrow")
        #expect(BarLooks.jiggler(on: true).label != BarLooks.jiggler(on: false).label)
        #expect(BarLooks.microphone(muted: true).symbol == "mic.slash.fill")
        #expect(BarLooks.microphone(muted: false).symbol == "mic.fill")
        #expect(BarLooks.microphone(muted: true).label != BarLooks.microphone(muted: false).label)
        // O-1 (user's pick A): no microphone → dimmed mic.slash, whatever the mute says.
        for muted in [true, false] {
            let none = BarLooks.microphone(muted: muted, available: false)
            #expect(none.symbol == "mic.slash" && none.dimmed && none.label != BarLooks.microphone(muted: muted).label)
        }
        #expect(!BarLooks.microphone(muted: true).dimmed && !BarLooks.microphone(muted: false).dimmed)
        #expect(BarLooks.music(playing: true).symbol == "music.quarternote.3")
        #expect(BarLooks.music(playing: false).symbol == "music.note")
        #expect(BarLooks.music(playing: true).label != BarLooks.music(playing: false).label)
    }

    // TB-25 / TB-14: a report shows its condition and temperature; location denied → location.slash;
    // nothing yet → a plain cloud (no loading placeholder).
    @Test("TB-25 TB-14 weather look")
    func weatherLook() {
        let report = WeatherModule.Report(celsius: 18, code: 0, isDay: true, date: .now)
        for noLocation in [false, true] {
            let look = BarLooks.weather(report: report, noLocation: noLocation)
            #expect(look.symbol == report.symbol)
            #expect(look.text == TemperatureText.short(celsius: 18))
        }
        #expect(BarLooks.weather(report: nil, noLocation: true).symbol == "location.slash")
        #expect(BarLooks.weather(report: nil, noLocation: false).symbol == "cloud")
        #expect(BarLooks.weather(report: nil, noLocation: false).text.isEmpty)
    }

    // TB-26 / TB-14: low below 50 °C, medium below 75 °C, high from 75 °C; unreadable → medium with "—".
    @Test("TB-26 thermometer", arguments: [
        (0, "thermometer.low"), (49, "thermometer.low"), (50, "thermometer.medium"),
        (74, "thermometer.medium"), (75, "thermometer.high"), (110, "thermometer.high"),
    ])
    func thermometer(celsius: Int, symbol: String) {
        #expect(BarLooks.thermometer(celsius: celsius) == symbol)
        #expect(BarLooks.cpu(celsius: celsius).symbol == symbol)
        #expect(BarLooks.cpu(celsius: celsius).text == TemperatureText.short(celsius: Double(celsius)))
    }

    @Test("TB-26 TB-14 CPU temperature unreadable")
    func cpuUnreadable() {
        let look = BarLooks.cpu(celsius: nil)
        #expect(look.symbol == "thermometer.medium")
        #expect(look.text == "—")
    }

    // TB-27: testing = the needle; a result = download 3 s, upload 3 s, idle; a failure = 6 s, idle.
    @Test("TB-27 speed test sequence")
    func speedSequence() {
        typealias S = BarLooks.SpeedStep
        for (failed, result) in [(false, false), (true, false), (false, true), (true, true)] {
            #expect(BarLooks.speedSteps(isRunning: true, failed: failed, hasResult: result) == [S(at: 0, phase: .testing)])
        }
        #expect(BarLooks.speedSteps(isRunning: false, failed: false, hasResult: true)
                == [S(at: 0, phase: .download), S(at: 3, phase: .upload), S(at: 6, phase: .idle)])
        #expect(BarLooks.speedSteps(isRunning: false, failed: true, hasResult: false)
                == [S(at: 0, phase: .failed), S(at: 6, phase: .idle)])
        // A failure after an earlier result shows the failure, not the old result.
        #expect(BarLooks.speedSteps(isRunning: false, failed: true, hasResult: true)
                == [S(at: 0, phase: .failed), S(at: 6, phase: .idle)])
        #expect(BarLooks.speedSteps(isRunning: false, failed: false, hasResult: false) == [S(at: 0, phase: .idle)])
    }

    // TB-27: the needle sweeps 0 → 33 → 67 → 100 and starts again, one step every 0.6 s.
    @Test("TB-27 speed test needle")
    func speedNeedle() {
        let percents = (0...4).map { BarLooks.needle(step: $0) }
        #expect(percents == ["gauge.with.dots.needle.0percent", "gauge.with.dots.needle.33percent",
                             "gauge.with.dots.needle.67percent", "gauge.with.dots.needle.100percent",
                             "gauge.with.dots.needle.0percent"])
        #expect(BarLooks.needleInterval == 0.6)
        #expect(BarLooks.speedTest(phase: .testing, needleStep: 2, result: nil).symbol == "gauge.with.dots.needle.67percent")
    }

    // TB-27: each phase's look; a download or upload phase without a result shows idle.
    @Test("TB-27 speed test looks")
    func speedLooks() {
        let result = SpeedTestModule.Result(download: 245, upload: 9.4, latency: 20, rpm: 800, date: .now)
        let down = BarLooks.speedTest(phase: .download, needleStep: 0, result: result)
        #expect(down.symbol == "arrow.down")
        #expect(down.text == SpeedText(mbps: 245).number && down.unit == "Mbps")
        let up = BarLooks.speedTest(phase: .upload, needleStep: 0, result: result)
        #expect(up.symbol == "arrow.up")
        #expect(up.text == SpeedText(mbps: 9.4).number && up.unit == "Mbps")
        #expect(BarLooks.speedTest(phase: .failed, needleStep: 0, result: result).symbol == "wifi.exclamationmark")
        #expect(BarLooks.speedTest(phase: .idle, needleStep: 0, result: result).symbol == "speedometer")
        #expect(BarLooks.speedTest(phase: .download, needleStep: 0, result: nil).symbol == "speedometer")
        #expect(BarLooks.speedTest(phase: .upload, needleStep: 0, result: nil).symbol == "speedometer")
    }

    // TB-11 / TB-16: multicolor = the state color (battery level) or the button's own, white text;
    // monochrome = one color for symbols and texts; rainbow = red → violet left to right, texts too.
    @Test("TB-11 TB-16 button colors by mode")
    func tints() {
        let own = NSColor(hex: 0x08DA73), state = NSColor.systemRed, mono = NSColor(hex: 0x123456)
        let multi = BarView.tint(mode: .multicolor, index: 3, count: 13, own: own, state: nil, mono: mono)
        #expect(multi.color == own && !multi.colorsText)
        #expect(BarView.tint(mode: .multicolor, index: 3, count: 13, own: own, state: state, mono: mono).color == state)
        let single = BarView.tint(mode: .monochrome, index: 3, count: 13, own: own, state: state, mono: mono)
        #expect(single.color == mono && single.colorsText)

        for (index, count, hue) in [(0, 13, 0.0), (6, 13, 0.415), (12, 13, 0.83), (0, 1, 0.0), (1, 2, 0.83)] {
            let rainbow = BarView.tint(mode: .rainbow, index: index, count: count, own: own, state: state, mono: mono)
            let color = rainbow.color
            // Hue is a circle: red reads back as 1.0 as well as 0.
            let distance = abs(color.hueComponent - hue)
            #expect(min(distance, 1 - distance) < 0.002, "\(index) of \(count): \(color.hueComponent)")
            #expect(abs(color.saturationComponent - 0.75) < 0.002)
            #expect(abs(color.brightnessComponent - 1) < 0.002)
            #expect(rainbow.colorsText)
        }
    }

    // MARK: S3 timing and gestures

    // TB-31: 4 s after opening if untouched, 1 s after the last change, 0.4 s after the finger lifts;
    // with auto-close off only the ✕ closes it.
    @Test("TB-31 when a slider closes by itself")
    func sliderCloseDelay() {
        #expect(SliderPanel.closeDelay(after: .open, autoClose: true) == 4)
        #expect(SliderPanel.closeDelay(after: .change, autoClose: true) == 1)
        #expect(SliderPanel.closeDelay(after: .release, autoClose: true) == 0.4)
        for reason in [SliderPanel.CloseReason.open, .change, .release] {
            #expect(SliderPanel.closeDelay(after: reason, autoClose: false) == nil)
        }
    }

    // TB-29: rightwards from the bar's left half, leftwards from the right half; as wide as the
    // button plus 300 pt, at most the bar.
    @Test("TB-29 where a slider opens", arguments: [
        (CGRect(x: 72, y: 0, width: 70, height: 30), true, 370.0),    // brightness, 2nd of 13
        (CGRect(x: 0, y: 0, width: 70, height: 30), true, 370.0),
        (CGRect(x: 787, y: 0, width: 70, height: 30), false, 370.0),  // volume, 11th of 13
        (CGRect(x: 467, y: 0, width: 70, height: 30), false, 370.0),  // center exactly at the half → leftwards
        (CGRect(x: 466, y: 0, width: 70, height: 30), true, 370.0),   // 1 pt left of the half → rightwards
        (CGRect(x: 0, y: 0, width: 800, height: 30), true, 1004.0),   // few buttons: never wider than the bar
    ] as [(CGRect, Bool, CGFloat)])
    func sliderPlacement(frame: CGRect, opensRight: Bool, width: CGFloat) {
        let placement = BarView.sliderPlacement(buttonFrame: frame, barWidth: 1004)
        #expect(placement.opensRight == opensRight)
        #expect(placement.width == width)
    }

    // TB-32: a slider sets 0…1 only; the volume slider at 0 mutes, anything above unmutes.
    @Test("TB-32 what a slider sets")
    func sliderValues() {
        #expect(OutputVolume.clamped(-0.2) == 0)
        #expect(OutputVolume.clamped(1.4) == 1)
        #expect(DisplayBrightness.clamped(0.45) == 0.45)
        #expect(KeyboardBrightness.clamped(2) == 1)
        #expect(OutputVolume.mute(for: 0) == 1)
        #expect(OutputVolume.mute(for: 0.01) == 0)
        #expect(OutputVolume.mute(for: 1) == 0)
    }

    // B-12: the value follows the finger's x clamped to the track, so past the end is 100 %
    // (it stopped at 97 % and jumped back to the start value when lifted outside).
    @Test("TB-29 TB-32 B-12 the slider value follows the finger, clamped past either end")
    func sliderFollowsFinger() {
        #expect(LevelSlider.value(x: 557, width: 318.5, knob: 22) == 1)
        #expect(LevelSlider.value(x: 307, width: 318.5, knob: 22) < 1)
        #expect(LevelSlider.value(x: -40, width: 318.5, knob: 22) == 0)
        #expect(LevelSlider.value(x: 11, width: 318.5, knob: 22) == 0)
        #expect(abs(LevelSlider.value(x: 159.25, width: 318.5, knob: 22) - 0.5) < 0.0001)
        #expect(LevelSlider.value(x: 50, width: 10, knob: 22) == 0)
    }

    // TB-12 / TB-20 / TB-28 / TB-47: a hold's release isn't also a tap: taps are ignored while held
    // and for 0.5 s after.
    @Test("TB-12 TB-20 TB-28 TB-47 the release after a hold is not a tap")
    func tapGuard() {
        let ended = Date(timeIntervalSinceReferenceDate: 1000)
        #expect(!TouchBarModule.tapAllowed(holding: true, holdEnded: .distantPast, now: ended))
        #expect(!TouchBarModule.tapAllowed(holding: false, holdEnded: ended, now: ended))
        #expect(!TouchBarModule.tapAllowed(holding: false, holdEnded: ended, now: ended + 0.49))
        #expect(TouchBarModule.tapAllowed(holding: false, holdEnded: ended, now: ended + 0.5))
        #expect(TouchBarModule.tapAllowed(holding: false, holdEnded: .distantPast, now: ended))
    }

    static func local(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0) throws -> Date {
        try #require(Calendar.current.date(from: DateComponents(year: year, month: month, day: day,
                                                                hour: hour, minute: minute, second: second)))
    }

    // TB-28: 12-hour "h:mm" with no AM/PM and DD/MM/YY, whatever the Mac's region.
    @Test("TB-28 time and date texts")
    func clockTexts() throws {
        #expect(TouchBarModule.timeText(try Self.local(2026, 11, 18, 15, 7)) == "3:07")
        #expect(TouchBarModule.timeText(try Self.local(2026, 11, 18, 0, 5)) == "12:05")
        #expect(TouchBarModule.timeText(try Self.local(2026, 11, 18, 12, 0)) == "12:00")
        #expect(TouchBarModule.timeText(try Self.local(2026, 11, 18, 9, 41)) == "9:41")
        #expect(TouchBarModule.dateText(try Self.local(2026, 11, 18, 15, 7)) == "18/11/26")
        #expect(TouchBarModule.dateText(try Self.local(2027, 2, 3, 8, 0)) == "03/02/27")
    }

    // TB-28 / TB-31: the date shows 4 s with auto-close on, until the next tap with it off; the clock
    // wakes once a minute, at the start of the next one.
    @Test("TB-28 date timeout and the clock's minute")
    func clockTiming() throws {
        #expect(TouchBarModule.dateHideDelay(autoClose: true) == 4)
        #expect(TouchBarModule.dateHideDelay(autoClose: false) == nil)
        #expect(TouchBarModule.nextMinute(after: try Self.local(2026, 11, 18, 15, 7, 30)) == (try Self.local(2026, 11, 18, 15, 8)))
        #expect(TouchBarModule.nextMinute(after: try Self.local(2026, 11, 18, 15, 7)) == (try Self.local(2026, 11, 18, 15, 8)))
        #expect(TouchBarModule.nextMinute(after: try Self.local(2026, 12, 31, 23, 59, 59)) == (try Self.local(2027, 1, 1, 0, 0)))
    }

    // TB-33: after wake (nothing pending) all three levels are read; otherwise only the changed ones.
    @Test("TB-33 which levels are read")
    func levelsToRead() {
        #expect(TouchBarModule.levelsToRead(pending: []) == [.brightness, .keyboardLight, .volume])
        #expect(TouchBarModule.levelsToRead(pending: [.volume]) == [.volume])
        #expect(TouchBarModule.levelsToRead(pending: [.brightness, .keyboardLight]) == [.brightness, .keyboardLight])
    }

    // MARK: S4 dialog detection

    /// A plain Accessibility tree; counts the reads so a test can tell what was asked.
    final class Node: DialogNode {
        var role: String?
        var subrole: String?
        var modal: Bool?
        var children: [Node] = []
        weak var parent: Node?
        var focusedWindow: Node?
        var focusedElement: Node?
        nonisolated(unsafe) static var reads = 0

        init(_ role: String? = "AXGroup", subrole: String? = nil, modal: Bool? = nil, children: [Node] = []) {
            self.role = role
            self.subrole = subrole
            self.modal = modal
            self.children = children
            for child in children { child.parent = self }
        }

        func isSame(as other: Node) -> Bool { self === other }

        /// The focused element `depth` levels inside `top` (0 = `top` itself), each level a group.
        func deepest(below depth: Int) -> Node {
            var node = self
            for _ in 0..<depth {
                let child = Node()
                node.children.append(child)
                child.parent = node
                node = child
            }
            return node
        }

        /// An app whose focused window is `window`, with the focus on `focus`.
        static func app(window: Node?, focus: Node? = nil) -> Node {
            let app = Node("AXApplication")
            app.focusedWindow = window
            app.focusedElement = focus
            return app
        }
    }

    static let window = { (children: [Node]) in Node("AXWindow", subrole: "AXStandardWindow", children: children) }

    // TB-44: sheets, system dialogs and modal windows count; a plain AXDialog window doesn't.
    @Test("TB-44 what counts as a dialog", arguments: [
        ("AXSheet", nil, nil, true),
        ("AXWindow", "AXSystemDialog", nil, true),
        ("AXWindow", "AXStandardWindow", true, true),
        ("AXGroup", nil, true, true),
        ("AXWindow", "AXDialog", false, false),
        ("AXWindow", "AXDialog", nil, false),
        ("AXWindow", "AXStandardWindow", false, false),
        (nil, nil, nil, false),
    ] as [(String?, String?, Bool?, Bool)])
    func isDialog(role: String?, subrole: String?, modal: Bool?, dialog: Bool) {
        #expect(DialogsModule.isDialog(role: role, subrole: subrole, modal: modal) == dialog)
        #expect(DialogsModule.isDialog(Node(role, subrole: subrole, modal: modal)) == dialog)
    }

    // TB-44: a system prompt app in front counts even without Accessibility; other apps need it.
    @Test("TB-44 system prompt apps")
    func systemPromptApps() {
        let prompts = ["com.apple.SecurityAgent", "com.apple.UserNotificationCenter", "com.apple.coreservices.uiagent",
                       "com.apple.LocalAuthentication.UIAgent", "com.apple.CoreLocationAgent",
                       "com.apple.accessibility.universalAccessAuthWarn"]
        #expect(DialogsModule.systemPromptApps == Set(prompts))
        var appReads = 0
        func app() -> Node { appReads += 1; return Node.app(window: Self.window([])) }
        // Outside #expect: it evaluates a call's arguments up front, which would read the app.
        for id in prompts {
            let open = DialogsModule.dialogIsOpen(frontBundleID: id, trusted: false, app: app())
            #expect(open, "\(id)")
        }
        let textEdit = DialogsModule.dialogIsOpen(frontBundleID: "com.apple.TextEdit", trusted: false, app: app())
        let none = DialogsModule.dialogIsOpen(frontBundleID: nil, trusted: false, app: app())
        #expect(!textEdit && !none)
        #expect(appReads == 0) // nothing of the app is read without Accessibility or for a prompt app
    }

    // TB-44: with Accessibility, the focused window, an attached sheet, or focus inside a dialog.
    @Test("TB-44 dialogs in the front app")
    func dialogsInFrontApp() {
        func open(_ app: Node) -> Bool { DialogsModule.dialogIsOpen(frontBundleID: "com.apple.TextEdit", trusted: true, app: app) }

        #expect(!open(Node.app(window: nil)))                                   // no focused window
        #expect(!open(Node.app(window: Self.window([Node("AXButton")]))))       // a plain window
        #expect(open(Node.app(window: Node("AXWindow", subrole: "AXSystemDialog"))))
        #expect(open(Node.app(window: Self.window([Node("AXButton"), Node("AXSheet")])))) // save sheet
        #expect(open(Node.app(window: Self.window([Node("AXSheet")]))))

        // Warp: hidden plain AXDialog windows are not dialogs, even as children.
        #expect(!open(Node.app(window: Self.window([Node("AXWindow", subrole: "AXDialog", modal: false)]))))

        // Focus three levels inside a modal group that isn't a direct child of the window.
        let modal = Node("AXGroup", modal: true)
        let window = Self.window([Node("AXGroup", children: [modal])])
        #expect(!open(Node.app(window: window)))
        #expect(open(Node.app(window: window, focus: modal.deepest(below: 3))))

        // A sheet's grandchild isn't a child of the window: found through the focus only.
        let sheet = Node("AXSheet")
        let deep = Self.window([Node("AXGroup", children: [sheet])])
        #expect(!open(Node.app(window: deep)))
        #expect(open(Node.app(window: deep, focus: sheet.deepest(below: 1))))
    }

    // TB-64: the element found is the dialog itself (its "destroyed" notification is watched).
    @Test("TB-64 the dialog watched is the one found")
    func dialogFound() {
        let sheet = Node("AXSheet")
        #expect(DialogsModule.openDialog(in: Node.app(window: Self.window([Node("AXButton"), sheet]))) === sheet)
        let system = Node("AXWindow", subrole: "AXSystemDialog")
        #expect(DialogsModule.openDialog(in: Node.app(window: system)) === system)
        let modal = Node("AXGroup", modal: true)
        let window = Self.window([Node("AXGroup", children: [modal])])
        #expect(DialogsModule.openDialog(in: Node.app(window: window, focus: modal.deepest(below: 2))) === modal)
        #expect(DialogsModule.openDialog(in: Node.app(window: Self.window([Node("AXButton")]))) == nil)
    }

    // TB-44: the walk up from the focus checks 12 elements at most and stops at the window.
    @Test("TB-44 how far up the focus is followed")
    func focusWalk() {
        func open(_ app: Node) -> Bool { DialogsModule.dialogIsOpen(frontBundleID: "com.apple.TextEdit", trusted: true, app: app) }
        // The modal group is a grandchild of the window, so only the walk from the focus finds it.
        let modal = Node("AXGroup", modal: true)
        let window = Self.window([Node("AXGroup", children: [modal])])
        #expect(open(Node.app(window: window, focus: modal.deepest(below: 11)))) // the 12th element
        let far = Node("AXGroup", modal: true)
        #expect(!open(Node.app(window: Self.window([Node("AXGroup", children: [far])]), focus: far.deepest(below: 12)))) // the 13th

        // Above the window nothing counts (a modal app-level group isn't the window's dialog).
        let top = Node("AXGroup", modal: true)
        let inner = Self.window([])
        top.children = [inner]
        inner.parent = top
        #expect(!open(Node.app(window: inner, focus: inner.deepest(below: 2))))
    }

    // MARK: S5 game rules

    // TB-49: a swipe cuts a fruit it crosses within its radius + 2 pt horizontally; a fruit mostly
    // below the edge (center under −0.4 × radius) can't be cut.
    @Test("TB-49 what a swipe cuts")
    func canCut() {
        let fruit = CGPoint(x: 100, y: 15), r: CGFloat = 11
        func cuts(_ a: CGPoint, _ b: CGPoint, center: CGPoint = fruit) -> Bool {
            SliceRules.canCut(center: center, radius: r, from: a, to: b)
        }
        #expect(cuts(CGPoint(x: 90, y: 15), CGPoint(x: 110, y: 15)))   // straight through
        #expect(cuts(CGPoint(x: 60, y: 2), CGPoint(x: 140, y: 28)))    // a slanted swipe through it
        #expect(cuts(CGPoint(x: 60, y: 15), CGPoint(x: 87, y: 15)))    // ends 2 pt short of the edge
        #expect(!cuts(CGPoint(x: 60, y: 15), CGPoint(x: 86, y: 15)))   // 3 pt beside it
        #expect(cuts(CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 30)))   // up and down through it
        #expect(!cuts(CGPoint(x: 120, y: 0), CGPoint(x: 120, y: 30)))  // up and down beside it
        #expect(cuts(CGPoint(x: 90, y: 0), CGPoint(x: 110, y: 0), center: CGPoint(x: 100, y: -4.3)))
        #expect(!cuts(CGPoint(x: 90, y: 0), CGPoint(x: 110, y: 0), center: CGPoint(x: 100, y: -4.5)))
    }

    // TB-50: difficulty grows for 60 s; speed and gravity up to × 1.6.
    @Test("TB-50 difficulty", arguments: [(0.0, 0.0, 1.0), (30, 0.5, 1.3), (60, 1, 1.6), (600, 1, 1.6)])
    func difficulty(elapsed: TimeInterval, level: CGFloat, boost: CGFloat) {
        #expect(abs(SliceRules.difficulty(elapsed: elapsed) - level) < 1e-9)
        #expect(abs(SliceRules.boost(elapsed: elapsed) - boost) < 1e-9)
    }

    // TB-50: bombs after the first 4 s, 13 % of the spawns; a new object every
    // max(0.35, 0.95 − t/90) s × 0.6–1.3; after 15 s, 25 % bring another one 0.12 s later.
    @Test("TB-50 spawns")
    func spawns() {
        var rolls = 0
        func roll(_ value: Double) -> Double { rolls += 1; return value }
        // Outside #expect, which would evaluate the rolls up front.
        let early = SliceRules.isBomb(elapsed: 4, roll: roll(0))
        let calm = SliceRules.nextSpawn(elapsed: 15, spacing: 1, pairRoll: roll(0))
        #expect(!early && rolls == 0)
        #expect(abs(calm - (0.95 - 15.0 / 90)) < 1e-9 && rolls == 0)

        #expect(SliceRules.isBomb(elapsed: 4.01, roll: 0.129))
        #expect(!SliceRules.isBomb(elapsed: 4.01, roll: 0.13))
        #expect(abs(SliceRules.nextSpawn(elapsed: 0, spacing: 1, pairRoll: 0) - 0.95) < 1e-9)
        #expect(abs(SliceRules.nextSpawn(elapsed: 0, spacing: 0.6, pairRoll: 0) - 0.57) < 1e-9)
        #expect(abs(SliceRules.nextSpawn(elapsed: 0, spacing: 1.3, pairRoll: 0) - 1.235) < 1e-9)
        #expect(abs(SliceRules.nextSpawn(elapsed: 54, spacing: 1, pairRoll: 0.9) - 0.35) < 1e-9)
        #expect(abs(SliceRules.nextSpawn(elapsed: 300, spacing: 1, pairRoll: 0.9) - 0.35) < 1e-9)
        #expect(SliceRules.nextSpawn(elapsed: 16, spacing: 1, pairRoll: 0.24) == 0.12)
        #expect(SliceRules.nextSpawn(elapsed: 16, spacing: 1, pairRoll: 0.25) != 0.12)
        #expect(SliceRules.firstSpawn == 0.6)
    }

    // TB-50: 3 lives; an uncut fruit that falls back out costs one (not a bomb, not after game over).
    @Test("TB-50 lives")
    func lives() {
        #expect(SliceRules.lives == 3)
        #expect(SliceRules.afterEscape(lives: 3) == (2, false))
        #expect(SliceRules.afterEscape(lives: 2) == (1, false))
        #expect(SliceRules.afterEscape(lives: 1) == (0, true))
        #expect(SliceRules.escapeCostsLife(bomb: false, gameOver: false))
        #expect(!SliceRules.escapeCostsLife(bomb: true, gameOver: false))
        #expect(!SliceRules.escapeCostsLife(bomb: false, gameOver: true))
        #expect(SliceRules.hasEscaped(risen: true, y: -12.1, radius: 11))
        #expect(!SliceRules.hasEscaped(risen: true, y: -12, radius: 11))
        #expect(!SliceRules.hasEscaped(risen: false, y: -30, radius: 11)) // just launched, below the edge
    }

    // TB-50: the n-th fruit of a combo (each cut ≤ 0.35 s after the previous) is worth n; a single cut 1.
    @Test("TB-50 combos and points")
    func combos() {
        #expect(SliceRules.comboIndex(sinceLastCut: 10, previous: 0) == 1)
        #expect(SliceRules.comboIndex(sinceLastCut: 0.1, previous: 0) == 1) // a new swipe starts at 0
        #expect(SliceRules.comboIndex(sinceLastCut: 0.2, previous: 1) == 2)
        #expect(SliceRules.comboIndex(sinceLastCut: 0.34, previous: 2) == 3)
        #expect(SliceRules.comboIndex(sinceLastCut: 0.35, previous: 3) == 1)
        #expect((1...3).map { SliceRules.points(comboIndex: $0) } == [1, 2, 3]) // 6 points for three in a swipe
    }

    // TB-51: after game over a tap restarts after 0.8 s; the buttons come back after 6 s.
    @Test("TB-51 after game over", arguments: [
        (0.5, SliceRules.GameOver.wait), (0.8, .wait), (0.9, .tapRestarts), (6, .tapRestarts), (6.1, .close),
    ])
    func afterGameOver(elapsed: TimeInterval, expected: SliceRules.GameOver) {
        #expect(SliceRules.afterGameOver(elapsed: elapsed) == expected)
    }

    // TB-52: the best score is replaced only when beaten.
    @Test("TB-52 a new best")
    func newBest() {
        #expect(SliceRules.newBest(score: 5, best: 3) == 5)
        #expect(SliceRules.newBest(score: 3, best: 3) == nil)
        #expect(SliceRules.newBest(score: 0, best: 0) == nil)
    }

    // MARK: S6 module lifecycle

    /// Records what the module asks of the system; never touches the real Touch Bar.
    final class FakePresenter: BarPresenter {
        var hasTouchBar = true
        var isAvailable = true
        var presented = 0, minimized = 0, traysAdded = 0, traysRemoved = 0
        func present(_ bar: NSTouchBar, trayIdentifier: NSTouchBarItem.Identifier) { presented += 1 }
        func minimize(_ bar: NSTouchBar) { minimized += 1 }
        func addTrayItem(_ item: NSTouchBarItem) { traysAdded += 1 }
        func removeTrayItem(_ identifier: NSTouchBarItem.Identifier) { traysRemoved += 1 }
    }

    /// A Touch Bar module with a fake presenter and no manager (so only the bar's own buttons
    /// show: battery, brightness, keyboard light, volume, time, as the user's layout allows).
    /// Starting it only adds listeners and reads levels; nothing is shown or changed.
    static func makeBar(_ presenter: FakePresenter) -> (bar: TouchBarModule, dialogs: DialogsModule) {
        let dialogs = DialogsModule()
        let bar = TouchBarModule(jiggler: JigglerModule(), microphone: MicrophoneModule(), dialogs: dialogs,
                                 music: MusicModule(), cpu: CPUTemperatureModule(), weather: WeatherModule(),
                                 speedTest: SpeedTestModule(), presenter: presenter)
        return (bar, dialogs)
    }

    // TB-60: turning the module off releases everything it started, every time.
    @Test("TB-60 module off holds nothing")
    func moduleOffHoldsNothing() {
        let presenter = FakePresenter()
        let (bar, _) = Self.makeBar(presenter)
        for round in 1...2 {
            bar.start()
            #expect(bar.holdsObservers, "round \(round): started")
            #expect(presenter.presented >= round)
            bar.stop()
            #expect(!bar.holdsObservers, "round \(round): stopped")
            #expect(presenter.traysRemoved == round)
        }
        #expect(presenter.traysAdded == 2)
    }

    // TB-01 / TB-02: without a Touch Bar, or without the private calls, start does nothing.
    @Test("TB-01 TB-02 no Touch Bar or no private calls: nothing starts", arguments: [(false, true), (true, false)])
    func nothingStarts(hasTouchBar: Bool, isAvailable: Bool) {
        let presenter = FakePresenter()
        presenter.hasTouchBar = hasTouchBar
        presenter.isAvailable = isAvailable
        let (bar, _) = Self.makeBar(presenter)
        bar.start()
        #expect(!bar.holdsObservers)
        #expect(presenter.presented == 0 && presenter.traysAdded == 0)
        bar.stop()
    }

    // MARK: Fixes

    // B-5 / TB-46: Native Dialogs watches only while it is on AND the Touch Bar listens, so with
    // no Touch Bar (or the Touch Bar module off) it holds no observer. Safe here: watching only
    // adds an app-activation observer (the test host has no Accessibility) and never shows anything.
    @Test("B-5 TB-46 when Native Dialogs watches", arguments: [(true, true, true), (true, false, false), (false, true, false), (false, false, false)])
    func dialogsWatchRule(enabled: Bool, hasListener: Bool, watches: Bool) {
        #expect(DialogsModule.shouldWatch(enabled: enabled, hasListener: hasListener) == watches)
    }

    @Test("B-5 TB-46 Native Dialogs holds nothing without the Touch Bar")
    func dialogsWithoutListener() {
        let dialogs = DialogsModule()
        dialogs.start() // module on, no Touch Bar listening (a Mac without one)
        #expect(!dialogs.isWatching)
        dialogs.onChange = { _ in } // the Touch Bar starts
        #expect(dialogs.isWatching)
        dialogs.onChange = nil // the Touch Bar stops
        #expect(!dialogs.isWatching)
        dialogs.onChange = { _ in }
        #expect(dialogs.isWatching)
        dialogs.stop() // module off
        #expect(!dialogs.isWatching)
        dialogs.onChange = nil
        dialogs.onChange = { _ in } // the Touch Bar starts again with the module still off
        #expect(!dialogs.isWatching)
        dialogs.onChange = nil
    }

    // B-6 / TB-61: a button's watcher or timer runs only while the button is on the bar.
    @Test("B-6 TB-61 only the buttons on the bar are watched")
    func watchedButtons() {
        let all: Set<BarItem> = [.battery, .microphone, .brightness, .keyboardLight, .volume, .music, .speedTest]
        #expect(TouchBarModule.watched(shown: Self.defaultOrder) == all)

        let hidden: Set<BarItem> = [.music, .microphone, .speedTest, .volume]
        let shown = Self.defaultOrder.filter { !hidden.contains($0) }
        #expect(TouchBarModule.watched(shown: shown) == all.subtracting(hidden))

        // The fallback bar (only the time) watches nothing; the time and the CPU have their own timers.
        #expect(TouchBarModule.watched(shown: [.time]).isEmpty)
        #expect(TouchBarModule.watched(shown: [.time, .cpu, .weather, .jiggler, .lock, .screenshot]).isEmpty)
    }

    // B-7 (a) / TB-27: after a rebuild or a restart, with no sequence running the speed test
    // button shows the needle (a test runs) or idle, never a phase left from before.
    @Test("B-7 TB-27 the speed test button after a rebuild", arguments: [
        (false, true, true, TouchBarModule.SpeedRebuild.idle),
        (false, false, false, .idle),
        (true, true, false, .keep),
        (true, true, true, .keep),
        (true, false, true, .startNeedle),
        (true, false, false, .idle),
    ])
    func speedAfterRebuild(shown: Bool, sequenceRunning: Bool, testRunning: Bool, expected: TouchBarModule.SpeedRebuild) {
        #expect(TouchBarModule.speedAfterRebuild(shown: shown, sequenceRunning: sequenceRunning, testRunning: testRunning) == expected)
    }

    // B-7 (b) / TB-43: off while stepped aside for a dialog, then on: the bar is presented again.
    @Test("B-7 TB-43 a step-aside doesn't survive off and on")
    func stepAsideReset() {
        let presenter = FakePresenter()
        let (bar, dialogs) = Self.makeBar(presenter)
        bar.start()
        dialogs.onChange?(true) // a dialog came to the front
        #expect(presenter.minimized == 1)
        bar.stop()
        let before = presenter.presented
        bar.start()
        #expect(presenter.presented == before + 1)
        bar.stop()
    }

    // B-7 (c) / TB-60: each off → on cycle must not leave one more jiggler tracking behind.
    @Test("B-7 TB-60 one jiggler tracking after off and on")
    func oneJigglerTracking() {
        let (bar, _) = Self.makeBar(FakePresenter())
        for _ in 1...3 {
            bar.start()
            bar.stop()
        }
        bar.start()
        #expect(bar.jigglerTrackings == 1)
        bar.stop()
    }

    // O-8 / TB-44: Penknife's own Customize sheet doesn't make the bar step aside; Penknife's other
    // dialogs and every other app's still count.
    @Test("O-8 TB-44 the Customize sheet is not a dialog", arguments: [
        (true, true, true), (true, false, false), (false, true, false), (false, false, false),
    ])
    func customizeSheetIgnored(isPenknife: Bool, customizing: Bool, ignored: Bool) {
        #expect(DialogsModule.ignoresFront(isPenknife: isPenknife, customizingBar: customizing) == ignored)
    }

    // O-7 / TB-01 / TB-46: without a Touch Bar, only Touch Bar and Native Dialogs are unavailable.
    @Test("O-7 TB-01 TB-46 which modules need a Touch Bar")
    func modulesNeedingTouchBar() {
        for id in ModuleID.allCases {
            let needs = id == .touchBar || id == .dialogs
            #expect(id.needsTouchBar == needs, "\(id)")
            #expect(id.isAvailable(hasTouchBar: true), "\(id)")
            #expect(id.isAvailable(hasTouchBar: false) == !needs, "\(id)")
        }
    }

    /// A new empty suite (never written, so no plist is created); fails if any key is already there.
    static func emptySuite(keys: [String]) throws -> UserDefaults {
        let empty = try #require(UserDefaults(suiteName: "PenknifeTests.empty.\(UUID().uuidString)"))
        for key in keys { #expect(empty.object(forKey: key) == nil, "\(key) leaked into the empty suite") }
        return empty
    }

    @Test("O-34 b the speed test fill slows down and never passes 92 % before the test ends")
    func speedTestFillCurve() {
        let v = TestFill.values
        #expect(v.first == 0)
        #expect(zip(v, v.dropFirst()).allSatisfy { $0 < $1 })
        #expect(v.last! <= 0.92)
        #expect(v[3] > 0.45 && v[3] < 0.6)   // ~15 s: about half
    }

    @Test("O-34 b a second speed test shows its fill again (the first one hides when it ends)")
    func speedTestFillRepeats() async throws {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 78, height: 30))
        host.wantsLayer = true
        let fill = TestFill(on: host)
        fill.start()
        #expect(fill.isShown)
        fill.finish(succeeded: true)
        try await Task.sleep(for: .milliseconds(400))
        #expect(!fill.isShown)
        fill.start()
        #expect(fill.isShown)
        fill.finish(succeeded: false)
        try await Task.sleep(for: .milliseconds(400))
        #expect(!fill.isShown)
    }
}

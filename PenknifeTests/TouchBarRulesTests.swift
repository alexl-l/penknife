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

    /// A new empty suite (never written, so no plist is created); fails if any key is already there.
    static func emptySuite(keys: [String]) throws -> UserDefaults {
        let empty = try #require(UserDefaults(suiteName: "PenknifeTests.empty.\(UUID().uuidString)"))
        for key in keys { #expect(empty.object(forKey: key) == nil, "\(key) leaked into the empty suite") }
        return empty
    }
}

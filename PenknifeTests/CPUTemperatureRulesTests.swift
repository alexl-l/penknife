import Foundation
import Testing
@testable import Penknife

/// CPU temperature rules (docs/requirements/cputemp.md). Each test names the rule it checks.
/// Nothing here opens the SMC (`read()`), creates a menu bar item or writes the user's settings.
@MainActor
@Suite("CPU temperature rules")
struct CPUTemperatureRulesTests {

    @Test("CT-01 module on by default with its symbol, no actions")
    func module() {
        #expect(ModuleID.cpuTemperature.symbol == "thermometer.medium" && ModuleID.cpuTemperature.defaultOn)
        #expect(!ModuleID.cpuTemperature.needsTouchBar)
        let module = CPUTemperatureModule()
        #expect(module.actions.isEmpty && !module.needsAccessibility)
    }

    // MARK: Reading

    @Test("CT-03 core keys: Tp then Te, every 0x suffix, then 1a…9a")
    func coreKeys() {
        let keys = CPUTemperatureModule.coreKeys
        #expect(keys.count == 2 * (59 + 9))
        #expect(Set(keys).count == keys.count)
        #expect(keys.first == "Tp00" && keys.last == "Te9a")
        #expect(keys.contains("Tp0a") && keys.contains("Tp01") && keys.contains("Tp05") && keys.contains("Tp0Z"))
        #expect(keys.contains("Te0y") && keys.contains("Tp5a"))
        #expect(!keys.contains("Tp0b") && !keys.contains("Tp0z") && !keys.contains("Tp15") && !keys.contains("TCMb"))
        let lastTp = keys.firstIndex(of: "Tp9a"), firstTe = keys.firstIndex(of: "Te00")
        #expect(lastTp != nil && firstTe != nil && lastTp! < firstTe!)
    }

    @Test("CT-04 a reading counts only between 0 and 150 °C", arguments: [
        (Float(0), nil), (-3, nil), (150, nil), (200, nil), (0.5, 0.5), (54.9, Double(Float(54.9))), (149.9, Double(Float(149.9))),
    ] as [(Float, Double?)])
    func celsius(raw: Float, expected: Double?) {
        #expect(CPUTemperatureModule.celsius(raw: raw) == expected)
    }

    @Test("CT-04 the hottest reading, truncated to whole degrees")
    func degrees() {
        #expect(CPUTemperatureModule.degrees([]) == nil)
        #expect(CPUTemperatureModule.degrees([54.9]) == 54)
        #expect(CPUTemperatureModule.degrees([41.2, 63.99, 58]) == 63)
    }

    // MARK: Menu bar item

    @Test("CT-07 menu bar item: symbol by style, hot from 85 °C")
    func menuBarLook() {
        typealias R = MenuBarReadings
        #expect(R.hot == 85)
        #expect(R.temperatureLook(celsius: 54, style: .sober).symbol == "thermometer.medium")
        #expect(R.temperatureLook(celsius: 54, style: .bold).symbol == "thermometer.medium")
        #expect(R.temperatureLook(celsius: 54, style: .color).symbol == "cpu")
        let normal = R.temperatureLook(celsius: 84, style: .color)
        #expect(!normal.hot && normal.text == TemperatureText.short(celsius: 84))
        let hot = R.temperatureLook(celsius: 85, style: .color)
        #expect(hot.hot && hot.label.hasSuffix(", " + String(localized: "temperature.hot", defaultValue: "hot")))
        #expect(!normal.label.contains(","))
    }

    @Test("CT-07 menu bar item unreadable: a dash, never hot")
    func menuBarUnreadable() {
        for style in MenuBarReadings.Style.allCases {
            let look = MenuBarReadings.temperatureLook(celsius: nil, style: style)
            #expect(look.text == "—" && !look.hot)
            #expect(look.label == String(localized: "CPU temperature not available"))
        }
    }

    // MARK: Text

    @Test("CT-05 whole degrees with no unit letter")
    func shortText() {
        let text = TemperatureText.short(celsius: 54)
        #expect(text.hasSuffix("°") && !text.contains("C") && !text.contains("F"))
        #expect(Int(text.dropLast()) != nil)
    }
}

import Foundation
import Testing
@testable import Penknife

/// Speed test rules (docs/requirements/speedtest.md). Each test names the rule it checks.
/// Nothing here runs networkQuality (`run()`), creates a menu bar item, shows an alert or writes
/// the user's settings.
@MainActor
@Suite("Speed test rules")
struct SpeedTestRulesTests {

    private func defaults() -> UserDefaults {
        let name = "penknife.tests.speed.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private let result = SpeedTestModule.Result(download: 87.6, upload: 196.5, latency: 106.8, rpm: 82,
                                                date: Date(timeIntervalSince1970: 1_800_000_000))

    @Test("ST-01 module on by default with its symbol, one action with no default key")
    func module() {
        #expect(ModuleID.speedTest.symbol == "speedometer" && ModuleID.speedTest.defaultOn)
        #expect(!ModuleID.speedTest.needsTouchBar)
        let module = SpeedTestModule(defaults: defaults())
        #expect(module.actions.count == 1 && module.actions[0].shortcut == .speedTest && module.actions[0].symbol == "speedometer")
        #expect(!module.needsAccessibility && !module.isRunning && !module.failed && module.result == nil)
        #expect(AlertCategory.allCases.contains(.speedTest))
    }

    // MARK: Reading the tool's output

    @Test("ST-04 parse: bits/s to Mbps, base_rtt, responsiveness rounded")
    func parse() {
        // Trimmed from a real `networkQuality -c` run on this Mac (2026-11-19).
        let json = #"{"base_rtt":106.84628295898438,"dl_throughput":87603240,"ul_throughput":196466912,"responsiveness":82.34029388427734,"interface_name":"en0"}"#
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let parsed = SpeedTestModule.parse(Data(json.utf8), now: now)
        #expect(parsed == SpeedTestModule.Result(download: 87.60324, upload: 196.466912, latency: 106.84628295898438, rpm: 82, date: now))
    }

    @Test("ST-04 no throughput is a failure", arguments: [
        #"{"error_code":-1009}"#,
        #"{"dl_throughput":0,"ul_throughput":0,"base_rtt":20}"#,
        #"{"dl_throughput":5000000}"#,
        "not json",
        "",
    ])
    func parseFails(json: String) {
        #expect(SpeedTestModule.parse(Data(json.utf8)) == nil)
    }

    @Test("ST-04 one direction is enough; missing latency and RPM read as 0")
    func parsePartial() {
        let parsed = SpeedTestModule.parse(Data(#"{"dl_throughput":0,"ul_throughput":2500000}"#.utf8))
        #expect(parsed?.download == 0 && parsed?.upload == 2.5 && parsed?.latency == 0 && parsed?.rpm == 0)
    }

    // MARK: Text

    @Test("ST-05 responsiveness bands: Low < 300 ≤ Medium < 1000 ≤ High", arguments: [
        (0, "Low"), (299, "Low"), (300, "Medium"), (999, "Medium"), (1000, "High"), (4000, "High"),
    ])
    func rating(rpm: Int, expected: String) {
        let r = SpeedTestModule.Result(download: 1, upload: 1, latency: 1, rpm: rpm, date: .now)
        #expect(r.rating == String(localized: String.LocalizationValue(expected)))
    }

    @Test("ST-05 speed units: kbps under 1, one decimal under 10, whole, then Gbps", arguments: [
        (0.85, "850", "kbps"), (9.4, "9.4", "Mbps"), (245, "245", "Mbps"), (999.4, "999", "Mbps"),
        (1200, "1.2", "Gbps"), (12_000, "12", "Gbps"),
    ])
    func units(mbps: Double, number: String, unit: String) {
        let text = SpeedText(mbps: mbps)
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = .current
        let expected = formatter.string(from: NSNumber(value: Double(number)!)) ?? number
        #expect(text.number == expected && text.unit == unit)
        #expect(text.spoken.contains(text.number))
    }

    @Test("ST-05 result texts: both speeds with arrows, latency in whole ms, rating and RPM")
    func resultTexts() {
        #expect(result.speeds.hasPrefix("↓ ") && result.speeds.contains(" · ↑ "))
        #expect(result.speeds.contains("Mbps"))
        #expect(result.details.contains("107") && result.details.contains("82"))
    }

    // MARK: Last result

    @Test("ST-06 the last result survives a relaunch; unreadable data counts as none")
    func stored() {
        let store = defaults()
        #expect(SpeedTestModule.load(from: store) == nil)
        SpeedTestModule.save(result, to: store)
        #expect(SpeedTestModule.load(from: store) == result)
        #expect(SpeedTestModule(defaults: store).result == result)
        store.set(Data("garbage".utf8), forKey: "speedTest.lastResult")
        #expect(SpeedTestModule.load(from: store) == nil)
    }

    // MARK: Menus

    @Test("ST-08 menu lines: testing hides the result; failure above the last result")
    func menuLines() {
        let testing = SpeedTestModule.menuLines(isRunning: true, failed: true, result: result)
        #expect(testing.map(\.symbol) == ["speedometer"])
        #expect(SpeedTestModule.menuLines(isRunning: false, failed: false, result: nil).isEmpty)
        let failed = SpeedTestModule.menuLines(isRunning: false, failed: true, result: result, isToday: { _ in true })
        #expect(failed.map(\.symbol) == ["wifi.exclamationmark", "speedometer", "timer"])
        #expect(failed.last?.title == result.details)
        #expect(SpeedTestModule.menuLines(isRunning: false, failed: true, result: nil).map(\.symbol) == ["wifi.exclamationmark"])
    }

    @Test("ST-08 the result's time, with the date only when it isn't today")
    func menuTime() {
        let today = SpeedTestModule.menuLines(isRunning: false, failed: false, result: result, isToday: { _ in true })[0].title
        let older = SpeedTestModule.menuLines(isRunning: false, failed: false, result: result, isToday: { _ in false })[0].title
        let time = result.date.formatted(date: .omitted, time: .shortened)
        let dated = result.date.formatted(date: .abbreviated, time: .shortened)
        #expect(today.contains(time) && !today.contains(dated) && today.contains(result.speeds))
        #expect(older.contains(dated))
    }

    // MARK: Menu bar item

    @Test("ST-09 menu bar sequence: like the Touch Bar, but only after a test it saw")
    func menuBarSteps() {
        typealias S = BarLooks.SpeedStep
        for failed in [false, true] {
            for wasTesting in [false, true] {
                #expect(MenuBarReadings.speedSteps(isRunning: true, failed: failed, hasResult: true, wasTesting: wasTesting)
                        == [S(at: 0, phase: .testing)])
            }
        }
        #expect(MenuBarReadings.speedSteps(isRunning: false, failed: false, hasResult: true, wasTesting: true)
                == [S(at: 0, phase: .download), S(at: 3, phase: .upload), S(at: 6, phase: .idle)])
        #expect(MenuBarReadings.speedSteps(isRunning: false, failed: true, hasResult: true, wasTesting: true)
                == [S(at: 0, phase: .failed), S(at: 6, phase: .idle)])
        #expect(MenuBarReadings.speedSteps(isRunning: false, failed: false, hasResult: false, wasTesting: true)
                == [S(at: 0, phase: .idle)])
        for failed in [false, true] {
            #expect(MenuBarReadings.speedSteps(isRunning: false, failed: failed, hasResult: true, wasTesting: false)
                    == [S(at: 0, phase: .idle)])
        }
    }

    @Test("ST-09 menu bar looks: needle, speed with its unit on one line, failure, idle")
    func menuBarLooks() {
        #expect(MenuBarReadings.speedLook(phase: .testing, needleStep: 1, result: nil).symbol == "gauge.with.dots.needle.33percent")
        let down = MenuBarReadings.speedLook(phase: .download, needleStep: 0, result: result)
        let speed = SpeedText(mbps: result.download)
        #expect(down.symbol == "arrow.down" && down.text == "\(speed.number) Mbps" && down.label.contains(speed.spoken))
        let up = MenuBarReadings.speedLook(phase: .upload, needleStep: 0, result: result)
        #expect(up.symbol == "arrow.up" && up.text == "\(SpeedText(mbps: result.upload).number) Mbps")
        let failed = MenuBarReadings.speedLook(phase: .failed, needleStep: 0, result: result)
        #expect(failed.symbol == "wifi.exclamationmark" && failed.text == nil)
        for phase in [BarLooks.SpeedPhase.idle, .download, .upload] {
            let idle = MenuBarReadings.speedLook(phase: phase, needleStep: 0, result: phase == .idle ? result : nil)
            #expect(idle.symbol == "speedometer" && idle.text == nil)
        }
    }
}

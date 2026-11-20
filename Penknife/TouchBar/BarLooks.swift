import AppKit

/// What each Touch Bar button shows for a state (S2): plain rules the module's update methods
/// call with the values they just read, so tests pass plain values (TB-16…TB-27, MIC-65).
/// Each look carries what VoiceOver reads (TB-13); state is never shown by color alone.
enum BarLooks {
    struct Look: Equatable {
        var symbol: String?
        var text = ""
        /// With a unit, the text is a number drawn over it (the speed test, TB-10).
        var unit = ""
        /// Shown at 35 %: the thing exists but can't be used now (no microphone, O-1).
        var dimmed = false
        var label: String
    }

    // MARK: Battery (TB-16)

    /// The battery icon's color in multicolor mode; the text stays white.
    enum BatteryLevel: Equatable {
        case green, yellow, red

        var color: NSColor {
            switch self {
            case .green: .systemGreen
            case .yellow: .systemYellow
            case .red: .systemRed
            }
        }
    }

    struct BatteryLook: Equatable {
        /// Draw the battery icon instead of the text (only with a reading).
        let icon: Bool
        /// "85%", or "—" with no reading.
        let text: String
        /// Only on the icon: green above 50 %, yellow from 20 to 50 %, red below 20 %.
        let level: BatteryLevel?
        let label: String
    }

    static func battery(percent: Int?, charging: Bool, showIcon: Bool) -> BatteryLook {
        let text = percent.map { "\($0)%" } ?? "—"
        let label = charging
            ? String(localized: "Battery \(text), charging. Tap to switch between percentage and icon; hold to change the colors.")
            : String(localized: "Battery \(text). Tap to switch between percentage and icon; hold to change the colors.")
        let icon = showIcon && percent != nil
        let level: BatteryLevel? = switch (icon, percent) {
        case (true, let p?) where p > 50: .green
        case (true, let p?) where p >= 20: .yellow
        case (true, _?): .red
        default: nil
        }
        return BatteryLook(icon: icon, text: text, level: level, label: label)
    }

    // MARK: Levels (TB-17, TB-18, TB-19)

    /// Unreadable counts as full (sun.max.fill).
    static func brightness(_ level: Float?) -> Look {
        let level = level ?? 1
        return Look(symbol: level < 0.5 ? "sun.min.fill" : "sun.max.fill",
                    label: String(localized: "Brightness \(percent(level))"))
    }

    /// Unreadable counts as off (light.min).
    static func keyboardLight(_ level: Float?) -> Look {
        let level = level ?? 0
        return Look(symbol: level < 0.5 ? "light.min" : "light.max",
                    label: String(localized: "Keyboard backlight \(percent(level))"))
    }

    /// Outputs without volume control (HDMI, some DACs) have no level: 50 %, not muted.
    static func volume(level: Float?, muted: Bool) -> Look {
        let level = level ?? 0.5
        let muted = muted || level == 0
        let symbol = muted ? "speaker.slash.fill"
            : level < 0.34 ? "speaker.wave.1.fill" : level < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        return Look(symbol: symbol,
                    label: muted ? String(localized: "Volume, muted") : String(localized: "Volume \(percent(level))"))
    }

    // MARK: States (TB-20, TB-21, TB-24)

    static func jiggler(on: Bool) -> Look {
        Look(symbol: on ? "cursorarrow.motionlines" : "cursorarrow",
             label: on ? String(localized: "Mouse Jiggler, on") : String(localized: "Mouse Jiggler, off"))
    }

    /// No input device at all (O-1, user's pick A): dimmed, never "open" or "muted".
    static func microphone(muted: Bool, available: Bool = true) -> Look {
        guard available else {
            return Look(symbol: "mic.slash", dimmed: true, label: String(localized: "Microphone: none connected"))
        }
        return Look(symbol: muted ? "mic.slash.fill" : "mic.fill",
             label: muted ? String(localized: "Microphone muted") : String(localized: "Microphone on"))
    }

    static func music(playing: Bool) -> Look {
        let hint = String(localized: "One tap plays or pauses, two go to the next song, three to the previous one.")
        return Look(symbol: playing ? "music.quarternote.3" : "music.note",
                    label: (playing ? String(localized: "Music, playing.") : String(localized: "Music, paused.")) + " " + hint)
    }

    // MARK: Readings (TB-25, TB-26)

    static func weather(report: WeatherModule.Report?, noLocation: Bool) -> Look {
        if let report {
            Look(symbol: report.symbol, text: TemperatureText.short(celsius: report.celsius),
                 label: String(localized: "Weather: \(report.summary), \(TemperatureText.long(celsius: report.celsius))"))
        } else if noLocation {
            Look(symbol: "location.slash", label: String(localized: "Weather: location access is off. Tap to open Settings."))
        } else {
            Look(symbol: "cloud", label: String(localized: "Weather: no data yet"))
        }
    }

    static func thermometer(celsius: Int) -> String {
        celsius < 50 ? "thermometer.low" : celsius < 75 ? "thermometer.medium" : "thermometer.high"
    }

    static func cpu(celsius: Int?) -> Look {
        guard let celsius else {
            return Look(symbol: "thermometer.medium", text: "—", label: String(localized: "CPU temperature not available"))
        }
        return Look(symbol: thermometer(celsius: celsius), text: TemperatureText.short(celsius: Double(celsius)),
                    label: String(localized: "CPU temperature: \(TemperatureText.long(celsius: Double(celsius)))"))
    }

    // MARK: Speed test (TB-27)

    enum SpeedPhase: Equatable { case idle, testing, download, upload, failed }

    /// A phase shown `at` seconds after the test changed.
    struct SpeedStep: Equatable {
        let at: TimeInterval
        let phase: SpeedPhase
    }

    /// Variant 4 (user, 2026-11-14): testing = the needle sweeps (its own 0.6 s timer); a result =
    /// download for 3 s, upload for 3 s, idle; a failure for 6 s, then idle.
    static func speedSteps(isRunning: Bool, failed: Bool, hasResult: Bool) -> [SpeedStep] {
        if isRunning { return [SpeedStep(at: 0, phase: .testing)] }
        if failed { return [SpeedStep(at: 0, phase: .failed), SpeedStep(at: 6, phase: .idle)] }
        if hasResult {
            return [SpeedStep(at: 0, phase: .download), SpeedStep(at: 3, phase: .upload), SpeedStep(at: 6, phase: .idle)]
        }
        return [SpeedStep(at: 0, phase: .idle)]
    }

    static let needleInterval: TimeInterval = 0.6
    static let needles = ["gauge.with.dots.needle.0percent", "gauge.with.dots.needle.33percent",
                          "gauge.with.dots.needle.67percent", "gauge.with.dots.needle.100percent"]

    /// The needle after `step` timer ticks: 0 → 33 → 67 → 100 → 0…
    static func needle(step: Int) -> String { needles[step % needles.count] }

    static func speedTest(phase: SpeedPhase, needleStep: Int, result: SpeedTestModule.Result?) -> Look {
        switch phase {
        case .testing:
            return Look(symbol: needle(step: needleStep), label: String(localized: "Speed test: testing…"))
        case .download where result != nil:
            let speed = SpeedText(mbps: result!.download)
            return Look(symbol: "arrow.down", text: speed.number, unit: speed.unit,
                        label: String(localized: "Download \(speed.spoken)"))
        case .upload where result != nil:
            let speed = SpeedText(mbps: result!.upload)
            return Look(symbol: "arrow.up", text: speed.number, unit: speed.unit,
                        label: String(localized: "Upload \(speed.spoken)"))
        case .failed:
            return Look(symbol: "wifi.exclamationmark", label: String(localized: "Couldn't test the speed. Tap to try again."))
        default:
            return Look(symbol: "speedometer", label: String(localized: "Speed Test"))
        }
    }

    // MARK: Helpers

    static func percent(_ level: Float) -> String {
        Double(level).formatted(.percent.precision(.fractionLength(0)))
    }
}

extension BarButton {
    func show(_ look: BarLooks.Look) {
        show(symbol: look.symbol, text: look.text, unit: look.unit, dimmed: look.dimmed, label: look.label)
    }
}

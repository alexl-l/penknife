import AppKit
import os

/// Internet speed test (R-10) with macOS `networkQuality -c`. One test at a time (~20–45 s);
/// only the last result is kept. Nothing runs between tests; the tool is ended if the module
/// stops or Penknife quits.
final class SpeedTestModule: Module {
    let id = ModuleID.speedTest

    struct Result: Codable, Equatable {
        /// Megabits per second.
        let download: Double
        let upload: Double
        /// Idle latency (ping), milliseconds.
        let latency: Double
        /// Responsiveness under load, round-trips per minute.
        let rpm: Int
        let date: Date

        /// Low < 300 ≤ Medium < 1000 ≤ High: the bands of the IETF responsiveness draft
        /// networkQuality comes from (Apple doesn't publish its own cutoffs).
        var rating: String {
            switch rpm {
            case ..<300: String(localized: "rating.low", defaultValue: "Low")
            case ..<1000: String(localized: "rating.medium", defaultValue: "Medium")
            default: String(localized: "rating.high", defaultValue: "High")
            }
        }

        var speeds: String {
            let down = SpeedText(mbps: download), up = SpeedText(mbps: upload)
            return "↓ \(down.number) \(down.unit) · ↑ \(up.number) \(up.unit)"
        }
        var details: String {
            String(localized: "Latency \(Int(latency.rounded())) ms · Responsiveness \(rating) (\(rpm) RPM)")
        }
    }

    private static let resultKey = "speedTest.lastResult"

    private(set) var isRunning = false
    private(set) var result: Result?
    /// Set when the last test failed; cleared when a new one starts.
    private(set) var failed = false
    /// The Touch Bar listens; the menu reads the state when it opens.
    var onChange: (() -> Void)?
    /// Posted with `onChange`, for other listeners (the menu bar item, R-30).
    static let didChangeNotification = Notification.Name("PenknifeSpeedTestDidChange")

    private func changed() {
        onChange?()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    /// The running tool's pid, written from the background thread that waits for it;
    /// -1 = cancelled before the pid was known (the tool is killed as soon as it starts).
    private let pid = OSAllocatedUnfairLock<Int32>(initialState: 0)
    /// Set only by Penknife's own cancel (module off, quitting): the one end that stays silent (B-22).
    private var cancelled = false
    private var quitObserver: NSObjectProtocol?
    private let log = Logger(subsystem: "Penknife", category: "SpeedTest")

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        result = Self.load(from: defaults)
    }

    /// The last result survives a relaunch (R-10); unreadable data counts as none.
    static func load(from defaults: UserDefaults) -> Result? {
        defaults.data(forKey: resultKey).flatMap { try? JSONDecoder().decode(Result.self, from: $0) }
    }

    static func save(_ result: Result, to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(result) { defaults.set(data, forKey: resultKey) }
    }

    /// The lines Penknife's menu and the menu bar item's menu show (R-10, R-30): "testing…" while
    /// a test runs; otherwise the failure (if the last test failed) and the last result with its
    /// time (with the date when it isn't from today).
    static func menuLines(isRunning: Bool, failed: Bool, result: Result?,
                          isToday: (Date) -> Bool = Calendar.current.isDateInToday) -> [(title: String, symbol: String)] {
        if isRunning { return [(String(localized: "Speed test: testing…"), "speedometer")] }
        var lines: [(title: String, symbol: String)] = []
        if failed {
            lines.append((String(localized: "Speed test failed. Check the internet connection."), "wifi.exclamationmark"))
        }
        if let result {
            let time = result.date.formatted(date: isToday(result.date) ? .omitted : .abbreviated, time: .shortened)
            lines.append((String(localized: "Speed (\(time)): \(result.speeds)"), "speedometer"))
            lines.append((result.details, "timer"))
        }
        return lines
    }

    var actions: [ModuleAction] {
        [ModuleAction(shortcut: .speedTest, title: String(localized: "Speed Test"), symbol: "speedometer") { [weak self] in
            self?.run()
        }]
    }

    func start() {
        quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        }
    }

    private func showTesting() {
        HUD.shared.show(String(localized: "Testing internet speed…"), symbol: "speedometer", kind: .on, category: .speedTest)
    }

    func stop() {
        if let quitObserver { NotificationCenter.default.removeObserver(quitObserver) }
        quitObserver = nil
        cancel()
    }

    /// Starts a test. While one is running nothing new starts; the menu and the shortcut show the
    /// "Testing…" alert again (O-29), the Touch Bar doesn't (its needle already says so, TB-27).
    func run(repeatAlert: Bool = true) {
        guard !isRunning else {
            log.notice("Speed test already running; tap ignored")
            if repeatAlert { showTesting() }
            return
        }
        log.notice("Speed test started")
        isRunning = true
        cancelled = false
        failed = false
        changed()
        showTesting()
        let pid = self.pid
        pid.withLock { $0 = 0 }
        Task { [weak self] in
            let output = await Self.measure(pid: pid)
            self?.finish(output)
        }
    }

    private func cancel() {
        let active = isRunning
        if active { cancelled = true }
        pid.withLock { running in
            if running > 0 { kill(running, SIGTERM) } else if active { running = -1 }
        }
    }

    /// How a test ended. Only Penknife's own cancel is silent; a tool killed by any other signal
    /// (a crash, someone else's kill) is a failure like a non-zero exit (ST-07, B-22).
    enum Outcome: Equatable {
        case cancelled, success(Result), failure
    }

    nonisolated static func outcome(of output: (data: Data, status: Int32)?, cancelled: Bool, now: Date = Date()) -> Outcome {
        if cancelled { return .cancelled }
        guard let output, output.status == 0, let parsed = parse(output.data, now: now) else { return .failure }
        return .success(parsed)
    }

    private func finish(_ output: (data: Data, status: Int32)?) {
        isRunning = false
        let outcome = Self.outcome(of: output, cancelled: cancelled)
        cancelled = false
        // Ended by quitting or turning the module off: not a failure, the last result stays.
        if outcome == .cancelled {
            changed()
            return
        }
        log.notice("Speed test ended, status \(output?.status ?? -1)")
        if case .success(let parsed) = outcome {
            result = parsed
            failed = false
            Self.save(parsed, to: defaults)
            HUD.shared.show(parsed.speeds, detail: parsed.details, symbol: "speedometer", kind: .on, category: .speedTest)
        } else {
            failed = true
            log.error("networkQuality failed, status \(output?.status ?? -1)")
            HUD.shared.show(String(localized: "Speed test failed"), detail: String(localized: "Check the internet connection."),
                            symbol: "wifi.exclamationmark", kind: .error, category: .speedTest)
        }
        changed()
    }

    /// Runs the tool on a background queue (it blocks for the whole test) and resumes when done.
    nonisolated private static func measure(pid: OSAllocatedUnfairLock<Int32>) async -> (data: Data, status: Int32)? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: runTool(pid: pid))
            }
        }
    }

    /// The output is read while the tool runs (it can be larger than a pipe's buffer).
    nonisolated private static func runTool(pid: OSAllocatedUnfairLock<Int32>) -> (data: Data, status: Int32)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/networkQuality")
        process.arguments = ["-c"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        pid.withLock { stored in
            if stored == -1 { process.terminate() } // cancelled while starting
            stored = process.processIdentifier
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        pid.withLock { $0 = 0 }
        // Killed by a signal: the status is the signal's number, never 0, so it reads as a failure
        // unless Penknife cancelled it (B-22).
        if process.terminationReason == .uncaughtSignal {
            return (data, process.terminationStatus == 0 ? -1 : process.terminationStatus)
        }
        return (data, process.terminationStatus)
    }

    /// Keys of `networkQuality -c`: throughputs in bits/s, `base_rtt` in ms, `responsiveness` in RPM.
    /// An error run still exits 0, with only `error_code` (D: Speed test): no throughput = no result.
    nonisolated static func parse(_ data: Data, now: Date = Date()) -> Result? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let down = (json["dl_throughput"] as? NSNumber)?.doubleValue,
              let up = (json["ul_throughput"] as? NSNumber)?.doubleValue,
              down > 0 || up > 0 else { return nil }
        let latency = (json["base_rtt"] as? NSNumber)?.doubleValue ?? 0
        let rpm = (json["responsiveness"] as? NSNumber)?.doubleValue ?? 0
        return Result(download: down / 1_000_000, upload: up / 1_000_000, latency: latency,
                      rpm: Int(rpm.rounded()), date: now)
    }
}

/// A speed with its unit scaled to 3 significant digits (designer's rule, 2026-11-16):
/// under 1 Mbps in kbps (850 kbps), 1–9.9 with one decimal (9.4 Mbps), 10–999 whole (245 Mbps),
/// from 1000 in Gbps (1.2 Gbps, then whole). The same text on the Touch Bar, in the menu and
/// spelled out for VoiceOver.
struct SpeedText {
    let number: String
    let unit: String
    let spoken: String

    init(mbps: Double) {
        let value: Double, digits: Int
        if mbps < 1 {
            value = mbps * 1000; digits = 0; unit = "kbps"
        } else if mbps < 1000 {
            value = mbps; digits = mbps < 10 ? 1 : 0; unit = "Mbps"
        } else {
            value = mbps / 1000; digits = value < 10 ? 1 : 0; unit = "Gbps"
        }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = digits
        formatter.maximumFractionDigits = digits
        number = formatter.string(from: NSNumber(value: value)) ?? "\(value)"
        spoken = switch unit {
        case "kbps": String(localized: "\(number) kilobits per second")
        case "Gbps": String(localized: "\(number) gigabits per second")
        default: String(localized: "\(number) megabits per second")
        }
    }
}

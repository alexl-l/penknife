import Foundation
import IOKit

/// CPU temperature (R-9): read-only, the same value MacFanPro shows: SMC key `TCMb` truncated to
/// whole degrees; without it, the hottest core key. Reads only when asked (the Touch Bar every
/// ~10 s, the menu when it opens); the SMC connection is closed while the module is off.
final class CPUTemperatureModule: Module {
    let id = ModuleID.cpuTemperature
    let actions: [ModuleAction] = []

    private var connection: io_connect_t = 0
    /// Keys that gave a reading the first time (TCMb, or the core keys found by the scan).
    private var keys: [String]?

    func start() {}

    func stop() {
        if connection != 0 { IOServiceClose(connection) }
        connection = 0
    }

    /// Degrees Celsius, truncated; nil if the SMC can't be read.
    func read() -> Int? {
        guard open() else { return nil }
        if keys == nil { keys = findKeys() }
        let hottest = (keys ?? []).compactMap(readTemperature).max()
        return hottest.map { Int($0) }
    }

    private func open() -> Bool {
        if connection != 0 { return true }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        return IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess
    }

    /// TCMb, or every core key (Tp**: performance, Te**: efficiency; "a" is the current reading
    /// on M1, older chips number them Tp01, Tp05...).
    private func findKeys() -> [String] {
        if readTemperature("TCMb") != nil { return ["TCMb"] }
        let digits = Array("0123456789")
        let suffixes = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZacdefghijklmnopqrstuvwy")
        var found: [String] = []
        for prefix in ["Tp", "Te"] {
            for a in digits {
                for b in suffixes where a == "0" || b == "a" {
                    let key = prefix + String(a) + String(b)
                    if readTemperature(key) != nil { found.append(key) }
                }
            }
        }
        return found
    }

    // MARK: SMC

    // SMCKeyData as the AppleSMC user client expects it (80 bytes, C layout).
    private static let size = 80
    private static let keyOffset = 0, dataSizeOffset = 28, dataTypeOffset = 32
    private static let resultOffset = 40, commandOffset = 42, bytesOffset = 48
    private static let getKeyInfo: UInt8 = 9, readKey: UInt8 = 5

    private static func fourCC(_ text: String) -> UInt32 {
        text.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }

    /// Calls the SMC; returns the output buffer if it succeeded.
    private func call(_ input: [UInt8]) -> [UInt8]? {
        var output = [UInt8](repeating: 0, count: Self.size)
        var outputSize = Self.size
        let status = input.withUnsafeBytes { inPtr in
            output.withUnsafeMutableBytes { outPtr in
                IOConnectCallStructMethod(connection, 2, inPtr.baseAddress, Self.size, outPtr.baseAddress, &outputSize)
            }
        }
        return status == kIOReturnSuccess && output[Self.resultOffset] == 0 ? output : nil
    }

    /// The key's temperature in °C, or nil if it doesn't exist or isn't a float.
    private func readTemperature(_ key: String) -> Double? {
        var input = [UInt8](repeating: 0, count: Self.size)
        func put(_ value: UInt32, at offset: Int) {
            withUnsafeBytes(of: value) { input.replaceSubrange(offset..<offset + 4, with: $0) }
        }
        func get(_ buffer: [UInt8], at offset: Int) -> UInt32 {
            buffer[offset..<offset + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        }
        put(Self.fourCC(key), at: Self.keyOffset)
        input[Self.commandOffset] = Self.getKeyInfo
        guard let info = call(input), get(info, at: Self.dataTypeOffset) == Self.fourCC("flt ") else { return nil }

        put(get(info, at: Self.dataSizeOffset), at: Self.dataSizeOffset)
        input[Self.commandOffset] = Self.readKey
        guard let output = call(input) else { return nil }
        let value = output[Self.bytesOffset..<Self.bytesOffset + 4].withUnsafeBytes { $0.loadUnaligned(as: Float.self) }
        return value > 0 && value < 150 ? Double(value) : nil
    }
}

/// Temperatures in the unit the user chose in System Settings (°C or °F).
enum TemperatureText {
    private static let long: MeasurementFormatter = {
        let formatter = MeasurementFormatter()
        formatter.unitStyle = .long
        formatter.numberFormatter.maximumFractionDigits = 0
        return formatter
    }()

    /// "52°" for the Touch Bar (no unit letter, as before in MTMR).
    static func short(celsius: Double) -> String {
        let value = Measurement(value: celsius, unit: UnitTemperature.celsius)
            .converted(to: UnitTemperature(forLocale: .current)).value
        return "\(Int(value.rounded()))°"
    }

    /// "52 degrees Celsius" for VoiceOver and the menu.
    static func long(celsius: Double) -> String {
        long.string(from: Measurement(value: celsius, unit: UnitTemperature.celsius))
    }
}

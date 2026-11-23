import Foundation
import Testing
@testable import Penknife

/// R-42 (GN-28…31): export and import of the settings file. Only in-memory suites and temporary
/// folders: the user's settings and pins are never touched.
@MainActor @Suite("Settings transfer rules")
struct SettingsTransferTests {
    typealias T = SettingsTransfer

    private func suite() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "PenknifeTests.transfer.\(UUID().uuidString)"))
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "PenknifeTransfer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("GN-28 only Penknife's own keys travel, never the per-Mac ones")
    func whichKeys() {
        #expect(T.travels("KeyboardShortcuts_toggleMicrophone"))
        #expect(T.travels("module.weather.enabled"))
        #expect(T.travels("touchBar.order"))
        #expect(T.travels("microphone.holdToTalk"))
        #expect(!T.travels("microphone.teamsConsent"))
        #expect(!T.travels("screenshot.folder"))
        #expect(!T.travels("SULastCheckTime"))
        #expect(!T.travels("launchAtLogin.registeredPath"))
        #expect(!T.travels("settings.selectedPage"))
        #expect(!T.travels("NSColorPanelMode"))
    }

    @Test("GN-29 GN-30 export then import gives back the same settings and files")
    func roundTrip() throws {
        let from = try suite(), fromFolder = try folder()
        from.set(false, forKey: "module.weather.enabled")
        from.set(["mic", "time"], forKey: "touchBar.order")
        from.set(true, forKey: "microphone.teamsConsent")
        from.set("x", forKey: "SULastCheckTime")
        try Data("[]".utf8).write(to: fromFolder.appending(path: "Macros.json"))
        let data = try T.encode(T.package(defaults: from, folder: fromFolder), version: "1.16")

        let to = try suite(), toFolder = try folder()
        to.set(true, forKey: "jiggler.followsLock")          // replaced: not in the file → removed
        to.set(false, forKey: "microphone.teamsConsent")     // per Mac: kept
        try Data("old".utf8).write(to: toFolder.appending(path: "Pinned.plist")) // not in the file → removed
        try T.apply(T.decode(data), defaults: to, folder: toFolder)

        #expect(to.object(forKey: "module.weather.enabled") as? Bool == false)
        #expect(to.stringArray(forKey: "touchBar.order") == ["mic", "time"])
        #expect(to.object(forKey: "jiggler.followsLock") == nil)
        #expect(to.object(forKey: "microphone.teamsConsent") as? Bool == false)
        #expect(to.object(forKey: "SULastCheckTime") == nil)
        #expect(try Data(contentsOf: toFolder.appending(path: "Macros.json")) == Data("[]".utf8))
        #expect(!FileManager.default.fileExists(atPath: toFolder.appending(path: "Pinned.plist").path))
        let mode = try FileManager.default.attributesOfItem(atPath: toFolder.appending(path: "Macros.json").path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test("GN-31 other files are refused")
    func refused() throws {
        #expect(throws: T.TransferError.notSettings) { try T.decode(Data("hello".utf8)) }
        let plain = try PropertyListSerialization.data(fromPropertyList: ["a": 1], format: .xml, options: 0)
        #expect(throws: T.TransferError.notSettings) { try T.decode(plain) }
        let newer = try PropertyListSerialization.data(fromPropertyList: ["penknifeSettings": 9, "settings": [String: Any]()], format: .xml, options: 0)
        #expect(throws: T.TransferError.newerFormat) { try T.decode(newer) }
        let badMacros = try PropertyListSerialization.data(fromPropertyList: [
            "penknifeSettings": 1, "settings": [String: Any](), "files": ["Macros.json": Data("{nope".utf8)],
        ], format: .xml, options: 0)
        #expect(throws: T.TransferError.notSettings) { try T.decode(badMacros) }
        // Unknown files and keys are dropped, not written.
        let extra = try PropertyListSerialization.data(fromPropertyList: [
            "penknifeSettings": 1, "settings": ["evil.key": 1, "hud.duration": 6.0],
            "files": ["../../x": Data("[]".utf8)],
        ], format: .xml, options: 0)
        let package = try T.decode(extra)
        #expect(package.files.isEmpty)
        #expect(Array(package.settings.keys) == ["hud.duration"])
    }

    @Test("GN-30 a staged import is applied once at launch, a bad one is dropped")
    func staged() throws {
        let defaults = try suite(), dir = try folder()
        let source = try suite()
        source.set(8.0, forKey: "hud.duration")
        try T.stage(T.encode(T.package(defaults: source, folder: dir), version: "1.16"), folder: dir)
        #expect(T.applyPending(defaults: defaults, folder: dir))
        #expect(defaults.double(forKey: "hud.duration") == 8)
        #expect(!T.applyPending(defaults: defaults, folder: dir)) // gone
        try Data("junk".utf8).write(to: dir.appending(path: T.pendingName))
        #expect(!T.applyPending(defaults: defaults, folder: dir))
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: T.pendingName).path))
    }
}

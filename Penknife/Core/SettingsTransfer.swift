import AppKit
import UniformTypeIdentifiers

/// R-42: Penknife's settings, shortcuts, Touch Bar layout, pinned clipboard items and macros in
/// one property list file, to keep a copy or move them to another Mac. An import is staged next
/// to the pins and applied at the next launch, before any module reads its settings, so nothing
/// running can write over it; Penknife then restarts itself.
enum SettingsTransfer {
    static let format = 1
    /// A file this big is not a settings file (pins with images stay far below it).
    static let maxBytes = 256 * 1024 * 1024
    static let fileType = UTType.propertyList

    /// Only Penknife's own keys travel; Apple's, Sparkle's and window state stay behind.
    static let prefixes = [
        "KeyboardShortcuts_", "alerts.", "clipboard.", "hud.", "jiggler.", "keepAwake.", "macros.",
        "meeting.", "menuBar.", "microphone.", "module.", "music.", "pastable.", "recording.",
        "screenshot.", "touchBar.", "weather.",
    ]
    /// Asked once on each Mac (the Teams consent confirmation, R-31), or tied to this Mac (a folder,
    /// a permission already asked): never exported, never replaced.
    static let excluded: Set<String> = ["microphone.teamsConsent", "screenshot.askedPermission", "screenshot.folder"]
    /// The data files, in the folder of `ClipboardStore.defaultFolder`.
    static let dataFiles = ["Pinned.plist", "Macros.json"]
    static let pendingName = "Pending Import.plist"

    static func travels(_ key: String) -> Bool {
        !excluded.contains(key) && prefixes.contains { key.hasPrefix($0) }
    }

    struct Package: Equatable {
        var settings: [String: NSObject]
        /// File name → contents; a name that is missing means "none" (an import removes it).
        var files: [String: Data]

        static func == (a: Package, b: Package) -> Bool {
            a.files == b.files && NSDictionary(dictionary: a.settings).isEqual(to: b.settings)
        }
    }

    enum TransferError: Error, Equatable { case tooBig, notSettings, newerFormat }

    // MARK: Export

    static func package(defaults: UserDefaults, folder: URL) -> Package {
        var settings: [String: NSObject] = [:]
        for (key, value) in defaults.dictionaryRepresentation() where travels(key) {
            if let value = value as? NSObject { settings[key] = value }
        }
        var files: [String: Data] = [:]
        for name in dataFiles {
            if let data = try? Data(contentsOf: folder.appending(path: name)) { files[name] = data }
        }
        return Package(settings: settings, files: files)
    }

    static func encode(_ package: Package, version: String) throws -> Data {
        let root: [String: Any] = [
            "penknifeSettings": format,
            "appVersion": version,
            "exported": Date(),
            "settings": package.settings,
            "files": package.files,
        ]
        return try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
    }

    // MARK: Import

    /// Reads a file made by `encode`. Anything else is refused; unknown keys and files are dropped,
    /// and a data file that doesn't parse is refused (the stores would set it aside anyway).
    static func decode(_ data: Data) throws -> Package {
        guard data.count <= maxBytes else { throw TransferError.tooBig }
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = root["penknifeSettings"] as? Int,
              let settings = root["settings"] as? [String: Any] else { throw TransferError.notSettings }
        guard version <= format else { throw TransferError.newerFormat }
        var kept: [String: NSObject] = [:]
        for (key, value) in settings where travels(key) {
            if let value = value as? NSObject { kept[key] = value }
        }
        var files: [String: Data] = [:]
        for (name, value) in root["files"] as? [String: Any] ?? [:] where dataFiles.contains(name) {
            guard let contents = value as? Data, isReadable(contents, name: name) else { throw TransferError.notSettings }
            files[name] = contents
        }
        return Package(settings: kept, files: files)
    }

    private static func isReadable(_ data: Data, name: String) -> Bool {
        name.hasSuffix(".json")
            ? (try? JSONSerialization.jsonObject(with: data)) != nil
            : (try? PropertyListSerialization.propertyList(from: data, format: nil)) != nil
    }

    /// Replaces every travelling setting and the data files with the package's.
    static func apply(_ package: Package, defaults: UserDefaults, folder: URL) throws {
        for key in defaults.dictionaryRepresentation().keys where travels(key) {
            defaults.removeObject(forKey: key)
        }
        for (key, value) in package.settings { defaults.set(value, forKey: key) }
        try makeFolder(folder)
        for name in dataFiles {
            let url = folder.appending(path: name)
            if let data = package.files[name] {
                try writeOwnerOnly(data, to: url)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: Staging and restart

    /// Saves the checked file to be applied at the next launch.
    static func stage(_ data: Data, folder: URL) throws {
        _ = try decode(data)
        try makeFolder(folder)
        try writeOwnerOnly(data, to: folder.appending(path: pendingName))
    }

    /// At launch, before the modules start: applies a staged import, then removes it (also when it
    /// can't be read, so a bad file never blocks every launch). Returns whether one was applied.
    @discardableResult
    static func applyPending(defaults: UserDefaults, folder: URL) -> Bool {
        let url = folder.appending(path: pendingName)
        guard let data = try? Data(contentsOf: url) else { return false }
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try apply(decode(data), defaults: defaults, folder: folder)
            return true
        } catch {
            NSLog("Penknife: staged settings import not applied: \(error)")
            return false
        }
    }

    /// Opens a new copy of Penknife once this one has quit, then quits.
    @MainActor static func restart() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\"",
                          "sh", String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundlePath]
        do {
            try task.run()
            NSApp.terminate(nil)
        } catch {
            NSLog("Penknife: restart failed: \(error)")
        }
    }

    private static func makeFolder(_ folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    /// Owner-only from the first byte, then moved into place in one step.
    static func writeOwnerOnly(_ data: Data, to url: URL) throws {
        let temp = url.deletingLastPathComponent().appending(path: ".\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(temp.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: temp)
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

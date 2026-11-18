import AppKit

/// Finder pastes files, not images. An image put on the clipboard together with a file holding
/// it pastes as that file in a Finder folder and as the image everywhere else (as CleanShot does).
/// The files live in Penknife's caches, owner-only. They stay until the space the user gives
/// them is full; then the oldest go first. An image bigger than that space is not kept as a file.
enum PastableImage {
    static let limitKey = "pastable.limitMB"
    static let limits = [100, 250, 500, 1000, 2000]

    /// Disk space for these files, in MB (setting, default 500).
    static var limitMB: Int {
        let value = UserDefaults.standard.integer(forKey: limitKey)
        return value > 0 ? value : 500
    }

    static var folder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Penknife", isDirectory: true)
            .appendingPathComponent("Pastable", isDirectory: true)
    }

    /// Whether `url` is one of these files (the clipboard history keeps them as images).
    static func isOurs(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/")
    }

    /// Clears the clipboard and puts `png` on it, as image data and, if it can be written, as a
    /// file named `name` (".png" is added).
    static func copy(_ png: Data, named name: String) {
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        if let url = write(png, named: name) {
            item.setString(url.absoluteString, forType: .fileURL)
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }

    /// Clears the clipboard and puts a copy of the file at `source` on it, as a file named `name`
    /// (its extension is kept): a screen recording pastes into messages and Finder folders. False
    /// when it doesn't fit in the space the user gives these files.
    static func copyFile(_ source: URL, named name: String) -> Bool {
        let manager = FileManager.default
        let size = Int64((try? source.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        let limit = Int64(limitMB) * 1_000_000
        guard size <= limit else { return false }
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            makeRoom(size, limit: limit)
            let directory = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let url = directory.appendingPathComponent(name).appendingPathExtension(source.pathExtension)
            try manager.copyItem(at: source, to: url)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            return pasteboard.writeObjects([url as NSURL])
        } catch {
            return false
        }
    }

    /// "Image 2026-11-13 at 16.30.05" style name for the current time.
    static func timestampName(_ prefix: (String, String) -> String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let date = formatter.string(from: .now)
        formatter.dateFormat = "HH.mm.ss"
        return prefix(date, formatter.string(from: .now))
    }

    /// PNG data from PNG or TIFF data.
    static func png(from data: Data, type: String?) -> Data? {
        if type == NSPasteboard.PasteboardType.png.rawValue { return data }
        return NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
    }

    private static func write(_ png: Data, named name: String) -> URL? {
        let limit = Int64(limitMB) * 1_000_000
        guard Int64(png.count) <= limit else { return nil }
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            makeRoom(Int64(png.count), limit: limit)
            // Each copy gets its own subfolder, so the pasted file keeps a clean name.
            let directory = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let url = directory.appendingPathComponent(name + ".png")
            try png.write(to: url, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return url
        } catch {
            return nil
        }
    }

    /// Removes the oldest files until `incoming` more bytes fit within `limit`.
    static func makeRoom(_ incoming: Int64 = 0, limit: Int64 = Int64(limitMB) * 1_000_000) {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey]) else { return }
        var folders = entries.map { entry -> (url: URL, date: Date, size: Int64) in
            let date = (try? entry.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            let files = (try? manager.contentsOfDirectory(at: entry, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            let size = files.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
            return (entry, date, size)
        }
        folders.sort { $0.date < $1.date }
        var total = folders.reduce(Int64(0)) { $0 + $1.size } + incoming
        for entry in folders where total > limit {
            try? manager.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    /// Space used now, in bytes (shown in Settings).
    static var used: Int64 {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }

    static func removeAll() {
        try? FileManager.default.removeItem(at: folder)
    }
}

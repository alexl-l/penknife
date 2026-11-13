import AppKit
import CryptoKit
import Observation

/// One copied thing: text (plain, plus rich text when the app offered it), an image, or files
/// (kept as references to the originals, never copied).
struct ClipItem: Identifiable, Codable, Equatable {
    enum Kind: String, Codable { case text, image, files }

    let id: UUID
    let kind: Kind
    var text: String?
    var rtf: Data?
    var image: Data?
    var imageType: String?
    var files: [URL]?
    /// The app that copied it (bundle id), for the row icon.
    var source: String?
    var date: Date
    var pinned = false
    /// Content fingerprint, to move a repeated copy to the top instead of storing it twice.
    let key: String

    /// Memory the item takes, counted against the limit (R-7).
    var bytes: Int {
        (text?.utf8.count ?? 0) + (rtf?.count ?? 0) + (image?.count ?? 0)
            + (files?.reduce(0) { $0 + $1.path.utf8.count } ?? 0)
    }

    /// One line for the list and for search.
    var title: String {
        switch kind {
        case .text:
            let line = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            return String(line.prefix(200))
        case .image:
            return String(localized: "Image")
        case .files:
            let names = (files ?? []).map(\.lastPathComponent)
            return names.count == 1 ? names[0] : String(localized: "\(names.count) files: \(names.joined(separator: ", "))")
        }
    }

    /// Big data (images) is keyed by its size plus its first and last 64 KB: hashing a whole
    /// screenshot on every copy would block the main thread for nothing.
    static func fingerprint(_ parts: [Data]) -> String {
        var hash = SHA256()
        let window = 65_536
        for part in parts {
            if part.count > window * 2 {
                withUnsafeBytes(of: part.count) { hash.update(bufferPointer: $0) }
                hash.update(data: part.prefix(window))
                hash.update(data: part.suffix(window))
            } else {
                hash.update(data: part)
            }
        }
        return Data(hash.finalize()).base64EncodedString()
    }
}

/// The clipboard history (R-7). Lives in memory and is lost when the app quits; pinned items are
/// saved to disk (owner-only) and never removed except by the user. Unpinned items are limited by
/// the memory they use: the oldest go first.
@Observable
final class ClipboardStore {
    static let limitKey = "clipboard.limitMB"
    static let limits = [25, 50, 100, 250, 500]
    static var limitBytes: Int {
        let mb = UserDefaults.standard.integer(forKey: limitKey)
        return (mb > 0 ? mb : 100) * 1_000_000
    }

    /// Newest first. Pinned items keep their place in the "Pinned" section.
    private(set) var pinned: [ClipItem] = []
    private(set) var history: [ClipItem] = []

    /// Kept up to date on every change instead of summing the history each time.
    private(set) var usedBytes = 0

    @ObservationIgnored private let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "Penknife", directoryHint: .isDirectory)
    }()
    @ObservationIgnored private var pinsFile: URL { folder.appending(path: "Pinned.plist") }

    init() {
        loadPins()
    }

    /// Adds a new copy at the top. A repeat of an existing item moves it up instead.
    func add(_ item: ClipItem) {
        if let index = pinned.firstIndex(where: { $0.key == item.key }) {
            // Already pinned: nothing to store, it stays where the user put it.
            pinned[index].date = item.date
            return
        }
        if let index = history.firstIndex(where: { $0.key == item.key }) {
            usedBytes -= history.remove(at: index).bytes
        }
        let size = item.bytes
        guard size <= Self.limitBytes else { return }
        history.insert(item, at: 0)
        usedBytes += size
        trim()
    }

    /// Drops the oldest unpinned items until the history fits the limit.
    func trim() {
        let limit = Self.limitBytes
        while usedBytes > limit, let last = history.popLast() {
            usedBytes -= last.bytes
        }
    }

    func remove(_ id: ClipItem.ID) {
        if pinned.contains(where: { $0.id == id }) {
            pinned.removeAll { $0.id == id }
            savePins()
        } else if let index = history.firstIndex(where: { $0.id == id }) {
            usedBytes -= history.remove(at: index).bytes
        }
    }

    func togglePin(_ id: ClipItem.ID) {
        if let index = pinned.firstIndex(where: { $0.id == id }) {
            var item = pinned.remove(at: index)
            item.pinned = false
            history.insert(item, at: 0)
            usedBytes += item.bytes
            trim()
        } else if let index = history.firstIndex(where: { $0.id == id }) {
            var item = history.remove(at: index)
            usedBytes -= item.bytes
            item.pinned = true
            pinned.append(item)
        }
        savePins()
    }

    /// "Clear history": pinned items are never touched (R-7).
    func clearHistory() {
        history.removeAll()
        usedBytes = 0
    }

    func item(_ id: ClipItem.ID) -> ClipItem? {
        pinned.first { $0.id == id } ?? history.first { $0.id == id }
    }

    /// Moves a pasted history item to the top, as a new copy would.
    func touch(_ id: ClipItem.ID) {
        guard let index = history.firstIndex(where: { $0.id == id }), index > 0 else { return }
        var item = history.remove(at: index)
        item.date = .now
        history.insert(item, at: 0)
    }

    // MARK: Pinned items on disk

    private func loadPins() {
        guard let data = try? Data(contentsOf: pinsFile),
              let items = try? PropertyListDecoder().decode([ClipItem].self, from: data) else { return }
        // Only plain file references are ever written back to the clipboard.
        pinned = items.map { item in
            var item = item
            item.files = item.files?.filter(\.isFileURL)
            return item
        }
    }

    private func savePins() {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            if pinned.isEmpty {
                try? manager.removeItem(at: pinsFile)
                return
            }
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let data = try encoder.encode(pinned)
            // Owner-only from the first byte: the atomic write's temporary file follows the umask.
            let previous = umask(0o077)
            defer { umask(previous) }
            try data.write(to: pinsFile, options: [.atomic])
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pinsFile.path)
        } catch {
            NSLog("Penknife: saving pinned clipboard items: \(error.localizedDescription)")
        }
    }
}

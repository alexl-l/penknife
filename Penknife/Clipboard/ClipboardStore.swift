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
    var key: String

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

    static func text(_ text: String, rtf: Data? = nil, source: String? = nil, date: Date = .now) -> ClipItem {
        ClipItem(id: UUID(), kind: .text, text: text, rtf: rtf, source: source, date: date,
                 key: fingerprint(.text, [Data(text.utf8)]))
    }

    static func image(_ data: Data, type: String, source: String? = nil, date: Date = .now) -> ClipItem {
        ClipItem(id: UUID(), kind: .image, image: data, imageType: type, source: source, date: date,
                 key: fingerprint(.image, [data]))
    }

    static func files(_ urls: [URL], source: String? = nil, date: Date = .now) -> ClipItem {
        ClipItem(id: UUID(), kind: .files, files: urls, source: source, date: date,
                 key: fingerprint(.files, urls.map { Data($0.path.utf8) }))
    }

    /// Only the kind and id are required: a field added later, or one an older version didn't
    /// write, never makes a saved pin unreadable (B-18). The key is always derived again.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        kind = try values.decode(Kind.self, forKey: .kind)
        text = try values.decodeIfPresent(String.self, forKey: .text)
        rtf = try values.decodeIfPresent(Data.self, forKey: .rtf)
        image = try values.decodeIfPresent(Data.self, forKey: .image)
        imageType = try values.decodeIfPresent(String.self, forKey: .imageType)
        files = try values.decodeIfPresent([URL].self, forKey: .files)
        source = try values.decodeIfPresent(String.self, forKey: .source)
        date = try values.decodeIfPresent(Date.self, forKey: .date) ?? .now
        pinned = try values.decodeIfPresent(Bool.self, forKey: .pinned) ?? true
        key = ""
        key = contentKey
    }

    init(id: UUID, kind: Kind, text: String? = nil, rtf: Data? = nil, image: Data? = nil, imageType: String? = nil,
         files: [URL]? = nil, source: String? = nil, date: Date, pinned: Bool = false, key: String) {
        self.id = id
        self.kind = kind
        self.text = text
        self.rtf = rtf
        self.image = image
        self.imageType = imageType
        self.files = files
        self.source = source
        self.date = date
        self.pinned = pinned
        self.key = key
    }

    /// The fingerprint of this item's content.
    var contentKey: String {
        switch kind {
        case .text: Self.fingerprint(.text, [Data((text ?? "").utf8)])
        case .image: Self.fingerprint(.image, [image ?? Data()])
        case .files: Self.fingerprint(.files, (files ?? []).map { Data($0.path.utf8) })
        }
    }

    /// Big data (images) is keyed by its size plus its first and last 64 KB: hashing a whole
    /// screenshot on every copy would block the main thread for nothing. The kind and each part's
    /// size are hashed too: a copied path is not the file it names, and ["/a", "/bc"] is not
    /// ["/ab", "/c"] (B-17).
    static func fingerprint(_ kind: Kind, _ parts: [Data]) -> String {
        var hash = SHA256()
        let window = 65_536
        hash.update(data: Data(kind.rawValue.utf8))
        for part in parts {
            withUnsafeBytes(of: part.count) { hash.update(bufferPointer: $0) }
            if part.count > window * 2 {
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
    static var limitBytes: Int { limitBytes(in: .standard) }
    /// The memory limit in bytes; any value not offered counts as 100 MB.
    static func limitBytes(in defaults: UserDefaults) -> Int {
        let mb = defaults.integer(forKey: limitKey)
        return (mb > 0 ? mb : 100) * 1_000_000
    }

    /// Newest first. Pinned items keep their place in the "Pinned" section.
    private(set) var pinned: [ClipItem] = []
    private(set) var history: [ClipItem] = []

    /// Kept up to date on every change instead of summing the history each time.
    private(set) var usedBytes = 0

    static var defaultFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "Penknife", directoryHint: .isDirectory)
    }

    @ObservationIgnored private let folder: URL
    @ObservationIgnored private let limit: () -> Int
    @ObservationIgnored var pinsFile: URL { folder.appending(path: "Pinned.plist") }

    /// The app passes nothing: Application Support/Penknife and the user's setting. Tests pass a
    /// temp folder and a fixed limit.
    init(folder: URL = ClipboardStore.defaultFolder, limit: @escaping () -> Int = { ClipboardStore.limitBytes }) {
        self.folder = folder
        self.limit = limit
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
        guard size <= limit() else { return }
        history.insert(item, at: 0)
        usedBytes += size
        trim()
    }

    /// Drops the oldest unpinned items until the history fits the limit.
    func trim() {
        let limit = limit()
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

    /// One saved pin, or nil when this version can't read it.
    private struct SavedPin: Decodable {
        let item: ClipItem?
        init(from decoder: Decoder) throws { item = try? ClipItem(from: decoder) }
    }

    /// Where a pins file that couldn't be read whole is kept, untouched (B-18).
    var unreadablePinsFile: URL {
        var url = folder.appending(path: "Pinned (unreadable).plist")
        var number = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appending(path: "Pinned (unreadable) \(number).plist")
            number += 1
        }
        return url
    }

    /// Pins are read one by one. If any can't be read (a kind this version doesn't know, a damaged
    /// file), the file is first copied aside as it is, so saving the readable pins never loses the
    /// others (B-18).
    private func loadPins() {
        guard let data = try? Data(contentsOf: pinsFile) else { return }
        let saved = try? PropertyListDecoder().decode([SavedPin].self, from: data)
        let items = saved?.compactMap(\.item) ?? []
        if saved == nil || items.count < saved!.count {
            do {
                // Nothing readable: moved, so the next launch doesn't set it aside again.
                if saved == nil {
                    try FileManager.default.moveItem(at: pinsFile, to: unreadablePinsFile)
                } else {
                    try FileManager.default.copyItem(at: pinsFile, to: unreadablePinsFile)
                }
            } catch {
                // It couldn't be kept: never write over it in this run.
                pinsLocked = true
                NSLog("Penknife: setting aside unreadable pinned clipboard items: \(error.localizedDescription)")
            }
        }
        // Only plain file references are ever written back to the clipboard.
        pinned = items.map { item in
            var item = item
            item.files = item.files?.filter(\.isFileURL)
            return item
        }
    }

    /// Set when an unreadable pins file couldn't be set aside: it is never written over.
    @ObservationIgnored private var pinsLocked = false

    private func savePins() {
        guard !pinsLocked else { return }
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

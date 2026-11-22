import AppKit
import CryptoKit
import Observation

/// One copied thing: text (plain, plus rich text when the app offered it), an image, or files
/// (kept as references to the originals, never copied).
/// The colors a pinned item's own icon can have: system colors, so they follow light and dark.
enum PinColor: String, Codable, CaseIterable {
    case red, orange, yellow, green, teal, blue, purple, gray

    var color: NSColor {
        switch self {
        case .red: .systemRed
        case .orange: .systemOrange
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .teal: .systemTeal
        case .blue: .systemBlue
        case .purple: .systemPurple
        case .gray: .systemGray
        }
    }

    var name: String {
        switch self {
        case .red: String(localized: "Red")
        case .orange: String(localized: "Orange")
        case .yellow: String(localized: "Yellow")
        case .green: String(localized: "Green")
        case .teal: String(localized: "Teal")
        case .blue: String(localized: "Blue")
        case .purple: String(localized: "Purple")
        case .gray: String(localized: "Gray")
        }
    }
}

/// A pinned item's own icon (CB-33): one letter or emoji, a color, or both. Neither = the app's icon.
struct PinIcon: Codable, Equatable {
    var glyph: String?
    var color: PinColor?

    /// nil when there is nothing to show (no glyph and no color): the row uses the app's icon.
    init?(glyph: String?, color: PinColor?) {
        let first = glyph?.trimmingCharacters(in: .whitespacesAndNewlines).first.map { String($0).uppercased() }
        guard first != nil || color != nil else { return nil }
        self.glyph = first
        self.color = color
    }

    /// The field keeps one letter or emoji: what was typed replaces what was there (first one of a paste).
    static func oneGlyph(old: String, new: String) -> String {
        guard new.count > 1 else { return new.uppercased() }
        let added = new.hasPrefix(old) ? new.dropFirst(old.count) : new.hasSuffix(old) ? new.dropLast(old.count) : Substring(new)
        return (added.first.map { String($0) } ?? "").uppercased()
    }

    /// An emoji is drawn bare, or on its color; a letter always sits on a tile (gray with no color).
    var isEmoji: Bool {
        guard let scalar = glyph?.unicodeScalars.first else { return false }
        return scalar.properties.isEmojiPresentation || (glyph?.unicodeScalars.count ?? 0) > 1 && scalar.properties.isEmoji
    }
}

struct ClipItem: Identifiable, Codable, Equatable {
    enum Kind: String, Codable { case text, image, files }

    let id: UUID
    let kind: Kind
    var text: String?
    var rtf: Data?
    /// HTML that came with the text (web pages), written back with the RTF when formatting is kept.
    var html: Data?
    var image: Data?
    var imageType: String?
    var files: [URL]?
    /// The app that copied it (bundle id), for the row icon.
    var source: String?
    var date: Date
    var pinned = false
    /// The icon the user gave it while pinned (CB-33); kept when unpinned, shown only while pinned.
    var icon: PinIcon?
    /// Content fingerprint, to move a repeated copy to the top instead of storing it twice.
    var key: String

    /// Memory the item takes, counted against the limit (R-7).
    var bytes: Int {
        (text?.utf8.count ?? 0) + (rtf?.count ?? 0) + (html?.count ?? 0) + (image?.count ?? 0)
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

    static func text(_ text: String, rtf: Data? = nil, html: Data? = nil, source: String? = nil,
                     date: Date = .now) -> ClipItem {
        ClipItem(id: UUID(), kind: .text, text: text, rtf: rtf, html: html, source: source, date: date,
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
        html = try values.decodeIfPresent(Data.self, forKey: .html)
        image = try values.decodeIfPresent(Data.self, forKey: .image)
        imageType = try values.decodeIfPresent(String.self, forKey: .imageType)
        files = try values.decodeIfPresent([URL].self, forKey: .files)
        source = try values.decodeIfPresent(String.self, forKey: .source)
        date = try values.decodeIfPresent(Date.self, forKey: .date) ?? .now
        pinned = try values.decodeIfPresent(Bool.self, forKey: .pinned) ?? true
        icon = try? values.decodeIfPresent(PinIcon.self, forKey: .icon)
        key = ""
        key = contentKey
    }

    init(id: UUID, kind: Kind, text: String? = nil, rtf: Data? = nil, html: Data? = nil, image: Data? = nil, imageType: String? = nil,
         files: [URL]? = nil, source: String? = nil, date: Date, pinned: Bool = false, key: String) {
        self.id = id
        self.kind = kind
        self.text = text
        self.rtf = rtf
        self.html = html
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

    /// Row thumbnails of the images, by content key. Made once, off the main thread, when an
    /// image comes in (or a pin is loaded): decoding a screenshot takes 25–150 ms, and doing it
    /// for every image row when the panel opened made it take seconds (B-21).
    private(set) var thumbnails: [String: NSImage] = [:]
    @ObservationIgnored private var thumbnailsWaiting: [(key: String, data: Data)] = []
    @ObservationIgnored private var makingThumbnails = false

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
        var item = item
        if let index = history.firstIndex(where: { $0.key == item.key }) {
            let old = history.remove(at: index)
            usedBytes -= old.bytes
            item.icon = old.icon
        }
        let size = item.bytes
        guard size <= limit() else { return }
        history.insert(item, at: 0)
        usedBytes += size
        trim()
        makeThumbnail(for: item)
    }

    /// A small picture for an image row, made from the image's data. Slow for big images: never
    /// on the main thread.
    nonisolated static func thumbnail(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 96,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary)
    }

    /// Queues the item's thumbnail. They are made one at a time: decoding needs the whole image in
    /// memory (about 60 MB for a 5K screenshot), so many pins at launch must not decode together.
    private func makeThumbnail(for item: ClipItem) {
        guard item.kind == .image, let data = item.image, thumbnails[item.key] == nil,
              !thumbnailsWaiting.contains(where: { $0.key == item.key }) else { return }
        thumbnailsWaiting.append((item.key, data))
        guard !makingThumbnails else { return }
        makingThumbnails = true
        Task { [weak self] in
            while let self, !self.thumbnailsWaiting.isEmpty {
                let (key, data) = self.thumbnailsWaiting.removeFirst()
                // Skipped if the item left while waiting (deleted, trimmed, history cleared).
                guard self.keeps(key) else { continue }
                let image = await Task.detached(priority: .utility) { autoreleasepool { Self.thumbnail(data) } }.value
                if let image, self.keeps(key) { self.thumbnails[key] = NSImage(cgImage: image, size: .zero) }
            }
            self?.makingThumbnails = false
        }
    }

    private func keeps(_ key: String) -> Bool {
        history.contains { $0.key == key } || pinned.contains { $0.key == key }
    }

    /// Thumbnails of items no longer kept are let go.
    private func dropUnusedThumbnails() {
        guard !thumbnails.isEmpty else { return }
        let keys = Set((history + pinned).lazy.filter { $0.kind == .image }.map(\.key))
        for key in thumbnails.keys where !keys.contains(key) { thumbnails[key] = nil }
    }

    /// Drops the oldest unpinned items until the history fits the limit. `keeping` is never
    /// dropped: an item just unpinned stays even if it alone is over the limit (O-21).
    func trim(keeping kept: ClipItem.ID? = nil) {
        let limit = limit()
        let count = history.count
        while usedBytes > limit, let index = history.lastIndex(where: { $0.id != kept }) {
            usedBytes -= history.remove(at: index).bytes
        }
        if history.count < count { dropUnusedThumbnails() }
    }

    /// Files that no longer exist leave the history (O-22): the missing ones are taken out of
    /// each files item, and an item with none left is removed. Pinned items are never removed
    /// (CB-15); the ids of those whose files are all missing are returned, to be hidden.
    /// Every file the history and the pins point to, for `missing` off the main thread.
    var fileURLs: Set<URL> {
        Set((history + pinned).filter { $0.kind == .files }.flatMap { $0.files ?? [] })
    }

    /// The ones of `urls` that don't exist. Slow on a network disk: never on the main thread.
    nonisolated static func missing(_ urls: Set<URL>) -> Set<URL> {
        urls.filter { !FileManager.default.fileExists(atPath: $0.path) }
    }

    @discardableResult
    func dropMissingFiles(exists: (URL) -> Bool) -> Set<ClipItem.ID> {
        for index in history.indices.reversed() where history[index].kind == .files {
            let files = history[index].files ?? []
            let left = files.filter(exists)
            guard left.count < files.count else { continue }
            usedBytes -= history[index].bytes
            if left.isEmpty {
                history.remove(at: index)
            } else {
                history[index].files = left
                history[index].key = history[index].contentKey
                usedBytes += history[index].bytes
            }
        }
        return Set(pinned.filter { $0.kind == .files && !($0.files ?? []).contains(where: exists) }.map(\.id))
    }

    func remove(_ id: ClipItem.ID) {
        if pinned.contains(where: { $0.id == id }) {
            pinned.removeAll { $0.id == id }
            savePins()
        } else if let index = history.firstIndex(where: { $0.id == id }) {
            usedBytes -= history.remove(at: index).bytes
        }
        dropUnusedThumbnails()
    }

    func togglePin(_ id: ClipItem.ID) {
        if let index = pinned.firstIndex(where: { $0.id == id }) {
            var item = pinned.remove(at: index)
            item.pinned = false
            history.insert(item, at: 0)
            usedBytes += item.bytes
            trim(keeping: id)
        } else if let index = history.firstIndex(where: { $0.id == id }) {
            var item = history.remove(at: index)
            usedBytes -= item.bytes
            item.pinned = true
            pinned.append(item)
        }
        savePins()
    }

    /// A pinned item's own icon (CB-33); nil = back to the app's icon. Saved with the pins.
    func setIcon(_ id: ClipItem.ID, _ icon: PinIcon?) {
        guard let index = pinned.firstIndex(where: { $0.id == id }), pinned[index].icon != icon else { return }
        pinned[index].icon = icon
        savePins()
    }

    /// "Update with Copied" (R-35): a pinned item takes the content of `item` (what is on the
    /// clipboard now) and keeps its id, icon and place, so macros linked to it use the new value.
    /// The same content in the history leaves it (it is the pin now).
    func updatePin(_ id: ClipItem.ID, with item: ClipItem) {
        guard let index = pinned.firstIndex(where: { $0.id == id }), pinned[index].key != item.key else { return }
        if let other = pinned.firstIndex(where: { $0.key == item.key }), other != index { return }
        if let old = history.firstIndex(where: { $0.key == item.key }) {
            usedBytes -= history.remove(at: old).bytes
        }
        var updated = ClipItem(id: id, kind: item.kind, text: item.text, rtf: item.rtf, html: item.html, image: item.image,
                               imageType: item.imageType, files: item.files, source: item.source, date: .now,
                               pinned: true, key: item.key)
        updated.icon = pinned[index].icon
        pinned[index] = updated
        makeThumbnail(for: updated)
        dropUnusedThumbnails()
        savePins()
    }

    /// Reorders the pinned items (R-35, drag in the panel). Saved when the drag ends (`savePinOrder`):
    /// pins can hold images, and writing them on every row passed would be wasted work.
    func movePin(_ id: ClipItem.ID, to target: Int) {
        guard let index = pinned.firstIndex(where: { $0.id == id }) else { return }
        let target = min(max(target, 0), pinned.count - 1)
        guard target != index else { return }
        pinned.move(fromOffsets: [index], toOffset: target > index ? target + 1 : target)
    }

    func savePinOrder() { savePins() }

    /// "Clear history": pinned items are never touched (R-7).
    func clearHistory() {
        history.removeAll()
        usedBytes = 0
        dropUnusedThumbnails()
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

    /// Whether these exact bytes are already set aside: a pin that stays unreadable is copied
    /// once, not at every launch.
    private func isSetAside(_ data: Data) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.contains { name in
            name.hasPrefix("Pinned (unreadable)")
                && (try? Data(contentsOf: folder.appending(path: name))) == data
        }
    }

    /// Owner-only, whatever the file had before (pins files older than the 0600 rule).
    private func ownerOnly(_ url: URL) throws {
        let manager = FileManager.default
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Pins are read one by one. If any can't be read (a kind this version doesn't know, a damaged
    /// file), the file is first copied aside as it is, so saving the readable pins never loses the
    /// others (B-18).
    private func loadPins() {
        guard let data = try? Data(contentsOf: pinsFile) else { return }
        let saved = try? PropertyListDecoder().decode([SavedPin].self, from: data)
        let items = saved?.compactMap(\.item) ?? []
        if saved == nil || items.count < saved!.count, !isSetAside(data) {
            do {
                // Nothing readable: moved, so the next launch doesn't set it aside again.
                if saved == nil {
                    let aside = unreadablePinsFile
                    try FileManager.default.moveItem(at: pinsFile, to: aside)
                    try ownerOnly(aside)
                } else {
                    let aside = unreadablePinsFile
                    try FileManager.default.copyItem(at: pinsFile, to: aside)
                    try ownerOnly(aside)
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
        pinned.forEach(makeThumbnail)
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

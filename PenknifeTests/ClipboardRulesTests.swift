import AppKit
import Foundation
import Testing
@testable import Penknife

/// Clipboard History rules (docs/requirements/clipboard.md). Each test names the rule it checks.
/// Nothing here touches `NSPasteboard.general`, the user's Pinned.plist or settings, presses keys
/// or opens the panel: stores live in temp folders, pasteboards are private and released.
@MainActor
@Suite("Clipboard rules")
struct ClipboardRulesTests {

    // MARK: Helpers

    static let mb = 1_000_000

    /// A store in its own temp folder ("PenknifeTests-Clipboard-…"), removed by `done`.
    @MainActor final class TempStore {
        let folder: URL
        var limit: Int
        private(set) var store: ClipboardStore!

        init(limit: Int = 100 * ClipboardRulesTests.mb) {
            folder = FileManager.default.temporaryDirectory
                .appending(path: "PenknifeTests-Clipboard-\(UUID().uuidString)", directoryHint: .isDirectory)
            self.limit = limit
            reload()
        }

        /// A new store on the same folder, as at the next launch.
        func reload() {
            store = ClipboardStore(folder: folder, limit: { [unowned self] in self.limit })
        }

        var pinsFile: URL { folder.appending(path: "Pinned.plist") }

        isolated deinit { try? FileManager.default.removeItem(at: folder) }
    }

    /// A private pasteboard holding one item with these types.
    static func pasteboard(_ fill: (NSPasteboardItem) -> Void) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: .init("PenknifeTests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        fill(item)
        pasteboard.writeObjects([item])
        return pasteboard
    }

    static func read(_ fill: (NSPasteboardItem) -> Void, frontApp: String? = nil) -> ClipItem? {
        let pasteboard = pasteboard(fill)
        defer { pasteboard.releaseGlobally() }
        return ClipboardReader.read(pasteboard, frontApp: frontApp)
    }

    static func blob(_ size: Int, _ byte: UInt8 = 1) -> Data { Data(repeating: byte, count: size) }

    // MARK: B. Watching the clipboard

    @Test("CB-06 passwords and temporary data are not stored")
    func skipsPasswords() {
        #expect(Self.read { $0.setString("secret", forType: .string)
            $0.setData(Data(), forType: .init("org.nspasteboard.ConcealedType")) } == nil)
        #expect(Self.read { $0.setString("secret", forType: .string)
            $0.setData(Data(), forType: .init("org.nspasteboard.TransientType")) } == nil)
        #expect(Self.read({ $0.setString("secret", forType: .string) }, frontApp: "com.apple.Passwords") == nil)
        #expect(Self.read({ $0.setString("secret", forType: .string)
            $0.setString("com.bitwarden.desktop", forType: .init("org.nspasteboard.source")) },
                          frontApp: "com.apple.TextEdit") == nil)
        let plain = Self.read({ $0.setString("hello", forType: .string) }, frontApp: "com.apple.TextEdit")
        #expect(plain?.kind == .text && plain?.text == "hello" && plain?.source == "com.apple.TextEdit")
    }

    @Test("CB-07 what kind a copy is")
    func kinds() throws {
        let png = try #require(NSImage(size: NSSize(width: 4, height: 4), flipped: false) { _ in
            NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 4, height: 4).fill(); return true
        }.tiffRepresentation)
        let file = URL(filePath: "/tmp/PenknifeTests-report.pdf")
        let files = Self.read { $0.setString(file.absoluteString, forType: .fileURL); $0.setData(png, forType: .tiff) }
        #expect(files?.kind == .files && files?.files == [file])

        let ours = PastableImage.folder.appending(path: "x/Image.png")
        let image = Self.read { $0.setString(ours.absoluteString, forType: .fileURL); $0.setData(png, forType: .png) }
        #expect(image?.kind == .image && image?.imageType == NSPasteboard.PasteboardType.png.rawValue)

        let picture = Self.read { $0.setString("caption", forType: .string); $0.setData(png, forType: .png) }
        #expect(picture?.kind == .image)

        let rtf = Data("{\\rtf1 hi}".utf8)
        let document = Self.read { $0.setString("hi", forType: .string); $0.setData(rtf, forType: .rtf)
            $0.setData(png, forType: .png) }
        #expect(document?.kind == .text && document?.rtf == rtf)

        #expect(Self.read { $0.setString("", forType: .string) } == nil)
        #expect(Self.read { $0.setData(Data("<b>x</b>".utf8), forType: .html) } == nil)
    }

    @Test("CB-08 a repeat moves up instead of being stored twice")
    func repeats() {
        let temp = TempStore()
        let store = temp.store!
        store.add(.text("a")); store.add(.text("b")); store.add(.text("a"))
        #expect(store.history.map(\.text) == ["a", "b"])

        store.togglePin(store.history[1].id)          // pin "b"
        store.add(.text("b"))
        #expect(store.history.map(\.text) == ["a"])
        #expect(store.pinned.map(\.text) == ["b"])

        var big = Self.blob(300_000)
        let key = ClipItem.image(big, type: "public.png").key
        big[150_000] = 9
        #expect(ClipItem.image(big, type: "public.png").key == key)   // known, accepted
    }

    @Test("B-17 a copied path and that same file are different copies")
    func pathAndFileDiffer() {
        let temp = TempStore()
        let store = temp.store!
        let path = "/Users/someone/report.pdf"
        store.add(.text(path))
        store.add(.files([URL(filePath: path)]))
        #expect(store.history.map(\.kind) == [.files, .text])
        // Each file is a separate part: ["/a", "/bc"] is not ["/ab", "/c"].
        #expect(ClipItem.files([URL(filePath: "/a"), URL(filePath: "/bc")]).key
                != ClipItem.files([URL(filePath: "/ab"), URL(filePath: "/c")]).key)
    }

    @Test("B-17 a pin saved with the old fingerprint still matches a new copy")
    func oldPinKey() throws {
        let temp = TempStore()
        temp.store.add(.text("pinned text"))
        temp.store.togglePin(temp.store.history[0].id)
        var list = try #require(PropertyListSerialization.propertyList(
            from: Data(contentsOf: temp.pinsFile), format: nil) as? [[String: Any]])
        list[0]["key"] = "an older fingerprint"
        try PropertyListSerialization.data(fromPropertyList: list, format: .binary, options: 0).write(to: temp.pinsFile)
        temp.reload()
        temp.store.add(.text("pinned text"))
        #expect(temp.store.history.isEmpty)
    }

    // MARK: C. The history and its limit

    @Test("CB-10 an item's weight")
    func weight() {
        #expect(ClipItem.text("abc", rtf: Self.blob(10)).bytes == 13)
        #expect(ClipItem.files([URL(filePath: "/a/b")]).bytes == 4)
        #expect(ClipItem.image(Self.blob(7), type: "public.png").bytes == 7)
    }

    @Test("CB-11 the limit drops the oldest unpinned items; too big is not stored")
    func limit() {
        let temp = TempStore(limit: 25 * Self.mb)
        let store = temp.store!
        for byte: UInt8 in [1, 2, 3] { store.add(.image(Self.blob(10 * Self.mb, byte), type: "public.png")) }
        #expect(store.history.count == 2 && store.usedBytes == 20 * Self.mb)
        store.add(.image(Self.blob(30 * Self.mb, 4), type: "public.png"))
        #expect(store.history.count == 2)

        temp.limit = 15 * Self.mb
        store.trim()
        #expect(store.history.count == 1)
    }

    @Test("CB-11 limit setting: unknown values are 100 MB")
    func limitSetting() {
        let defaults = ScreenshotRulesTests.MemoryDefaults([ClipboardStore.limitKey: 250])
        #expect(ClipboardStore.limitBytes(in: defaults) == 250 * Self.mb)
        #expect(ClipboardStore.limitBytes(in: ScreenshotRulesTests.MemoryDefaults()) == 100 * Self.mb)
        #expect(ClipboardStore.limits == [25, 50, 100, 250, 500])
    }

    @Test("CB-12 memory in use is the history's total")
    func usedBytes() {
        let temp = TempStore()
        let store = temp.store!
        store.add(.text("hello")); store.add(.text("hi", rtf: Self.blob(5))); store.add(.files([URL(filePath: "/x")]))
        store.togglePin(store.history[0].id)
        store.remove(store.history[0].id)
        store.togglePin(store.pinned[0].id)
        #expect(store.usedBytes == store.history.reduce(0) { $0 + $1.bytes })
        store.clearHistory()
        #expect(store.usedBytes == 0)
    }

    @Test("CB-13 a chosen history item moves to the top; a pinned one stays")
    func touch() {
        let temp = TempStore()
        let store = temp.store!
        store.add(.text("a")); store.add(.text("b")); store.add(.text("c"))
        store.touch(store.history[2].id)
        #expect(store.history.map(\.text) == ["a", "c", "b"])
        store.togglePin(store.history[1].id); store.togglePin(store.history[1].id)   // pin c, b
        store.touch(store.pinned[1].id)
        #expect(store.pinned.map(\.text) == ["c", "b"])
    }

    @Test("CB-14 Clear History keeps pins; deleting a pin removes it from disk")
    func clear() {
        let temp = TempStore()
        let store = temp.store!
        store.add(.text("a")); store.add(.text("b"))
        store.togglePin(store.history[0].id)
        store.clearHistory()
        #expect(store.history.isEmpty && store.pinned.map(\.text) == ["b"])
        store.remove(store.pinned[0].id)
        temp.reload()
        #expect(temp.store.pinned.isEmpty)
    }

    // MARK: D. Pinned items

    @Test("CB-15 pins survive the limit, Clear History and a new launch")
    func pinsStay() {
        let temp = TempStore(limit: 15 * Self.mb)
        let store = temp.store!
        store.add(.image(Self.blob(10 * Self.mb, 1), type: "public.png"))
        store.togglePin(store.history[0].id)
        for byte: UInt8 in [2, 3, 4] { store.add(.image(Self.blob(10 * Self.mb, byte), type: "public.png")) }
        store.clearHistory()
        temp.reload()
        #expect(temp.store.pinned.count == 1 && temp.store.pinned[0].pinned)
    }

    @Test("CB-16 pin goes to the bottom of Pinned; unpin to the top of History")
    func pinOrder() {
        let temp = TempStore()
        let store = temp.store!
        store.add(.text("a")); store.add(.text("b")); store.add(.text("c"))
        let used = store.usedBytes
        store.togglePin(store.history[1].id)   // b
        store.togglePin(store.history[1].id)   // a
        #expect(store.pinned.map(\.text) == ["b", "a"] && store.history.map(\.text) == ["c"])
        #expect(store.usedBytes == used - 2)
        store.togglePin(store.pinned[0].id)
        #expect(store.history.map(\.text) == ["b", "c"])
    }

    @Test("CB-17 pins file: owner-only, read back, no file without pins, only file URLs")
    func pinsFile() throws {
        let temp = TempStore()
        let store = temp.store!
        store.add(.files([URL(filePath: "/tmp/a"), URL(string: "https://example.com/x")!]))
        store.togglePin(store.history[0].id)
        let manager = FileManager.default
        let file = try manager.attributesOfItem(atPath: temp.pinsFile.path)[.posixPermissions] as? Int
        let folder = try manager.attributesOfItem(atPath: temp.folder.path)[.posixPermissions] as? Int
        #expect(file == 0o600 && folder == 0o700)
        temp.reload()
        #expect(temp.store.pinned.first?.files == [URL(filePath: "/tmp/a")])
        temp.store.togglePin(temp.store.pinned[0].id)
        #expect(!manager.fileExists(atPath: temp.pinsFile.path))
    }

    @Test("B-18 an unreadable pins file is never written over")
    func unreadablePins() throws {
        let temp = TempStore()
        temp.store.add(.text("kept"))
        temp.store.togglePin(temp.store.history[0].id)
        // One readable pin and one of a kind this version doesn't know.
        var list = try #require(PropertyListSerialization.propertyList(
            from: Data(contentsOf: temp.pinsFile), format: nil) as? [[String: Any]])
        var unknown = list[0]
        unknown["kind"] = "link"
        unknown["id"] = UUID().uuidString
        list.append(unknown)
        let original = try PropertyListSerialization.data(fromPropertyList: list, format: .binary, options: 0)
        try original.write(to: temp.pinsFile)

        temp.reload()
        #expect(temp.store.pinned.map(\.text) == ["kept"])
        temp.store.add(.text("new"))
        temp.store.togglePin(temp.store.history[0].id)
        let aside = temp.folder.appending(path: "Pinned (unreadable).plist")
        #expect((try? Data(contentsOf: aside)) == original)

        // Not a list at all: set aside, never overwritten.
        try Data("garbage".utf8).write(to: temp.pinsFile)
        try? FileManager.default.removeItem(at: aside)
        temp.reload()
        temp.store.add(.text("x"))
        temp.store.togglePin(temp.store.history[0].id)
        #expect((try? Data(contentsOf: aside)) == Data("garbage".utf8))
    }

    @Test("CB-16 O-21 an unpinned item over the limit stays; the others go")
    func unpinBig() {
        let temp = TempStore(limit: 15 * Self.mb)
        let store = temp.store!
        store.add(.image(Self.blob(10 * Self.mb, 1), type: "public.png"))
        store.togglePin(store.history[0].id)
        temp.limit = 5 * Self.mb
        store.add(.text("a")); store.add(.text("b"))
        let big = store.pinned[0].id
        store.togglePin(big)
        #expect(store.history.map(\.id) == [big] && store.usedBytes == 10 * Self.mb)
    }

    // MARK: F. Using an item

    @Test("CB-07 CB-25 O-20 web formatting: HTML is kept and written back only when formatting is kept")
    func htmlFormatting() throws {
        let html = Data("<b>hi</b>".utf8)
        let item = try #require(Self.read { $0.setString("hi", forType: .string); $0.setData(html, forType: .html) })
        #expect(item.kind == .text && item.html == html && item.bytes == 2 + html.count)

        let pasteboard = NSPasteboard(name: .init("PenknifeTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        ClipboardReader.write(item, formatted: true, to: pasteboard)
        #expect(pasteboard.data(forType: .html) == html && pasteboard.string(forType: .string) == "hi")
        pasteboard.clearContents()
        ClipboardReader.write(item, formatted: false, to: pasteboard)
        #expect(pasteboard.data(forType: .html) == nil && pasteboard.data(forType: .rtf) == nil)
        #expect(pasteboard.string(forType: .string) == "hi")
    }

    @Test("O-22 files that no longer exist leave the history; pins are only hidden")
    func missingFiles() {
        let temp = TempStore()
        let store = temp.store!
        let gone = URL(filePath: "/gone/a"), here = URL(filePath: "/here/b")
        store.add(.files([gone]))
        store.togglePin(store.history[0].id)
        store.add(.files([gone, here])); store.add(.files([URL(filePath: "/gone/c")])); store.add(.text("t"))
        let pin = store.pinned[0].id
        let hidden = store.dropMissingFiles { !$0.path.hasPrefix("/gone") }
        #expect(hidden == [pin] && store.pinned.count == 1)
        #expect(store.history.map(\.kind) == [.text, .files] && store.history[1].files == [here])
        #expect(store.usedBytes == store.history.reduce(0) { $0 + $1.bytes })
        store.add(.files([here]))
        #expect(store.history.count == 2)   // the same copy as the trimmed item

        let model = ClipboardPanelModel(store: store, hidden: hidden)
        #expect(!model.rows.contains { $0.id == pin })
    }

    // MARK: E. The panel

    @Test("CB-21 a row's line")
    func titles() {
        #expect(ClipItem.text("  \n hello\nworld").title == "hello")
        #expect(ClipItem.text(String(repeating: "x", count: 250)).title.count == 200)
        #expect(ClipItem.files([URL(filePath: "/a/report.pdf")]).title == "report.pdf")
        #expect(ClipItem.files(["a", "b", "c"].map { URL(filePath: "/x/\($0)") }).title == "3 files: a, b, c")
    }

    @Test("CB-24 what VoiceOver hears for a row")
    func spoken() {
        var item = ClipItem.text("hi")
        item.pinned = true
        #expect(ClipboardPanelModel.spoken(item) == "Text: hi, pinned")
        #expect(ClipboardPanelModel.spoken(.image(Self.blob(3), type: "public.png")) == "Image")
        #expect(ClipboardPanelModel.spoken(.files([URL(filePath: "/a/r.pdf")])) == "Files: r.pdf")
    }

    // MARK: G. Privacy and language

    static var sources: [String] {
        let folder = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Penknife/Clipboard")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasSuffix(".swift") }
            .compactMap { try? String(contentsOf: folder.appending(path: $0), encoding: .utf8) }
    }

    @Test("CB-30 nothing is uploaded")
    func noNetwork() {
        let sources = Self.sources
        #expect(sources.count >= 3)
        for word in ["URLSession", "URLRequest", "NWConnection"] {
            #expect(!sources.contains { $0.contains(word) }, "\(word) in Penknife/Clipboard")
        }
    }

    @Test("CB-31 every visible string has Spanish")
    func spanish() {
        let keys = ["Clipboard History", "Image", "%lld files: %@", "Search", "Search the clipboard history",
                    "Nothing copied yet", "No results", "%lld results", "Pinned", "History", "Paste", "Copy",
                    "Pin", "Unpin", "Delete", "Clear History…", "Clear the clipboard history?",
                    "Pinned items are kept.", "Clear", "Copied", "To paste it too, allow Accessibility", "Text",
                    "Files", "%@, pinned", "Deleted", "History cleared", "Unpinned", "Memory for the history",
                    "Paste after choosing an item", "Keep text formatting", "Open the history",
                    "Center of the screen", "At the pointer", "In use: %@", "Image %@ at %@"]
        for key in keys {
            #expect(ScreenshotRulesTests.spanish[key]?.isEmpty == false, "no Spanish for \(key)")
        }
    }
}

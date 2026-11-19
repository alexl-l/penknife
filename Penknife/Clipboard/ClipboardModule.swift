import AppKit

/// Clipboard history (R-7, replaces Maccy). macOS has no "clipboard changed" notification, so a
/// light timer compares the pasteboard's change count (one cheap call, no data read unless it
/// changed). It runs only while the module is on and the screens are awake.
final class ClipboardModule: Module {
    let id = ModuleID.clipboard
    static let pasteKey = "clipboard.paste"
    static let positionKey = "clipboard.position"
    static let formattingKey = "clipboard.keepFormatting"

    /// Paste text with its formatting (fonts, bold, colors) or as plain text. ⇧ inverts it once.
    static var keepsFormatting: Bool {
        UserDefaults.standard.object(forKey: formattingKey) as? Bool ?? true
    }

    let store = ClipboardStore()
    private var timer: Timer?
    private var lastChange = NSPasteboard.general.changeCount
    private var observers: [NSObjectProtocol] = []
    private var panel: ClipboardPanel?
    /// The app in front when the panel opened: the paste goes there and nowhere else.
    private var previousApp: NSRunningApplication?

    /// Paste into the front app after choosing an item (needs Accessibility); otherwise only copy.
    static var pastes: Bool {
        UserDefaults.standard.object(forKey: pasteKey) as? Bool ?? true
    }

    var actions: [ModuleAction] {
        [ModuleAction(shortcut: .clipboardHistory, title: String(localized: "Clipboard History"), symbol: id.symbol,
                      perform: { [weak self] in self?.showPanel() })]
    }

    func start() {
        lastChange = NSPasteboard.general.changeCount
        startTimer()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification] {
            let asleep = name == NSWorkspace.screensDidSleepNotification
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    asleep ? self.stopTimer() : self.startTimer()
                }
            })
        }
    }

    func stop() {
        stopTimer()
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers.removeAll()
        panel?.close()
        panel = nil
        // The history lives only while the module is on; pinned items stay on disk.
        store.clearHistory()
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func check() {
        let pasteboard = NSPasteboard.general
        let change = pasteboard.changeCount
        guard change != lastChange else { return }
        lastChange = change
        if let item = ClipboardReader.read(pasteboard, frontApp: NSWorkspace.shared.frontmostApplication?.bundleIdentifier) {
            store.add(item)
        }
    }

    // MARK: Using an item

    /// Puts the item back on the clipboard and, if chosen, pastes it into the front app.
    func use(_ id: ClipItem.ID, paste: Bool, invertFormatting: Bool = false) {
        guard let item = store.item(id) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        switch item.kind {
        case .text, .files:
            ClipboardReader.write(item, formatted: Self.keepsFormatting != invertFormatting, to: pasteboard)
        case .image:
            guard let data = item.image else { break }
            if previousApp?.bundleIdentifier == "com.apple.finder",
               let png = PastableImage.png(from: data, type: item.imageType) {
                // In Finder the image is pasted as a PNG file into the open folder.
                PastableImage.copy(png, named: PastableImage.timestampName { String(localized: "Image \($0) at \($1)") })
            } else {
                pasteboard.setData(data, forType: NSPasteboard.PasteboardType(item.imageType ?? NSPasteboard.PasteboardType.tiff.rawValue))
            }
        }
        // Our own write is not a new copy.
        lastChange = pasteboard.changeCount
        store.touch(id)
        panel?.close()

        guard paste, Self.pastes else { return }
        guard Permissions.shared.ensureAccessibility() else {
            HUD.shared.show(String(localized: "Copied"), detail: String(localized: "To paste it too, allow Accessibility"),
                             symbol: "doc.on.clipboard.fill", kind: .permission, category: .clipboard)
            return
        }
        // ⌘V only once the app that was in front when the panel opened has the keyboard back;
        // if it went away, the item stays copied and nothing is pressed.
        let target = previousApp
        func pasteWhenReady(_ tries: Int) {
            guard let target, !target.isTerminated else { return }
            if NSWorkspace.shared.frontmostApplication == target, NSApp.keyWindow == nil {
                EventPoster.key(EventPoster.keyCode(for: "v") ?? 9, flags: .maskCommand)
            } else if tries > 0 {
                target.activate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { pasteWhenReady(tries - 1) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { pasteWhenReady(6) }
    }

    // MARK: Panel

    /// Built when opened and released when closed, so it costs no memory while hidden (R-11).
    func showPanel() {
        check()
        if let panel {
            panel.close()
            return
        }
        previousApp = NSWorkspace.shared.frontmostApplication
        // Checked once per opening, never in the background (O-22).
        let hidden = store.dropMissingFiles()
        let panel = ClipboardPanel(module: self, hidden: hidden) { [weak self] in self?.panel = nil }
        self.panel = panel
        panel.show()
    }
}

/// What a clipboard change becomes in the history (CB-06, CB-07): nothing for passwords and
/// temporary data, else files, text or an image. Only the data that will be kept is read.
enum ClipboardReader {
    /// Markers apps put on passwords and temporary data (nspasteboard.org convention and a few
    /// apps' own).
    private static let skipped: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType",
        "com.agilebits.onepassword",
        "com.agilebits.onepassword.ConcealedType",
        "de.petermaurer.TransientPasteboardType",
        "com.typeit4me.clipping",
    ]

    /// Password managers and Keychain: nothing they copy is stored, marked or not.
    private static let skippedApps: Set<String> = [
        "com.apple.keychainaccess",
        "com.apple.Passwords",
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
        "org.keepassxc.keepassxc",
        "com.lastpass.LastPass",
        "com.dashlane.dashlanephonefinal",
        "com.dashlane.Dashlane",
    ]

    /// Puts a text or files item on a cleared pasteboard: the plain text, plus the RTF and HTML
    /// when `formatted`; files as references, only those that still exist (O-22).
    static func write(_ item: ClipItem, formatted: Bool,
                      exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
                      to pasteboard: NSPasteboard) {
        switch item.kind {
        case .text:
            if formatted {
                if let rtf = item.rtf { pasteboard.setData(rtf, forType: .rtf) }
                if let html = item.html { pasteboard.setData(html, forType: .html) }
            }
            pasteboard.setString(item.text ?? "", forType: .string)
        case .files:
            pasteboard.writeObjects((item.files ?? []).filter(exists) as [NSURL])
        case .image:
            break
        }
    }

    static func read(_ pasteboard: NSPasteboard, frontApp: String?) -> ClipItem? {
        guard let types = pasteboard.types, !types.isEmpty,
              !types.contains(where: { skipped.contains($0.rawValue) }) else { return nil }
        // The copying app may name itself (nspasteboard.org); otherwise the front app.
        let source = pasteboard.string(forType: NSPasteboard.PasteboardType("org.nspasteboard.source"))
            ?? frontApp
        if let source, skippedApps.contains(source) { return nil }

        // Only the data that will be kept is read (a screenshot can be tens of MB).
        let imageType: NSPasteboard.PasteboardType? = types.contains(.png) ? .png : types.contains(.tiff) ? .tiff : nil

        if types.contains(.fileURL),
           let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty,
           // An image Penknife also offered as a file (to paste into Finder) is kept as the image.
           !(imageType != nil && urls.allSatisfy(PastableImage.isOurs)) {
            return .files(urls, source: source)
        }

        let hasRTF = types.contains(.rtf)
        // Documents (Word, Pages) offer text and a picture of it: rich text means it is text.
        let isText = types.contains(.string) && (imageType == nil || hasRTF)

        if isText, let text = pasteboard.string(forType: .string), !text.isEmpty {
            let rtf = hasRTF ? pasteboard.data(forType: .rtf) : nil
            // Web pages often offer HTML and no RTF: keep it too, so their formatting can come back (O-20).
            let html = types.contains(.html) ? pasteboard.data(forType: .html) : nil
            return .text(text, rtf: rtf, html: html, source: source)
        }
        if let imageType, let data = pasteboard.data(forType: imageType) {
            return .image(data, type: imageType.rawValue, source: source)
        }
        return nil
    }
}

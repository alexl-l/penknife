import AppKit
import ImageIO
import Observation
import SwiftUI

/// Where the panel opens (setting): centered like Spotlight, or at the pointer.
enum ClipboardPosition: String, CaseIterable {
    case center, pointer

    var title: String {
        switch self {
        case .center: String(localized: "Center of the screen")
        case .pointer: String(localized: "At the pointer")
        }
    }

    static var current: Self {
        Self(rawValue: UserDefaults.standard.string(forKey: ClipboardModule.positionKey) ?? "") ?? .center
    }
}

/// State of one open panel: the search, the selected row and small caches (thumbnails, app
/// icons) that go away with the panel.
@Observable
final class ClipboardPanelModel {
    let store: ClipboardStore
    /// Pinned items whose files are all missing: kept, but not shown (O-22).
    var hidden: Set<ClipItem.ID>
    var query = "" {
        didSet {
            selectFirst()
            let count = rows.count
            announce(count == 0 ? String(localized: "No results") : String(localized: "\(count) results"))
        }
    }
    var selection: ClipItem.ID?
    /// Where VoiceOver announcements are posted (the panel; NSApp may be ignored while inactive).
    @ObservationIgnored weak var announcer: NSWindow?
    /// Rows scrolled by the keyboard slide under a resting pointer; hover is ignored meanwhile.
    @ObservationIgnored var lastKeyMove = Date.distantPast
    @ObservationIgnored private var icons: [String: NSImage] = [:]
    @ObservationIgnored private var thumbnails: [ClipItem.ID: NSImage] = [:]

    init(store: ClipboardStore, hidden: Set<ClipItem.ID> = []) {
        self.store = store
        self.hidden = hidden
        selectFirst()
    }

    private func matches(_ item: ClipItem) -> Bool {
        guard !query.isEmpty else { return true }
        let haystack = item.kind == .text ? (item.text ?? "") : item.title
        return haystack.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    var pinned: [ClipItem] { store.pinned.filter { !hidden.contains($0.id) && matches($0) } }
    var history: [ClipItem] { store.history.filter(matches) }
    /// Visible rows in order; the first nine get ⌘1–⌘9.
    var rows: [ClipItem] { pinned + history }

    func selectFirst() {
        selection = rows.first?.id
    }

    func move(_ step: Int) {
        let rows = rows
        guard !rows.isEmpty else { return }
        let index = rows.firstIndex { $0.id == selection } ?? -1
        let next = min(max(index + step, 0), rows.count - 1)
        selection = rows[next].id
        lastKeyMove = .now
        announce(Self.spoken(rows[next]))
    }

    /// The search field keeps the keyboard focus, so VoiceOver is told what changed.
    func announce(_ message: String) {
        guard let announcer else { return }
        NSAccessibility.post(element: announcer, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    static func spoken(_ item: ClipItem) -> String {
        let kind = switch item.kind {
        case .text: String(localized: "Text")
        case .image: String(localized: "Image")
        case .files: String(localized: "Files")
        }
        let text = item.kind == .image ? kind : "\(kind): \(item.title)"
        return item.pinned ? String(localized: "\(text), pinned") : text
    }

    func icon(for item: ClipItem) -> NSImage? {
        switch item.kind {
        case .image:
            if let cached = thumbnails[item.id] { return cached }
            guard let data = item.image, let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceThumbnailMaxPixelSize: 96,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                  ] as CFDictionary) else { return nil }
            let thumbnail = NSImage(cgImage: image, size: .zero)
            thumbnails[item.id] = thumbnail
            return thumbnail
        case .files:
            guard let first = item.files?.first else { return nil }
            return NSWorkspace.shared.icon(forFile: first.path)
        case .text:
            guard let source = item.source else { return nil }
            if let cached = icons[source] { return cached }
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: source) else { return nil }
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icons[source] = icon
            return icon
        }
    }
}

/// A floating panel that takes the keyboard without activating Penknife, so the app you were in
/// stays in front and receives the paste. Esc or clicking elsewhere closes it.
final class ClipboardPanel: NSPanel, NSWindowDelegate {
    private let model: ClipboardPanelModel
    private weak var module: ClipboardModule?
    private let onClose: () -> Void

    init(module: ClipboardModule, onClose: @escaping () -> Void) {
        self.module = module
        self.onClose = onClose
        model = ClipboardPanelModel(store: module.store)
        super.init(contentRect: NSRect(x: 0, y: 0, width: 480, height: 460),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        delegate = self
        model.announcer = self
        setAccessibilityLabel(String(localized: "Clipboard History"))

        let view = ClipboardView(model: model,
                                 use: { [weak self] id, paste in self?.module?.use(id, paste: paste) },
                                 togglePin: { [weak self] id in self?.togglePin(id) },
                                 remove: { [weak self] id in self?.remove(id) },
                                 clear: { [weak self] in self?.confirmClear() })
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
        let workspace = NSWorkspace.shared
        if workspace.accessibilityDisplayShouldReduceTransparency || workspace.accessibilityDisplayShouldIncreaseContrast {
            // Opaque, with a border when contrast is increased (R-19).
            let plain = NSView()
            plain.wantsLayer = true
            plain.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            plain.layer?.cornerRadius = 22
            plain.layer?.masksToBounds = true
            if workspace.accessibilityDisplayShouldIncreaseContrast {
                plain.layer?.borderWidth = 1
                plain.layer?.borderColor = NSColor.labelColor.cgColor
            }
            hosting.frame = plain.bounds
            hosting.autoresizingMask = [.width, .height]
            plain.addSubview(hosting)
            contentView = plain
        } else {
            let glass = NSGlassEffectView()
            glass.cornerRadius = 22
            glass.contentView = hosting
            contentView = glass
        }
    }

    /// Pinned items whose files went missing (O-22), found after the panel opened.
    func hide(_ ids: Set<ClipItem.ID>) {
        model.hidden = ids
        if !model.rows.contains(where: { $0.id == model.selection }) { model.selectFirst() }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func show() {
        position()
        makeKeyAndOrderFront(nil)
    }

    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        var origin: NSPoint
        switch ClipboardPosition.current {
        case .center:
            origin = NSPoint(x: visible.midX - frame.width / 2, y: visible.maxY - visible.height * 0.18 - frame.height)
        case .pointer:
            origin = NSPoint(x: mouse.x - 24, y: mouse.y - frame.height + 12)
        }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - frame.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - frame.height - 8)
        setFrameOrigin(origin)
    }

    // MARK: Keyboard

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, attachedSheet == nil, handle(event) { return }
        super.sendEvent(event)
    }

    private func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        switch Int(event.keyCode) {
        case 125: model.move(1); return true                // ↓
        case 126: model.move(-1); return true               // ↑
        case 53: close(); return true                       // Esc
        case 36, 76:                                        // Return: paste; ⌥Return: copy only; ⇧: other formatting
            if let id = model.selection {
                module?.use(id, paste: !flags.contains(.option), invertFormatting: flags.contains(.shift))
            }
            return true
        case 51 where command && flags.contains(.shift):    // ⌘⇧⌫: clear history
            confirmClear(); return true
        case 51 where command:                              // ⌘⌫: delete the selected item
            if let id = model.selection { remove(id) }
            return true
        default: break
        }
        guard command, let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        if key == "p", let id = model.selection {
            togglePin(id)
            return true
        }
        if let digit = Int(key), (1...9).contains(digit) {
            let rows = model.rows
            if rows.indices.contains(digit - 1) { module?.use(rows[digit - 1].id, paste: true) }
            return true
        }
        return false
    }

    private func togglePin(_ id: ClipItem.ID) {
        model.store.togglePin(id)
        model.selection = id
        if let item = model.store.item(id) {
            model.announce(item.pinned ? String(localized: "Pinned") : String(localized: "Unpinned"))
        }
    }

    private func remove(_ id: ClipItem.ID) {
        let rows = model.rows
        let index = rows.firstIndex { $0.id == id } ?? 0
        model.store.remove(id)
        let left = model.rows
        model.selection = left.isEmpty ? nil : left[min(index, left.count - 1)].id
        model.announce(String(localized: "Deleted"))
    }

    private func confirmClear() {
        guard !model.store.history.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Clear the clipboard history?")
        alert.informativeText = String(localized: "Pinned items are kept.")
        alert.addButton(withTitle: String(localized: "Clear"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: self) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated {
                self.model.store.clearHistory()
                self.model.selectFirst()
                self.model.announce(String(localized: "History cleared"))
            }
        }
    }

    // MARK: Closing

    func windowDidResignKey(_ notification: Notification) {
        guard attachedSheet == nil else { return }
        close()
    }

    private var closing = false

    override func close() {
        guard !closing else { return }
        closing = true
        super.close()
        contentView = nil
        onClose()
    }
}

// MARK: - View

struct ClipboardView: View {
    @Bindable var model: ClipboardPanelModel
    let use: (ClipItem.ID, Bool) -> Void
    let togglePin: (ClipItem.ID) -> Void
    let remove: (ClipItem.ID) -> Void
    let clear: () -> Void
    @FocusState private var searchFocused: Bool
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiate
    private let selectedText = Color(nsColor: .alternateSelectedControlTextColor)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($searchFocused)
                    .accessibilityLabel("Search the clipboard history")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if model.rows.isEmpty {
                Text(model.query.isEmpty ? "Nothing copied yet" : "No results")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }

            Divider()
            footer
        }
        .onAppear { searchFocused = true }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Filtered once per render; rows know their position for ⌘1–⌘9.
                let pinned = model.pinned
                let history = model.history
                LazyVStack(alignment: .leading, spacing: 2) {
                    if !pinned.isEmpty {
                        header("Pinned")
                        ForEach(Array(pinned.enumerated()), id: \.element.id) { index, item in row(item, number: index) }
                        if !history.isEmpty { header("History") }
                    }
                    ForEach(Array(history.enumerated()), id: \.element.id) { index, item in
                        row(item, number: pinned.count + index)
                    }
                }
                .padding(8)
            }
            .onChange(of: model.selection) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
    }

    private func header(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }

    private func row(_ item: ClipItem, number: Int?) -> some View {
        let selected = model.selection == item.id
        return HStack(spacing: 10) {
            Group {
                if let icon = model.icon(for: item) {
                    Image(nsImage: icon).resizable().aspectRatio(contentMode: item.kind == .image ? .fill : .fit)
                } else {
                    Image(systemName: "doc.on.clipboard").foregroundStyle(.secondary)
                }
            }
            .frame(width: 18, height: 18)
            .clipShape(RoundedRectangle(cornerRadius: item.kind == .image ? 4 : 0))
            .accessibilityHidden(true)

            Text(item.kind == .image ? String(localized: "Image") : item.title)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            if item.pinned {
                Image(systemName: "pin.fill")
                    .font(.caption)
                    .foregroundStyle(selected ? selectedText : .secondary)
                    .accessibilityHidden(true)
            }
            if let number, number < 9 {
                Text("⌘\(number + 1)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(selected ? selectedText : .secondary)
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(selected ? selectedText : .primary)
        .padding(.horizontal, 10)
        .frame(minHeight: 34)
        .background(selected ? Color(nsColor: .selectedContentBackgroundColor) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            // Selection not only by color (Increase Contrast / Differentiate Without Color).
            if selected, contrast == .increased || differentiate {
                RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .labelColor), lineWidth: 2)
            }
        }
        .contentShape(Rectangle())
        .id(item.id)
        .onHover { inside in
            if inside, Date.now.timeIntervalSince(model.lastKeyMove) > 0.4 { model.selection = item.id }
        }
        .onTapGesture { use(item.id, true) }
        .contextMenu {
            Button("Paste") { use(item.id, true) }
            Button("Copy") { use(item.id, false) }
            Button(item.pinned ? "Unpin" : "Pin") { togglePin(item.id) }
            Divider()
            Button("Delete") { remove(item.id) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ClipboardPanelModel.spoken(item))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { use(item.id, true) }
        .accessibilityAction(named: Text(item.pinned ? "Unpin" : "Pin")) { togglePin(item.id) }
        .accessibilityAction(named: Text("Copy")) { use(item.id, false) }
        .accessibilityAction(named: Text("Delete")) { remove(item.id) }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            hint("↩", "Paste")
            hint("⌘P", "Pin")
            hint("⌘⌫", "Delete")
            Spacer()
            Button("Clear History…", action: clear)
                .buttonStyle(.borderless)
                .disabled(model.store.history.isEmpty)
                .help("⌘⇧⌫")
                .accessibilityHint("Command Shift Delete")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    private func hint(_ keys: String, _ title: LocalizedStringKey) -> some View {
        HStack(spacing: 4) {
            Text(keys).fontWeight(.medium)
            Text(title)
        }
        .accessibilityElement(children: .combine)
    }
}

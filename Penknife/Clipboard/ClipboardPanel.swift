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

/// What a key does in the panel (CB-22); nil = it goes to the search field.
enum ClipboardKeyAction: Equatable {
    case move(Int)
    case close
    /// Return: paste (⌥ only copies); ⇧ uses the other formatting once.
    case choose(paste: Bool, invertFormatting: Bool)
    case clear
    case delete
    case togglePin
    /// ⌘E: the selected pinned item's own icon (CB-33).
    case editIcon
    /// ⌘1–⌘9: paste that visible row (0-based).
    case row(Int)
    /// ⌘U: edit the selected text pin's value (CB-34).
    case editValue
    /// ⌥⌘↑ / ⌥⌘↓: move the selected pinned item (R-35).
    case movePin(Int)
}

enum ClipboardKeys {
    static func action(keyCode: Int, characters: String?, flags: NSEvent.ModifierFlags) -> ClipboardKeyAction? {
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        switch keyCode {
        case 125 where command && flags.contains(.option): return .movePin(1)
        case 126 where command && flags.contains(.option): return .movePin(-1)
        case 125: return .move(1)                                   // ↓
        case 126: return .move(-1)                                  // ↑
        case 53: return .close                                      // Esc
        case 36, 76: return .choose(paste: !flags.contains(.option), invertFormatting: flags.contains(.shift))
        case 51 where command && flags.contains(.shift): return .clear   // ⌘⇧⌫
        case 51 where command: return .delete                       // ⌘⌫
        default: break
        }
        guard command, let key = characters?.lowercased() else { return nil }
        if key == "p" { return .togglePin }
        if key == "e" { return .editIcon }
        if key == "u" { return .editValue }
        if let digit = Int(key), (1...9).contains(digit) { return .row(digit - 1) }
        return nil
    }
}

/// State of one open panel: the search, the selected row and a small cache (app
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
    /// The pinned item whose icon editor is open (CB-33); the panel stays open meanwhile.
    /// The pinned item whose editor (icon or value) is open.
    var editingIcon: ClipItem.ID?
    var editing: PinEditor = .icon

    enum PinEditor { case icon, value }

    func edit(_ id: ClipItem.ID, _ editor: PinEditor) {
        editing = editor
        editingIcon = id
    }
    /// Where VoiceOver announcements are posted (the panel; NSApp may be ignored while inactive).
    @ObservationIgnored weak var announcer: NSWindow?
    /// Rows scrolled by the keyboard slide under a resting pointer; hover is ignored meanwhile.
    @ObservationIgnored var lastKeyMove = Date.distantPast
    @ObservationIgnored private var icons: [String: NSImage] = [:]

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

    /// Deletes an item; the selection goes to the row now in its place, else the last (CB-22).
    func remove(_ id: ClipItem.ID) {
        let index = rows.firstIndex { $0.id == id } ?? 0
        store.remove(id)
        let left = rows
        selection = left.isEmpty ? nil : left[min(index, left.count - 1)].id
    }

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
            // Made by the store when the image came in; never decoded here (B-21). Until it's
            // ready (a fraction of a second after a copy) the row shows the generic icon.
            return store.thumbnails[item.key]
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
final class ClipboardPanel: NSPanel, NSWindowDelegate, NSPopoverDelegate {
    private let model: ClipboardPanelModel
    private weak var module: ClipboardModule?
    private let onClose: () -> Void
    private weak var hosting: NSView?

    init(module: ClipboardModule, onClose: @escaping () -> Void) {
        self.module = module
        self.onClose = onClose
        model = ClipboardPanelModel(store: module.store)
        super.init(contentRect: NSRect(x: 0, y: 0, width: PanelLayout.width, height: PanelLayout.minHeight),
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
                                 clear: { [weak self] in self?.confirmClear() },
                                 showEditor: { [weak self] id, rect in self?.showIconEditor(id, at: rect) })
        let hosting = NSHostingView(rootView: view)
        self.hosting = hosting
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
        let visible = (NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main)?.visibleFrame.height ?? 900
        setContentSize(NSSize(width: PanelLayout.width,
                              height: PanelLayout.height(pinned: model.pinned.count, history: model.history.count, visible: visible)))
        position()
        makeKeyAndOrderFront(nil)
    }

    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        setFrameOrigin(Self.origin(position: ClipboardPosition.current, mouse: mouse, visible: visible, size: frame.size))
    }

    /// Centered with its top 18 % below the top, or by the pointer; 8 pt inside the visible frame (CB-19).
    static func origin(position: ClipboardPosition, mouse: NSPoint, visible: NSRect, size: NSSize) -> NSPoint {
        var origin: NSPoint
        switch position {
        case .center:
            origin = NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - visible.height * 0.18 - size.height)
        case .pointer:
            origin = NSPoint(x: mouse.x - 24, y: mouse.y - size.height + 12)
        }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        return origin
    }

    // MARK: Keyboard

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, attachedSheet == nil, model.editingIcon == nil, handle(event) { return }
        super.sendEvent(event)
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let action = ClipboardKeys.action(keyCode: Int(event.keyCode), characters: event.charactersIgnoringModifiers,
                                                flags: event.modifierFlags) else { return false }
        switch action {
        case .move(let step): model.move(step)
        case .close: close()
        case .choose(let paste, let invert):
            if let id = model.selection { module?.use(id, paste: paste, invertFormatting: invert) }
        case .clear: confirmClear()
        case .delete:
            if let id = model.selection { remove(id) }
        case .togglePin:
            // With nothing selected, ⌘P goes on to the search field.
            guard let id = model.selection else { return false }
            togglePin(id)
        case .editIcon:
            guard let id = model.selection, model.store.item(id)?.pinned == true else { return false }
            model.edit(id, .icon)
        case .row(let index):
            let rows = model.rows
            if rows.indices.contains(index) { module?.use(rows[index].id, paste: true) }
        case .editValue:
            guard let id = model.selection, let item = model.store.item(id), item.pinned, item.kind == .text else { return false }
            model.edit(id, .value)
        case .movePin(let step):
            guard let id = model.selection, let index = model.store.pinned.firstIndex(where: { $0.id == id }) else { return false }
            model.store.movePin(id, to: index + step)
            model.store.savePinOrder()
            model.announce(String(localized: "Moved"))
        }
        return true
    }

    private func togglePin(_ id: ClipItem.ID) {
        model.store.togglePin(id)
        model.selection = id
        if let item = model.store.item(id) {
            model.announce(item.pinned ? String(localized: "Pinned") : String(localized: "Unpinned"))
        }
    }

    private func remove(_ id: ClipItem.ID) {
        model.remove(id)
        model.announce(String(localized: "Deleted"))
    }

    private func confirmClear() {
        guard !model.store.history.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Clear the clipboard history?")
        alert.informativeText = String(localized: "Pinned items are kept.")
        alert.addButton(withTitle: String(localized: "Clear"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addTouchBar()
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
        // The icon editor and the emoji viewer take the keyboard: the panel stays (CB-33).
        guard attachedSheet == nil, model.editingIcon == nil else { return }
        close()
    }

    // MARK: Icon editor (CB-33)

    private var iconPopover: NSPopover?
    private var iconMonitors: [Any] = []
    private static let emojiViewer = "com.apple.CharacterPaletteIM"

    /// A native popover that closes only when Penknife says so: SwiftUI's closes as soon as the
    /// emoji viewer (another process) takes the keyboard (measured 2026-11-20).
    fileprivate func showIconEditor(_ id: ClipItem.ID, at rect: CGRect) {
        guard iconPopover == nil else { return }
        guard let hosting, let item = model.store.item(id), item.pinned else {
            model.editingIcon = nil
            return
        }
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = false
        switch model.editing {
        case .icon:
            popover.contentViewController = NSHostingController(
                rootView: IconEditor(initial: item.icon, appIcon: model.icon(for: item)) { [store = model.store] icon in
                    store.setIcon(id, icon)
                })
        case .value:
            guard item.kind == .text else {
                model.editingIcon = nil
                return
            }
            popover.contentViewController = NSHostingController(
                rootView: ValueEditor(initial: item.text ?? "") { [weak self] text in
                    guard let self else { return }
                    if let text, self.model.store.setPinText(id, text) {
                        self.model.announce(String(localized: "Value updated"))
                    }
                    self.closeIconEditor()
                })
        }
        popover.delegate = self
        iconPopover = popover
        popover.show(relativeTo: rect, of: hosting, preferredEdge: .maxX)
        let window = popover.contentViewController?.view.window
        window?.makeKey()
        // The icon editor opens with nothing focused: the field takes the focus only when clicked,
        // tabbed to or when 🙂 is used (user, 2026-11-20: "no me gusta que el foco siempre se quede
        // en la caja"). The value editor opens on its field, all selected, to type or paste over.
        if model.editing == .icon { DispatchQueue.main.async { window?.makeFirstResponder(nil) } }
        watchWhileEditing()
    }

    /// Esc or a click on the panel closes the editor; a click in another app closes the panel too,
    /// as without the editor (CB-24); clicks in the emoji viewer are left alone.
    private func watchWhileEditing() {
        if let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self, event.keyCode == 53, self.iconPopover != nil else { return event }
            self.closeIconEditor()
            return nil
        }) { iconMonitors.append(keys) }
        if let clicks = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            if let self, event.window === self { self.closeIconEditor() }
            return event
        }) { iconMonitors.append(clicks) }
        if let outside = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            guard let self, !Self.inEmojiViewer(NSEvent.mouseLocation) else { return }
            self.closeIconEditor()
            self.close()
        }) { iconMonitors.append(outside) }
    }

    /// Whether a screen point (bottom-left origin) is on one of the emoji viewer's windows.
    private static func inEmojiViewer(_ point: NSPoint) -> Bool {
        let viewers = Set(NSRunningApplication.runningApplications(withBundleIdentifier: emojiViewer).map(\.processIdentifier))
        guard !viewers.isEmpty, let primary = NSScreen.screens.first,
              let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        let flipped = CGPoint(x: point.x, y: primary.frame.maxY - point.y)
        return info.contains { window in
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t, viewers.contains(pid),
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { return false }
            return rect.contains(flipped)
        }
    }

    fileprivate func closeIconEditor() {
        iconPopover?.close()
    }

    func popoverDidClose(_ notification: Notification) {
        iconMonitors.forEach(NSEvent.removeMonitor)
        iconMonitors.removeAll()
        iconPopover = nil
        model.editingIcon = nil
        // The panel takes the keyboard back, so typing searches again.
        if isVisible, !closing { makeKey() }
    }

    private var closing = false

    override func close() {
        guard !closing else { return }
        closing = true
        iconPopover?.close()
        super.close()
        contentView = nil
        onClose()
    }
}

// MARK: - View

/// Sizes of the panel's list (CB-21): rows, headers, and how far the pinned area grows before it
/// scrolls on its own.
enum PanelLayout {
    static let rowHeight: CGFloat = 28
    static let headerHeight: CGFloat = 22
    static let pinnedRows = 5
    /// Search field, footer and their lines.
    static let chrome: CGFloat = 82
    static let width: CGFloat = 480
    static let minHeight: CGFloat = 300
    static let maxHeight: CGFloat = 680

    /// The pinned area: its rows up to `pinnedRows`; past that it scrolls inside.
    static func pinnedArea(_ count: Int) -> CGFloat {
        CGFloat(min(count, pinnedRows)) * rowHeight
    }

    /// Height when the panel opens, from what it shows then; it doesn't change while open, so the
    /// window doesn't jump while typing a search (CB-20). Never above 72 % of the visible screen.
    static func height(pinned: Int, history: Int, visible: CGFloat) -> CGFloat {
        var content = CGFloat(history) * rowHeight + 12
        if pinned > 0 {
            content += headerHeight + pinnedArea(pinned) + 1
            if history > 0 { content += headerHeight }
        }
        let top = min(maxHeight, (visible * 0.72).rounded(.down))
        return min(max(chrome + content, minHeight), max(top, minHeight))
    }
}

struct ClipboardView: View {
    @Bindable var model: ClipboardPanelModel
    let use: (ClipItem.ID, Bool) -> Void
    let togglePin: (ClipItem.ID) -> Void
    let remove: (ClipItem.ID) -> Void
    let clear: () -> Void
    let showEditor: (ClipItem.ID, CGRect) -> Void
    @FocusState private var searchFocused: Bool
    /// Dragging a pinned row to reorder it (R-35); only without a search, when all pins show.
    @State private var draggedPin: ClipItem.ID?
    @State private var dragStart = 0
    @State private var dragOffset: CGFloat = 0
    private static let pinSpace = "pinnedRows"
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

    /// "Pinned" stays at the top and never scrolls away; only "History" scrolls. Past five pins the
    /// pinned area scrolls on its own. Headers show only when something is pinned (CB-21).
    private var list: some View {
        let pinned = model.pinned
        let history = model.history
        return VStack(spacing: 0) {
            if !pinned.isEmpty {
                header("Pinned")
                scrolling(pinned, first: 0, label: "Pinned")
                    .frame(height: PanelLayout.pinnedArea(pinned.count))
                    .scrollDisabled(pinned.count <= PanelLayout.pinnedRows)
                Divider().padding(.top, 4)
                if !history.isEmpty { header("History") }
            }
            if history.isEmpty {
                Spacer(minLength: 0)
            } else {
                scrolling(history, first: pinned.count, label: "History")
            }
        }
    }

    private func scrolling(_ items: [ClipItem], first: Int, label: LocalizedStringKey) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if item.pinned, model.query.isEmpty, model.hidden.isEmpty {
                            row(item, number: first + index)
                                .offset(y: draggedPin == item.id ? dragOffset : 0)
                                .zIndex(draggedPin == item.id ? 1 : 0)
                                .simultaneousGesture(pinDrag(item.id))
                        } else {
                            row(item, number: first + index)
                        }
                    }
                }
                .coordinateSpace(.named(Self.pinSpace))
                .padding(.horizontal, 6)
                .padding(.vertical, first == 0 ? 0 : 6)
            }
            .accessibilityLabel(label)
            .onChange(of: model.selection) { _, id in
                // Each area scrolls only to its own rows; the other one ignores the id.
                if let id, items.contains(where: { $0.id == id }) { proxy.scrollTo(id) }
            }
        }
    }

    private func pinDrag(_ id: ClipItem.ID) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.pinSpace))
            .onChanged { drag in
                let pins = model.store.pinned
                if draggedPin == nil {
                    draggedPin = id
                    dragStart = pins.firstIndex { $0.id == id } ?? 0
                    model.selection = id
                }
                guard let current = pins.firstIndex(where: { $0.id == id }) else { return }
                let steps = Int((drag.translation.height / PanelLayout.rowHeight).rounded())
                let target = min(max(dragStart + steps, 0), pins.count - 1)
                if target != current {
                    withAnimation(.snappy(duration: 0.2)) { model.store.movePin(id, to: target) }
                }
                dragOffset = drag.translation.height - CGFloat(target - dragStart) * PanelLayout.rowHeight
            }
            .onEnded { _ in
                withAnimation(.snappy(duration: 0.2)) { dragOffset = 0 }
                draggedPin = nil
                model.store.savePinOrder()
            }
    }

    private func header(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: PanelLayout.headerHeight, alignment: .bottomLeading)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }

    private func row(_ item: ClipItem, number: Int) -> some View {
        let selected = model.selection == item.id
        return HStack(spacing: 8) {
            Group {
                if item.pinned, let custom = item.icon {
                    PinIconView(icon: custom, size: 16)
                } else if let icon = model.icon(for: item) {
                    Image(nsImage: icon).resizable().aspectRatio(contentMode: item.kind == .image ? .fill : .fit)
                } else {
                    Image(systemName: "doc.on.clipboard").foregroundStyle(.secondary)
                }
            }
            .frame(width: 16, height: 16)
            .clipShape(RoundedRectangle(cornerRadius: item.kind == .image ? 3 : 0))
            .accessibilityHidden(true)

            Text(item.kind == .image ? String(localized: "Image") : item.title)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            if item.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(selected ? selectedText : .secondary)
                    .accessibilityHidden(true)
            }
            if number < 9 {
                Text("⌘\(number + 1)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(selected ? selectedText : .secondary)
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(selected ? selectedText : .primary)
        .padding(.horizontal, 10)
        .frame(height: PanelLayout.rowHeight)
        .background(selected ? Color(nsColor: .selectedContentBackgroundColor) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            // Selection not only by color (Increase Contrast / Differentiate Without Color).
            if selected, contrast == .increased || differentiate {
                RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .labelColor), lineWidth: 2)
            }
        }
        .contentShape(Rectangle())
        .onHover { inside in
            if inside, Date.now.timeIntervalSince(model.lastKeyMove) > 0.4 { model.selection = item.id }
        }
        .onTapGesture { use(item.id, true) }
        .contextMenu {
            Button("Paste") { use(item.id, true) }
            Button("Copy") { use(item.id, false) }
            Button(item.pinned ? "Unpin" : "Pin") { togglePin(item.id) }
            if item.pinned {
                if item.kind == .text { Button("Update Value…") { model.edit(item.id, .value) } }
                Button("Customize Icon…") { model.edit(item.id, .icon) }
            }
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
        .modifier(PinActions(item: item, store: model.store, editValue: { model.edit($0, .value) }))
        .modifier(IconEditorAnchor(item: item, model: model, show: showEditor))
    }

    private var footer: some View {
        HStack(spacing: 14) {
            hint("↩", "Paste")
            hint("⌘P", "Pin")
            hint("⌘⌫", "Delete")
            if let pin = model.pinned.first(where: { $0.id == model.selection }) {
                if pin.kind == .text { hint("⌘U", "clipboard.edit") }
                hint("⌘E", "Icon")
            }
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


// MARK: - Pinned item icon (CB-33)

/// A pinned item's own icon: a bare emoji, or a tile (its color, light gray without one) with the
/// letter or emoji on it; a color alone is a flat tile.
struct PinIconView: View {
    let icon: PinIcon
    let size: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        if icon.isEmoji, icon.color == nil, let glyph = icon.glyph {
            Text(glyph).font(.system(size: size * 0.875)).frame(width: size, height: size)
        } else {
            let fill = icon.color.map { Color(nsColor: $0.color) } ?? Color(nsColor: .quaternarySystemFill)
            RoundedRectangle(cornerRadius: size / 4, style: .continuous)
                .fill(fill)
                .overlay {
                    if contrast == .increased {
                        RoundedRectangle(cornerRadius: size / 4, style: .continuous)
                            .strokeBorder(Color(nsColor: .labelColor).opacity(0.3), lineWidth: 1)
                    }
                }
                .overlay {
                    if let glyph = icon.glyph {
                        Text(glyph)
                            .font(.system(size: size * (icon.isEmoji ? 0.69 : 0.66), weight: .semibold, design: .rounded))
                            .foregroundStyle(icon.color == nil ? Color.primary
                                             : icon.color == .yellow ? Color.black.opacity(0.85) : .white)
                    }
                }
                .frame(width: size, height: size)
        }
    }
}

/// VoiceOver actions only pinned rows have (R-35): update, move up, move down.
private struct PinActions: ViewModifier {
    let item: ClipItem
    let store: ClipboardStore
    let editValue: (ClipItem.ID) -> Void

    func body(content: Content) -> some View {
        if item.pinned, item.kind == .text {
            content
                .accessibilityAction(named: Text("Update Value")) { editValue(item.id) }
                .accessibilityAction(named: Text("Move up")) { move(-1) }
                .accessibilityAction(named: Text("Move down")) { move(1) }
        } else if item.pinned {
            content
                .accessibilityAction(named: Text("Move up")) { move(-1) }
                .accessibilityAction(named: Text("Move down")) { move(1) }
        } else {
            content
        }
    }

    private func move(_ step: Int) {
        guard let index = store.pinned.firstIndex(where: { $0.id == item.id }) else { return }
        store.movePin(item.id, to: index + step)
        store.savePinOrder()
    }
}

/// Tells the panel where the row being edited is, so the editor opens beside it.
private struct IconEditorAnchor: ViewModifier {
    let item: ClipItem
    let model: ClipboardPanelModel
    let show: (ClipItem.ID, CGRect) -> Void

    func body(content: Content) -> some View {
        content
            .background {
                if model.editingIcon == item.id {
                    GeometryReader { geometry in
                        Color.clear.onAppear { show(item.id, geometry.frame(in: .global)) }
                    }
                }
            }
            .accessibilityAction(named: Text("Customize Icon")) { if item.pinned { model.edit(item.id, .icon) } }
    }
}

/// "Update Value…" (CB-34, ux-ui-designer spec 2026-11-22): the pin's text, all selected, to type
/// or paste over. One line that grows to five; Return saves, ⌥Return adds a line, Esc cancels.
struct ValueEditor: View {
    let initial: String
    /// The new text, or nil to cancel.
    let done: (String?) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Value", text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
                .focused($focused)
                .onSubmit { done(text) }
                .accessibilityLabel("Value")
            Text("↩ Save   esc Cancel")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(12)
        .frame(width: 320)
        .onAppear {
            text = initial
            DispatchQueue.main.async { focused = true }
        }
    }
}

/// One view (user, 2026-11-20): a letter or emoji, a color ("no color" first); neither = the app's
/// icon. Changes apply at once; Esc or a click outside closes it.
struct IconEditor: View {
    /// The icon when the editor opens; each change goes to `onChange` at once.
    let initial: PinIcon?
    let appIcon: NSImage?
    /// Shown with no letter and no color when there is no app icon (macros: ▶).
    var fallbackSymbol = "doc.on.clipboard"
    var caption = String(localized: "No letter and no color = the app's icon")
    let onChange: (PinIcon?) -> Void
    @State private var glyph = ""
    @State private var color: PinColor?
    @FocusState private var focused: Bool

    private var icon: PinIcon? { PinIcon(glyph: glyph, color: color) }

    var body: some View {
        VStack(spacing: 14) {
            Group {
                if let icon {
                    PinIconView(icon: icon, size: 32)
                } else if let appIcon {
                    Image(nsImage: appIcon).resizable().frame(width: 32, height: 32)
                } else {
                    Image(systemName: fallbackSymbol).font(.system(size: 24)).foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                }
            }
            .accessibilityHidden(true)

            HStack(spacing: 8) {
                TextField(String("Aa"), text: $glyph)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 17))
                    .frame(width: 72)
                    .focused($focused)
                    .accessibilityLabel("Icon letter or emoji")
                    .overlay(alignment: .trailing) {
                        if !glyph.isEmpty {
                            Button { glyph = "" } label: {
                                Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                            .padding(.trailing, 5)
                            .help("Clear")
                            .accessibilityLabel("Clear")
                        }
                    }
                    .onChange(of: glyph) { old, new in
                        let one = PinIcon.oneGlyph(old: old, new: new)
                        if one != new { glyph = one; return }
                        save()
                        // One letter is all it takes: the field lets the focus go (user, 2026-11-20).
                        // An emoji keeps it: it comes from the Emoji & Symbols viewer, which types
                        // into the focused field, so a second pick there must replace the first
                        // (user, 2026-11-22: "si selecciono un emoji y luego otro, no cambia").
                        if !new.isEmpty, PinIcon(glyph: new, color: nil)?.isEmoji != true { focused = false }
                    }
                Button {
                    focused = true
                    NSApp.orderFrontCharacterPalette(nil)
                } label: {
                    Image(systemName: "face.smiling")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .help("Emoji & Symbols (⌃⌘Space)")
                .accessibilityLabel("Emoji & Symbols")
            }

            HStack(spacing: 10) {
                swatch(nil, name: String(localized: "No color")) {
                    Circle().strokeBorder(Color(nsColor: .secondaryLabelColor), lineWidth: 1.5)
                        .overlay {
                            Rectangle().fill(Color(nsColor: .secondaryLabelColor))
                                .frame(width: 1.5, height: 22).rotationEffect(.degrees(-45))
                        }
                        .clipShape(Circle())
                }
                ForEach(PinColor.allCases, id: \.self) { choice in
                    swatch(choice, name: choice.name) { Circle().fill(Color(nsColor: choice.color)) }
                }
            }

            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 360)
        .onAppear {
            glyph = initial?.glyph ?? ""
            color = initial?.color
        }
    }

    private func save() {
        onChange(icon)
    }

    private func swatch(_ choice: PinColor?, name: String, @ViewBuilder _ fill: () -> some View) -> some View {
        let chosen = color == choice
        return Button {
            color = choice
            save()
        } label: {
            fill()
                .frame(width: 22, height: 22)
                .padding(2)
                .overlay { if chosen { Circle().strokeBorder(.primary, lineWidth: 2) } }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

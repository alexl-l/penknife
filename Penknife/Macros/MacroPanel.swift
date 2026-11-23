import AppKit
import KeyboardShortcuts
import Observation
import SwiftUI

/// The list of macros (R-35): a sibling of the clipboard panel. It takes the keyboard without
/// activating Penknife, so the app you were in stays in front and gets the macro.
@Observable
final class MacroPanelModel {
    let store: MacroStore
    /// The app in front when the panel opened: macros used there come first.
    var query = "" { didSet { selection = rows.first?.id } }
    var selection: Macro.ID?
    @ObservationIgnored var lastKeyMove = Date.distantPast

    init(store: MacroStore) {
        self.store = store
        selection = rows.first?.id
    }

    private func matches(_ macro: Macro) -> Bool {
        query.isEmpty || macro.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// One list in the editor's order (the user, 2026-11-22, didn't like the "In <app>" /
    /// "All" split: "se ve raro").
    var rows: [Macro] { store.macros.filter(matches) }

    func move(_ step: Int) {
        let rows = rows
        guard !rows.isEmpty else { return }
        let index = rows.firstIndex { $0.id == selection } ?? -1
        selection = rows[min(max(index + step, 0), rows.count - 1)].id
        lastKeyMove = .now
    }

    static func detail(_ macro: Macro) -> String {
        var text = String(localized: "\(macro.steps.count) steps")
        if !macro.data.isEmpty {
            let next = macro.data.next >= macro.data.rows.count ? (macro.data.repeats ? 1 : macro.data.rows.count) : macro.data.next + 1
            text += " · " + String(localized: "row \(next) of \(macro.data.rows.count)")
        }
        return text
    }
}

final class MacroPanel: NSPanel, NSWindowDelegate {
    private let model: MacroPanelModel
    private weak var module: MacrosModule?
    private let onClose: () -> Void

    init(module: MacrosModule, onClose: @escaping () -> Void) {
        self.module = module
        self.onClose = onClose
        model = MacroPanelModel(store: module.store)
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
        setAccessibilityLabel(String(localized: "Macros"))
        let view = MacroListView(model: model,
                                 run: { [weak self] id in self?.module?.runFromPanel(id) },
                                 edit: { [weak self] id in self?.module?.openEditor(id) },
                                 new: { [weak self] in self?.module?.openEditor(new: true) },
                                 duplicate: { [weak self] id in self?.duplicate(id) },
                                 remove: { [weak self] id in self?.confirmRemove(id) })
        contentView = Self.backing(NSHostingView(rootView: view))
    }

    /// Glass like the clipboard panel; opaque with Reduce Transparency, bordered with Increase Contrast.
    static func backing<V: View>(_ hosting: NSHostingView<V>) -> NSView {
        hosting.sizingOptions = []
        let workspace = NSWorkspace.shared
        if workspace.accessibilityDisplayShouldReduceTransparency || workspace.accessibilityDisplayShouldIncreaseContrast {
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
            return plain
        }
        let glass = NSGlassEffectView()
        glass.cornerRadius = 22
        glass.contentView = hosting
        return glass
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func show() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let content = CGFloat(model.rows.count) * PanelLayout.rowHeight + 12
        let top = min(PanelLayout.maxHeight, (visible.height * 0.72).rounded(.down))
        setContentSize(NSSize(width: PanelLayout.width, height: min(max(PanelLayout.chrome + content, PanelLayout.minHeight), top)))
        setFrameOrigin(ClipboardPanel.origin(position: ClipboardPosition.current, mouse: mouse, visible: visible, size: frame.size))
        makeKeyAndOrderFront(nil)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, attachedSheet == nil, handle(event) { return }
        super.sendEvent(event)
    }

    private func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        switch Int(event.keyCode) {
        case 125: model.move(1)
        case 126: model.move(-1)
        case 53: close()
        case 36, 76:
            guard let id = model.selection else { return true }
            module?.runFromPanel(id)
        case 51 where command:
            guard let id = model.selection else { return true }
            confirmRemove(id)
        default:
            guard command, let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
            switch key {
            case "e": if let id = model.selection { module?.openEditor(id) }
            case "n": module?.openEditor(new: true)
            case "d": if let id = model.selection { duplicate(id) }
            default: return false
            }
        }
        return true
    }

    private func duplicate(_ id: Macro.ID) {
        model.selection = model.store.duplicate(id) ?? id
        module?.refreshShortcuts()
    }

    private func confirmRemove(_ id: Macro.ID) {
        guard let macro = model.store.macro(id) else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Delete “\(macro.name)”?")
        alert.informativeText = String(localized: "This can't be undone.")
        alert.addButton(withTitle: String(localized: "Delete")).hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addTouchBar()
        alert.beginSheetModal(for: self) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated {
                let rows = self.model.rows
                let index = rows.firstIndex { $0.id == id } ?? 0
                self.module?.forgetShortcut(id)
                self.model.store.remove(id)
                let left = self.model.rows
                self.model.selection = left.isEmpty ? nil : left[min(index, left.count - 1)].id
            }
        }
    }

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

struct MacroListView: View {
    @Bindable var model: MacroPanelModel
    let run: (Macro.ID) -> Void
    let edit: (Macro.ID) -> Void
    let new: () -> Void
    let duplicate: (Macro.ID) -> Void
    let remove: (Macro.ID) -> Void
    @FocusState private var searchFocused: Bool
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiate
    private let selectedText = Color(nsColor: .alternateSelectedControlTextColor)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Search Macros", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($searchFocused)
                    .accessibilityLabel("Search macros")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            if model.store.macros.isEmpty {
                empty
            } else if model.rows.isEmpty {
                Text("No results").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
            Divider()
            footer
        }
        .onAppear { searchFocused = true }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.cursor").font(.system(size: 32)).foregroundStyle(.secondary).accessibilityHidden(true)
            Text("No Macros").font(.headline)
            Text("Create one to type text and keys for you.").foregroundStyle(.secondary)
            Button("New Macro", action: new)
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        let rows = model.rows
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row($0) }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
            }
            .onChange(of: model.selection) { _, id in if let id { proxy.scrollTo(id) } }
        }
    }

    private func row(_ macro: Macro) -> some View {
        let selected = model.selection == macro.id
        let shortcut = KeyboardShortcuts.getShortcut(for: MacrosModule.shortcut(macro))?.description
        return HStack(spacing: 8) {
            Image(systemName: "play.fill")
                .font(.system(size: 10))
                .foregroundStyle(selected ? selectedText : .secondary)
                .frame(width: 16)
                .accessibilityHidden(true)
            Text(macro.name.isEmpty ? String(localized: "Untitled") : macro.name)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(MacroPanelModel.detail(macro))
                .font(.caption.monospacedDigit())
                .foregroundStyle(selected ? selectedText : .secondary)
            if let shortcut {
                Text(shortcut)
                    .font(.caption)
                    .foregroundStyle(selected ? selectedText.opacity(0.8) : Color(nsColor: .tertiaryLabelColor))
            }
        }
        .foregroundStyle(selected ? selectedText : .primary)
        .padding(.horizontal, 10)
        .frame(height: PanelLayout.rowHeight)
        .background(selected ? Color(nsColor: .selectedContentBackgroundColor) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            if selected, contrast == .increased || differentiate {
                RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .labelColor), lineWidth: 2)
            }
        }
        .contentShape(Rectangle())
        .id(macro.id)
        .onHover { inside in
            if inside, Date.now.timeIntervalSince(model.lastKeyMove) > 0.4 { model.selection = macro.id }
        }
        .onTapGesture { run(macro.id) }
        .contextMenu {
            Button("Run") { run(macro.id) }
            Button("Edit…") { edit(macro.id) }
            Button("Duplicate") { duplicate(macro.id) }
            Divider()
            Button("Delete…") { remove(macro.id) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(macro.name), \(MacroPanelModel.detail(macro))")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { run(macro.id) }
        .accessibilityAction(named: Text("macros.edit")) { edit(macro.id) }
        .accessibilityAction(named: Text("Duplicate")) { duplicate(macro.id) }
        .accessibilityAction(named: Text("Delete")) { remove(macro.id) }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            hint("↩", "Run")
            hint("⌘E", "macros.edit")
            hint("⌘N", "New")
            Spacer()
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

// MARK: - Asked before running

/// `{ask:Name}` answers and plan B for a gone pinned item: a small glass panel before the run.
/// Return runs, Esc cancels. It doesn't activate Penknife, so the app behind stays in front.
final class MacroPrompt: NSPanel, NSWindowDelegate {
    struct Field: Identifiable {
        let id: String
        let label: String
        var value: String
        var note: String?
    }

    private let done: ([String: String]?) -> Void
    private var finished = false

    init(title: String, fields: [Field], done: @escaping ([String: String]?) -> Void) {
        self.done = done
        super.init(contentRect: NSRect(x: 0, y: 0, width: 360, height: 100),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        delegate = self
        let view = MacroPromptView(title: title, fields: fields,
                                   run: { [weak self] answers in self?.end(answers) },
                                   cancel: { [weak self] in self?.end(nil) })
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        contentView = MacroPanel.backing(hosting)
        setContentSize(NSSize(width: 360, height: size.height))
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func show() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        setFrameOrigin(ClipboardPanel.origin(position: .center, mouse: mouse, visible: visible, size: frame.size))
        makeKeyAndOrderFront(nil)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53 {
            end(nil)
            return
        }
        super.sendEvent(event)
    }

    func windowDidResignKey(_ notification: Notification) { end(nil) }

    private func end(_ answers: [String: String]?) {
        guard !finished else { return }
        finished = true
        close()
        contentView = nil
        done(answers)
    }
}

private struct MacroPromptView: View {
    let title: String
    @State var fields: [MacroPrompt.Field]
    let run: ([String: String]) -> Void
    let cancel: () -> Void
    @FocusState private var focus: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Details for “\(title)”").font(.headline)
            ForEach($fields) { $field in
                VStack(alignment: .leading, spacing: 4) {
                    Text(field.label).font(.callout).foregroundStyle(.secondary)
                    TextField(field.label, text: $field.value)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .focused($focus, equals: field.id)
                        .onSubmit(submit)
                    if let note = field.note {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                Button("Run", action: submit).keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 360)
        .onAppear { focus = fields.first?.id }
    }

    private func submit() {
        run(Dictionary(uniqueKeysWithValues: fields.map { ($0.id, $0.value) }))
    }
}

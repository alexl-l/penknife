import AppKit
import Carbon.HIToolbox
import KeyboardShortcuts
import SwiftUI
import UniformTypeIdentifiers

/// The macro editor (R-35, variant A picked 2026-11-22): its own window, macros on the left,
/// the chosen macro's steps on the right as plain rows; drag the handle to reorder.
final class MacroEditorWindow: NSWindow, NSWindowDelegate {
    private static var current: MacroEditorWindow?
    private weak var module: MacrosModule?
    private let selection: EditorSelection

    static func show(module: MacrosModule, select id: Macro.ID?, new: Bool) {
        let window = current ?? MacroEditorWindow(module: module)
        current = window
        if new {
            let macro = Macro(name: module.store.freshName(),
                              typesText: UserDefaults.standard.bool(forKey: MacrosModule.typesTextKey))
            window.selection.id = module.store.add(macro)
            module.refreshShortcuts()
        } else if let id {
            window.selection.id = id
        } else if window.selection.id == nil {
            window.selection.id = module.store.macros.first?.id
        }
        // As Settings: the cooperative `activate()` is refused for a menu bar app when the
        // editor is opened from the panel (another app in front; QA 2026-11-22). Opening it is
        // always the user's request.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private init(module: MacrosModule) {
        self.module = module
        selection = EditorSelection()
        super.init(contentRect: NSRect(x: 0, y: 0, width: 700, height: 540),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        title = String(localized: "Macros")
        isReleasedWhenClosed = false
        minSize = NSSize(width: 680, height: 420) // narrower cut the detail on the right (QA 2026-11-23)
        delegate = self
        // The window keeps the size the user gave it: without this the hosting controller grows
        // it to the content's ideal size (the Data tab's text view made it fill the screen).
        let host = NSHostingController(rootView: MacroEditorView(module: module, selection: selection))
        host.sizingOptions = []
        contentViewController = host
        setContentSize(NSSize(width: 700, height: 540))
        center()
        setFrameAutosaveName("MacroEditor")
    }

    /// ⌘C / ⌘V copy and paste the selected steps (MAC-79), unless a text field is being edited:
    /// then they are the field's.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if !(firstResponder is NSText),
           event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function]) == .command {
            switch event.charactersIgnoringModifiers {
            case "c": if selection.copySteps?() == true { return true }
            case "v": if selection.pasteSteps?() == true { return true }
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    /// A click on anything that isn't a text field lets the field go (user, 2026-11-23: "los campos
    /// de texto o de tiempo no se les puede quitar el foco"): SwiftUI keeps the focus otherwise.
    override func sendEvent(_ event: NSEvent) {
        let editing = event.type == .leftMouseDown ? (firstResponder as? NSText)?.delegate as? NSView : nil
        super.sendEvent(event)
        guard let editing, editing.window === self,
              (firstResponder as? NSText)?.delegate as? NSView === editing,
              !editing.convert(editing.bounds, to: nil).contains(event.locationInWindow) else { return }
        makeFirstResponder(nil)
    }

    func windowWillClose(_ notification: Notification) {
        module?.store.saveNow()
        module?.refreshShortcuts()
        // Released when closed: the editor costs nothing while it isn't open.
        DispatchQueue.main.async { Self.current = nil }
    }
}

@Observable
final class EditorSelection {
    var id: Macro.ID?
    /// ⌘C / ⌘V on the steps (MAC-79), set by the shown macro; true when it handled the key.
    @ObservationIgnored var copySteps: (() -> Bool)?
    @ObservationIgnored var pasteSteps: (() -> Bool)?
}

struct MacroEditorView: View {
    let module: MacrosModule
    @Bindable var selection: EditorSelection
    private var store: MacroStore { module.store }

    var body: some View {
        NavigationSplitView {
            List(store.macros, selection: $selection.id) { macro in
                HStack(spacing: 6) {
                    if let icon = macro.icon { PinIconView(icon: icon, size: 16).accessibilityHidden(true) }
                    Text(macro.name.isEmpty ? String(localized: "Untitled") : macro.name)
                        .lineLimit(1)
                }
                    .contextMenu {
                        Button("Duplicate") { duplicate(macro.id) }
                        Button("Export…") { export([macro.id]) }
                        Divider()
                        Button("Delete…") { confirmDelete(macro.id) }
                    }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 260)
            .safeAreaInset(edge: .bottom) { sidebarBar }
        } detail: {
            if let id = selection.id, store.macro(id) != nil {
                MacroDetail(module: module, id: id, editor: selection).id(id)
            } else {
                VStack(spacing: 8) {
                    Text(store.macros.isEmpty ? "No Macros" : "Choose a macro").font(.headline)
                    if store.macros.isEmpty {
                        Text("Create one to type text and keys for you.").foregroundStyle(.secondary)
                        Button("New Macro") { add() }.buttonStyle(.borderedProminent)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onDeleteCommand { if let id = selection.id { confirmDelete(id) } }
        // Says once that there is no Save (user, 2026-11-22: "esperaba saber que quedó guardado
        // mi macro"): edits are written 0.4 s after the last change (MAC-40).
        .navigationSubtitle(Text("Changes are saved automatically"))
    }

    private var sidebarBar: some View {
        HStack(spacing: 2) {
            Button { add() } label: { Image(systemName: "plus").frame(width: 22, height: 20) }
                .help("New Macro")
                .accessibilityLabel("New Macro")
            Button { if let id = selection.id { confirmDelete(id) } } label: { Image(systemName: "minus").frame(width: 22, height: 20) }
                .disabled(selection.id == nil)
                .help("Delete Macro")
                .accessibilityLabel("Delete Macro")
            Spacer()
            Menu {
                Button("Import…") { importMacros() }
                Button("Export All…") { export(nil) }.disabled(store.macros.isEmpty)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More")
        }
        .buttonStyle(.borderless)
        .padding(8)
    }

    private func add() {
        let macro = Macro(name: store.freshName(), typesText: UserDefaults.standard.bool(forKey: MacrosModule.typesTextKey))
        selection.id = store.add(macro)
        module.refreshShortcuts()
    }

    private func duplicate(_ id: Macro.ID) {
        selection.id = store.duplicate(id)
        module.refreshShortcuts()
    }

    private func confirmDelete(_ id: Macro.ID) {
        guard let macro = store.macro(id) else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Delete “\(macro.name)”?")
        alert.informativeText = String(localized: "This can't be undone.")
        let delete = alert.addButton(withTitle: String(localized: "Delete"))
        delete.hasDestructiveAction = true
        delete.keyEquivalent = "" // never the default: Return doesn't delete (ux-ui-designer)
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addTouchBar()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let index = store.macros.firstIndex { $0.id == id } ?? 0
        module.forgetShortcut(id)
        store.remove(id)
        selection.id = store.macros.isEmpty ? nil : store.macros[min(index, store.macros.count - 1)].id
    }

    private func export(_ ids: [Macro.ID]?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        let single = ids?.count == 1 ? store.macro(ids![0])?.name : nil
        panel.nameFieldStringValue = (single ?? String(localized: "Macros")) + ".json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.exportData(ids).write(to: url, options: .atomic)
        } catch {
            let alert = NSAlert(error: error)
            alert.addTouchBar()
            alert.runModal()
        }
    }

    private func importMacros() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let macros: [Macro]
        do {
            macros = try MacroStore.imported(Data(contentsOf: url))
        } catch {
            let alert = NSAlert()
            alert.messageText = error is MacroStore.ImportError
                ? String(localized: "These macros are too big to import.")
                : String(localized: "This file has no macros Penknife can read.")
            alert.addTouchBar()
            alert.runModal()
            return
        }
        let risks = MacroStore.risks(macros)
        if !risks.isEmpty {
            let alert = NSAlert()
            alert.messageText = String(localized: "Import macros from someone else?")
            alert.informativeText = String(localized: "Some of them \(risks.formatted(.list(type: .and))). Import only files you trust.")
            alert.addButton(withTitle: String(localized: "Import"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            alert.addTouchBar()
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        for macro in macros {
            var replacing: Macro.ID?
            if let existing = store.macros.first(where: { $0.name == macro.name }) {
                let alert = NSAlert()
                alert.messageText = String(localized: "A macro named “\(macro.name)” already exists.")
                alert.addButton(withTitle: String(localized: "Keep Both"))
                alert.addButton(withTitle: String(localized: "Replace"))
                alert.addTouchBar()
                if alert.runModal() == .alertSecondButtonReturn { replacing = existing.id }
            }
            store.addImported(macro, replacing: replacing)
        }
        selection.id = store.macros.last?.id
        module.refreshShortcuts()
    }
}

// MARK: - One macro

private struct MacroDetail: View {
    let module: MacrosModule
    let id: Macro.ID
    let editor: EditorSelection
    @State private var tab = 0
    @State private var creating = false
    @State private var nameDraft = ""
    @State private var editingIcon = false
    @State private var confirmingSecureInput = false
    /// The steps the user is on (clicked, ⌘/⇧-clicked or editing): a new step goes right below
    /// the lowest one (MAC-76, MAC-79).
    @State private var selectedSteps: Set<MacroStep.ID> = []
    @FocusState private var nameFocused: Bool
    private var store: MacroStore { module.store }

    private var macro: Binding<Macro> {
        Binding(get: { store.macro(id) ?? Macro(name: "") }, set: { store.update($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
            MacroIconButton(icon: macro.wrappedValue.icon) { editingIcon = true }
                .background {
                    // AppKit's popover, not SwiftUI's: SwiftUI's closes as soon as the emoji viewer
                    // takes the keyboard, so the picked emoji went nowhere (user, 2026-11-23).
                    StayingPopover(isPresented: $editingIcon) {
                        IconEditor(initial: macro.wrappedValue.icon, appIcon: nil, fallbackSymbol: "play.fill",
                                   caption: String(localized: "Without a letter or color, ▶ is shown")) { icon in
                            macro.wrappedValue.icon = icon
                        }
                    }
                }
            TextField(macro.wrappedValue.name, text: $nameDraft)
                .textFieldStyle(.plain)
                .font(.title2.weight(.semibold))
                .focused($nameFocused)
                .accessibilityLabel("Macro name")
                .contextMenu { Button("Change Icon…") { editingIcon = true } }
                .onAppear { nameDraft = macro.wrappedValue.name }
                .onChange(of: nameDraft) { _, new in
                    if !new.trimmingCharacters(in: .whitespaces).isEmpty { macro.wrappedValue.name = new }
                }
                .onChange(of: nameFocused) { _, focused in
                    // A default name ("New Macro 2") clears on click, showing it as the
                    // placeholder; leaving the field empty puts it back (user, 2026-11-22).
                    if focused, MacroStore.isDefaultName(nameDraft) {
                        nameDraft = ""
                    } else if !focused, nameDraft.trimmingCharacters(in: .whitespaces).isEmpty {
                        nameDraft = macro.wrappedValue.name
                    }
                }
            }
            HStack(spacing: 16) {
                KeyboardShortcuts.Recorder(String(localized: "Shortcut"), name: MacrosModule.shortcut(id)) { _ in
                    module.refreshShortcuts()
                }
                .fixedSize()
                Spacer()
                Picker("Type as", selection: macro.typesText) {
                    Text("Paste").tag(false)
                    Text("Keystrokes").tag(true)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help("Paste is faster. Keystrokes works in fields that block paste.")
            }
            // Its own line under "Type as": in the same row it made the detail wider than the
            // window and cut it on the right (QA 2026-11-23, MAC-78).
            HStack {
                Spacer()
                // Turning it on asks first; turning it off doesn't (MAC-78).
                Toggle("Allow in password fields", isOn: Binding(
                    get: { macro.wrappedValue.allowsSecureInput },
                    set: { on in
                        if on { confirmingSecureInput = true } else { macro.wrappedValue.allowsSecureInput = false }
                    }))
                .toggleStyle(.checkbox)
                .help("Runs even when a password field or Secure Keyboard Entry is on.")
            }
            HStack {
                Picker("", selection: $tab) {
                    Text("Steps").tag(0)
                    Text("Data").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
            }

            if tab == 0 {
                StepList(module: module, macro: macro, selected: $selectedSteps,
                         copy: copySelected, paste: pasteCopied)
                HStack {
                    Menu {
                        ForEach(MacroStep.Kind.allCases, id: \.self) { kind in
                            Button { addStep(kind) } label: { Label(kind.title, systemImage: kind.symbol) }
                            if kind == .key {
                                // The key most steps need, without recording it (MAC-80).
                                Button {
                                    var step = MacroStep(kind: .key)
                                    step.key = MacroKey(code: Int(kVK_Return))
                                    insert([step])
                                } label: { Label("Return", systemImage: "return") }
                                .accessibilityLabel("Key step: Return")
                            }
                        }
                    } label: {
                        Label("Add Step", systemImage: "plus.circle")
                    }
                    .fixedSize()
                    Spacer()
                    Button("Create from Text…") { creating = true }
                }
            } else {
                DataEditor(macro: macro)
            }
        }
        .padding(16)
        .sheet(isPresented: $creating) {
            CreateFromText { steps in insert(steps) }
        }
        // Return = Cancel: a deliberate click to allow (ux-ui-designer, MAC-78).
        .alert("Allow in password fields?", isPresented: $confirmingSecureInput) {
            Button("Allow") { macro.wrappedValue.allowsSecureInput = true }
            Button("Cancel", role: .cancel) {}.keyboardShortcut(.defaultAction)
        } message: {
            Text("Esc won't stop it there; click or switch apps instead. You use this at your own risk, and Penknife isn't responsible for what it types.")
        }
        .onChange(of: macro.wrappedValue.id) { selectedSteps = [] }
        .onAppear {
            editor.copySteps = { tab == 0 && copySelected() }
            editor.pasteSteps = { tab == 0 && pasteCopied() }
        }
    }

    @discardableResult
    private func copySelected() -> Bool {
        let steps = MacroStep.copy(selectedSteps, from: macro.wrappedValue.steps)
        guard !steps.isEmpty else { return false }
        MacroStep.copied = steps
        return true
    }

    /// New ids on every paste, so the same steps can be pasted again (MAC-79).
    @discardableResult
    private func pasteCopied() -> Bool {
        guard !MacroStep.copied.isEmpty else { return false }
        insert(MacroStep.copied.map(\.duplicate))
        return true
    }

    private func addStep(_ kind: MacroStep.Kind) {
        insert([MacroStep(kind: kind)])
    }

    /// Below the selected steps, or at the end when none is selected (MAC-76); the new steps
    /// become the selection, so adding again keeps the order.
    private func insert(_ steps: [MacroStep]) {
        guard !steps.isEmpty else { return }
        let at = MacroStep.insertionIndex(after: selectedSteps, in: macro.wrappedValue.steps)
        macro.wrappedValue.steps.insert(contentsOf: steps, at: at)
        selectedSteps = Set(steps.map(\.id))
    }
}

/// A popover that stays while the emoji viewer (another process) has the keyboard, as the
/// clipboard's icon editor (CB-33): Esc or a click elsewhere in the window closes it.
private struct StayingPopover<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onClose = { isPresented = false }
        if isPresented, coordinator.popover == nil {
            DispatchQueue.main.async { coordinator.show(NSHostingController(rootView: content()), from: view) }
        } else if !isPresented {
            coordinator.popover?.close()
        }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.popover?.close()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, NSPopoverDelegate {
        var popover: NSPopover?
        var onClose: () -> Void = {}
        private var monitors: [Any] = []

        func show(_ controller: NSViewController, from view: NSView) {
            guard popover == nil, view.window != nil else { return }
            let popover = NSPopover()
            popover.behavior = .applicationDefined
            popover.animates = false
            popover.contentViewController = controller
            popover.contentSize = controller.view.fittingSize
            popover.delegate = self
            self.popover = popover
            popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
            let window = controller.view.window
            window?.makeKey()
            // Nothing focused when it opens, as in the clipboard (user, 2026-11-20).
            DispatchQueue.main.async { window?.makeFirstResponder(nil) }
            let host = view.window
            if let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
                guard event.keyCode == 53, let self, self.popover != nil else { return event }
                self.popover?.close()
                return nil
            }) { monitors.append(keys) }
            if let clicks = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
                if let self, event.window === host { self.popover?.close() }
                return event
            }) { monitors.append(clicks) }
        }

        func popoverDidClose(_ notification: Notification) {
            monitors.forEach(NSEvent.removeMonitor)
            monitors.removeAll()
            popover = nil
            onClose()
        }
    }
}

/// The macro's icon in the editor header (ux-ui-designer, 2026-11-22, for "no es tan intuitivo
/// saber dónde cambio el emoji"): a 40 pt tile; on hover an accent ring and a
/// pencil badge; tooltip, VoiceOver hint and a context menu say what it does.
private struct MacroIconButton: View {
    let icon: PinIcon?
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomTrailing) {
                tile
                if hover {
                    Image(systemName: "pencil.circle.fill")
                        .font(.system(size: 16))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.accentColor)
                        .background(Circle().fill(Color(nsColor: .windowBackgroundColor)).padding(-1.5))
                        .offset(x: 5, y: 5)
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hover = inside
            if icon == nil {
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
        .help("Change Icon…")
        .accessibilityLabel("Change Icon…")
        .accessibilityHint("Opens the icon editor")
        .contextMenu { Button("Change Icon…", action: action) }
    }

    private var tile: some View {
        Group {
            if let icon {
                PinIconView(icon: icon, size: 40)
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .quaternarySystemFill))
                    .overlay { Image(systemName: "play.fill").font(.system(size: 15)).foregroundStyle(.secondary) }
                    .frame(width: 40, height: 40)
            }
        }
        .overlay {
            if hover {
                RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
    }
}

// MARK: - Steps

private struct StepList: View {
    let module: MacrosModule
    @Binding var macro: Macro
    @Binding var selected: Set<MacroStep.ID>
    let copy: () -> Bool
    let paste: () -> Bool
    /// Where a ⇧-click range starts: the last step clicked without ⇧.
    @State private var anchor: MacroStep.ID?
    @FocusState private var editing: MacroStep.ID?
    @State private var dragging: MacroStep.ID?
    @State private var startIndex = 0
    @State private var offset: CGFloat = 0
    private let rowHeight: CGFloat = 36
    private static let space = "macroSteps"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(macro.steps.enumerated()), id: \.element.id) { index, step in
                        row(index: index, step: step)
                    }
                    if macro.steps.isEmpty {
                        Text("No steps yet. Add one below, or create them from text.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 80)
                    }
                }
                .coordinateSpace(.named(Self.space))
                .padding(4)
            }
            // New steps are selected on insert: bring the last one into view (MAC-77).
            .onChange(of: macro.steps.count) { old, new in
                guard new > old, let id = macro.steps.last(where: { selected.contains($0.id) })?.id else { return }
                anchor = id
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id) }
            }
        }
        // A click on the empty part of the list selects nothing: new steps go at the end.
        .contentShape(Rectangle())
        .onTapGesture { selected = []; anchor = nil }
        .onChange(of: editing) { if let id = editing { selected = [id]; anchor = id } }
        .contextMenu {
            Button("Paste") { _ = paste() }.disabled(MacroStep.copied.isEmpty)
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
    }

    private func row(index: Int, step: MacroStep) -> some View {
        let isDragged = dragging == step.id
        let binding = Binding(get: { macro.steps.first { $0.id == step.id } ?? step },
                              set: { new in
                                  if let i = macro.steps.firstIndex(where: { $0.id == step.id }) { macro.steps[i] = new }
                              })
        return HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .frame(width: 16, height: rowHeight)
                .contentShape(Rectangle())
                .gesture(drag(step.id))
                .help("Drag to reorder")
                .accessibilityHidden(true)
            Image(systemName: step.kind.symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .help(step.kind.title)
                .accessibilityHidden(true)
            StepEditor(module: module, step: binding, columns: macro.data.columns, editing: $editing)
                .frame(maxWidth: .infinity, alignment: .leading)
            Menu {
                Button("Duplicate") { duplicate(step.id) }
                Button("Delete") { delete(step.id) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
            .accessibilityLabel("Step actions")
        }
        .padding(.horizontal, 8)
        .frame(height: rowHeight)
        .background {
            if isDragged {
                RoundedRectangle(cornerRadius: 6).fill(.background).shadow(color: .black.opacity(0.25), radius: 6, y: 2)
            } else if selected.contains(step.id) {
                RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .unemphasizedSelectedContentBackgroundColor))
            } else if !index.isMultiple(of: 2) {
                RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.035))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { click(step.id) }
        .offset(y: isDragged ? offset : 0)
        .zIndex(isDragged ? 1 : 0)
        .contextMenu {
            // On a selected row they act on the whole selection; elsewhere on that row (MAC-79).
            Button("Copy") {
                if !selected.contains(step.id) { selected = [step.id]; anchor = step.id }
                _ = copy()
            }
            Button("Paste") {
                if !selected.contains(step.id) { selected = [step.id]; anchor = step.id }
                _ = paste()
            }
            .disabled(MacroStep.copied.isEmpty)
            Divider()
            Button("Duplicate") { duplicate(step.id) }
            Button("Move Up") { move(step.id, by: -1) }.disabled(index == 0)
            Button("Move Down") { move(step.id, by: 1) }.disabled(index == macro.steps.count - 1)
            Divider()
            Button("Delete") { delete(step.id) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(step.kind.title)
        .accessibilityAction(named: Text("Move up")) { move(step.id, by: -1) }
        .accessibilityAction(named: Text("Move down")) { move(step.id, by: 1) }
        .accessibilityAction(named: Text("Duplicate")) { duplicate(step.id) }
        .accessibilityAction(named: Text("Delete")) { delete(step.id) }
    }

    /// As in Finder (MAC-79): click selects one, ⌘-click adds or removes, ⇧-click a range.
    private func click(_ id: MacroStep.ID) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
            anchor = id
        } else if flags.contains(.shift) {
            selected = MacroStep.range(from: anchor, to: id, in: macro.steps)
        } else {
            selected = [id]
            anchor = id
        }
    }

    private func drag(_ id: MacroStep.ID) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.space))
            .onChanged { drag in
                if dragging == nil {
                    dragging = id
                    startIndex = macro.steps.firstIndex { $0.id == id } ?? 0
                }
                guard let current = macro.steps.firstIndex(where: { $0.id == id }) else { return }
                let steps = Int((drag.translation.height / rowHeight).rounded())
                let target = min(max(startIndex + steps, 0), macro.steps.count - 1)
                if target != current {
                    withAnimation(.snappy(duration: 0.2)) {
                        macro.steps.move(fromOffsets: [current], toOffset: target > current ? target + 1 : target)
                    }
                }
                offset = drag.translation.height - CGFloat(target - startIndex) * rowHeight
            }
            .onEnded { _ in
                withAnimation(.snappy(duration: 0.2)) { offset = 0 }
                dragging = nil
            }
    }

    private func move(_ id: MacroStep.ID, by delta: Int) {
        guard let index = macro.steps.firstIndex(where: { $0.id == id }) else { return }
        let target = min(max(index + delta, 0), macro.steps.count - 1)
        guard target != index else { return }
        withAnimation(.snappy(duration: 0.2)) {
            macro.steps.move(fromOffsets: [index], toOffset: target > index ? target + 1 : target)
        }
    }

    private func duplicate(_ id: MacroStep.ID) {
        guard let index = macro.steps.firstIndex(where: { $0.id == id }) else { return }
        macro.steps.insert(macro.steps[index].duplicate, at: index + 1)
    }

    private func delete(_ id: MacroStep.ID) {
        macro.steps.removeAll { $0.id == id }
    }
}

private struct StepEditor: View {
    let module: MacrosModule
    @Binding var step: MacroStep
    let columns: [String]
    var editing: FocusState<MacroStep.ID?>.Binding

    var body: some View {
        switch step.kind {
        case .text:
            HStack(spacing: 6) {
                TextField("Text", text: $step.text)
                    .textFieldStyle(.roundedBorder)
                    .focused(editing, equals: step.id)
                    .accessibilityLabel("Text to type")
                Menu {
                    ForEach(MacroText.offered, id: \.token) { variable in
                        Button("\(variable.title)  \(variable.token)") { step.text += variable.token }
                    }
                    if !columns.filter({ !$0.isEmpty }).isEmpty {
                        Section("Data columns") {
                            ForEach(columns.filter { !$0.isEmpty }, id: \.self) { column in
                                Button("{\(column)}") { step.text += "{\(column)}" }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "curlybraces")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Insert a variable")
                .accessibilityLabel("Insert a variable")
            }
        case .key:
            KeyPicker(key: Binding(get: { step.key ?? .tab }, set: { step.key = $0 }))
        case .wait:
            HStack(spacing: 6) {
                TextField("", value: $step.milliseconds, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                    .multilineTextAlignment(.trailing)
                    .focused(editing, equals: step.id)
                    .accessibilityLabel("Milliseconds")
                Stepper("", value: $step.milliseconds, in: 0...60_000, step: 100).labelsHidden()
                Text("ms").foregroundStyle(.secondary)
            }
        case .waitForMe:
            Text("Waits until you press the shortcut again")
                .foregroundStyle(.secondary)
        case .file:
            FilePicker(step: $step)
        case .pinned:
            PinPicker(store: module.clipboard?.store, step: $step)
        }
    }
}

/// A key as a cap; common keys from the menu, anything else (⌘A, F5) by recording it.
private struct KeyPicker: View {
    @Binding var key: MacroKey
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(MacroKey.common, id: \.self) { common in
                    Button("\(common.symbol)  \(common.name)") { key = common }
                }
                Divider()
                Button("Record a Key…") { startRecording() }
            } label: {
                Text(recording ? String(localized: "Press a key…") : key.symbol)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
            }
            .fixedSize()
            .accessibilityLabel("Key: \(key.name)")
            if !recording {
                Text(key.name).foregroundStyle(.secondary)
            }
        }
        .onDisappear(perform: stopRecording)
    }

    private func startRecording() {
        stopRecording()
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            key = MacroKey(code: Int(event.keyCode), modifiers: flags.rawValue)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }
}

private struct FilePicker: View {
    @Binding var step: MacroStep

    var body: some View {
        HStack(spacing: 8) {
            if let file = step.file {
                Image(nsImage: NSWorkspace.shared.icon(forFile: file.path))
                    .resizable()
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)
                Text(file.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(file.path)
            }
            Button(step.file == nil ? "Choose…" : "Change…") { choose() }
            Spacer(minLength: 4)
            Picker("", selection: $step.fileMode) {
                Text("Paste File").tag(MacroStep.FileMode.paste)
                Text("Type Path").tag(MacroStep.FileMode.path)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Type Path works in Open dialogs (⌘⇧G). Web upload buttons don't take a pasted file.")
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        if panel.runModal() == .OK { step.file = panel.url }
    }
}

/// A pinned clipboard item the step follows (R-35): its text at run time; asked if it's gone.
private struct PinPicker: View {
    let store: ClipboardStore?
    @Binding var step: MacroStep

    var body: some View {
        let pins = (store?.pinned ?? []).filter { $0.kind == .text }
        let linked = step.pin.flatMap { pin in pins.first { $0.id == pin } }
        HStack(spacing: 8) {
            Menu {
                ForEach(pins) { pin in
                    Button(pin.title) {
                        step.pin = pin.id
                        step.text = pin.title
                    }
                }
                if pins.isEmpty {
                    Text("No pinned text in Clipboard History")
                }
            } label: {
                Text(linked?.title ?? (step.text.isEmpty ? String(localized: "Choose a pinned item") : step.text))
                    .lineLimit(1)
            }
            .frame(maxWidth: 260)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("Pinned item")
            if step.pin != nil, linked == nil {
                Text("Gone: you'll be asked")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Data rows

private struct DataEditor: View {
    @Binding var macro: Macro
    private var data: MacroData { macro.data }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if data.columns.isEmpty {
                DataEmptyState(macro: $macro)
            } else {
                Text(hint)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
                DataTable(macro: $macro)
                HStack(spacing: 12) {
                    Toggle("Repeat rows", isOn: $macro.data.repeats)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .help("On: after the last row, the next run starts again at row 1. Off: the macro doesn't run and tells you.")
                    Spacer()
                    if !data.rows.isEmpty {
                        Text(nextLine).foregroundStyle(.secondary).monospacedDigit()
                        Button("Start Again") { macro.data.next = 0 }
                            .controlSize(.small)
                            .disabled(data.next == 0)
                    }
                }
                .font(.callout)
                Text("Names can have spaces; { and } aren't allowed. Renaming a column updates the steps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var hint: String {
        let names = data.columns.prefix(2).map { "{\($0)}" }
        let list = names.count == 2 ? String(localized: "\(names[0]) or \(names[1])") : names.first ?? ""
        return String(localized: "Each run uses the next row. Use \(list) in a “Type Text” step.")
    }

    private var nextLine: String {
        if data.next >= data.rows.count {
            return data.repeats ? String(localized: "Next: row 1 of \(data.rows.count)") : String(localized: "No rows left")
        }
        return String(localized: "Next: row \(data.next + 1) of \(data.rows.count)")
    }
}

/// The table is the interface (variant A): the header holds the column names, which are the
/// variables; the row the next run uses has ▶ and an accent background.
private struct DataTable: View {
    @Binding var macro: Macro
    private let side: CGFloat = 36

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: side)
                ForEach(macro.data.columns.indices, id: \.self) { column in
                    ColumnHeader(macro: $macro, column: column)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button { macro.data.addColumn() } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .frame(width: side)
                    .help("Add Column")
                    .accessibilityLabel("Add Column")
            }
            .frame(height: 32)
            .background(.quaternary.opacity(0.5))
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(macro.data.rows.indices, id: \.self) { row in
                        rowView(row)
                        Divider().opacity(0.5)
                    }
                    Button { macro.data.addRow() } label: { Label("Add Row", systemImage: "plus") }
                        .buttonStyle(.borderless)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var nextIndex: Int {
        macro.data.next < macro.data.rows.count ? macro.data.next : (macro.data.repeats ? 0 : -1)
    }

    private func rowView(_ row: Int) -> some View {
        let isNext = row == nextIndex
        return HStack(spacing: 0) {
            Group {
                if isNext {
                    Image(systemName: "play.fill").font(.system(size: 10)).foregroundStyle(.tint)
                } else {
                    Text("\(row + 1)").foregroundStyle(.tertiary).monospacedDigit()
                }
            }
            .frame(width: side)
            .help(isNext ? String(localized: "The next run uses this row") : String(localized: "Use Next"))
            .onTapGesture { macro.data.next = row }
            ForEach(macro.data.columns.indices, id: \.self) { column in
                TextField("", text: cell(row, column))
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(String(localized: "Row \(row + 1), \(macro.data.columns[column])"))
            }
            Button { macro.data.removeRow(row) } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .frame(width: side)
                .help("Remove Row")
                .accessibilityLabel("Remove Row")
        }
        .frame(height: 30)
        .background(isNext ? Color.accentColor.opacity(0.15) : (row % 2 == 1 ? Color.primary.opacity(0.04) : .clear))
        .contextMenu {
            Button("Use Next") { macro.data.next = row }.disabled(isNext)
            Button("Remove Row") { macro.data.removeRow(row) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityValue(isNext ? String(localized: "Next to run") : "")
    }

    private func cell(_ row: Int, _ column: Int) -> Binding<String> {
        Binding(get: {
            macro.data.rows.indices.contains(row) && macro.data.rows[row].indices.contains(column)
                ? macro.data.rows[row][column] : ""
        }, set: { macro.data.set($0, row: row, column: column) })
    }
}

/// A column name, edited in place; applied (and the steps renamed) when you leave the field.
/// An empty or repeated name shows red and isn't applied.
private struct ColumnHeader: View {
    @Binding var macro: Macro
    let column: Int
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var name: String {
        macro.data.columns.indices.contains(column) ? macro.data.columns[column] : ""
    }
    private var valid: Bool { macro.data.canName(draft, column: column) }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "curlybraces")
                .font(.system(size: 11))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            TextField("", text: $draft)
                .textFieldStyle(.plain)
                .fontWeight(.semibold)
                .foregroundStyle(valid ? Color.primary : Color.red)
                .focused($focused)
                .onSubmit(apply)
                .onChange(of: draft) { _, new in
                    let clean = new.filter { $0 != "{" && $0 != "}" }
                    if clean != new { draft = clean }
                }
                .onChange(of: focused) { _, isFocused in if !isFocused { apply() } }
                .accessibilityLabel(String(localized: "Column name"))
        }
        .padding(.horizontal, 8)
        .onAppear { draft = name }
        .onChange(of: name) { _, new in if !focused { draft = new } }
        .contextMenu {
            Button("Remove Column") { macro.data.removeColumn(column) }
        }
    }

    private func apply() {
        if !macro.renameColumn(column, to: draft) { draft = name }
        else { draft = name }
    }
}

/// No table yet (variant C): what Data is for, an example, and the two ways to start.
private struct DataEmptyState: View {
    @Binding var macro: Macro
    @State private var nothingToPaste = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "tablecells")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("One Row for Each Run").font(.title3.weight(.semibold))
            Text("Paste a table from Excel, Numbers or Sheets, or start an empty one. Then use {email} in a “Type Text” step.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            example
            HStack(spacing: 10) {
                Button { paste() } label: { Label("Paste Table", systemImage: "doc.on.clipboard") }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                Button { emptyTable() } label: { Label("Empty Table", systemImage: "plus") }
                    .controlSize(.large)
            }
            if nothingToPaste {
                Text("Copy a table first: its first row names the columns.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
    }

    private var example: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(["{email}", String(localized: "{name}")], id: \.self) { name in
                    Text(name)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.tint)
                        .frame(width: 130, alignment: .leading)
                        .padding(.horizontal, 8)
                }
            }
            .frame(height: 26)
            .background(.quaternary.opacity(0.5))
            HStack(spacing: 0) {
                ForEach(["ana@example.com", "Ana"], id: \.self) { value in
                    Text(value).font(.callout).frame(width: 130, alignment: .leading).padding(.horizontal, 8)
                }
            }
            .frame(height: 26)
        }
        .frame(width: 292)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
        .opacity(0.8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Example: columns email and name, row ana@example.com, Ana"))
    }

    private func paste() {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        let parsed = MacroData.parse(text)
        guard !parsed.columns.isEmpty else {
            nothingToPaste = true
            return
        }
        var data = macro.data
        // Names that are empty or repeated get a number, so each one is its own variable.
        data.columns = []
        for (index, name) in parsed.columns.enumerated() {
            var clean = MacroData.cleanName(name)
            if clean.isEmpty { clean = String(localized: "column") + " \(index + 1)" }
            let base = clean
            var number = 2
            while data.columns.contains(where: { $0.lowercased() == clean.lowercased() }) {
                clean = "\(base) \(number)"
                number += 1
            }
            data.columns.append(clean)
        }
        data.rows = parsed.rows
        data.next = 0
        data.source = ""
        macro.data = data
    }

    private func emptyTable() {
        var data = macro.data
        data.addColumn()
        data.addRow()
        data.next = 0
        macro.data = data
    }
}

// MARK: - Create from text

private struct CreateFromText: View {
    let create: ([MacroStep]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var pairs = true

    var body: some View {
        let steps = MacroText.steps(from: text, pairs: pairs)
        VStack(alignment: .leading, spacing: 12) {
            Text("Create from Text").font(.headline)
            Picker("", selection: $pairs) {
                Text("KEY=value").tag(true)
                Text("One text per line").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Text(pairs ? "Each line becomes: key, Tab, value, Return." : "Each line becomes a text, with Tab between them.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
                .frame(height: 200)
                .accessibilityLabel("Text")
            HStack {
                Text("\(steps.count) steps will be added").foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add Steps") {
                    create(steps)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(steps.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

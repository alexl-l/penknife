import AppKit
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
        NSApp.activate()
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
        minSize = NSSize(width: 620, height: 420)
        delegate = self
        contentViewController = NSHostingController(rootView: MacroEditorView(module: module, selection: selection))
        setContentSize(NSSize(width: 700, height: 540))
        center()
        setFrameAutosaveName("MacroEditor")
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
}

struct MacroEditorView: View {
    let module: MacrosModule
    @Bindable var selection: EditorSelection
    private var store: MacroStore { module.store }

    var body: some View {
        NavigationSplitView {
            List(store.macros, selection: $selection.id) { macro in
                Text(macro.name.isEmpty ? String(localized: "Untitled") : macro.name)
                    .lineLimit(1)
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
                MacroDetail(module: module, id: id).id(id)
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
        alert.addButton(withTitle: String(localized: "Delete"))
        alert.addButton(withTitle: String(localized: "Cancel"))
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
            NSAlert(error: error).runModal()
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
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        for macro in macros {
            var replacing: Macro.ID?
            if let existing = store.macros.first(where: { $0.name == macro.name }) {
                let alert = NSAlert()
                alert.messageText = String(localized: "A macro named “\(macro.name)” already exists.")
                alert.addButton(withTitle: String(localized: "Keep Both"))
                alert.addButton(withTitle: String(localized: "Replace"))
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
    @State private var tab = 0
    @State private var creating = false
    private var store: MacroStore { module.store }

    private var macro: Binding<Macro> {
        Binding(get: { store.macro(id) ?? Macro(name: "") }, set: { store.update($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Name", text: macro.name)
                .textFieldStyle(.plain)
                .font(.title2.weight(.semibold))
                .accessibilityLabel("Macro name")
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
            Picker("", selection: $tab) {
                Text("Steps").tag(0)
                Text("Data").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 220)

            if tab == 0 {
                StepList(module: module, macro: macro)
                HStack {
                    Menu {
                        ForEach(MacroStep.Kind.allCases, id: \.self) { kind in
                            Button { addStep(kind) } label: { Label(kind.title, systemImage: kind.symbol) }
                        }
                    } label: {
                        Label("Add Step", systemImage: "plus.circle")
                    }
                    .fixedSize()
                    Spacer()
                    Button("Create from Text…") { creating = true }
                }
            } else {
                DataEditor(data: macro.data)
            }
        }
        .padding(16)
        .sheet(isPresented: $creating) {
            CreateFromText { steps in macro.wrappedValue.steps += steps }
        }
    }

    private func addStep(_ kind: MacroStep.Kind) {
        macro.wrappedValue.steps.append(MacroStep(kind: kind))
    }
}

// MARK: - Steps

private struct StepList: View {
    let module: MacrosModule
    @Binding var macro: Macro
    @State private var dragging: MacroStep.ID?
    @State private var startIndex = 0
    @State private var offset: CGFloat = 0
    private let rowHeight: CGFloat = 36
    private static let space = "macroSteps"

    var body: some View {
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
            StepEditor(module: module, step: binding, columns: macro.data.columns)
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
            } else if !index.isMultiple(of: 2) {
                RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.035))
            }
        }
        .offset(y: isDragged ? offset : 0)
        .zIndex(isDragged ? 1 : 0)
        .contextMenu {
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

    var body: some View {
        switch step.kind {
        case .text:
            HStack(spacing: 6) {
                TextField("Text", text: $step.text)
                    .textFieldStyle(.roundedBorder)
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
    @Binding var data: MacroData
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Paste a table: the first line names the columns. Each run uses the next row; use the column names as variables, like {email}.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
                .accessibilityLabel("Data table")
                .onChange(of: text) { _, new in data.update(from: new) }
            HStack(spacing: 12) {
                if data.isEmpty {
                    Text("No data").foregroundStyle(.secondary)
                } else {
                    Text(columnsLine).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Text(nextLine).monospacedDigit()
                    Button("Start Again") { data.next = 0 }
                        .disabled(data.next == 0)
                }
            }
            Toggle("Repeat rows", isOn: $data.repeats)
                .help("On: after the last row, the next run starts again at row 1. Off: the macro doesn't run and tells you.")
        }
        .onAppear { text = data.source }
    }

    private var columnsLine: String {
        data.columns.filter { !$0.isEmpty }.map { "{\($0)}" }.joined(separator: " ")
    }

    private var nextLine: String {
        if data.next >= data.rows.count {
            return data.repeats ? String(localized: "Next: row 1 of \(data.rows.count)") : String(localized: "No rows left")
        }
        return String(localized: "Next: row \(data.next + 1) of \(data.rows.count)")
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

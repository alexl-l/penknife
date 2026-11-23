import AppKit
import KeyboardShortcuts

/// Macros (R-35): named lists of steps typed into the app in front. Its shortcut opens the list;
/// each macro may have its own shortcut too. While no macro runs nothing is watched or timed.
final class MacrosModule: Module {
    let id = ModuleID.macros
    var needsAccessibility: Bool { true }
    static let typesTextKey = "macros.typesText"

    let store: MacroStore
    /// Linked pinned items live in the clipboard's store (R-35, "linked pinned item").
    weak var clipboard: ClipboardModule?
    private let runner = MacroRunner.shared
    private var panel: MacroPanel?
    private var prompt: MacroPrompt?
    private var running = false
    /// Per-macro shortcuts that already have a handler (KeyboardShortcuts keeps them for good).
    private var handled: Set<String> = []
    private var macrosObserver: Any?

    init(store: MacroStore = MacroStore()) {
        self.store = store
        runner.onFinish = { [weak self] plan, completed in self?.finished(plan, completed: completed) }
    }

    var actions: [ModuleAction] {
        [ModuleAction(shortcut: .macroList, title: String(localized: "Macros"), symbol: id.symbol,
                      perform: { [weak self] in self?.listShortcut() })]
    }

    func start() {
        running = true
        refreshShortcuts()
    }

    func stop() {
        running = false
        runner.stop(.failed)
        panel?.close()
        prompt?.close()
        KeyboardShortcuts.disable(store.macros.map(Self.shortcut))
    }

    static func shortcut(_ macro: Macro) -> KeyboardShortcuts.Name { shortcut(macro.id) }
    static func shortcut(_ id: Macro.ID) -> KeyboardShortcuts.Name { KeyboardShortcuts.Name("macro.\(id.uuidString)") }

    /// Handlers for macros added since (editor, import); called when the list changes.
    func refreshShortcuts() {
        guard running else { return }
        for macro in store.macros {
            let name = Self.shortcut(macro)
            KeyboardShortcuts.enable(name)
            guard !handled.contains(name.rawValue) else { continue }
            handled.insert(name.rawValue)
            let id = macro.id
            KeyboardShortcuts.onKeyUp(for: name) { [weak self] in
                guard let self, self.running else { return }
                if self.runner.continueIfWaiting() { return }
                self.run(id)
            }
        }
    }

    /// A deleted macro's shortcut is freed, so it can't run anything or block the keys.
    func forgetShortcut(_ id: Macro.ID) {
        KeyboardShortcuts.reset(Self.shortcut(id))
    }

    private func listShortcut() {
        if runner.continueIfWaiting() { return }
        guard !runner.isBusy else { return }
        showPanel()
    }

    // MARK: Panel

    func showPanel() {
        if let panel {
            panel.close()
            return
        }
        let panel = MacroPanel(module: self) { [weak self] in self?.panel = nil }
        self.panel = panel
        panel.show()
    }

    /// From the panel: it closes, the app you were in gets the keyboard back, then it runs.
    func runFromPanel(_ id: Macro.ID) {
        panel?.close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.run(id) }
    }

    func openEditor(_ id: Macro.ID? = nil, new: Bool = false) {
        panel?.close()
        MacroEditorWindow.show(module: self, select: id, new: new)
    }

    // MARK: Running

    func run(_ id: Macro.ID) {
        guard !runner.isBusy, prompt == nil, let macro = store.macro(id), !macro.steps.isEmpty else { return }
        guard let row = macro.data.rowForRun() else {
            MacroRunner.announceStop(.rowsRanOut, name: macro.name)
            return
        }
        // Linked pins: their text now; a pin that is gone (or not text) is asked, as plan B.
        var pinned: [UUID: String] = [:]
        var asked: Set<UUID> = []
        var missing: [MacroPrompt.Field] = []
        for step in macro.steps where step.kind == .pinned {
            if let pin = step.pin, let item = clipboard?.store.item(pin), item.pinned, item.kind == .text {
                pinned[step.id] = item.text ?? ""
            } else {
                asked.insert(step.id)
                missing.append(.init(id: step.id.uuidString, label: step.text.isEmpty ? step.kind.title : step.text,
                                     value: step.lastValue ?? "",
                                     note: String(localized: "The pinned item is gone. Type the value for this run.")))
            }
        }
        let questions = macro.questions.map { MacroPrompt.Field(id: "ask:" + $0, label: $0, value: macro.lastAnswers[$0] ?? "") }
        let plan = MacroRunner.Plan(macro: macro, answers: [:], columns: row.values,
                                    row: macro.data.isEmpty ? nil : row.index, pinned: pinned, asked: asked)
        let fields = questions + missing
        guard !fields.isEmpty else {
            begin(plan)
            return
        }
        let prompt = MacroPrompt(title: macro.name, fields: fields) { [weak self] answers in
            guard let self else { return }
            self.prompt = nil
            guard let answers else { return }
            var plan = plan
            for (key, value) in answers {
                if key.hasPrefix("ask:") {
                    plan.answers[String(key.dropFirst(4))] = value
                } else if let id = UUID(uuidString: key) {
                    plan.pinned[id] = value
                }
            }
            // The prompt had the keyboard: the app behind it gets it back first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.begin(plan) }
        }
        self.prompt = prompt
        prompt.show()
    }

    private var runApp: String?

    private func begin(_ plan: MacroRunner.Plan) {
        runApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        runner.start(plan)
    }

    /// Only a run that ended moves the counter and the data row on; one that was stopped is
    /// tried again with the same values.
    private func finished(_ plan: MacroRunner.Plan, completed: Bool) {
        let app = runApp
        runApp = nil
        store.edit(plan.macro.id) { macro in
            macro.lastAnswers.merge(plan.answers) { $1 }
            // Only a value typed as plan B is remembered; a pin that was found isn't copied here
            // (it may hold something private, and it lives in the pins already).
            for index in macro.steps.indices where macro.steps[index].kind == .pinned {
                let id = macro.steps[index].id
                macro.steps[index].lastValue = plan.asked.contains(id) ? plan.pinned[id] : nil
            }
            if let app, !macro.apps.contains(app) { macro.apps.append(app) }
            guard completed else { return }
            macro.counter += 1
            macro.lastRun = .now
            if let row = plan.row { macro.data.next = row + 1 }
        }
    }
}

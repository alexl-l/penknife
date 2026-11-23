import KeyboardShortcuts
import SwiftUI

/// Every function has a customizable global shortcut (R-15, R-19).
struct ShortcutsPage: View {
    let manager: ModuleManager

    var body: some View {
        // Design audit 2026-11-22: modules with one shortcut share one group (their label is
        // the module name); modules with several get their own titled group.
        let modules = manager.modules.filter { !$0.actions.isEmpty }
        let single = modules.filter { $0.actions.count == 1 && $0.id != .screenshot }
        let grouped = modules.filter { !($0.actions.count == 1 && $0.id != .screenshot) }
        Form {
            Section {
                KeyboardShortcuts.Recorder(String(localized: "Open the Penknife menu"), name: .openMenu)
                ForEach(single, id: \.id) { module in
                    recorders(for: module)
                }
            }
            ForEach(grouped, id: \.id) { module in
                Section {
                    recorders(for: module)
                } header: {
                    Text(module.id.title)
                } footer: {
                    if module.id == grouped.last?.id { note }
                }
            }
            if grouped.isEmpty {
                Section {} footer: { note }
            }
        }
        .formStyle(.grouped)
    }
    @ViewBuilder private func recorders(for module: any Module) -> some View {
        let off = !manager.isEnabled(module.id)
        ForEach(module.actions, id: \.shortcut) { action in
            KeyboardShortcuts.Recorder(action.title, name: action.shortcut)
                .disabled(off)
        }
        if module.id == .screenshot {
            KeyboardShortcuts.Recorder(String(localized: "Draw While Recording"), name: .recordingDraw)
                .disabled(off)
        }
    }

    private var note: some View {
        Text("Shortcuts for modules that are off don't work. On a Mac without a Touch Bar, F keys need Fn, or turn on “Use F1, F2, etc. keys as standard function keys” in Keyboard settings.")
            .foregroundStyle(.secondary)
    }
}

import KeyboardShortcuts
import SwiftUI

/// Every function has a customizable global shortcut (R-15, R-19).
struct ShortcutsPage: View {
    let manager: ModuleManager

    var body: some View {
        Form {
            Section {
                KeyboardShortcuts.Recorder(String(localized: "Open the Penknife menu"), name: .openMenu)
            }
            Section {
                ForEach(manager.modules.filter { !$0.actions.isEmpty }, id: \.id) { module in
                    ForEach(module.actions, id: \.shortcut) { action in
                        KeyboardShortcuts.Recorder(action.title, name: action.shortcut)
                            .disabled(!manager.isEnabled(module.id))
                    }
                }
            } footer: {
                Text("Shortcuts of modules that are off are disabled. On a Mac without Touch Bar, F keys need Fn or “Use F1, F2, etc. keys as standard function keys”.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

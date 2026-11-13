import SwiftUI

/// Every function can be turned on and off (R-15). A module that is off uses no resources.
struct ModulesTab: View {
    let manager: ModuleManager

    var body: some View {
        Form {
            Section {
                ForEach(ModuleID.allCases) { id in
                    Toggle(isOn: Binding(
                        get: { manager.isEnabled(id) },
                        set: { manager.setEnabled(id, $0) }
                    )) {
                        Label {
                            Text(id.title)
                            Text(id.summary)
                        } icon: {
                            Image(systemName: id.symbol)
                                .accessibilityHidden(true)
                        }
                    }
                    if id == .jiggler, let jiggler = manager.module(.jiggler) as? JigglerModule {
                        Toggle("Turn on when unlocking, off when locking", isOn: Binding(
                            get: { jiggler.followsLock },
                            set: { jiggler.followsLock = $0 }
                        ))
                        .padding(.leading, 28)
                        .disabled(!manager.isEnabled(.jiggler))
                    }
                    if id == .touchBar {
                        AutoCloseToggle()
                            .padding(.leading, 28)
                            .disabled(!manager.isEnabled(.touchBar))
                    }
                }
            } footer: {
                Text("A module that is off uses no CPU or memory.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Sliders and the date close by themselves, or only when tapped (R-19).
private struct AutoCloseToggle: View {
    @AppStorage(TouchBarModule.autoCloseKey) private var autoClose = true

    var body: some View {
        Toggle("Close sliders and the date automatically", isOn: $autoClose)
    }
}

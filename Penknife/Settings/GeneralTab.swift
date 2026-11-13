import SwiftUI

struct GeneralTab: View {
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @AppStorage(HUD.durationKey) private var hudDuration = 4.0
    private var permissions = Permissions.shared

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        LaunchAtLogin.isEnabled = on
                    }
                Picker("Show confirmations for", selection: $hudDuration) {
                    ForEach(HUD.durations, id: \.self) { seconds in
                        Text("\(Int(seconds)) seconds").tag(seconds)
                    }
                }
            } footer: {
                Text("The language follows the system (Spanish or English).")
                    .foregroundStyle(.secondary)
            }

            Section("Permissions") {
                LabeledContent {
                    if permissions.accessibilityGranted {
                        Label {
                            Text("Granted")
                        } icon: {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                        .labelStyle(.titleAndIcon)
                    } else {
                        Button("Open System Settings") {
                            permissions.requestAccessibility()
                            permissions.openAccessibilitySettings()
                        }
                    }
                } label: {
                    Text("Accessibility")
                    Text("Needed for the mouse jiggler, the Teams microphone sync and dialog detection.")
                }
            }

            Section("About") {
                LabeledContent("Version", value: version)
                DisclosureGroup("Acknowledgements") {
                    Text(Acknowledgements.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

enum Acknowledgements {
    static let text = """
    KeyboardShortcuts — https://github.com/sindresorhus/KeyboardShortcuts

    MIT License

    Copyright (c) Sindre Sorhus <sindresorhus@gmail.com> (https://sindresorhus.com)

    Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
    """
}

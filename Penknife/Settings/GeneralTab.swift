import AppKit
import SwiftUI

/// General: start, menu bar dots and alerts.
struct GeneralPage: View {
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @AppStorage(HUD.durationKey) private var hudDuration = 4.0
    @AppStorage(StatusMenu.dotsKey) private var statusDots = true
    @AppStorage(MenuBarReadings.styleKey) private var readingStyle = MenuBarReadings.Style.sober

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        if on != LaunchAtLogin.isEnabled { LaunchAtLogin.isEnabled = on }
                    }
                    // Back from System Settings: show what the system has now (B-25).
                    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                        LaunchAtLogin.apply()
                        launchAtLogin = LaunchAtLogin.isEnabled
                    }
                Toggle("Show microphone and Mouse Jiggler dots", isOn: $statusDots)
                Picker("Menu bar readings", selection: $readingStyle) {
                    ForEach(MenuBarReadings.Style.allCases) { Text($0.title).tag($0) }
                }
            } footer: {
                Text("The language follows the system: Spanish or English.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Show alerts for", selection: $hudDuration) {
                    ForEach(HUD.durations, id: \.self) { seconds in
                        Text(Duration.seconds(seconds), format: .units(allowed: [.seconds], width: .wide)).tag(seconds)
                    }
                }
                ForEach(AlertCategory.allCases) { AlertToggle(category: $0) }
            } header: {
                Text("Alerts")
            } footer: {
                Text("VoiceOver still announces hidden alerts.")
                    .foregroundStyle(.secondary)
            }

            // R-42: one file with everything; an import replaces it all and restarts Penknife.
            Section {
                LabeledContent("Settings File") {
                    HStack {
                        Button("Export…", action: SettingsFile.export)
                        Button("Import…", action: SettingsFile.import)
                    }
                }
            } footer: {
                Text("Saves your settings, shortcuts, Touch Bar, pinned items and macros in one file, to keep a copy or move them to another Mac.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// The panels and alerts around `SettingsTransfer` (R-42).
@MainActor
enum SettingsFile {
    static func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [SettingsTransfer.fileType]
        panel.nameFieldStringValue = String(localized: "Penknife Settings") + ".plist"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        do {
            let package = SettingsTransfer.package(defaults: .standard, folder: ClipboardStore.defaultFolder)
            try SettingsTransfer.writeOwnerOnly(SettingsTransfer.encode(package, version: version), to: url)
        } catch {
            fail(String(localized: "The settings couldn't be saved."), error.localizedDescription)
        }
    }

    static func `import`() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [SettingsTransfer.fileType]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let data: Data
        do {
            data = try Data(contentsOf: url)
            _ = try SettingsTransfer.decode(data)
        } catch {
            fail(String(localized: "This isn't a Penknife settings file."),
                 error as? SettingsTransfer.TransferError == .newerFormat
                    ? String(localized: "It was made by a newer Penknife. Update Penknife and try again.")
                    : String(localized: "Choose a file made with Export…"))
            return
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "Replace your settings?")
        alert.informativeText = String(localized: "Your settings, shortcuts, Touch Bar, pinned items and macros are replaced with the ones in “\(url.lastPathComponent)”. Penknife restarts.")
        alert.addButton(withTitle: String(localized: "Replace and Restart"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try SettingsTransfer.stage(data, folder: ClipboardStore.defaultFolder)
            SettingsTransfer.restart()
        } catch {
            fail(String(localized: "The settings couldn't be imported."), error.localizedDescription)
        }
    }

    private static func fail(_ message: String, _ detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
    }
}

/// Permissions Penknife asks for, and their state (GN-21, O-31 variant A): the five macOS
/// permissions with the system's own names, what each is for, and its state. Read when the page
/// shows, when Penknife's window comes back to the front, and when Device Control changes.
struct PermissionsPage: View {
    private var permissions = Permissions.shared
    @State private var access: [PrivacyPermission: PrivacyPermission.Access] = [:]

    var body: some View {
        Form {
            Section {
                ForEach(PrivacyPermission.allCases) { permission in
                    LabeledContent {
                        control(for: permission)
                    } label: {
                        Text(permission.title)
                        Text(permission.detail)
                    }
                }
            } footer: {
                Text("macOS asks the first time you use a feature that needs it.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: read)
        .onChange(of: permissions.accessibilityGranted) { read() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in read() }
    }

    @ViewBuilder private func control(for permission: PrivacyPermission) -> some View {
        switch PrivacyPermission.control(for: access[permission] ?? .unknown) {
        case .granted:
            Label {
                Text("Granted")
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            .labelStyle(.titleAndIcon)
        case .allow:
            Button("Allow…") { permission.ask { read() } }
        case .openSettings:
            Button("Open System Settings") { permission.openSettings() }
        }
    }

    private func read() {
        var states: [PrivacyPermission: PrivacyPermission.Access] = [:]
        for permission in PrivacyPermission.allCases { states[permission] = permission.access }
        access = states
    }
}

/// Version and acknowledgements.
struct AboutPage: View {
    /// "1.0 (32)": version and build, as in Finder's Get Info.
    private var version: String {
        let info = Bundle.main.infoDictionary
        return Self.version(short: info?["CFBundleShortVersionString"] as? String ?? "",
                            build: info?["CFBundleVersion"] as? String ?? "")
    }

    /// GN-26: "1.11 (186)", or only the version when there is no build.
    static func version(short: String, build: String) -> String {
        build.isEmpty ? short : "\(short) (\(build))"
    }

    var body: some View {
        Form {
            Section {
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
    }
}

/// Show or hide one type of alert (R-20).
private struct AlertToggle: View {
    let category: AlertCategory
    @AppStorage private var shown: Bool

    init(category: AlertCategory) {
        self.category = category
        _shown = AppStorage(wrappedValue: true, category.key)
    }

    var body: some View {
        Toggle(category.title, isOn: $shown)
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
    """ + "\n\n" + #"""
    Sparkle — https://sparkle-project.org

    Copyright (c) 2006-2013 Andy Matuschak.
    Copyright (c) 2009-2013 Elgato Systems GmbH.
    Copyright (c) 2011-2014 Kornel Lesiński.
    Copyright (c) 2015-2017 Mayur Pawashe.
    Copyright (c) 2014 C.W. Betts.
    Copyright (c) 2014 Petroules Corporation.
    Copyright (c) 2014 Big Nerd Ranch.
    All rights reserved.

    Permission is hereby granted, free of charge, to any person obtaining a copy of
    this software and associated documentation files (the "Software"), to deal in
    the Software without restriction, including without limitation the rights to
    use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
    the Software, and to permit persons to whom the Software is furnished to do so,
    subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
    FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
    COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
    IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
    CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

    =================
    EXTERNAL LICENSES
    =================

    bspatch.c and bsdiff.c, from bsdiff 4.3 <http://www.daemonology.net/bsdiff/>:

    Copyright 2003-2005 Colin Percival
    All rights reserved

    Redistribution and use in source and binary forms, with or without
    modification, are permitted providing that the following conditions 
    are met:
    1. Redistributions of source code must retain the above copyright
       notice, this list of conditions and the following disclaimer.
    2. Redistributions in binary form must reproduce the above copyright
       notice, this list of conditions and the following disclaimer in the
       documentation and/or other materials provided with the distribution.

    THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
    IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
    WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
    ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
    DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
    DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
    OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
    HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
    STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
    IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
    POSSIBILITY OF SUCH DAMAGE.

    --

    sais.c and sais.h, from sais-lite (2010/08/07) <https://sites.google.com/site/yuta256/sais>:

    The sais-lite copyright is as follows:

    Copyright (c) 2008-2010 Yuta Mori All Rights Reserved.

    Permission is hereby granted, free of charge, to any person
    obtaining a copy of this software and associated documentation
    files (the "Software"), to deal in the Software without
    restriction, including without limitation the rights to use,
    copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the
    Software is furnished to do so, subject to the following
    conditions:

    The above copyright notice and this permission notice shall be
    included in all copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
    EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
    OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
    NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
    HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
    WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
    FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
    OTHER DEALINGS IN THE SOFTWARE.

    --

    Portable C implementation of Ed25519, from https://github.com/orlp/ed25519

    Copyright (c) 2015 Orson Peters <orsonpeters@gmail.com>

    This software is provided 'as-is', without any express or implied warranty. In no event will the
    authors be held liable for any damages arising from the use of this software.

    Permission is granted to anyone to use this software for any purpose, including commercial
    applications, and to alter it and redistribute it freely, subject to the following restrictions:

    1. The origin of this software must not be misrepresented; you must not claim that you wrote the
       original software. If you use this software in a product, an acknowledgment in the product
       documentation would be appreciated but is not required.

    2. Altered source versions must be plainly marked as such, and must not be misrepresented as
       being the original software.

    3. This notice may not be removed or altered from any source distribution.

    --

    SUSignatureVerifier.m:

    Copyright (c) 2011 Mark Hamlin.

    All rights reserved.

    Redistribution and use in source and binary forms, with or without
    modification, are permitted providing that the following conditions
    are met:
    1. Redistributions of source code must retain the above copyright
       notice, this list of conditions and the following disclaimer.
    2. Redistributions in binary form must reproduce the above copyright
       notice, this list of conditions and the following disclaimer in the
       documentation and/or other materials provided with the distribution.

    THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
    IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
    WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
    ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
    DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
    DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
    OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
    HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
    STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
    IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
    POSSIBILITY OF SUCH DAMAGE.
    """#
}

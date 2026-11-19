import SwiftUI

/// The bar while recording (R-29, chosen in the live demo): one glass capsule outside the
/// region, never in the file. Stop (system red) + pause, time | pointer, tools | color, size,
/// fixed or fading | microphone, Mac sound | erase all.
struct RecordingToolbar: View {
    let state: RecordingState
    let run: (RecordingCommand) -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: 4) {
            Button { run(.stop) } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Color(nsColor: .systemRed), in: Circle())
                    .contentShape(Circle())
            }
            .help(help(String(localized: "Stop"), keys: RecordingPrefs.keys(.recordScreen)))
            .accessibilityLabel(String(localized: "Stop recording"))
            Button { run(.pause) } label: { symbol(state.paused ? "play.fill" : "pause.fill") }
                .help(state.paused ? String(localized: "Resume") : String(localized: "Pause"))
                .accessibilityLabel(state.paused ? String(localized: "Resume recording") : String(localized: "Pause recording"))
            Text(state.time)
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(state.paused ? Color.orange : Color.secondary)
                .frame(minWidth: 40)
                .accessibilityLabel(state.paused
                    ? String(localized: "Paused at \(state.time)")
                    : String(localized: "Recording time \(state.time)"))
            separator
            // Pointer first and chosen at the start: clicks go to the apps. A tool = drawing.
            // The same tools, order, color and size as the screenshot editor (shared views).
            MarkToolButtons(selected: state.drawing ? state.tool : nil, pointerHelp: pointerHelp,
                            pointerHint: String(localized: "Clicks go to the app being recorded")) { tool in
                run(tool.map { .tool($0) } ?? .pointer)
            }
            separator
            MarkStyleButtons(colorIndex: state.colorIndex, sizeIndex: state.sizeIndex, expanded: state.expanded,
                             toggle: { run(.toggle($0)) }, color: { run(.color($0)) }, size: { run(.size($0)) })
            fadeMenu
            separator
            SoundSwitches(state: state, keys: false, run: run)
            separator
            Button { run(.erase) } label: { symbol("trash") }
                .help(String(localized: "Erase all drawings"))
                .accessibilityLabel(String(localized: "Erase all drawings"))
        }
        .buttonStyle(.plain)
        .padding(6)
        .background {
            if opaque {
                Capsule().fill(Color(nsColor: .windowBackgroundColor))
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(contrast == .increased ? 1 : 0.15)))
            }
        }
        .glassEffect(opaque ? .identity : .regular, in: .capsule)
        .gesture(WindowDragGesture())
        .fixedSize()
    }

    private var opaque: Bool { reduceTransparency || contrast == .increased }

    private var fadeMenu: some View {
        Menu {
            Picker(String(localized: "Drawings"), selection: Binding(get: { state.fade }, set: { run(.fade($0)) })) {
                Label(String(localized: "Fixed (until erased)"), systemImage: "pin").tag(0.0)
                Divider()
                ForEach(RecordingPrefs.fades.filter { $0 > 0 }, id: \.self) { seconds in
                    Label(String(localized: "Fade after \(Int(seconds)) s"), systemImage: "timer").tag(seconds)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(state.fade == 0 ? String(localized: "Fixed") : String(localized: "\(Int(state.fade)) s"),
                  systemImage: state.fade == 0 ? "pin" : "timer")
                .labelStyle(.titleAndIcon)
                .font(.system(size: 13, weight: .medium))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(width: 64, height: 28)
        .help(state.fade == 0 ? String(localized: "Drawings: fixed") : String(localized: "Drawings: fade after \(Int(state.fade)) s"))
        .accessibilityLabel(String(localized: "Drawings"))
        .accessibilityValue(state.fade == 0 ? String(localized: "Fixed") : String(localized: "Fade after \(Int(state.fade)) s"))
    }

    /// "Pointer: use your apps (⌃⌥D)"; while drawing "(Esc or ⌃⌥D)".
    private var pointerHelp: String {
        let keys = RecordingPrefs.keys(.recordingDraw)
        guard state.drawing else { return help(String(localized: "Pointer: use your apps"), keys: keys) }
        return help(String(localized: "Pointer: use your apps"), keys: keys.isEmpty ? "Esc" : String(localized: "Esc or \(keys)"))
    }

    private func help(_ text: String, keys: String) -> String {
        keys.isEmpty ? text : "\(text) (\(keys))"
    }

    private func symbol(_ name: String, selected: Bool = false) -> some View {
        Image(systemName: name)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(selected ? Color.white : Color.primary)
            .frame(width: 28, height: 28)
            .background(selected ? Color.accentColor : .clear, in: Circle())
            .contentShape(Circle())
    }

    private var separator: some View {
        Divider().frame(height: 18).padding(.horizontal, 2)
    }
}

/// Microphone and Mac sound (REC-27): in the recording toolbar and, with their keys M and S in
/// the tooltips, in the countdown capsule (O-18, user's pick A). Same look in both.
struct SoundSwitches: View {
    let state: RecordingState
    let keys: Bool
    let run: (RecordingCommand) -> Void

    var body: some View {
        Button { run(.microphone) } label: { symbol(state.microphone ? "mic" : "mic.slash", selected: state.microphone) }
            .help(withKey(state.microphone ? String(localized: "Microphone: on") : String(localized: "Microphone: off"), "M"))
            .accessibilityLabel(String(localized: "Microphone"))
            .accessibilityValue(state.microphone ? String(localized: "On") : String(localized: "Off"))
        Button { run(.macSound) } label: { symbol(state.macSound ? "speaker.wave.2" : "speaker.slash", selected: state.macSound) }
            .help(withKey(state.macSound ? String(localized: "Mac sound: on") : String(localized: "Mac sound: off"), "S"))
            .accessibilityLabel(String(localized: "Mac sound"))
            .accessibilityValue(state.macSound ? String(localized: "On") : String(localized: "Off"))
    }

    private func withKey(_ text: String, _ key: String) -> String { keys ? "\(text) (\(key))" : text }

    private func symbol(_ name: String, selected: Bool) -> some View {
        Image(systemName: name)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(selected ? Color.white : Color.primary)
            .frame(width: 28, height: 28)
            .background(selected ? Color.accentColor : .clear, in: Circle())
            .contentShape(Circle())
    }
}

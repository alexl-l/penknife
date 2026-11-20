import SwiftUI

/// The bar while recording (R-29, chosen in the live demo): one glass capsule outside the
/// region, never in the file. Stop (system red) + pause, time | pointer, tools | color, size,
/// fixed or fading | microphone, Mac sound | erase all.
struct RecordingToolbar: View {
    let state: RecordingState
    var hints: ShortcutHintModel?
    let run: (RecordingCommand) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
            .shortcut("stop", name: state.counting ? String(localized: "Cancel") : String(localized: "Stop"),
                      key: state.counting ? "Esc" : RecordingSession.stopKeys(RecordingPrefs.keys(.recordScreen)), in: hints)
            .accessibilityLabel(state.counting ? String(localized: "Cancel recording") : String(localized: "Stop recording"))
            Button { run(.pause) } label: { symbol(state.paused ? "play.fill" : "pause.fill") }
                .shortcut("pause", name: state.paused ? String(localized: "Resume") : String(localized: "Pause"),
                          key: String(localized: "Space"), in: hints)
                .accessibilityLabel(state.paused ? String(localized: "Resume recording") : String(localized: "Pause recording"))
                .disabled(state.counting)
            if state.counting {
                // O-32: the 3-2-1 in the time's place; VoiceOver hears it in the session's
                // announcements, not at every second.
                Text(String(localized: "Recording in \(max(state.countdown, 1))"))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .contentTransition(reduceMotion ? .opacity : .numericText(countsDown: true))
                    .animation(.easeInOut(duration: 0.25), value: state.countdown)
                    .padding(.horizontal, 6)
                    .accessibilityLabel(String(localized: "Recording in \(max(state.countdown, 1)) seconds"))
            } else {
                Text(state.time)
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(state.paused ? Color.orange : Color.secondary)
                    .frame(minWidth: 40)
                    .accessibilityLabel(state.paused
                        ? String(localized: "Paused at \(state.time)")
                        : String(localized: "Recording time \(state.time)"))
            }
            separator
            // The Mouse ⇄ Edit slot first, Mouse at the start: clicks go to the apps. Edit has no
            // tool until one is picked (REC-16). The same tools, order, color and size as the
            // screenshot editor (shared views).
            MarkToolButtons(selected: state.drawing ? state.tool : nil, mouse: !state.drawing, hints: hints, pointerHelp: pointerHelp,
                            pointerHint: state.drawing ? String(localized: "Press again to give the clicks back to your apps")
                                                       : String(localized: "Clicks go to the app being recorded")) { tool in
                run(tool.map { .tool($0) } ?? .pointer)
            }
            .disabled(state.counting)
            separator
            Group {
                MarkStyleButtons(colorIndex: state.colorIndex, sizeIndex: state.sizeIndex, expanded: state.expanded, hints: hints,
                                 toggle: { run(.toggle($0)) }, color: { run(.color($0)) }, size: { run(.size($0)) })
                fadeMenu
            }
            .disabled(state.counting)
            separator
            SoundSwitches(state: state, hints: hints, run: run)
            separator
            Button { run(.erase) } label: { symbol("trash") }
                .shortcut("erase", name: String(localized: "Erase all drawings"), key: "⇧⌫", in: hints)
                .accessibilityLabel(String(localized: "Erase all drawings"))
                .disabled(state.counting)
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
        .coordinateSpace(.named(ShortcutHintModel.space))
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
        .shortcut("fade", name: state.fade == 0 ? String(localized: "Drawings: fixed") : String(localized: "Drawings: fade after \(Int(state.fade)) s"),
                  key: "F", in: hints)
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

/// Microphone and Mac sound (REC-27): in the recording toolbar, keys M and S; during the
/// countdown they work too and the first touch restarts it at 3 (O-18, O-32).
struct SoundSwitches: View {
    let state: RecordingState
    var hints: ShortcutHintModel?
    let run: (RecordingCommand) -> Void

    var body: some View {
        Button { run(.microphone) } label: { symbol(state.microphone ? "mic" : "mic.slash", selected: state.microphone) }
            .shortcut("microphone", name: state.microphone ? String(localized: "Microphone: on") : String(localized: "Microphone: off"),
                      key: "M", in: hints)
            .accessibilityLabel(String(localized: "Microphone"))
            .accessibilityValue(state.microphone ? String(localized: "On") : String(localized: "Off"))
        Button { run(.macSound) } label: { symbol(state.macSound ? "speaker.wave.2" : "speaker.slash", selected: state.macSound) }
            .shortcut("macSound", name: state.macSound ? String(localized: "Mac sound: on") : String(localized: "Mac sound: off"),
                      key: "S", in: hints)
            .accessibilityLabel(String(localized: "Mac sound"))
            .accessibilityValue(state.macSound ? String(localized: "On") : String(localized: "Off"))
    }

    private func symbol(_ name: String, selected: Bool) -> some View {
        Image(systemName: name)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(selected ? Color.white : Color.primary)
            .frame(width: 28, height: 28)
            .background(selected ? Color.accentColor : .clear, in: Circle())
            .contentShape(Circle())
    }
}

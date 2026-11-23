import Observation
import SwiftUI

/// Editor state shared by the toolbar and the canvas.
@Observable
final class CaptureEditorState {
    var tool: CaptureTool?
    var colorIndex: Int
    var sizeIndex = CaptureSize.defaultIndex
    /// Which choice row is open in the toolbar, if any.
    var expanded: Expansion?
    var canUndo = false
    var canRedo = false
    /// Record mode (R-29, R-33): choosing a region starts the recording at once.
    var recordMode = false
    /// Opened with the record shortcut: no screenshot editor, Esc cancels.
    var recordOnly = false
    /// R-38: the color picker's loupe follows the pointer; a click copies the color.
    var picking = false
    /// Opened with the Pick Color shortcut: Esc cancels instead of going back to the screenshot.
    var pickOnly = false
    var microphone = RecordingPrefs.microphone
    var macSound = RecordingPrefs.macSound

    typealias Expansion = StyleRow

    /// Each overlay starts on the Pointer, the default color and Medium (SS-23).
    init(defaults: UserDefaults) {
        colorIndex = CapturePalette.defaultIndex(in: defaults)
    }

    var color: NSColor { CapturePalette.colors[colorIndex] }
}

enum CaptureCommand {
    case undo, redo, copy, copyText, save, toggle(CaptureEditorState.Expansion), pointer, tool(CaptureTool), color(Int), size(Int)
    case record
}

/// One glass capsule below the selection (variant B, chosen by the user): tools | color, size |
/// undo, redo | copy, save. Icons only, with tooltips and VoiceOver labels.
struct CaptureToolbar: View {
    let state: CaptureEditorState
    var hints: ShortcutHintModel?
    let run: (CaptureCommand) -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        editorControls
        .buttonStyle(.plain)
        .padding(8)
        .background {
            // Opaque, with a border when contrast is increased (R-19).
            if opaque {
                Capsule().fill(Color(nsColor: .windowBackgroundColor))
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(contrast == .increased ? 1 : 0.15)))
            }
        }
        .glassEffect(opaque ? .identity : .regular, in: .capsule)
        .fixedSize()
        .coordinateSpace(.named(ShortcutHintModel.space))
    }

    private var editorControls: some View {
        HStack(spacing: 4) {
            MarkToolButtons(selected: state.tool, hints: hints,
                            pointerHelp: String(localized: "Pointer: move the selection or a drawing"),
                            pointerHint: String(localized: "Drag to move the selection; click a drawing to change it")) { tool in
                run(tool.map { .tool($0) } ?? .pointer)
            }
            separator
            MarkStyleButtons(colorIndex: state.colorIndex, sizeIndex: state.sizeIndex, expanded: state.expanded, hints: hints,
                             toggle: { run(.toggle($0)) }, color: { run(.color($0)) }, size: { run(.size($0)) })
            separator
            Button { run(.undo) } label: { symbol("arrow.uturn.backward") }
                .disabled(!state.canUndo)
                .shortcut("undo", name: String(localized: "Undo"), key: "⌘Z", in: hints)
                .accessibilityLabel(String(localized: "Undo"))
            Button { run(.redo) } label: { symbol("arrow.uturn.forward") }
                .disabled(!state.canRedo)
                .shortcut("redo", name: String(localized: "Redo"), key: "⇧⌘Z", in: hints)
                .accessibilityLabel(String(localized: "Redo"))
            separator
            Button { run(.copy) } label: { symbol("doc.on.doc") }
                .shortcut("copy", name: String(localized: "Copy"), key: "⌘C", in: hints)
                .accessibilityLabel(String(localized: "Copy"))
            Button { run(.copyText) } label: { symbol("text.viewfinder") }
                .shortcut("copyText", name: String(localized: "Copy Text"), key: "⇧⌘C", in: hints)
                .accessibilityLabel(String(localized: "Copy Text"))
            Button { run(.save) } label: { symbol("square.and.arrow.down") }
                .shortcut("save", name: String(localized: "Save"), key: "⌘S", in: hints)
                .accessibilityLabel(String(localized: "Save"))
            separator
            Button { run(.record) } label: { symbol("record.circle") }
                .shortcut("record", name: String(localized: "Record video"), key: "⇧⌘R", in: hints)
                .accessibilityLabel(String(localized: "Record video"))
        }
    }

    private var opaque: Bool { reduceTransparency || contrast == .increased }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 14, weight: .medium))
            .frame(width: 28, height: 28)
            .contentShape(Circle())
    }

    private var separator: some View {
        Divider().frame(height: 18).padding(.horizontal, 2)
    }
}

/// Which choice row is open in a capsule.
enum StyleRow { case colors, sizes }

// The tools, color and size are THE SAME views in the screenshot editor and while recording
// (user, 2026-11-17: "las herramientas y el orden NO DEBEN CAMBIAR ENTRE VIDEO Y CAPTURA").

/// A capsule's symbol button face: white on the accent color when chosen; `ringed` = an accent
/// ring (the recording's Edit slot while a tool is armed); `dimmed` = not usable now.
struct CapsuleSymbol: View {
    let name: String
    var selected = false
    var ringed = false
    var dimmed = false

    var body: some View {
        Image(systemName: name)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(selected ? Color.white : ringed ? Color.accentColor : Color.primary.opacity(dimmed ? 0.35 : 1))
            .frame(width: 28, height: 28)
            .background(selected ? Color.accentColor : .clear, in: Circle())
            .overlay { if ringed && !selected { Circle().strokeBorder(Color.accentColor, lineWidth: 1.5) } }
            .contentShape(Circle())
    }
}

/// Pointer first, then every tool in `CaptureTool` order. `selected` nil = the Pointer.
/// `mouse` (recording only, REC-16 user's pick A): the same slot is Mouse ⇄ Edit; true = Mouse
/// (clicks go to the apps, tools dimmed), false = Edit (`cursorarrow.rays`, filled with no tool,
/// ringed while a tool is armed). nil = the editor's plain Pointer.
struct MarkToolButtons: View {
    let selected: CaptureTool?
    var mouse: Bool? = nil
    var hints: ShortcutHintModel?
    let pointerHelp: String
    let pointerHint: String
    let choose: (CaptureTool?) -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button { choose(nil) } label: {
                CapsuleSymbol(name: mouse == false ? "cursorarrow.rays" : "cursorarrow",
                              selected: mouse != true && selected == nil, ringed: mouse == false && selected != nil)
            }
                .shortcut("pointer", name: pointerName, key: "Q", in: hints)
                .accessibilityLabel(pointerName)
                .accessibilityHint(pointerHint)
                .accessibilityAddTraits(mouse == nil && selected == nil ? .isSelected : [])
            ForEach(CaptureTool.allCases) { tool in
                Button { choose(tool) } label: { CapsuleSymbol(name: tool.symbol, selected: selected == tool, dimmed: mouse == true) }
                    .shortcut("tool.\(tool)", name: tool.title, key: tool.key, in: hints)
                    .accessibilityLabel(tool.title)
                    .accessibilityAddTraits(selected == tool ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Tools"))
    }

    private var pointerName: String {
        switch mouse {
        case true?: String(localized: "Mouse: clicks go to your apps")
        case false?: String(localized: "Edit: select and move drawings")
        case nil: String(localized: "Pointer")
        }
    }
}

/// Color and size: one button each; its choices open inside the capsule, in its place.
struct MarkStyleButtons: View {
    let colorIndex: Int
    let sizeIndex: Int
    let expanded: StyleRow?
    var hints: ShortcutHintModel?
    let toggle: (StyleRow) -> Void
    let color: (Int) -> Void
    let size: (Int) -> Void
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: 4) {
            // The trigger gives way to the choices while they are open (no repeated option).
            if expanded != .colors {
                Button { toggle(.colors) } label: {
                    swatch(colorIndex, size: 18)
                }
                .shortcut("colors", name: String(localized: "Color"), key: "C", in: hints)
                .accessibilityLabel(String(localized: "Color: \(CapturePalette.name(colorIndex))"))
            } else {
                ForEach(CapturePalette.colors.indices, id: \.self) { index in
                    Button { color(index) } label: {
                        swatch(index, size: 16)
                            .overlay {
                                if index == colorIndex {
                                    Image(systemName: "checkmark").font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(CapturePalette.isLight(index) ? Color.black : Color.white)
                                }
                            }
                    }
                    .shortcut("color.\(index)", name: CapturePalette.name(index), key: "\(index + 1)", in: hints)
                    .accessibilityLabel(CapturePalette.name(index))
                    .accessibilityAddTraits(index == colorIndex ? .isSelected : [])
                }
            }
            if expanded != .sizes {
                Button { toggle(.sizes) } label: {
                    weight(sizeIndex)
                }
                .shortcut("sizes", name: String(localized: "Size"), key: "W", in: hints)
                .accessibilityLabel(String(localized: "Size: \(CaptureSize.name(sizeIndex))"))
            } else {
                ForEach(0..<CaptureSize.count, id: \.self) { index in
                    let selected = index == sizeIndex
                    Button { size(index) } label: {
                        weight(index)
                            .foregroundStyle(selected ? Color.white : Color.primary)
                            .background(selected ? Color.accentColor : .clear, in: Circle())
                    }
                    .shortcut("size.\(index)", name: CaptureSize.name(index), key: "\(index + 1)", in: hints)
                    .accessibilityLabel(CaptureSize.name(index))
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
    }

    private func swatch(_ index: Int, size: CGFloat) -> some View {
        Circle().fill(Color(nsColor: CapturePalette.colors[index]))
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(Color.primary.opacity(contrast == .increased ? 1 : 0.35), lineWidth: 1))
            .frame(width: 28, height: 28)
            .contentShape(Circle())
    }

    /// A short slanted line as thick as the size (scaled down to fit the button).
    private func weight(_ index: Int) -> some View {
        Capsule()
            .frame(width: 16, height: [1.5, 2.5, 4, 6][index])
            .rotationEffect(.degrees(-45))
            .frame(width: 28, height: 28)
            .contentShape(Circle())
    }
}

/// The hint at the top of the overlay (R-33, variant A of the live demo): how to choose what to
/// capture or record. It shows after 0.3 s (quick hands never see it) and goes at the first click.
@Observable
final class CaptureHintModel {
    var visible = false
    var windowMode = false
    var recording = false
    var picking = false
    var pickOnly = false
}

struct CaptureHint: View {
    let model: CaptureHintModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ZStack {
            if model.visible {
                HStack(spacing: 14) { items }
                    .font(.system(size: 13))
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .background {
                        if opaque {
                            Capsule().fill(Color(nsColor: .windowBackgroundColor))
                                .overlay(Capsule().strokeBorder(Color.primary.opacity(contrast == .increased ? 1 : 0.15)))
                        }
                    }
                    .glassEffect(opaque ? .identity : .regular, in: .capsule)
                    .fixedSize()
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.easeOut(duration: model.visible ? 0.25 : 0.2), value: model.visible)
        .animation(.easeInOut(duration: 0.15), value: model.windowMode)
        .animation(.easeInOut(duration: 0.15), value: model.picking)
        // VoiceOver hears the same in the overlay's announcement.
        .accessibilityHidden(true)
    }

    private var opaque: Bool { reduceTransparency || contrast == .increased }

    @ViewBuilder private var items: some View {
        if model.picking {
            item(nil, String(localized: "Click to copy the color"))
            item("return", String(localized: "Copy"))
            item("escape", model.pickOnly ? String(localized: "Cancel") : String(localized: "Back"))
        } else if model.windowMode {
            item(nil, String(localized: "Click a window"))
            item("space", String(localized: "Area"))
            item("escape", String(localized: "Cancel"))
        } else {
            item(nil, model.recording ? String(localized: "Drag to record an area") : String(localized: "Drag to capture an area"))
            item("space", String(localized: "Window"))
            item("return", String(localized: "Full screen"))
            if !model.recording { item("I", String(localized: "Color")) }
            item("escape", String(localized: "Cancel"))
        }
    }

    private func item(_ key: String?, _ text: String) -> some View {
        HStack(spacing: 6) {
            if let key {
                // One letter is a key itself (I); anything longer is a symbol's name.
                Group { key.count == 1 ? Text(key) : Text(Image(systemName: key)) }
                    .font(.system(size: 11, weight: .semibold))
                    .frame(minWidth: 28, minHeight: 20)
                    .padding(.horizontal, 4)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
            }
            Text(text).foregroundStyle(key == nil ? Color.primary : Color.secondary)
        }
    }
}

/// A SwiftUI view that never takes the pointer (the canvas under it does).
final class PassThroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

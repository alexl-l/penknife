import Observation
import SwiftUI

/// Editor state shared by the toolbar and the canvas.
@Observable
final class CaptureEditorState {
    var tool: CaptureTool?
    var colorIndex = CapturePalette.defaultIndex
    var sizeIndex = CaptureSize.defaultIndex
    /// Which choice row is open in the toolbar, if any.
    var expanded: Expansion?
    var canUndo = false
    var canRedo = false

    enum Expansion { case colors, sizes }

    var color: NSColor { CapturePalette.colors[colorIndex] }
}

enum CaptureCommand {
    case undo, redo, copy, save, toggle(CaptureEditorState.Expansion), tool(CaptureTool), color(Int), size(Int)
}

/// One glass capsule below the selection (variant B, chosen by the user): tools | color, size |
/// undo, redo | copy, save. Icons only, with tooltips and VoiceOver labels.
struct CaptureToolbar: View {
    let state: CaptureEditorState
    let run: (CaptureCommand) -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: 4) {
            ForEach(CaptureTool.allCases) { tool in
                let selected = state.tool == tool
                Button { run(.tool(tool)) } label: {
                    symbol(tool.symbol)
                        .foregroundStyle(selected ? Color.white : Color.primary)
                        .background(selected ? Color.accentColor : .clear, in: Circle())
                }
                .help("\(tool.title) (\(tool.key))")
                .accessibilityLabel(tool.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            separator
            // The trigger gives way to the choices while they are open (no repeated option).
            if state.expanded != .colors {
                Button { run(.toggle(.colors)) } label: {
                    swatch(state.colorIndex, size: 18)
                }
                .help(String(localized: "Color (1–8)"))
                .accessibilityLabel(String(localized: "Color: \(CapturePalette.name(state.colorIndex))"))
            } else {
                ForEach(CapturePalette.colors.indices, id: \.self) { index in
                    Button { run(.color(index)) } label: {
                        swatch(index, size: 16)
                            .overlay {
                                if index == state.colorIndex {
                                    Image(systemName: "checkmark").font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(CapturePalette.isLight(index) ? Color.black : Color.white)
                                }
                            }
                    }
                    .help("\(CapturePalette.name(index)) (\(index + 1))")
                    .accessibilityLabel(CapturePalette.name(index))
                    .accessibilityAddTraits(index == state.colorIndex ? .isSelected : [])
                }
            }
            if state.expanded != .sizes {
                Button { run(.toggle(.sizes)) } label: {
                    weight(state.sizeIndex)
                }
                .help(String(localized: "Size (- and +, or scroll)"))
                .accessibilityLabel(String(localized: "Size: \(CaptureSize.name(state.sizeIndex))"))
            } else {
                ForEach(0..<CaptureSize.count, id: \.self) { index in
                    let selected = index == state.sizeIndex
                    Button { run(.size(index)) } label: {
                        weight(index)
                            .foregroundStyle(selected ? Color.white : Color.primary)
                            .background(selected ? Color.accentColor : .clear, in: Circle())
                    }
                    .help(CaptureSize.name(index))
                    .accessibilityLabel(CaptureSize.name(index))
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            separator
            Button { run(.undo) } label: { symbol("arrow.uturn.backward") }
                .disabled(!state.canUndo)
                .help(String(localized: "Undo (⌘Z)"))
                .accessibilityLabel(String(localized: "Undo"))
            Button { run(.redo) } label: { symbol("arrow.uturn.forward") }
                .disabled(!state.canRedo)
                .help(String(localized: "Redo (⇧⌘Z)"))
                .accessibilityLabel(String(localized: "Redo"))
            separator
            Button { run(.copy) } label: { symbol("doc.on.doc") }
                .help(String(localized: "Copy (⌘C)"))
                .accessibilityLabel(String(localized: "Copy"))
            Button { run(.save) } label: { symbol("square.and.arrow.down") }
                .help(String(localized: "Save (⌘S)"))
                .accessibilityLabel(String(localized: "Save"))
        }
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
    }

    private var opaque: Bool { reduceTransparency || contrast == .increased }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 14, weight: .medium))
            .frame(width: 28, height: 28)
            .contentShape(Circle())
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

    private var separator: some View {
        Divider().frame(height: 18).padding(.horizontal, 2)
    }
}

import AppKit

/// What the overlay knows when a key arrives (docs/requirements/screenshot.md SS-13, 27, 38, 42,
/// 43, 44, 52).
struct CaptureKeyContext: Equatable {
    var hasSelection = false
    var recordMode = false
    /// A window's frozen image is selected: the selection can't move.
    var fixedSelection = false
    var windowMode = false
    /// The frozen screen is still being grabbed.
    var capturing = false
    var typing = false
    var tool: CaptureTool?
    var markCount = 0
    var selectedMark: Int?
    var sizeIndex = 0
}

/// What a key does in the overlay. The canvas performs it exactly as it did inline.
enum CaptureKeyAction: Equatable {
    /// Ours, but nothing happens (a held key, a ⌘ key in record mode).
    case swallow
    case selectMark(Int)
    case deselectMark
    case removeMark(Int)
    case nudgeMark(Int, CGVector, grow: Bool)
    case cancel
    case toggleWindowMode
    /// The highlighted target, or the whole screen.
    case choose
    case startRecording
    case beginText
    case copy
    case save
    case undo
    case redo
    case record
    case nextTarget(forward: Bool)
    case nudgeSelection(dx: CGFloat, dy: CGFloat, resize: Bool)
    case tool(CaptureTool)
    case color(Int)
    case size(Int)
}

/// The overlay's key table as a plain rule: nil means not ours (the key goes on to the app).
enum CaptureKeys {
    static func action(keyCode: UInt16, characters: String?, flags: NSEvent.ModifierFlags, isRepeat: Bool,
                       context c: CaptureKeyContext) -> CaptureKeyAction? {
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        let key = characters?.lowercased() ?? ""
        let code = Int(keyCode)
        if isRepeat, [49, 36, 76, 53].contains(code) { return .swallow }   // held Space/Return/Esc: once only
        if !c.recordMode, c.hasSelection, let mark = markAction(code: code, flags: flags, context: c) { return mark }
        switch code {
        case 53:                                                // Esc
            return .cancel
        case 49 where !c.hasSelection:                          // Space: window ⇄ area
            return c.capturing ? .swallow : .toggleWindowMode
        case 36, 76:                                            // Return
            if c.recordMode { return c.hasSelection ? .startRecording : .choose }
            if !c.hasSelection { return .choose }
            return c.tool == .text && !c.typing ? .beginText : .copy
        case 123, 124, 125, 126:
            guard c.hasSelection, !c.fixedSelection else {
                // Window mode: the arrows go through the windows, front to back, then the desktop.
                return c.windowMode && !c.hasSelection ? .nextTarget(forward: code == 124 || code == 125) : .swallow
            }
            let step: CGFloat = flags.contains(.shift) ? 10 : 1
            return .nudgeSelection(dx: code == 123 ? -step : code == 124 ? step : 0,
                                   dy: code == 126 ? -step : code == 125 ? step : 0,
                                   resize: flags.contains(.option))
        default: break
        }
        if c.recordMode {
            // Record mode has no tools, copy or save.
            return command && key != "q" ? .swallow : nil
        }
        if command {
            switch key {
            case "r" where flags.contains(.shift): return .record
            case "z": return flags.contains(.shift) ? .redo : .undo
            case "c": return .copy
            case "s": return .save
            default: return nil
            }
        }
        guard c.hasSelection, flags.isDisjoint(with: [.control, .option]) else { return nil }
        if let tool = CaptureTool.allCases.first(where: { $0.key.lowercased() == key }) { return .tool(tool) }
        if let digit = Int(key), (1...CapturePalette.colors.count).contains(digit) { return .color(digit - 1) }
        if key == "-" { return .size(max(c.sizeIndex - 1, 0)) }
        if key == "+" || key == "=" { return .size(min(c.sizeIndex + 1, CaptureSize.count - 1)) }
        return nil
    }

    /// Keys for marks: Tab selects the next one (⇧ the previous); with one selected, Esc lets it
    /// go, Delete removes it, arrows move it (⇧ by 10, ⌥ make it bigger or smaller).
    private static func markAction(code: Int, flags: NSEvent.ModifierFlags, context c: CaptureKeyContext) -> CaptureKeyAction? {
        if code == 48, c.markCount > 0, flags.isDisjoint(with: [.control, .option, .command]) {
            let count = c.markCount
            let backward = flags.contains(.shift)
            return .selectMark(c.selectedMark.map { ($0 + (backward ? -1 : 1) + count) % count } ?? (backward ? count - 1 : 0))
        }
        guard let index = c.selectedMark, (0..<c.markCount).contains(index), !flags.contains(.command) else { return nil }
        switch code {
        case 53: return .deselectMark
        case 51, 117: return .removeMark(index)
        case 123, 124, 125, 126:
            let step: CGFloat = flags.contains(.shift) ? 10 : 1
            let delta = CGVector(dx: code == 123 ? -step : code == 124 ? step : 0,
                                 dy: code == 126 ? -step : code == 125 ? step : 0)
            return .nudgeMark(index, delta, grow: flags.contains(.option))
        default: return nil
        }
    }
}

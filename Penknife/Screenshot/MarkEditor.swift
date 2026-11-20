import Foundation

/// The marks of a screenshot and their undo history, with no view (S4): the canvas asks for each
/// change and redraws what it touched. Undo and redo keep the marks as they were before each
/// change, with what the change was (SS-39, SS-40).
struct MarkEditor {
    typealias Step = (marks: [Annotation], label: String)

    private(set) var marks: [Annotation] = []
    private(set) var undoStack: [Step] = []
    private(set) var redoStack: [Step] = []
    /// R-32: the mark selected for changes.
    var selected: Int?
    /// The marks before a drag changed them (move, resize, eraser).
    private var before: [Annotation]?
    /// The newest undo step was made by arrow keys (another change or an undo closes it).
    private var nudgeStepOpen = false
    private var lastNudge = Date.distantPast
    /// A text being typed again (double-click): the marks before, the old text and its depth.
    private var textEdit: (before: [Annotation], original: Annotation, index: Int)?

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var selectedMark: Annotation? { selected.flatMap { marks.indices.contains($0) ? marks[$0] : nil } }

    func contains(_ index: Int?) -> Bool { index.map(marks.indices.contains) ?? false }

    /// A change was made: `before` is what undo brings back.
    mutating func commit(_ before: [Annotation], label: String) {
        nudgeStepOpen = false
        undoStack.append((before, label))
        redoStack.removeAll()
    }

    /// A finished mark: one undo step named after its tool.
    mutating func add(_ mark: Annotation) {
        let before = marks
        marks.append(mark)
        commit(before, label: mark.tool.title)
    }

    /// Brings back the marks before the newest step; returns its label (nil: nothing to undo).
    mutating func undo() -> String? {
        guard let last = undoStack.popLast() else { return nil }
        nudgeStepOpen = false
        redoStack.append((marks, last.label))
        marks = last.marks
        selected = nil
        return last.label
    }

    mutating func redo() -> String? {
        guard let next = redoStack.popLast() else { return nil }
        nudgeStepOpen = false
        undoStack.append((marks, next.label))
        marks = next.marks
        selected = nil
        return next.label
    }

    /// Deletes a mark (one undo step "Delete") and returns it.
    mutating func remove(at index: Int) -> Annotation? {
        guard marks.indices.contains(index) else { return nil }
        let before = marks
        let mark = marks.remove(at: index)
        selected = nil
        commit(before, label: String(localized: "Delete"))
        return mark
    }

    /// A copy of the mark moved by `offset`, added on top and selected (one undo step "Duplicate").
    mutating func duplicate(_ index: Int, offset: CGVector) {
        guard marks.indices.contains(index) else { return }
        let before = marks
        var copy = marks[index]
        copy.move(by: offset)
        marks.append(copy)
        selected = marks.count - 1
        commit(before, label: String(localized: "Duplicate"))
    }

    /// Double-click on a bent line's middle handle: straight again (one undo step).
    mutating func straighten(at index: Int) {
        guard marks.indices.contains(index) else { return }
        let before = marks
        marks[index].bend = nil
        commit(before, label: String(localized: "Straighten"))
    }

    /// A change in progress (a drag): no undo step until it finishes.
    mutating func change(_ index: Int, _ change: (inout Annotation) -> Void) {
        guard marks.indices.contains(index) else { return }
        change(&marks[index])
    }

    /// A drag that may change marks starts: what it ends with is compared with this.
    mutating func beginDrag() {
        before = marks
    }

    /// The selected mark moved or resized: one undo step, none when it ended where it began.
    mutating func finishEditing(moved: Bool) {
        guard let before else { return }
        self.before = nil
        guard let index = selected, before.indices.contains(index), marks.indices.contains(index),
              before[index].points != marks[index].points || before[index].scale != marks[index].scale
                || before[index].bend != marks[index].bend else { return }
        commit(before, label: moved ? String(localized: "Move") : String(localized: "Resize"))
    }

    /// One step of the eraser: only the marks it goes over lose what it covers. True when it
    /// touched any.
    mutating func erase(from: CGPoint?, to: CGPoint, width: CGFloat, stroke: Int) -> Bool {
        var touched = false
        for index in marks.indices where marks[index].erase(from: from, to: to, width: width, stroke: stroke) {
            touched = true
        }
        return touched
    }

    /// The eraser drag ended: marks erased completely go away (returned, to be redrawn); the
    /// whole drag is one undo step.
    mutating func finishErasing() -> [Annotation] {
        guard let before else { return [] }
        self.before = nil
        let gone = marks.filter(\.isFullyErased)
        marks.removeAll { $0.isFullyErased }
        let changed = marks.count != before.count || zip(marks, before).contains { $0.erasures.count != $1.erasures.count }
        if changed { commit(before, label: CaptureTool.eraser.title) }
        return gone
    }

    /// Color and size changes go to the selected mark too (one undo step). False when there is
    /// no selected mark it applies to.
    mutating func restyleSelected(label: String, applies: (Annotation) -> Bool, _ change: (inout Annotation) -> Void) -> Bool {
        guard let index = selected, marks.indices.contains(index), applies(marks[index]) else { return false }
        let before = marks
        change(&marks[index])
        commit(before, label: label)
        return true
    }

    /// Arrows on a mark: held or repeated arrows (same kind, less than 1 s apart, nothing else
    /// in between) make one undo step.
    mutating func nudge(_ index: Int, label: String, now: Date, _ change: (inout Annotation) -> Void) {
        guard marks.indices.contains(index) else { return }
        if !(nudgeStepOpen && undoStack.last?.label == label && now.timeIntervalSince(lastNudge) < 1) {
            commit(marks, label: label)
            nudgeStepOpen = true
        }
        lastNudge = now
        change(&marks[index])
    }

    /// Double-click on a text: it leaves the marks to be typed again; returns it.
    mutating func beginTextEdit(_ index: Int) -> Annotation {
        let mark = marks[index]
        textEdit = (marks, mark, index)
        marks.remove(at: index)
        selected = nil
        return mark
    }

    /// Typing ended with `text`. A text typed again goes back to its place and depth; one undo
    /// step brings back the old one, and nothing changes when it wasn't changed (SS-31). A new
    /// text is added when it has something in it.
    mutating func endText(_ text: Annotation) {
        if let edit = textEdit {
            textEdit = nil
            let index = min(edit.index, marks.count)
            let old = edit.original
            if text.text == old.text, text.color == old.color, text.size == old.size, text.scale == old.scale {
                marks.insert(old, at: index)
            } else {
                if text.isMeaningful { marks.insert(text, at: index) }
                commit(edit.before, label: CaptureTool.text.title)
            }
        } else if text.isMeaningful {
            add(text)
        }
    }
}

import AppKit
import SwiftUI

/// Borderless panel for the recording's pieces. Non-activating: the app in front stays active.
final class OverlayPanel: NSPanel {
    var keyable = false
    /// Keys reach this first; true = handled.
    var onKey: ((NSEvent) -> Bool)?

    init(frame: CGRect, level: NSWindow.Level) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        self.level = level
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { keyable }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let onKey, onKey(event) { return }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let onKey, onKey(event) { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// A SwiftUI view whose buttons work on the first click, without the panel becoming key.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The drawings, in a window the recording INCLUDES. Each finished mark is its own small layer,
/// so fading is a Core Animation opacity change (no redraw, no timer); the mark being drawn and
/// the text being typed are drawn by this view, only where they change. Coordinates: points,
/// top-left origin, relative to the recorded region. Marks can be changed afterwards (R-32):
/// a mark being changed is redrawn in its layer and doesn't fade until it is let go.
final class StrokeCanvas: NSView {
    private var current: Annotation?
    private(set) var marks: [MarkView] = []
    /// Marks the eraser touched in the current drag.
    private var erasing: [MarkView] = []
    /// A blur mark appeared, changed or went away (the recording blurs those areas).
    var onBlursChanged: (() -> Void)?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var hasMarks: Bool { !marks.isEmpty }

    /// The mark being drawn (nil when done).
    func setCurrent(_ annotation: Annotation?) {
        let dirty = (current?.paintedBounds ?? .null).union(annotation?.paintedBounds ?? .null)
        let blur = current?.tool == .blur || annotation?.tool == .blur
        current = annotation
        if !dirty.isNull { setNeedsDisplay(dirty) }
        if blur { onBlursChanged?() }
    }

    /// The areas to blur (points, top-left origin): the blur marks and one being drawn. What the
    /// eraser took from a blur doesn't count: a blur is all or nothing in a recording.
    var blurRects: [CGRect] {
        let rects = marks.filter { $0.annotation.tool == .blur }.map(\.annotation.rect) + (current?.tool == .blur ? [current!.rect] : [])
        return rects.filter { $0.width >= 2 && $0.height >= 2 }
    }

    override func draw(_ dirtyRect: NSRect) {
        current?.draw()
    }

    /// A finished mark: drawn once into its own layer. With `fade` > 0 it fades during its last
    /// half second (at once under Reduce Motion) and is then removed.
    func add(_ annotation: Annotation, fade: Double) {
        let frame = annotation.paintedBounds.intersection(bounds).integral
        guard !frame.isNull, frame.width > 0, frame.height > 0 else { return }
        // A blur never fades: what it hides would show again.
        let mark = MarkView(annotation, frame: frame, fade: annotation.tool == .blur ? 0 : fade)
        addSubview(mark)
        marks.append(mark)
        scheduleFade(mark)
        if annotation.tool == .blur { onBlursChanged?() }
    }

    private func scheduleFade(_ mark: MarkView) {
        guard mark.fade > 0 else { return }
        let generation = mark.generation
        // Reduce Motion: no fade, the mark goes at the chosen time.
        let fadeLength = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : min(0.5, mark.fade)
        DispatchQueue.main.asyncAfter(deadline: .now() + mark.fade - fadeLength) { [weak self, weak mark] in
            guard let self, let mark, mark.superview != nil, mark.generation == generation else { return }
            guard fadeLength > 0 else {
                remove(mark)
                return
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = fadeLength
                mark.animator().alphaValue = 0
            } completionHandler: { [weak self, weak mark] in
                MainActor.assumeIsolated {
                    guard let self, let mark, mark.generation == generation else { return }
                    self.remove(mark)
                }
            }
        }
    }

    /// The topmost mark under `point`.
    func mark(at point: CGPoint) -> MarkView? {
        marks.last { $0.annotation.hit(point) }
    }

    /// A mark being changed stays fully visible (its fade waits).
    func hold(_ mark: MarkView) {
        mark.generation += 1
        mark.layer?.removeAllAnimations()
        mark.alphaValue = 1
    }

    /// Let go: its fade starts again from the beginning.
    func release(_ mark: MarkView) {
        guard mark.superview != nil else { return }
        mark.generation += 1
        scheduleFade(mark)
    }

    /// The mark changed (moved, resized, recolored, erased): redrawn in its layer.
    func update(_ mark: MarkView, to annotation: Annotation) {
        mark.annotation = annotation
        let frame = annotation.paintedBounds.intersection(bounds).integral
        mark.isHidden = frame.isNull || frame.width <= 0 || frame.height <= 0
        if !mark.isHidden { mark.frame = frame }
        mark.needsDisplay = true
        if annotation.tool == .blur { onBlursChanged?() }
    }

    /// One step of an eraser drag over every mark.
    func erase(from: CGPoint?, to: CGPoint, width: CGFloat, stroke: Int) {
        for mark in marks {
            var annotation = mark.annotation
            guard annotation.erase(from: from, to: to, width: width, stroke: stroke) else { continue }
            // A mark being erased doesn't fade meanwhile (QA, 2026-11-17).
            if !erasing.contains(where: { $0 === mark }) {
                hold(mark)
                erasing.append(mark)
            }
            update(mark, to: annotation)
        }
    }

    /// After an eraser drag: marks erased completely go away, and a blur the eraser touched.
    func removeErased() {
        for mark in marks where mark.annotation.isFullyErased || (mark.annotation.tool == .blur && !mark.annotation.erasures.isEmpty) {
            remove(mark)
        }
        // What is left fades again from the start.
        for mark in erasing { release(mark) }
        erasing.removeAll()
    }

    /// Removes the newest mark still on screen; false when there is none.
    @discardableResult
    func undo() -> Bool {
        guard let last = marks.last else { return false }
        remove(last)
        return true
    }

    func eraseAll() {
        let blurs = !blurRects.isEmpty
        for mark in marks { mark.removeFromSuperview() }
        marks.removeAll()
        setCurrent(nil)
        if blurs { onBlursChanged?() }
    }

    func remove(_ mark: MarkView) {
        mark.removeFromSuperview()
        marks.removeAll { $0 === mark }
        if mark.annotation.tool == .blur { onBlursChanged?() }
    }
}

/// One finished mark, drawn into its own layer (again only when it changes).
final class MarkView: NSView {
    var annotation: Annotation
    let fade: Double
    /// Changes when its fade is cancelled or restarted.
    var generation = 0

    init(_ annotation: Annotation, frame: CGRect, fade: Double) {
        self.annotation = annotation
        self.fade = fade
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.cgContext.translateBy(x: -frame.minX, y: -frame.minY)
        annotation.draw()
    }
}

/// Takes the pointer and the keys while drawing is on, in a window the recording EXCLUDES; what
/// it makes is drawn into the StrokeCanvas below it. Text is typed into an invisible text view
/// here (its caret shows on screen, not in the file) and mirrored into the canvas. The selection
/// of a mark (R-32: box, handles, ✕) and the faint outline under the pointer are drawn here too,
/// so they are never recorded.
final class DrawingInputView: NSView, NSTextViewDelegate {
    private let state: RecordingState
    private let canvas: StrokeCanvas
    private var current: Annotation?
    private var textView: NSTextView?
    private var textOrigin = CGPoint.zero
    private var textSize = CaptureSize.defaultIndex
    private var textColor = NSColor.systemBlue
    private var textScale: CGFloat = 1
    private var selected: MarkView?
    private var hovered: MarkView?
    private var drag = Drag.none
    private var eraserStrokes = 0
    /// A finished mark goes into the canvas (with the fade chosen when it was finished).
    var onMark: ((Annotation) -> Void)?
    var announce: ((String) -> Void)?
    /// The scroll wheel: +1 thicker, -1 thinner (as in the screenshot editor).
    var onScroll: ((Int) -> Void)?
    private var scrollAccumulator: CGFloat = 0

    private enum Drag {
        case none, drawing
        case moving(last: CGPoint)
        case resizing(handle: Int, original: Annotation)
        case erasing(last: CGPoint, stroke: Int)
    }

    init(frame: CGRect, state: RecordingState, canvas: StrokeCanvas) {
        self.state = state
        self.canvas = canvas
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "Drawing on the recording"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Penknife isn't the active app while drawing, so cursor rects don't apply: the pointer
    // shape is set from a tracking area that works always.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, trackingAreas.isEmpty else { return }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self))
    }

    override func cursorUpdate(with event: NSEvent) { updateCursor(convert(event.locationInWindow, from: nil)) }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateHovered(point)
        updateCursor(point)
    }

    private func updateCursor(_ point: CGPoint) {
        if let mark = selected?.annotation {
            if MarkEditing.isOnClose(point, of: mark, within: bounds) { NSCursor.pointingHand.set(); return }
            if let handle = MarkEditing.handle(at: point, of: mark) {
                MarkEditing.cursor(forHandle: handle, of: mark).set()
                return
            }
        }
        if state.tool == .eraser { MarkEditing.eraserCursor(size: state.sizeIndex).set(); return }
        if hovered != nil { NSCursor.openHand.set(); return }
        (state.tool == .text ? NSCursor.iBeam : NSCursor.crosshair).set()
    }

    /// The mark a click would select: outlined faintly.
    private func updateHovered(_ point: CGPoint) {
        let mark = textView == nil && state.tool != .eraser ? canvas.mark(at: point) : nil
        guard mark !== hovered else { return }
        redraw(hovered)
        hovered = mark
        redraw(mark)
    }

    private func redraw(_ mark: MarkView?) {
        guard let mark else { return }
        setNeedsDisplay(MarkEditing.area(mark.annotation))
    }

    override func draw(_ dirtyRect: NSRect) {
        if let hovered, hovered !== selected, hovered.superview != nil { MarkEditing.drawHover(hovered.annotation) }
        if let selected, selected.superview != nil { MarkEditing.drawSelection(selected.annotation, within: bounds) }
    }

    func toolChanged() {
        endText()
        select(nil)
        redraw(hovered)
        hovered = nil
        if let window { updateCursor(convert(window.mouseLocationOutsideOfEventStream, from: nil)) }
    }

    var isTyping: Bool { textView != nil }
    var hasSelection: Bool { selected?.superview != nil }

    // MARK: Selection (R-32)

    /// Selects a mark (nil: none). The toolbar then shows its color and size, and changing them
    /// changes it.
    func select(_ mark: MarkView?) {
        guard mark !== selected else { return }
        if let selected {
            redraw(selected)
            canvas.release(selected)
        }
        selected = mark
        guard let mark else { return }
        canvas.hold(mark)
        redraw(mark)
        let annotation = mark.annotation
        if annotation.tool.usesColor, let color = MarkEditing.colorIndex(of: annotation) { state.colorIndex = color }
        state.sizeIndex = annotation.size
        announce?(String(localized: "Selected: \(annotation.tool.title). Delete removes it, arrows move it, Tab selects the next one."))
    }

    /// Tab: the next mark (⇧ the previous).
    func selectNext(backward: Bool) {
        let marks = canvas.marks
        guard !marks.isEmpty else { return }
        let index = selected.flatMap { mark in marks.firstIndex { $0 === mark } }
        let count = marks.count
        select(marks[index.map { ($0 + (backward ? -1 : 1) + count) % count } ?? (backward ? count - 1 : 0)])
    }

    /// Delete or ✕: false when nothing is selected.
    @discardableResult
    func deleteSelected() -> Bool {
        guard let mark = selected, mark.superview != nil else { return false }
        redraw(mark)
        selected = nil
        hovered = nil
        canvas.remove(mark)
        announce?(String(localized: "Removed: \(mark.annotation.tool.title)"))
        return true
    }

    /// Arrow keys: move (⌥: bigger or smaller).
    func nudge(_ delta: CGVector, grow: Bool) {
        guard let mark = selected, mark.superview != nil else { return }
        change(mark, to: grow ? MarkEditing.grown(mark.annotation, by: delta) : moved(mark.annotation, by: delta))
    }

    /// The color (or the size) chosen in the toolbar goes to the selected mark.
    func restyleSelected(color: Bool) {
        guard let mark = selected, mark.superview != nil else { return }
        var annotation = mark.annotation
        if color {
            guard annotation.tool.usesColor else { return }
            annotation.color = state.color
        } else {
            annotation.size = state.sizeIndex
            annotation.scale = 1
        }
        change(mark, to: annotation)
    }

    private func moved(_ annotation: Annotation, by delta: CGVector) -> Annotation {
        var annotation = annotation
        annotation.move(by: delta)
        return annotation
    }

    private func change(_ mark: MarkView, to annotation: Annotation) {
        redraw(mark)
        canvas.update(mark, to: annotation)
        redraw(mark)
    }

    // MARK: Pointer

    override func scrollWheel(with event: NSEvent) {
        // Physical direction: natural scrolling's inversion undone; which way is thicker is a setting.
        var delta = event.scrollingDeltaY * (event.isDirectionInvertedFromDevice ? -1 : 1)
        if ScreenshotModule.scrollUpThinner { delta = -delta }
        if event.hasPreciseScrollingDeltas {
            scrollAccumulator += delta
            guard abs(scrollAccumulator) >= 24 else { return }
            delta = scrollAccumulator
            scrollAccumulator = 0
        }
        guard delta != 0 else { return }
        onScroll?(delta > 0 ? 1 : -1)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if textView != nil {
            endText()
            if state.tool != .text { return }
        }
        if let mark = selected, mark.superview != nil {
            if MarkEditing.isOnClose(point, of: mark.annotation, within: bounds) {
                deleteSelected()
                return
            }
            if let handle = MarkEditing.handle(at: point, of: mark.annotation) {
                if event.clickCount == 2, mark.annotation.bends, handle == 2, mark.annotation.bend != nil {
                    // Double-click the bend handle: straight again.
                    var straight = mark.annotation
                    straight.bend = nil
                    change(mark, to: straight)
                    return
                }
                drag = .resizing(handle: handle, original: mark.annotation)
                return
            }
        }
        if state.tool == .eraser {
            select(nil)
            eraserStrokes += 1
            drag = .erasing(last: point, stroke: eraserStrokes)
            canvas.erase(from: nil, to: point, width: MarkEditing.eraserSizes[state.sizeIndex], stroke: eraserStrokes)
            return
        }
        if let mark = canvas.mark(at: point) {
            if event.clickCount == 2, mark.annotation.tool == .text {
                editText(mark)
                return
            }
            select(mark)
            drag = .moving(last: point)
            NSCursor.closedHand.set()
            return
        }
        select(nil)
        if state.tool == .text {
            beginText(at: point)
            return
        }
        current = Annotation(tool: state.tool, color: state.color, size: state.sizeIndex, points: [point, point],
                             liveBlur: state.tool == .blur)
        canvas.setCurrent(current)
        drag = .drawing
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch drag {
        case .none:
            return
        case .drawing:
            guard var mark = current, let last = mark.points.last else { return }
            switch mark.tool {
            case .pen, .highlighter:
                guard hypot(point.x - last.x, point.y - last.y) >= 1.5 else { return }
                mark.points.append(point)
            default:
                let snap = (mark.tool == .arrow || mark.tool == .line) && event.modifierFlags.contains(.shift)
                mark.points[1] = snap ? MarkEditing.snapped(point, from: mark.points[0]) : point
            }
            current = mark
            canvas.setCurrent(mark)
        case .moving(let last):
            guard let mark = selected, mark.superview != nil else { return }
            change(mark, to: moved(mark.annotation, by: CGVector(dx: point.x - last.x, dy: point.y - last.y)))
            drag = .moving(last: point)
        case .resizing(let handle, let original):
            guard let mark = selected, mark.superview != nil else { return }
            change(mark, to: MarkEditing.resized(original, handle: handle, to: point, keepRatio: event.modifierFlags.contains(.shift)))
        case .erasing(let last, let stroke):
            canvas.erase(from: last, to: point, width: MarkEditing.eraserSizes[state.sizeIndex], stroke: stroke)
            drag = .erasing(last: point, stroke: stroke)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let finished = drag
        drag = .none
        switch finished {
        case .drawing:
            guard var mark = current else { return }
            current = nil
            if mark.tool == .pen || mark.tool == .highlighter, mark.points.count == 1 { mark.points.append(mark.points[0]) }
            // The finished mark goes in first, then the one being drawn goes: a blur is never
            // missing between the two, not even for one frame (security review, 2026-11-17).
            if mark.isMeaningful { onMark?(mark) }
            canvas.setCurrent(nil)
        case .erasing:
            canvas.removeErased()
        default:
            break
        }
        let point = convert(event.locationInWindow, from: nil)
        updateHovered(point)
        updateCursor(point)
    }

    /// Drops a mark half drawn and lets the selection go (drawing turned off meanwhile).
    func cancelMark() {
        current = nil
        drag = .none
        canvas.setCurrent(nil)
        select(nil)
        redraw(hovered)
        hovered = nil
    }

    // MARK: Text

    /// Double-click on a text: typed again in place (it fades again from the end).
    private func editText(_ mark: MarkView) {
        let annotation = mark.annotation
        select(nil)
        redraw(mark)
        hovered = nil
        canvas.remove(mark)
        if let color = MarkEditing.colorIndex(of: annotation) { state.colorIndex = color }
        state.sizeIndex = annotation.size
        beginText(at: annotation.points.first ?? .zero, text: annotation.text, scale: annotation.scale)
    }

    private func beginText(at point: CGPoint, text: String = "", scale: CGFloat = 1) {
        textScale = scale
        let font = textFont
        let view = NSTextView(frame: CGRect(origin: point, size: CGSize(width: 40, height: font.boundingRectForFont.height)))
        view.isRichText = false
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.containerSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        view.isHorizontallyResizable = true
        view.isVerticallyResizable = true
        view.minSize = view.frame.size
        view.maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.allowsUndo = true
        view.delegate = self
        view.setAccessibilityLabel(String(localized: "Text"))
        view.string = text
        addSubview(view)
        textView = view
        textOrigin = point
        styleText()
        window?.makeFirstResponder(view)
    }

    private var textFont: NSFont { .systemFont(ofSize: CaptureSize.fontSizes[state.sizeIndex] * textScale, weight: .semibold) }

    /// A new size from the toolbar: the text loses the size its handles gave it.
    func sizeChanged() {
        textScale = 1
        styleText()
    }

    /// Color and size apply to the whole text being typed. The text view's own letters are
    /// clear: the canvas below shows them (and the recording gets them), the caret stays here.
    func styleText() {
        guard let view = textView else { return }
        textSize = state.sizeIndex
        textColor = state.color
        let font = textFont
        var attributes = Annotation.textAttributes(textColor, font: font)
        attributes[.foregroundColor] = NSColor.clear
        attributes[.shadow] = nil
        view.typingAttributes = attributes
        view.insertionPointColor = textColor
        view.textStorage?.setAttributes(attributes, range: NSRange(location: 0, length: view.textStorage?.length ?? 0))
        view.minSize = CGSize(width: 40, height: font.boundingRectForFont.height)
        view.sizeToFit()
        mirrorText()
        window?.makeFirstResponder(view)
    }

    func textDidChange(_ notification: Notification) {
        textView?.sizeToFit()
        mirrorText()
    }

    private func mirrorText() {
        guard let view = textView else { return }
        canvas.setCurrent(Annotation(tool: .text, color: textColor, size: textSize, points: [textOrigin], text: view.string, scale: textScale))
    }

    /// Esc ends the text (a second Esc turns drawing off).
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(cancelOperation(_:)) {
            endText()
            return true
        }
        return false
    }

    func endText() {
        guard let view = textView else { return }
        textView = nil
        let mark = Annotation(tool: .text, color: textColor, size: textSize, points: [textOrigin], text: view.string, scale: textScale)
        view.removeFromSuperview()
        window?.makeFirstResponder(self)
        canvas.setCurrent(nil)
        textScale = 1
        if mark.isMeaningful { onMark?(mark) }
    }
}

/// What a blur looks like on screen while recording (R-32), in a window the recording EXCLUDES:
/// frosted glass over each blur area. The file gets the real blur, made by the writer.
final class BlurOverlay: NSView {
    private var views: [NSVisualEffectView] = []

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ rects: [CGRect]) {
        while views.count < rects.count {
            let view = NSVisualEffectView()
            view.material = .fullScreenUI
            view.blendingMode = .behindWindow
            view.state = .active
            view.maskImage = Self.mask
            addSubview(view)
            views.append(view)
        }
        while views.count > rects.count { views.removeLast().removeFromSuperview() }
        for (view, rect) in zip(views, rects) { view.frame = rect }
    }

    /// Rounded corners (10 pt, as the screenshot's blur), stretched to any size.
    private static let mask: NSImage = {
        let image = NSImage(size: CGSize(width: 21, height: 21), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        image.resizingMode = .stretch
        return image
    }()
}

/// The edge of the recorded region, in a window the recording EXCLUDES: a fine light-and-dark
/// line outside it, or a blue 2 pt line while drawing is on (inside the screen's edges for the
/// full screen, which otherwise shows no line).
final class RegionFrameView: NSView {
    var drawing = false { didSet { if drawing != oldValue { needsDisplay = true } } }
    let fullScreen: Bool
    static let outset: CGFloat = 3

    init(frame: CGRect, fullScreen: Bool) {
        self.fullScreen = fullScreen
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let region = fullScreen ? bounds : bounds.insetBy(dx: Self.outset, dy: Self.outset)
        if drawing {
            NSColor.systemBlue.setStroke()
            let path = NSBezierPath(rect: fullScreen ? region.insetBy(dx: 1, dy: 1) : region.insetBy(dx: -1, dy: -1))
            path.lineWidth = 2
            path.stroke()
        } else if !fullScreen {
            NSColor.black.withAlphaComponent(0.35).setStroke()
            let outer = NSBezierPath(rect: region.insetBy(dx: -1.5, dy: -1.5))
            outer.lineWidth = 1
            outer.stroke()
            NSColor.white.withAlphaComponent(0.8).setStroke()
            let inner = NSBezierPath(rect: region.insetBy(dx: -0.5, dy: -0.5))
            inner.lineWidth = 1
            inner.stroke()
        }
    }
}

/// The 3-2-1 before recording (R-33, variant A of the live demo, chosen by the user): nothing
/// dimmed, only a fine accent line around the region and a small glass capsule at the top center
/// (where the hint was) saying "Recording in 3".
final class CountdownView: NSView {
    private let region: CGRect

    /// `region`: in this view's coordinates (bottom-left origin). `top`: the menu bar's height.
    init(frame: CGRect, region: CGRect, top: CGFloat, state: RecordingState) {
        self.region = region
        super.init(frame: frame)
        let capsule = NSHostingView(rootView: CountdownCapsule(state: state))
        capsule.frame = CGRect(x: 0, y: bounds.height - top - 12 - 36, width: bounds.width, height: 36)
        capsule.autoresizingMask = [.width, .minYMargin]
        addSubview(capsule)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.9).setStroke()
        let border = NSBezierPath(rect: region.insetBy(dx: -0.5, dy: -0.5))
        border.lineWidth = 1
        border.stroke()
    }
}

private struct CountdownCapsule: View {
    let state: RecordingState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color(nsColor: .systemRed).opacity(0.6))
                .frame(width: 7, height: 7)
            Text(String(localized: "Recording in \(max(state.countdown, 1))"))
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .contentTransition(reduceMotion ? .opacity : .numericText(countsDown: true))
        }
        .padding(.horizontal, 16)
        .frame(height: 36)
        .background {
            if opaque {
                Capsule().fill(Color(nsColor: .windowBackgroundColor))
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(contrast == .increased ? 1 : 0.15)))
            }
        }
        .glassEffect(opaque ? .identity : .regular, in: .capsule)
        .fixedSize()
        .animation(.easeInOut(duration: 0.25), value: state.countdown)
        .frame(maxWidth: .infinity)
        // VoiceOver hears it once, in the session's announcement.
        .accessibilityHidden(true)
    }

    private var opaque: Bool { reduceTransparency || contrast == .increased }
}

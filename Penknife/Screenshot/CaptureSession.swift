import AppKit
import CoreImage
import SwiftUI

/// One screenshot from shortcut to Copy/Save/Esc: an overlay window per screen. The selection
/// lives on one screen; starting one on another screen moves it there.
final class CaptureSession {
    let mode: ScreenshotMode
    let state = CaptureEditorState(defaults: .standard)
    private var windows: [CaptureWindow] = []
    private let previousApp: NSRunningApplication?
    private let onRecord: (RecordingRequest) -> Void
    private let onFinish: () -> Void
    private var finished = false

    /// `recordOnly`: opened with the record shortcut (R-29), straight in record mode.
    init(mode: ScreenshotMode, images: [CGDirectDisplayID: CGImage], previousApp: NSRunningApplication?, recordOnly: Bool = false,
         onRecord: @escaping (RecordingRequest) -> Void, onFinish: @escaping () -> Void) {
        self.mode = mode
        self.previousApp = previousApp
        self.onRecord = onRecord
        self.onFinish = onFinish
        state.recordMode = recordOnly
        state.recordOnly = recordOnly
        let windowRects = Self.onScreenWindows()
        for screen in NSScreen.screens {
            let window = CaptureWindow(screen: screen, image: images[screen.displayID], windowRects: windowRects, session: self)
            windows.append(window)
        }
    }

    func show() {
        // Penknife is not activated: the app in front keeps its active look, so a captured window
        // shows its colored title bar buttons, as macOS's own screenshot does.
        let mouse = NSEvent.mouseLocation
        for window in windows {
            window.orderFrontRegardless()
            window.canvas.showHint()
        }
        let first = windows.first { $0.frame.contains(mouse) } ?? windows.first
        first?.makeKey()
        first?.canvas.announce(state.recordOnly
            ? String(localized: "Record the screen. Drag to select an area, Space to choose a window, Return for the whole screen, Esc to cancel.")
            : String(localized: "Screenshot. Drag to select an area, Space to choose a window, Return for the whole screen, Esc to cancel."))
    }

    /// Record (button, ⇧⌘R, or the record shortcut while the overlay is open): with a selection
    /// the recording starts at once (R-33); without one, choosing a region will start it.
    func enterRecordMode() {
        guard !state.recordMode else { return }
        state.recordMode = true
        if let canvas = windows.first(where: { $0.canvas.selection != nil })?.canvas {
            canvas.recordModeChanged()
            return
        }
        for window in windows { window.canvas.recordModeChanged() }
    }

    /// The first click or choice: the hints go, on every screen.
    func hideHints() {
        for window in windows { window.canvas.hideHint() }
    }

    /// Record was pressed: the overlay closes and the recording takes over.
    func record(screen: NSScreen, rect: CGRect, fullScreen: Bool, window: (id: CGWindowID, frame: CGRect)?, marks: [Annotation]) {
        guard !finished else { return }
        finished = true
        for overlay in windows {
            overlay.canvas.tearDown()
            overlay.orderOut(nil)
            overlay.close()
        }
        windows.removeAll()
        onRecord(RecordingRequest(screen: screen, rect: rect, fullScreen: fullScreen, window: window, marks: marks,
                                  microphone: state.microphone, macSound: state.macSound, previousApp: previousApp))
        onFinish()
    }

    /// A selection started on `canvas`: the other screens drop theirs, unless they have marks.
    func focus(_ canvas: CaptureCanvas) -> Bool {
        for window in windows where window.canvas !== canvas {
            if window.canvas.hasAnnotations { return false }
        }
        for window in windows where window.canvas !== canvas { window.canvas.reset() }
        return true
    }

    func cancel() {
        guard !finished else { return }
        finished = true
        for window in windows {
            window.canvas.tearDown()
            window.orderOut(nil)
            window.close()
        }
        windows.removeAll()
        previousApp?.activate()
        onFinish()
    }

    /// Visible app windows, front to back, in global top-left coordinates (as CoreGraphics gives
    /// them). Penknife's own windows are skipped.
    private static func onScreenWindows() -> [CaptureTarget] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let pid = getpid()
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? pid_t) != pid,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds),
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  rect.width > 40, rect.height > 40 else { return nil }
            return .window(id, rect)
        }
    }
}

/// Borderless window over one whole screen, above the menu bar and the Dock.
final class CaptureWindow: NSPanel {
    let canvas: CaptureCanvas

    init(screen: NSScreen, image: CGImage?, windowRects: [CaptureTarget], session: CaptureSession) {
        canvas = CaptureCanvas(screen: screen, image: image, windowRects: windowRects, session: session)
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        setAccessibilityLabel(String(localized: "Screenshot"))

        let container = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        container.wantsLayer = true
        if let image {
            // The frozen screen is a layer: the GPU composites it, nothing redraws it.
            container.layer?.contents = image
            container.layer?.contentsGravity = .resize
        }
        canvas.frame = container.bounds
        canvas.autoresizingMask = [.width, .height]
        container.addSubview(canvas)
        contentView = container
        initialFirstResponder = canvas
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, !(firstResponder is NSTextView), canvas.handleKey(event) { return }
        super.sendEvent(event)
    }

    /// ⌘ keys reach the window before the app's menu, whose Undo/Copy would otherwise take ⌘Z and
    /// ⌘C (e.g. after typing text, Undo was enabled for the text view and swallowed ⌘Z).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if !(firstResponder is NSTextView), canvas.handleKey(event) { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// Something window mode can select: an app window (captured alone, with its rounded corners)
/// or the desktop (wallpaper and icons, without windows), as macOS does.
enum CaptureTarget: Equatable {
    case window(CGWindowID, CGRect)
    case desktop(CGRect)

    var rect: CGRect {
        switch self {
        case .window(_, let rect), .desktop(let rect): rect
        }
    }
}

/// Selection, marks and the toolbar for one screen. Coordinates are points, top-left origin.
final class CaptureCanvas: NSView, NSTextViewDelegate {
    /// Weak, and the state is kept here: the session is released as soon as it hands over to the
    /// recording (its owner drops it in `onFinish`), which can happen in the middle of this view's
    /// own event — a drag's mouse-up starts the countdown and then updates the cursor. With
    /// `unowned` that last step read a freed session and crashed (2026-11-17).
    private weak var session: CaptureSession?
    private let state: CaptureEditorState
    private let screen: NSScreen
    private var base: CGImage?
    private var scale: CGFloat
    /// App windows on this screen, front to back, in canvas coordinates (window mode).
    private let windowRects: [CaptureTarget]

    private(set) var selection: CGRect?
    private var windowMode = false
    private var hovered: CaptureTarget?
    /// A window or the desktop taken on its own: it replaces the screen under the selection,
    /// which can then not be moved or resized.
    private var targetImage: CGImage?
    private var targetNSImage: NSImage?
    private var fixedSelection: Bool { targetImage != nil }
    /// The selection's background blurred once, so the blur tool shows real pixels while dragging.
    private var blurred: (selection: CGRect, image: CGImage, scale: CGFloat)?
    private var annotations: [Annotation] = []
    /// Undo and redo keep the marks as they were before each change, with what the change was.
    private var undoStack: [(marks: [Annotation], label: String)] = []
    private var redoStack: [(marks: [Annotation], label: String)] = []
    /// R-32: the mark selected for changes, the one under the pointer, the marks before a drag
    /// changed them, and the eraser drags made so far.
    private var selectedMark: Int?
    private var hoveredMark: Int?
    private var marksBefore: [Annotation]?
    private var eraserStrokes = 0
    private var lastNudge = Date.distantPast
    /// The newest undo step was made by arrow keys (another change or an undo closes it).
    private var nudgeStepOpen = false
    /// A text being typed again (double-click): the marks before, for one undo step.
    private var textEditBefore: [Annotation]?
    /// The text being typed again, and where it was (it goes back there, at the same depth).
    private var textEditOriginal: (mark: Annotation, index: Int)?
    private var current: Annotation?
    private var drag: Drag = .none
    private var capturing = false
    /// Record mode (R-29): the window to record.
    private var recordWindow: CGWindowID?
    private var selectedTarget: CaptureTarget?
    /// R-33: how to choose a region, at the top of the screen until the first click.
    private let hintModel = CaptureHintModel()
    private var hintView: NSView?
    private var hintWork: DispatchWorkItem?
    private var hintDone = false

    private var toolbar: NSHostingView<CaptureToolbar>?
    private var textView: NSTextView?
    private var textOrigin = CGPoint.zero
    private lazy var ciContext = CIContext()

    private enum Drag {
        case none
        case selecting(start: CGPoint)
        case moving(offset: CGPoint)
        case resizing(handle: Int, original: CGRect)
        case drawing
        case movingMark(last: CGPoint)
        case resizingMark(handle: Int, original: Annotation)
        case erasing(last: CGPoint, stroke: Int)
    }

    /// Handle positions as fractions of the selection: corners and edge midpoints.
    private static let handles: [(CGFloat, CGFloat)] = [(0, 0), (0.5, 0), (1, 0), (1, 0.5), (1, 1), (0.5, 1), (0, 1), (0, 0.5)]

    init(screen: NSScreen, image: CGImage?, windowRects: [CaptureTarget], session: CaptureSession) {
        self.session = session
        state = session.state
        self.screen = screen
        self.base = image
        scale = image.map { CGFloat($0.width) / screen.frame.width } ?? screen.backingScaleFactor
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let top = primaryHeight - screen.frame.maxY
        let local = CGRect(origin: .zero, size: screen.frame.size)
        self.windowRects = windowRects.compactMap { target in
            guard case .window(let id, let rect) = target else { return nil }
            let converted = rect.offsetBy(dx: -screen.frame.minX, dy: -top)
            let visible = converted.intersection(local)
            return visible.isNull || visible.width < 40 || visible.height < 40 ? nil : .window(id, converted)
        }
        super.init(frame: NSRect(origin: .zero, size: screen.frame.size))
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "Screenshot"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self))
    }

    var hasAnnotations: Bool { !annotations.isEmpty || textView != nil }

    func reset() {
        endText()
        selection = nil
        annotations.removeAll()
        undoStack.removeAll()
        redoStack.removeAll()
        selectedMark = nil
        hoveredMark = nil
        hovered = nil
        windowMode = false
        targetImage = nil
        targetNSImage = nil
        blurred = nil
        recordWindow = nil
        selectedTarget = nil
        toolbar?.removeFromSuperview()
        toolbar = nil
        needsDisplay = true
    }

    func tearDown() {
        hintWork?.cancel()
        hintDone = true
        annotations.removeAll()
        undoStack.removeAll()
        redoStack.removeAll()
        selectedMark = nil
        hoveredMark = nil
        current = nil
        textView?.removeFromSuperview()
        textView = nil
        toolbar?.removeFromSuperview()
        toolbar = nil
        base = nil
        targetImage = nil
        targetNSImage = nil
        blurred = nil
        window?.contentView?.layer?.contents = nil
    }

    func announce(_ message: String) {
        guard let window else { return }
        NSAccessibility.post(element: window, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let hoveredRect = selection == nil ? hovered?.rect : nil
        let shown = targetImage == nil ? (selection ?? hoveredRect) : nil
        let dim = NSBezierPath(rect: bounds)
        if let shown { dim.append(NSBezierPath(rect: shown)) }
        dim.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.38).setFill()
        dim.fill()

        if let hoveredRect {
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
            hoveredRect.fill()
            NSColor.controlAccentColor.setStroke()
            let border = NSBezierPath(rect: hoveredRect.insetBy(dx: 1.5, dy: 1.5))
            border.lineWidth = 3
            border.stroke()
            return
        }
        guard let selection else { return }

        // A window or the desktop on its own, over the dimmed screen.
        targetNSImage?.draw(in: selection, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: selection).addClip()
        for annotation in annotations { annotation.draw() }
        current?.draw()
        NSGraphicsContext.restoreGraphicsState()

        if !fixedSelection {
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: selection.insetBy(dx: -0.5, dy: -0.5))
            border.lineWidth = 1
            border.stroke()

            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.4)
            shadow.shadowBlurRadius = 2
            NSGraphicsContext.saveGraphicsState()
            shadow.set()
            NSColor.white.setFill()
            for point in handlePoints(selection) {
                NSBezierPath(ovalIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)).fill()
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        drawSizeLabel(selection)

        // R-32: the mark under the pointer and the selected one, above everything else.
        if let index = hoveredMark, index != selectedMark, annotations.indices.contains(index) {
            MarkEditing.drawHover(annotations[index])
        }
        if let index = selectedMark, annotations.indices.contains(index) {
            MarkEditing.drawSelection(annotations[index], within: bounds)
        }
    }

    private func drawSizeLabel(_ selection: CGRect) {
        let text = "\(Int((selection.width * outputScale).rounded())) × \(Int((selection.height * outputScale).rounded()))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        var pill = CGRect(x: selection.minX, y: selection.minY - size.height - 12, width: size.width + 14, height: size.height + 6)
        if pill.minY < 4 { pill.origin.y = selection.minY + 6; pill.origin.x += 6 }
        pill.origin.x = min(max(pill.minX, 4), bounds.width - pill.width - 4)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        string.draw(at: CGPoint(x: pill.minX + 7, y: pill.minY + 3))
    }

    private func handlePoints(_ rect: CGRect) -> [CGPoint] {
        Self.handles.map { CGPoint(x: rect.minX + rect.width * $0.0, y: rect.minY + rect.height * $0.1) }
    }

    private func handle(at point: CGPoint) -> Int? {
        guard let selection, !fixedSelection else { return nil }
        return handlePoints(selection).firstIndex { abs($0.x - point.x) <= 8 && abs($0.y - point.y) <= 8 }
    }

    // MARK: Pointer

    override func cursorUpdate(with event: NSEvent) { updateCursor(convert(event.locationInWindow, from: nil)) }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if windowMode, selection == nil {
            let target = target(at: point)
            if target != hovered {
                hovered = target
                needsDisplay = true
            }
        }
        updateHoveredMark(point)
        updateCursor(point)
    }

    /// The mark a click would select (R-32): outlined faintly.
    private func updateHoveredMark(_ point: CGPoint) {
        var mark: Int?
        if let selection, selection.contains(point), textView == nil, state.tool != .eraser, !state.recordMode,
           toolbar.map({ !$0.frame.contains(point) }) ?? true {
            mark = MarkEditing.topmost(at: point, in: annotations)
        }
        guard mark != hoveredMark else { return }
        redrawMark(hoveredMark)
        hoveredMark = mark
        redrawMark(mark)
    }

    /// Redraws only around one mark and its selection.
    private func redrawMark(_ index: Int?) {
        guard let index, annotations.indices.contains(index) else { return }
        setNeedsDisplay(MarkEditing.area(annotations[index]))
    }

    private func updateCursor(_ point: CGPoint) {
        if let toolbar, toolbar.frame.contains(point) { NSCursor.arrow.set(); return }
        guard let selection else {
            (windowMode ? NSCursor.pointingHand : NSCursor.crosshair).set()
            return
        }
        if let index = selectedMark, annotations.indices.contains(index) {
            let mark = annotations[index]
            if MarkEditing.isOnClose(point, of: mark, within: bounds) { NSCursor.pointingHand.set(); return }
            if let handle = MarkEditing.handle(at: point, of: mark) {
                MarkEditing.cursor(forHandle: handle, of: mark).set()
                return
            }
        }
        if state.tool == .eraser, selection.contains(point) {
            MarkEditing.eraserCursor(size: state.sizeIndex).set()
            return
        }
        if hoveredMark != nil { NSCursor.openHand.set(); return }
        if fixedSelection, !selection.contains(point) || state.tool == nil { NSCursor.arrow.set(); return }
        if let index = handle(at: point) {
            let cursor: NSCursor = switch index {
            case 1, 5: .frameResize(position: index == 1 ? .top : .bottom, directions: .all)
            case 3, 7: .frameResize(position: index == 3 ? .right : .left, directions: .all)
            case 0: .frameResize(position: .topLeft, directions: .all)
            case 2: .frameResize(position: .topRight, directions: .all)
            case 4: .frameResize(position: .bottomRight, directions: .all)
            default: .frameResize(position: .bottomLeft, directions: .all)
            }
            cursor.set()
        } else if selection.contains(point) {
            switch state.tool {
            case nil: NSCursor.openHand.set()
            case .text: NSCursor.iBeam.set()
            default: NSCursor.crosshair.set()
            }
        } else {
            (hasAnnotations ? NSCursor.arrow : NSCursor.crosshair).set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        session?.hideHints()
        closeChoices()
        let point = convert(event.locationInWindow, from: nil)
        if textView != nil {
            endText()
            if state.tool != .text { return }
        }
        guard let selection else {
            guard session?.focus(self) ?? false else { return }
            if windowMode {
                if let target = target(at: point) { select(target) }
                return
            }
            drag = .selecting(start: point)
            return
        }
        if !state.recordMode, markMouseDown(at: point, in: selection, clicks: event.clickCount) { return }
        if let index = handle(at: point) {
            drag = .resizing(handle: index, original: selection)
            hideToolbar()
        } else if selection.contains(point) {
            switch state.tool {
            case nil:
                guard !fixedSelection else { return }
                drag = .moving(offset: CGPoint(x: point.x - selection.minX, y: point.y - selection.minY))
                NSCursor.closedHand.set()
                hideToolbar()
            case .text?:
                beginText(at: point)
            case let tool?:
                current = Annotation(tool: tool, color: state.color, size: state.sizeIndex, points: [point, point])
                if tool == .blur { prepareBlur() }
                drag = .drawing
            }
        } else if !hasAnnotations, !fixedSelection {
            self.selection = nil
            drag = .selecting(start: point)
            hideToolbar()
            needsDisplay = true
        }
    }

    // MARK: Changing marks (R-32)

    /// A click on the selected mark's ✕ or handles, with the eraser, or on a mark. True when handled.
    private func markMouseDown(at point: CGPoint, in selection: CGRect, clicks: Int) -> Bool {
        if let index = selectedMark, annotations.indices.contains(index) {
            let mark = annotations[index]
            if MarkEditing.isOnClose(point, of: mark, within: bounds) {
                removeMark(index)
                return true
            }
            if let handle = MarkEditing.handle(at: point, of: mark) {
                if clicks == 2, mark.bends, handle == 2, mark.bend != nil {
                    // Double-click the bend handle: straight again.
                    let before = annotations
                    redrawMark(index)
                    annotations[index].bend = nil
                    redrawMark(index)
                    commit(before, label: String(localized: "Straighten"))
                    return true
                }
                marksBefore = annotations
                if mark.tool == .blur { prepareBlur() }
                drag = .resizingMark(handle: handle, original: mark)
                return true
            }
        }
        guard selection.contains(point) else {
            selectMark(nil)
            return false
        }
        if state.tool == .eraser {
            selectMark(nil)
            marksBefore = annotations
            eraserStrokes += 1
            drag = .erasing(last: point, stroke: eraserStrokes)
            erase(from: nil, to: point, stroke: eraserStrokes)
            return true
        }
        guard let index = MarkEditing.topmost(at: point, in: annotations) else {
            selectMark(nil)
            return false
        }
        if clicks == 2, annotations[index].tool == .text {
            editText(index)
            return true
        }
        selectMark(index)
        marksBefore = annotations
        if annotations[index].tool == .blur { prepareBlur() }
        drag = .movingMark(last: point)
        NSCursor.closedHand.set()
        return true
    }

    /// Selects a mark (nil: none). The toolbar then shows its color and size, and changing them
    /// changes it.
    private func selectMark(_ index: Int?) {
        guard index != selectedMark else { return }
        redrawMark(selectedMark)
        selectedMark = index
        guard let index, annotations.indices.contains(index) else { return }
        redrawMark(index)
        let mark = annotations[index]
        if mark.tool.usesColor, let color = MarkEditing.colorIndex(of: mark) { state.colorIndex = color }
        if mark.tool != .blur { state.sizeIndex = mark.size }
        announce(String(localized: "Selected: \(mark.tool.title). Delete removes it, arrows move it, Tab selects the next one."))
    }

    private func removeMark(_ index: Int) {
        guard annotations.indices.contains(index) else { return }
        let before = annotations
        redrawMark(index)
        let mark = annotations.remove(at: index)
        selectedMark = nil
        hoveredMark = nil
        commit(before, label: String(localized: "Delete"))
        announce(String(localized: "Removed: \(mark.tool.title)"))
    }

    /// One step of the eraser: only the marks it goes over lose what it covers.
    private func erase(from: CGPoint?, to: CGPoint, stroke: Int) {
        let width = MarkEditing.eraserSizes[state.sizeIndex]
        var touched = false
        for index in annotations.indices where annotations[index].erase(from: from, to: to, width: width, stroke: stroke) {
            touched = true
        }
        guard touched else { return }
        let start = from ?? to
        setNeedsDisplay(CGRect(x: min(start.x, to.x), y: min(start.y, to.y), width: abs(to.x - start.x), height: abs(to.y - start.y))
            .insetBy(dx: -width / 2 - 2, dy: -width / 2 - 2))
    }

    /// The drag ended: marks erased completely go away; the whole drag is one undo step.
    private func finishErasing() {
        guard let before = marksBefore else { return }
        marksBefore = nil
        for index in annotations.indices where annotations[index].isFullyErased { redrawMark(index) }
        annotations.removeAll { $0.isFullyErased }
        let changed = annotations.count != before.count || zip(annotations, before).contains { $0.erasures.count != $1.erasures.count }
        if changed { commit(before, label: CaptureTool.eraser.title) }
    }

    /// The selected mark moved or resized: one undo step.
    private func finishEditing(moved: Bool) {
        guard let before = marksBefore else { return }
        marksBefore = nil
        guard let index = selectedMark, before.indices.contains(index), annotations.indices.contains(index),
              before[index].points != annotations[index].points || before[index].scale != annotations[index].scale
                || before[index].bend != annotations[index].bend else { return }
        commit(before, label: moved ? String(localized: "Move") : String(localized: "Resize"))
    }

    /// Color and size changes go to the selected mark too.
    private func restyleSelectedMark(label: String, applies: (Annotation) -> Bool, _ change: (inout Annotation) -> Void) {
        guard let index = selectedMark, annotations.indices.contains(index), applies(annotations[index]) else { return }
        let before = annotations
        redrawMark(index)
        change(&annotations[index])
        redrawMark(index)
        commit(before, label: label)
    }

    /// Double-click on a text: it is typed again in place.
    private func editText(_ index: Int) {
        let mark = annotations[index]
        textEditBefore = annotations
        textEditOriginal = (mark, index)
        redrawMark(index)
        annotations.remove(at: index)
        selectedMark = nil
        hoveredMark = nil
        if let color = MarkEditing.colorIndex(of: mark) { state.colorIndex = color }
        state.sizeIndex = mark.size
        beginText(at: mark.points.first ?? .zero, text: mark.text, scale: mark.scale)
    }

    /// Keys for marks: Tab selects the next one (⇧ the previous); with one selected, Esc lets it
    /// go, Delete removes it, arrows move it (⇧ by 10, ⌥ make it bigger or smaller). Nil: not ours.
    private func handleMarkKey(_ event: NSEvent, flags: NSEvent.ModifierFlags) -> Bool? {
        if event.keyCode == 48, !annotations.isEmpty, flags.isDisjoint(with: [.control, .option, .command]) {
            let count = annotations.count
            let backward = flags.contains(.shift)
            selectMark(selectedMark.map { ($0 + (backward ? -1 : 1) + count) % count } ?? (backward ? count - 1 : 0))
            return true
        }
        guard let index = selectedMark, annotations.indices.contains(index), !flags.contains(.command) else { return nil }
        switch Int(event.keyCode) {
        case 53:
            selectMark(nil)
            return true
        case 51, 117:
            removeMark(index)
            return true
        case 123, 124, 125, 126:
            let step: CGFloat = flags.contains(.shift) ? 10 : 1
            let delta = CGVector(dx: event.keyCode == 123 ? -step : event.keyCode == 124 ? step : 0,
                                 dy: event.keyCode == 126 ? -step : event.keyCode == 125 ? step : 0)
            let grow = flags.contains(.option)
            let label = grow ? String(localized: "Resize") : String(localized: "Move")
            // Held or repeated arrows make one undo step.
            if !(nudgeStepOpen && undoStack.last?.label == label && Date().timeIntervalSince(lastNudge) < 1) {
                commit(annotations, label: label)
                nudgeStepOpen = true
            }
            lastNudge = Date()
            redrawMark(index)
            if grow { annotations[index] = MarkEditing.grown(annotations[index], by: delta) } else { annotations[index].move(by: delta) }
            if annotations[index].tool == .blur {
                prepareBlur()
                annotations[index].image = blurredPart(annotations[index].rect)
            }
            redrawMark(index)
            announceSoon(grow ? String(localized: "Resized") : String(localized: "Moved"))
            return true
        default:
            return nil
        }
    }

    /// What the selection paints: its border, handles and the size label above it.
    private func selectionArea() -> CGRect {
        guard let selection else { return .null }
        return selection.insetBy(dx: -8, dy: -8)
            .union(CGRect(x: selection.minX - 8, y: selection.minY - 40, width: 160, height: 40))
            .union(CGRect(x: selection.minX, y: selection.minY, width: 160, height: 40))
    }

    override func mouseDragged(with event: NSEvent) {
        let point = clamp(convert(event.locationInWindow, from: nil))
        // Only what changed is redrawn, not the whole screen (R-11).
        let before = selectionArea()
        let beforeMark = current?.bounds ?? .null
        defer {
            let dirty = before.union(selectionArea()).union(beforeMark).union(current?.bounds ?? .null)
            if !dirty.isNull { setNeedsDisplay(dirty) }
        }
        switch drag {
        case .none: return
        case .selecting(let start):
            selection = CGRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(point.x - start.x), height: abs(point.y - start.y))
        case .moving(let offset):
            guard let selection else { return }
            var origin = CGPoint(x: point.x - offset.x, y: point.y - offset.y)
            origin.x = min(max(origin.x, 0), bounds.width - selection.width)
            origin.y = min(max(origin.y, 0), bounds.height - selection.height)
            self.selection?.origin = origin
        case .resizing(let index, let original):
            let (fx, fy) = Self.handles[index]
            var minX = original.minX, maxX = original.maxX, minY = original.minY, maxY = original.maxY
            if fx == 0 { minX = point.x } else if fx == 1 { maxX = point.x }
            if fy == 0 { minY = point.y } else if fy == 1 { maxY = point.y }
            selection = CGRect(x: min(minX, maxX), y: min(minY, maxY), width: max(abs(maxX - minX), 1), height: max(abs(maxY - minY), 1))
        case .drawing:
            guard let tool = current?.tool, let last = current?.points.last else { return }
            switch tool {
            case .pen, .highlighter:
                if hypot(point.x - last.x, point.y - last.y) >= 1.5 { current?.points.append(point) }
            default:
                let snap = (tool == .arrow || tool == .line) && event.modifierFlags.contains(.shift)
                let origin = current?.points.first ?? point
                current?.points[1] = snap ? MarkEditing.snapped(point, from: origin) : point
                if tool == .blur, let rect = current?.rect { current?.image = blurredPart(rect) }
            }
        case .movingMark(let last):
            guard let index = selectedMark, annotations.indices.contains(index) else { return }
            redrawMark(index)
            annotations[index].move(by: CGVector(dx: point.x - last.x, dy: point.y - last.y))
            if annotations[index].tool == .blur { annotations[index].image = blurredPart(annotations[index].rect) }
            redrawMark(index)
            drag = .movingMark(last: point)
        case .resizingMark(let handle, let original):
            guard let index = selectedMark, annotations.indices.contains(index) else { return }
            redrawMark(index)
            annotations[index] = MarkEditing.resized(original, handle: handle, to: point, keepRatio: event.modifierFlags.contains(.shift))
            if annotations[index].tool == .blur { annotations[index].image = blurredPart(annotations[index].rect) }
            redrawMark(index)
        case .erasing(let last, let stroke):
            erase(from: last, to: point, stroke: stroke)
            drag = .erasing(last: point, stroke: stroke)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let finished = drag
        drag = .none
        switch finished {
        case .none: return
        case .selecting:
            if let selection, selection.width >= 4, selection.height >= 4 {
                select(selection)
            } else {
                selection = nil
                needsDisplay = true
            }
        case .moving, .resizing:
            showToolbar()
        case .drawing:
            guard var annotation = current else { return }
            current = nil
            if annotation.tool == .pen || annotation.tool == .highlighter, annotation.points.count == 1 {
                annotation.points.append(annotation.points[0])
            }
            if annotation.isMeaningful { add(annotation) }
            needsDisplay = true
        case .movingMark:
            finishEditing(moved: true)
        case .resizingMark:
            finishEditing(moved: false)
        case .erasing:
            finishErasing()
        }
        let point = convert(event.locationInWindow, from: nil)
        updateHoveredMark(point)
        updateCursor(point)
    }

    private func clamp(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), bounds.width), y: min(max(point.y, 0), bounds.height))
    }

    /// Canvas rect back to global top-left coordinates (CoreGraphics / Accessibility).
    private static func globalFrame(_ rect: CGRect, on screen: NSScreen) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        return rect.offsetBy(dx: screen.frame.minX, dy: primaryHeight - screen.frame.maxY)
    }

    /// The window under the pointer, or the desktop when there's none.
    private func target(at point: CGPoint) -> CaptureTarget? {
        windowRects.first { $0.rect.contains(point) } ?? .desktop(bounds)
    }

    /// Pixels per point of what Copy and Save produce.
    private var outputScale: CGFloat {
        guard let targetImage, let selection, selection.width > 0 else { return scale }
        return CGFloat(targetImage.width) / selection.width
    }

    /// A window or the desktop: taken on its own now (window alone with its rounded corners;
    /// desktop without windows).
    private func select(_ target: CaptureTarget) {
        guard !capturing else { return }
        session?.hideHints()
        if state.recordMode {
            // Nothing to capture now: the window is recorded live.
            hovered = nil
            windowMode = false
            switch target {
            case .window(let id, let rect):
                recordWindow = id
                selectedTarget = target
                selection = rect.intersection(bounds)
            case .desktop:
                recordWindow = nil
                selection = bounds
            }
            needsDisplay = true
            startRecording()
            return
        }
        capturing = true
        hovered = nil
        windowMode = false
        needsDisplay = true
        let screen = screen
        Task { [weak self] in
            let image: CGImage?
            switch target {
            case .window(let id, let rect):
                // Focus it first (behind the frozen screen), so it is captured active, with colored
                // title bar buttons; the previous app gets the focus back when the screenshot closes.
                await WindowFocus.focus(id, frame: Self.globalFrame(rect, on: screen))
                image = try? await ScreenGrabber.captureWindow(id, size: rect.size, scale: screen.backingScaleFactor)
                self?.window?.makeKey()
            case .desktop: image = try? await ScreenGrabber.captureDesktop(screen)
            }
            guard let self else { return }
            self.capturing = false
            guard let image else {
                HUD.shared.show(String(localized: "Couldn't take the screenshot"), symbol: "exclamationmark.triangle.fill",
                                kind: .error, category: .screenshot)
                self.session?.cancel()
                return
            }
            self.targetImage = image
            self.targetNSImage = NSImage(cgImage: image, size: target.rect.size)
            self.selectedTarget = target
            self.selection = target.rect
            self.needsDisplay = true
            self.announceSelection()
            self.showToolbar()
        }
    }

    private func announceSelection() {
        guard let selection else { return }
        announce(String(localized: "Selected \(Int(selection.width * outputScale)) by \(Int(selection.height * outputScale)) pixels. Tools: V, L, R, O, P, H, T, B, E. Copy with Command C, save with Command S."))
    }

    /// The selection is made. In live mode the screen is taken now, without Penknife's windows.
    private func select(_ rect: CGRect) {
        session?.hideHints()
        selection = rect.integral.intersection(bounds)
        hovered = nil
        windowMode = false
        recordWindow = nil
        selectedTarget = nil
        needsDisplay = true
        if state.recordMode {
            // The region IS the choice (R-33): the countdown starts now. Too small: choose again.
            if let selection, selection.width >= 8, selection.height >= 8 {
                startRecording()
            } else {
                selection = nil
            }
            return
        }
        announceSelection()
        guard base == nil, !capturing else { showToolbar(); return }
        capturing = true
        let screen = screen
        Task { [weak self] in
            let image = try? await ScreenGrabber.capture(screen)
            guard let self else { return }
            self.capturing = false
            guard let image else {
                HUD.shared.show(String(localized: "Couldn't take the screenshot"), symbol: "exclamationmark.triangle.fill",
                                kind: .error, category: .screenshot)
                self.session?.cancel()
                return
            }
            self.base = image
            self.scale = CGFloat(image.width) / self.bounds.width
            self.window?.contentView?.layer?.contents = image
            self.window?.contentView?.layer?.contentsGravity = .resize
            self.showToolbar()
        }
    }

    /// What is under the selection, at full resolution: the window/desktop image or the screen.
    private func selectionImage() -> (image: CGImage, scale: CGFloat)? {
        guard let selection else { return nil }
        if let targetImage { return (targetImage, outputScale) }
        guard let base else { return nil }
        let pixels = CGRect(x: selection.minX * scale, y: selection.minY * scale,
                            width: selection.width * scale, height: selection.height * scale).integral
        return base.cropping(to: pixels).map { ($0, scale) }
    }

    private func prepareBlur() {
        guard let selection, blurred?.selection != selection, let source = selectionImage(),
              let image = Annotation.blur(source.image, scale: source.scale, context: ciContext) else { return }
        blurred = (selection, image, source.scale)
    }

    /// The blurred pixels under `rect` (points). Cropping shares memory, it doesn't copy.
    private func blurredPart(_ rect: CGRect) -> CGImage? {
        guard let blurred else { return nil }
        let local = rect.offsetBy(dx: -blurred.selection.minX, dy: -blurred.selection.minY)
        let pixels = CGRect(x: local.minX * blurred.scale, y: local.minY * blurred.scale,
                            width: local.width * blurred.scale, height: local.height * blurred.scale).integral
        return blurred.image.cropping(to: pixels)
    }

    // MARK: Toolbar

    private func showToolbar() {
        guard selection != nil else { return }
        if toolbar == nil {
            let view = NSHostingView(rootView: CaptureToolbar(state: state) { [weak self] in self?.run($0) })
            addSubview(view)
            toolbar = view
        }
        layoutToolbar()
    }

    private func hideToolbar() {
        toolbar?.isHidden = true
    }

    /// Below the selection; above when there's no room; inside its bottom when neither fits.
    private func layoutToolbar() {
        guard let toolbar, let selection else { return }
        let size = toolbar.fittingSize
        var y = selection.maxY + 10
        if y + size.height > bounds.height - 8 {
            y = selection.minY - 10 - size.height
            if y < 8 { y = selection.maxY - size.height - 10 }
        }
        var x = selection.midX - size.width / 2
        x = min(max(x, 8), bounds.width - size.width - 8)
        toolbar.frame = CGRect(x: x, y: max(y, 8), width: size.width, height: size.height)
        toolbar.isHidden = false
    }

    private func run(_ command: CaptureCommand) {
        switch command {
        case .color(let index):
            state.colorIndex = index
            state.expanded = nil
            styleText()
            restyleSelectedMark(label: String(localized: "Color"), applies: { $0.tool.usesColor && $0.color != CapturePalette.colors[index] }) {
                $0.color = CapturePalette.colors[index]
            }
            announce(CapturePalette.name(index))
            relayoutToolbar()
            return
        case .size(let index):
            state.sizeIndex = index
            state.expanded = nil
            textScale = 1
            styleText()
            restyleSelectedMark(label: String(localized: "Size"), applies: { $0.tool != .blur && ($0.size != index || $0.scale != 1) }) {
                $0.size = index
                $0.scale = 1
            }
            announce(CaptureSize.name(index))
            relayoutToolbar()
            return
        case .toggle(let row):
            state.expanded = state.expanded == row ? nil : row
            relayoutToolbar()
            if let textView { window?.makeFirstResponder(textView) }
            return
        case .record:
            session?.enterRecordMode()
            return
        default: break
        }
        endText()
        closeChoices()
        switch command {
        case .undo: undo()
        case .redo: redo()
        case .copy: copyImage()
        case .save: saveImage()
        case .pointer:
            state.tool = nil
            selectMark(nil)
            updateHoveredMark(mouseLocation)
            announce(String(localized: "No tool: drag to move the selection"))
        case .tool(let tool):
            state.tool = state.tool == tool ? nil : tool
            selectMark(nil)
            updateHoveredMark(mouseLocation)
            announce(state.tool.map { $0.title } ?? String(localized: "No tool: drag to move the selection"))
        default: break
        }
    }

    /// Color or size choices close when you do something else.
    private func closeChoices() {
        guard state.expanded != nil else { return }
        state.expanded = nil
        relayoutToolbar()
    }

    /// The scroll wheel changes the size; which way is thicker is a setting.
    private var scrollAccumulator: CGFloat = 0

    override func scrollWheel(with event: NSEvent) {
        guard selection != nil else { return }
        // Physical direction: undo natural scrolling's inversion.
        var delta = event.scrollingDeltaY * (event.isDirectionInvertedFromDevice ? -1 : 1)
        if ScreenshotModule.scrollUpThinner { delta = -delta }
        if event.hasPreciseScrollingDeltas {
            scrollAccumulator += delta
            guard abs(scrollAccumulator) >= 24 else { return }
            delta = scrollAccumulator
            scrollAccumulator = 0
        }
        guard delta != 0 else { return }
        let next = min(max(state.sizeIndex + (delta > 0 ? 1 : -1), 0), CaptureSize.count - 1)
        if next != state.sizeIndex { run(.size(next)) }
    }

    /// The toolbar's width changes when a choice row opens or closes.
    private func relayoutToolbar() {
        DispatchQueue.main.async { [weak self] in self?.layoutToolbar() }
    }

    // MARK: Keyboard

    /// Keys while no text is being typed. Returns false to let the event through.
    func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if event.type == .keyDown, event.isARepeat, [49, 36, 76, 53].contains(Int(event.keyCode)) {
            return true                                         // held Space/Return/Esc: once only
        }
        if !state.recordMode, selection != nil, let handled = handleMarkKey(event, flags: flags) { return handled }
        switch Int(event.keyCode) {
        case 53:                                                // Esc
            session?.cancel()
            return true
        case 49 where selection == nil:                         // Space: window ⇄ area
            guard !capturing else { return true }
            windowMode.toggle()
            hintModel.windowMode = windowMode
            hovered = windowMode ? target(at: mouseLocation) : nil
            needsDisplay = true
            updateCursor(mouseLocation)
            announce(windowMode
                ? String(localized: "Window: click a window, or use the arrows and Return")
                : String(localized: "Area: drag to select, or Return for the whole screen"))
            return true
        case 36, 76:                                            // Return
            if state.recordMode {
                if selection == nil {
                    if let hovered { select(hovered) } else { select(bounds) }
                } else {
                    startRecording()
                }
                return true
            }
            if selection == nil {
                if let hovered { select(hovered) } else { select(bounds) }
            } else if state.tool == .text, textView == nil, let selection {
                beginText(at: CGPoint(x: selection.minX + 12, y: selection.minY + 12))
            } else {
                copyImage()
            }
            return true
        case 123, 124, 125, 126:
            let forward = event.keyCode == 124 || event.keyCode == 125
            guard var rect = selection, !fixedSelection else {
                // Window mode: the arrows go through the windows, front to back, then the desktop.
                guard windowMode, selection == nil else { return true }
                let targets = windowRects + [.desktop(bounds)]
                let index = hovered.flatMap { targets.firstIndex(of: $0) } ?? -1
                let next = (index + (forward ? 1 : -1) + targets.count) % targets.count
                hovered = targets[next]
                needsDisplay = true
                announce(next == targets.count - 1
                    ? String(localized: "Desktop")
                    : String(localized: "Window \(next + 1) of \(windowRects.count)"))
                return true
            }
            let step: CGFloat = flags.contains(.shift) ? 10 : 1
            let dx: CGFloat = event.keyCode == 123 ? -step : event.keyCode == 124 ? step : 0
            let dy: CGFloat = event.keyCode == 126 ? -step : event.keyCode == 125 ? step : 0
            if flags.contains(.option) {
                // ⌥ arrows resize from the bottom-right corner.
                rect.size.width = min(max(rect.width + dx, 8), bounds.width - rect.minX)
                rect.size.height = min(max(rect.height + dy, 8), bounds.height - rect.minY)
            } else {
                rect.origin.x = min(max(rect.minX + dx, 0), bounds.width - rect.width)
                rect.origin.y = min(max(rect.minY + dy, 0), bounds.height - rect.height)
            }
            selection = rect
            layoutToolbar()
            needsDisplay = true
            announceSoon(flags.contains(.option)
                ? String(localized: "\(Int(rect.width * scale)) by \(Int(rect.height * scale)) pixels")
                : String(localized: "Selection moved"))
            return true
        default: break
        }
        if state.recordMode {
            // Record mode has no tools, copy or save.
            return command && key != "q"
        }
        if command {
            switch key {
            case "r" where flags.contains(.shift): run(.record); return true
            case "z": flags.contains(.shift) ? redo() : undo(); return true
            case "c": copyImage(); return true
            case "s": saveImage(); return true
            default: return false
            }
        }
        guard selection != nil, flags.isDisjoint(with: [.control, .option]) else { return false }
        if let tool = CaptureTool.allCases.first(where: { $0.key.lowercased() == key }) {
            run(.tool(tool))
            return true
        }
        if let digit = Int(key), (1...CapturePalette.colors.count).contains(digit) {
            run(.color(digit - 1))
            return true
        }
        if key == "-" {
            run(.size(max(state.sizeIndex - 1, 0)))
            return true
        }
        if key == "+" || key == "=" {
            run(.size(min(state.sizeIndex + 1, CaptureSize.count - 1)))
            return true
        }
        return false
    }

    private var pendingAnnouncement: DispatchWorkItem?

    /// For repeated keys (nudging): one announcement after the keys stop, not one per press.
    private func announceSoon(_ message: String) {
        pendingAnnouncement?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.announce(message) }
        pendingAnnouncement = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private var mouseLocation: CGPoint {
        guard let window else { return .zero }
        return convert(window.mouseLocationOutsideOfEventStream, from: nil)
    }

    // MARK: Record mode (R-29)

    /// The session switched to record mode: with a selection the recording starts now (its
    /// marks go with it); without one, the hint says how to choose what to record.
    func recordModeChanged() {
        endText()
        closeChoices()
        selectMark(nil)
        redrawMark(hoveredMark)
        hoveredMark = nil
        guard selection != nil else {
            hintModel.recording = true
            announce(String(localized: "Record the screen. Drag to select an area, Space to choose a window, Return for the whole screen, Esc to cancel."))
            return
        }
        if targetImage != nil, case .window(let id, _)? = selectedTarget { recordWindow = id }
        startRecording()
    }

    // MARK: Hint (R-33)

    /// Shown after 0.3 s, so quick hands never see it.
    func showHint() {
        guard hintView == nil, !hintDone else { return }
        hintModel.recording = state.recordMode
        // Under the menu bar (and the camera housing).
        let top = max(screen.frame.maxY - screen.visibleFrame.maxY, screen.safeAreaInsets.top) + 12
        let view = PassThroughHostingView(rootView: CaptureHint(model: hintModel))
        view.frame = CGRect(x: 0, y: top, width: bounds.width, height: 44)
        view.autoresizingMask = [.width]
        addSubview(view)
        hintView = view
        let work = DispatchWorkItem { [weak self] in
            guard let self, !hintDone, selection == nil else { return }
            hintModel.visible = true
        }
        hintWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// Gone for good (it fades out) at the first click or choice.
    func hideHint() {
        guard !hintDone else { return }
        hintDone = true
        hintWork?.cancel()
        hintWork = nil
        hintModel.visible = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.hintView?.removeFromSuperview()
            self?.hintView = nil
        }
    }

    private func startRecording() {
        guard state.recordMode, let selection, !capturing, selection.width >= 8, selection.height >= 8 else { return }
        var window: (id: CGWindowID, frame: CGRect)?
        if let recordWindow, case .window(let id, let rect)? = selectedTarget, id == recordWindow {
            window = (id, Self.globalFrame(rect, on: screen))
        }
        session?.record(screen: screen, rect: selection, fullScreen: selection == bounds, window: window,
                       marks: annotations.map { mark in
                           // A blur is blurred live in the recording, not from this screenshot.
                           var mark = mark
                           mark.image = nil
                           mark.liveBlur = mark.tool == .blur
                           return mark
                       })
    }

    // MARK: Text

    /// `text` and `scale`: a text typed again (double-click), with its size.
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
        view.typingAttributes = Annotation.textAttributes(state.color, font: font)
        textSize = state.sizeIndex
        view.insertionPointColor = state.color
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.allowsUndo = true
        view.delegate = self
        view.setAccessibilityLabel(String(localized: "Text"))
        if !text.isEmpty {
            view.string = text
            view.textStorage?.setAttributes(view.typingAttributes, range: NSRange(location: 0, length: view.textStorage?.length ?? 0))
            view.sizeToFit()
        }
        addSubview(view)
        textView = view
        textOrigin = point
        window?.makeFirstResponder(view)
    }

    private var textSize = CaptureSize.defaultIndex
    /// A text made bigger or smaller with its handles keeps that while typed again.
    private var textScale: CGFloat = 1
    private var textFont: NSFont { .systemFont(ofSize: CaptureSize.fontSizes[state.sizeIndex] * textScale, weight: .semibold) }

    /// Color and size apply to the text being typed, all of it.
    private func styleText() {
        guard let view = textView else { return }
        let font = textFont
        let attributes = Annotation.textAttributes(state.color, font: font)
        textSize = state.sizeIndex
        view.typingAttributes = attributes
        view.insertionPointColor = state.color
        view.textStorage?.setAttributes(attributes, range: NSRange(location: 0, length: view.textStorage?.length ?? 0))
        view.minSize = CGSize(width: 40, height: font.boundingRectForFont.height)
        view.sizeToFit()
        window?.makeFirstResponder(view)
    }

    func textDidChange(_ notification: Notification) {
        textView?.sizeToFit()
    }

    /// Esc ends the text (a second Esc cancels the screenshot).
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(cancelOperation(_:)) {
            endText()
            return true
        }
        return false
    }

    private func endText() {
        guard let view = textView else { return }
        textView = nil
        let color = (view.typingAttributes[.foregroundColor] as? NSColor) ?? state.color
        let annotation = Annotation(tool: .text, color: color, size: textSize, points: [textOrigin], text: view.string, scale: textScale)
        view.removeFromSuperview()
        window?.makeFirstResponder(self)
        if let before = textEditBefore {
            // A text typed again goes back to its place and depth; one undo step brings back the
            // old one, and nothing changes when it wasn't changed (QA, 2026-11-17).
            let original = textEditOriginal
            textEditBefore = nil
            textEditOriginal = nil
            let index = min(original?.index ?? annotations.count, annotations.count)
            if let old = original?.mark, annotation.text == old.text, annotation.color == old.color,
               annotation.size == old.size, annotation.scale == old.scale {
                annotations.insert(old, at: index)
            } else {
                if annotation.isMeaningful { annotations.insert(annotation, at: index) }
                commit(before, label: CaptureTool.text.title)
            }
        } else if annotation.isMeaningful {
            add(annotation)
        }
        textScale = 1
        needsDisplay = true
    }

    // MARK: Undo

    private func add(_ annotation: Annotation) {
        let before = annotations
        annotations.append(annotation)
        commit(before, label: annotation.tool.title)
    }

    /// A change was made: `before` is what undo brings back.
    private func commit(_ before: [Annotation], label: String) {
        nudgeStepOpen = false
        undoStack.append((before, label))
        redoStack.removeAll()
        updateUndoState()
    }

    private func undo() {
        guard let last = undoStack.popLast() else { return }
        nudgeStepOpen = false
        redoStack.append((annotations, last.label))
        annotations = last.marks
        selectedMark = nil
        hoveredMark = nil
        updateUndoState()
        needsDisplay = true
        announce(String(localized: "Undone: \(last.label)"))
    }

    private func redo() {
        guard let next = redoStack.popLast() else { return }
        nudgeStepOpen = false
        undoStack.append((annotations, next.label))
        annotations = next.marks
        selectedMark = nil
        hoveredMark = nil
        updateUndoState()
        needsDisplay = true
        announce(String(localized: "Redone: \(next.label)"))
    }

    private func updateUndoState() {
        state.canUndo = !undoStack.isEmpty
        state.canRedo = !redoStack.isEmpty
    }

    // MARK: Output

    /// The selected part of the screen (or the window/desktop alone) with the marks, at full
    /// resolution.
    private func render() -> NSBitmapImageRep? {
        guard let selection, !capturing, let (background, scale) = selectionImage(),
              let context = CGContext(data: nil, width: background.width, height: background.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: background.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.draw(background, in: CGRect(x: 0, y: 0, width: background.width, height: background.height))
        // Same drawing as on screen: flipped, in points, offset to the selection.
        context.translateBy(x: 0, y: CGFloat(background.height))
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -selection.minX, y: -selection.minY)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        for annotation in annotations { annotation.draw() }
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        return rep
    }

    private func copyImage() {
        endText()
        guard let rep = render(), let png = rep.representation(using: .png, properties: [:]) else { return }
        if ScreenshotModule.copiesFile {
            // Also as a file, so ⌘V in a Finder folder creates it; elsewhere it pastes as the image.
            PastableImage.copy(png, named: PastableImage.timestampName { String(localized: "Screenshot \($0) at \($1)") })
        } else {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setData(png, forType: .png)
        }
        announce(String(localized: "Screenshot copied"))
        session?.cancel()
    }

    private func saveImage() {
        endText()
        guard let rep = render(), let png = rep.representation(using: .png, properties: [:]) else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let date = formatter.string(from: .now)
        formatter.dateFormat = "HH.mm.ss"
        let time = formatter.string(from: .now)
        let folder = ScreenshotModule.folder
        var url = folder.appendingPathComponent(String(localized: "Screenshot \(date) at \(time)") + ".png")
        var copyNumber = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent(String(localized: "Screenshot \(date) at \(time)") + " \(copyNumber).png")
            copyNumber += 1
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try png.write(to: url, options: .atomic)
            announce(String(localized: "Screenshot saved"))
            session?.cancel()
        } catch {
            HUD.shared.show(String(localized: "Couldn't save the screenshot"), detail: folder.lastPathComponent,
                            symbol: "exclamationmark.triangle.fill", kind: .error, category: .screenshot)
        }
    }
}

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
    /// R-40: the pin this editor was opened from; hidden while editing, back on every exit.
    private var pinSource: PinnedWindow?
    var editingPin: Bool { pinSource != nil }

    /// `start`: `.record` = opened with the record shortcut (R-29), straight in record mode;
    /// `.pickColor` = opened with the Pick Color shortcut (R-38), straight in the color picker.
    init(mode: ScreenshotMode, images: [CGDirectDisplayID: CGImage], previousApp: NSRunningApplication?, start: CaptureStart = .screenshot,
         onRecord: @escaping (RecordingRequest) -> Void, onFinish: @escaping () -> Void) {
        self.mode = mode
        self.previousApp = previousApp
        self.onRecord = onRecord
        self.onFinish = onFinish
        state.recordMode = start == .record
        state.recordOnly = start == .record
        state.picking = start == .pickColor
        state.pickOnly = start == .pickColor
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
        if state.picking { first?.canvas.pickerChanged(); return }
        first?.canvas.announce(state.recordOnly
            ? String(localized: "Record the screen. Drag to select an area, Space to choose a window, Return for the whole screen, Esc to cancel.")
            : String(localized: "Screenshot. Drag to select an area, Space to choose a window, Return for the whole screen, Esc to cancel. I for the color picker."))
    }

    /// R-38: I or the Pick Color shortcut turns the picker on (off again with I or Esc). Only
    /// before an area is chosen and not while choosing what to record.
    func togglePicker() {
        guard !state.recordMode, !windows.contains(where: { $0.canvas.selection != nil }) else { return }
        state.picking.toggle()
        for window in windows { window.canvas.pickerChanged() }
    }

    /// Record (button, ⇧⌘R, or the record shortcut while the overlay is open): with a selection
    /// the recording starts at once (R-33); without one, choosing a region will start it.
    func enterRecordMode() {
        // An editor opened from a pin has no Record (SS-70).
        guard !state.recordMode, !state.fromPin else { return }
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

    /// SS-70: opens the editor on a pin's screenshot, on the screen the pin is on.
    func edit(_ pin: PinnedWindow) {
        guard !finished else { return }
        pinSource = pin
        state.fromPin = true
        let center = CGPoint(x: pin.imageFrame.midX, y: pin.imageFrame.midY)
        guard let window = windows.first(where: { $0.frame.contains(center) }) ?? windows.first else { return }
        window.makeKey()
        window.canvas.load(pin.capture, at: CGPoint(x: pin.imageFrame.minX, y: pin.imageFrame.maxY))
    }

    /// Pin (SS-67), or an exit from an editor opened on a pin (SS-70): the overlay closes and
    /// the screenshot floats (the same pin, updated, when it came from one).
    func pin(_ capture: PinnedCapture) {
        guard !finished else { return }
        let source = pinSource
        pinSource = nil
        cancel()
        if let source { source.update(capture) } else { PinBoard.shared.add(capture) }
    }

    func cancel() {
        guard !finished else { return }
        finished = true
        // Esc on an editor opened from a pin: the pin comes back as it was.
        pinSource?.reappear()
        pinSource = nil
        for window in windows {
            window.canvas.tearDown()
            window.orderOut(nil)
            window.close()
        }
        windows.removeAll()
        previousApp?.activate()
        onFinish()
    }

    /// Visible windows, front to back, in global top-left coordinates (as CoreGraphics gives
    /// them). Which ones can be chosen: `CaptureGeometry.windowTargets`.
    private static func onScreenWindows() -> [WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds),
                  let id = info[kCGWindowNumber as String] as? CGWindowID else { return nil }
            return WindowInfo(id: id, layer: info[kCGWindowLayer as String] as? Int, ownerPID: info[kCGWindowOwnerPID as String] as? pid_t,
                              alpha: info[kCGWindowAlpha as String] as? Double, bounds: rect)
        }
    }
}

/// Borderless window over one whole screen, above the menu bar and the Dock.
final class CaptureWindow: NSPanel {
    let canvas: CaptureCanvas

    init(screen: NSScreen, image: CGImage?, windowRects: [WindowInfo], session: CaptureSession) {
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
        if firstResponder is NSTextView {
            guard CaptureKeys.reachesMenuWhileTyping(characters: event.charactersIgnoringModifiers,
                                                     flags: event.modifierFlags) else { return true }
        } else if canvas.handleKey(event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Something window mode can select: an app window (captured alone, with its rounded corners)
/// or the desktop (wallpaper and icons, without windows), as macOS does.
nonisolated enum CaptureTarget: Equatable {
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
    /// The marks, the selected one and the undo history (S4).
    private var editor = MarkEditor()
    private var annotations: [Annotation] { editor.marks }
    private var selectedMark: Int? {
        get { editor.selected }
        set { editor.selected = newValue }
    }
    /// R-32: the mark under the pointer, and the eraser drags made so far.
    private var hoveredMark: Int?
    private var eraserStrokes = 0
    private var current: Annotation?
    private var drag: Drag = .none
    private var capturing = false
    /// Copy Text is reading the selection (R-36); a second press waits for it.
    private var readingText = false
    /// Record mode (R-29): the window to record.
    private var recordWindow: CGWindowID?
    private var selectedTarget: CaptureTarget?
    /// R-33: how to choose a region, at the top of the screen until the first click.
    private let hintModel = CaptureHintModel()
    private var hintView: NSView?
    private var hintWork: DispatchWorkItem?
    private var hintDone = false

    private var toolbar: HintTrackingHostingView<CaptureToolbar>?
    /// Every button's key, on demand (SS-62): the pointer over a button, or ⌘ held.
    private let hints = ShortcutHintModel()
    private var hintsView: NSView?
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

    init(screen: NSScreen, image: CGImage?, windowRects: [WindowInfo], session: CaptureSession) {
        self.session = session
        state = session.state
        self.screen = screen
        self.base = image
        scale = image.map { CGFloat($0.width) / screen.frame.width } ?? screen.backingScaleFactor
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        self.windowRects = CaptureGeometry.windowTargets(list: windowRects, ownPID: getpid(), screenFrame: screen.frame, primaryHeight: primaryHeight)
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
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate],
                                       owner: self))
    }

    var hasAnnotations: Bool { !annotations.isEmpty || textView != nil }

    func reset() {
        endText()
        selection = nil
        editor = MarkEditor()
        updateUndoState()
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
        editor = MarkEditor()
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
        pickImage = nil
        loupe = nil
        window?.contentView?.layer?.contents = nil
    }

    func announce(_ message: String) {
        guard let window else { return }
        NSAccessibility.post(element: window, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        // R-38: the screen as it is (not dimmed), so the colors look true, and the loupe.
        if state.picking {
            return
        }
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
            for point in CaptureGeometry.handlePoints(selection) {
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
        let text = CaptureGeometry.sizeText(selection: selection, scale: outputScale)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        let pill = CaptureGeometry.sizeLabelFrame(selection: selection, textSize: size, bounds: bounds)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        string.draw(at: CGPoint(x: pill.minX + 7, y: pill.minY + 3))
    }

    private func handle(at point: CGPoint) -> Int? {
        guard let selection, !fixedSelection else { return nil }
        return CaptureGeometry.handle(at: point, of: selection)
    }

    // MARK: Pointer

    override func cursorUpdate(with event: NSEvent) { updateCursor(convert(event.locationInWindow, from: nil)) }

    /// ⌘ held alone shows every button's key (SS-62).
    override func flagsChanged(with event: NSEvent) {
        hints.modifiersChanged(event.modifierFlags)
        super.flagsChanged(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if state.picking { moveLoupe(to: point); return }
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
        if state.picking {
            (pickImage == nil ? NSCursor.crosshair : ColorLoupe.blankCursor).set()
            return
        }
        if let toolbar, toolbar.frame.contains(point) { NSCursor.arrow.set(); return }
        guard let selection else {
            (windowMode ? NSCursor.pointingHand : NSCursor.crosshair).set()
            return
        }
        if let index = selectedMark, annotations.indices.contains(index) {
            let mark = annotations[index]
            if MarkEditing.isOnClose(point, of: mark, within: bounds)
                || MarkEditing.isOnDuplicate(point, of: mark, within: bounds) { NSCursor.pointingHand.set(); return }
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
        if state.picking {
            pickColor(at: convert(event.locationInWindow, from: nil))
            return
        }
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
            if MarkEditing.isOnDuplicate(point, of: mark, within: bounds) {
                duplicateMark(index)
                return true
            }
            if let handle = MarkEditing.handle(at: point, of: mark) {
                if clicks == 2, mark.bends, handle == 2, mark.bend != nil {
                    // Double-click the bend handle: straight again.
                    redrawMark(index)
                    editor.straighten(at: index)
                    redrawMark(index)
                    updateUndoState()
                    return true
                }
                editor.beginDrag()
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
            editor.beginDrag()
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
        editor.beginDrag()
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

    /// A shape's key (O-15): that tool goes on (a drag then draws it too) and its mark goes in
    /// the middle of the selection, selected, so the arrows move it and ⌥ arrows change its tip
    /// or size (SS-38).
    private func placeMark(_ tool: CaptureTool) {
        guard let selection, CaptureKeys.placeable.contains(tool) else { return }
        endText()
        closeChoices()
        state.tool = tool
        let ends = CaptureGeometry.placedMark(tool, in: selection)
        var mark = Annotation(tool: tool, color: state.color, size: state.sizeIndex, points: [ends.start, ends.end])
        if tool == .blur {
            prepareBlur()
            mark.image = blurredPart(mark.rect)
        }
        add(mark)
        selectedMark = nil
        selectMark(annotations.count - 1)
        needsDisplay = true
        announce(tool == .arrow || tool == .line
            ? String(localized: "\(tool.title) placed in the middle. Arrows move it, Option arrows move its tip.")
            : String(localized: "\(tool.title) placed in the middle. Arrows move it, Option arrows change its size."))
    }

    /// A copy of the mark next to it (12 pt down and right, inside the selection), selected, so
    /// the arrows place it (user, 2026-11-19: "duplicar elementos … con un botón y un sc").
    private func duplicateMark(_ index: Int) {
        guard annotations.indices.contains(index) else { return }
        redrawMark(index)
        let offset = MarkEditing.duplicateOffset(annotations[index], in: selection ?? bounds)
        editor.duplicate(index, offset: offset)
        let copy = annotations.count - 1
        if annotations[copy].tool == .blur {
            prepareBlur()
            let image = blurredPart(annotations[copy].rect)
            editor.change(copy) { $0.image = image }
        }
        updateUndoState()
        redrawMark(copy)
        announce(String(localized: "Duplicated: \(annotations[copy].tool.title)"))
    }

    private func removeMark(_ index: Int) {
        guard annotations.indices.contains(index) else { return }
        redrawMark(index)
        guard let mark = editor.remove(at: index) else { return }
        hoveredMark = nil
        updateUndoState()
        announce(String(localized: "Removed: \(mark.tool.title)"))
    }

    /// One step of the eraser: only the marks it goes over lose what it covers.
    private func erase(from: CGPoint?, to: CGPoint, stroke: Int) {
        let width = MarkEditing.eraserSizes[state.sizeIndex]
        guard editor.erase(from: from, to: to, width: width, stroke: stroke) else { return }
        let start = from ?? to
        setNeedsDisplay(CGRect(x: min(start.x, to.x), y: min(start.y, to.y), width: abs(to.x - start.x), height: abs(to.y - start.y))
            .insetBy(dx: -width / 2 - 2, dy: -width / 2 - 2))
    }

    /// The drag ended: marks erased completely go away; the whole drag is one undo step.
    private func finishErasing() {
        for mark in editor.finishErasing() { setNeedsDisplay(MarkEditing.area(mark)) }
        updateUndoState()
    }

    /// The selected mark moved or resized: one undo step.
    private func finishEditing(moved: Bool) {
        editor.finishEditing(moved: moved)
        updateUndoState()
    }

    /// Color and size changes go to the selected mark too.
    private func restyleSelectedMark(label: String, applies: (Annotation) -> Bool, _ change: (inout Annotation) -> Void) {
        guard let index = selectedMark, annotations.indices.contains(index), applies(annotations[index]) else { return }
        redrawMark(index)
        _ = editor.restyleSelected(label: label, applies: applies, change)
        redrawMark(index)
        updateUndoState()
    }

    /// Double-click on a text: it is typed again in place.
    private func editText(_ index: Int) {
        redrawMark(index)
        let mark = editor.beginTextEdit(index)
        hoveredMark = nil
        if let color = MarkEditing.colorIndex(of: mark) { state.colorIndex = color }
        state.sizeIndex = mark.size
        beginText(at: mark.points.first ?? .zero, text: mark.text, scale: mark.scale)
    }

    /// Arrows on the selected mark: move it, or (⌥) make it bigger or smaller.
    private func nudgeMark(_ index: Int, by delta: CGVector, grow: Bool) {
        let label = grow ? String(localized: "Resize") : String(localized: "Move")
        redrawMark(index)
        editor.nudge(index, label: label, now: Date()) { mark in
            if grow { mark = MarkEditing.grown(mark, by: delta) } else { mark.move(by: delta) }
        }
        updateUndoState()
        if annotations[index].tool == .blur {
            prepareBlur()
            let image = blurredPart(annotations[index].rect)
            editor.change(index) { $0.image = image }
        }
        redrawMark(index)
        announceSoon(grow ? String(localized: "Resized") : String(localized: "Moved"))
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
            selection = CaptureGeometry.dragRect(from: start, to: point)
        case .moving(let offset):
            guard let selection else { return }
            self.selection = CaptureGeometry.moved(selection, to: CGPoint(x: point.x - offset.x, y: point.y - offset.y), bounds: bounds)
        case .resizing(let index, let original):
            selection = CaptureGeometry.resizeSelection(handle: index, original: original, to: point)
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
            editor.change(index) { $0.move(by: CGVector(dx: point.x - last.x, dy: point.y - last.y)) }
            refreshBlur(index)
            redrawMark(index)
            drag = .movingMark(last: point)
        case .resizingMark(let handle, let original):
            guard let index = selectedMark, annotations.indices.contains(index) else { return }
            redrawMark(index)
            let resized = MarkEditing.resized(original, handle: handle, to: point, keepRatio: event.modifierFlags.contains(.shift))
            editor.change(index) { $0 = resized }
            refreshBlur(index)
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
            if let selection, CaptureGeometry.keepsDrag(selection) {
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
        CaptureGeometry.clamp(point, to: bounds)
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
        selection = CaptureGeometry.chosen(rect, bounds: bounds)
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
            let view = HintTrackingHostingView(rootView: CaptureToolbar(state: state, hints: hints) { [weak self] in self?.run($0) })
            view.hints = hints
            addSubview(view)
            toolbar = view
            let above = PassThroughHostingView(rootView: ShortcutHints(model: hints))
            addSubview(above)
            hintsView = above
        }
        layoutToolbar()
    }

    private func hideToolbar() {
        toolbar?.isHidden = true
        hintsView?.isHidden = true
        hints.reset()
    }

    /// Below the selection; above when there's no room; inside its bottom when neither fits.
    private func layoutToolbar() {
        guard let toolbar, let selection else { return }
        toolbar.frame = CaptureGeometry.toolbarFrame(selection: selection, size: toolbar.fittingSize, bounds: bounds)
        toolbar.isHidden = false
        // Right above the toolbar (this view is flipped: up is a smaller y).
        let room = ShortcutHintModel.headroom, side = ShortcutHintModel.overhang
        hintsView?.frame = CGRect(x: toolbar.frame.minX - side, y: toolbar.frame.minY - room,
                                  width: toolbar.frame.width + side * 2, height: room)
        hintsView?.isHidden = false
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
        case .pin where state.recordMode:
            return
        default: break
        }
        endText()
        closeChoices()
        switch command {
        case .undo: undo()
        case .redo: redo()
        case .copy: copyImage()
        case .copyText: copyText()
        case .save: saveImage()
        case .pin: pinImage()
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
        let (step, accumulated) = CaptureGeometry.scrollStep(
            delta: event.scrollingDeltaY, inverted: event.isDirectionInvertedFromDevice, precise: event.hasPreciseScrollingDeltas,
            accumulated: scrollAccumulator, upThinner: ScreenshotModule.scrollUpThinner)
        scrollAccumulator = accumulated
        guard step != 0 else { return }
        let next = min(max(state.sizeIndex + step, 0), CaptureSize.count - 1)
        if next != state.sizeIndex { run(.size(next)) }
    }

    /// The toolbar's width changes when a choice row opens or closes.
    private func relayoutToolbar() {
        DispatchQueue.main.async { [weak self] in self?.layoutToolbar() }
    }

    // MARK: Keyboard

    /// Keys while no text is being typed. Returns false to let the event through.
    func handleKey(_ event: NSEvent) -> Bool {
        hints.keyPressed()
        let context = CaptureKeyContext(
            hasSelection: selection != nil, recordMode: state.recordMode, fixedSelection: fixedSelection,
            windowMode: windowMode, capturing: capturing, typing: textView != nil, tool: state.tool,
            markCount: annotations.count, selectedMark: selectedMark, sizeIndex: state.sizeIndex,
            sizesOpen: state.expanded == .sizes, picking: state.picking, pickOnly: state.pickOnly)
        guard let action = CaptureKeys.action(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers,
                                              flags: event.modifierFlags, isRepeat: event.type == .keyDown && event.isARepeat,
                                              context: context) else { return false }
        perform(action)
        return true
    }

    private func perform(_ action: CaptureKeyAction) {
        switch action {
        case .swallow: break
        case .selectMark(let index): selectMark(index)
        case .deselectMark: selectMark(nil)
        case .removeMark(let index): removeMark(index)
        case .duplicateMark(let index): duplicateMark(index)
        case .nudgeMark(let index, let delta, let grow): nudgeMark(index, by: delta, grow: grow)
        case .cancel: session?.cancel()
        case .toggleWindowMode:
            windowMode.toggle()
            hintModel.windowMode = windowMode
            hovered = windowMode ? target(at: mouseLocation) : nil
            needsDisplay = true
            updateCursor(mouseLocation)
            announce(windowMode
                ? String(localized: "Window: click a window, or use the arrows and Return")
                : String(localized: "Area: drag to select, or Return for the whole screen"))
        case .choose:
            if let hovered { select(hovered) } else { select(bounds) }
        case .startRecording: startRecording()
        case .beginText:
            if let selection { beginText(at: CGPoint(x: selection.minX + 12, y: selection.minY + 12)) }
        case .placeMark(let tool): placeMark(tool)
        case .copy: copyImage()
        case .copyText: copyText()
        case .save: saveImage()
        case .pin: pinImage()
        case .undo: undo()
        case .redo: redo()
        case .record: run(.record)
        case .nextTarget(let forward):
            let targets = windowRects + [.desktop(bounds)]
            let index = hovered.flatMap { targets.firstIndex(of: $0) }
            let next = CaptureGeometry.nextTarget(current: index, count: targets.count, forward: forward)
            hovered = targets[next]
            needsDisplay = true
            announce(next == targets.count - 1
                ? String(localized: "Desktop")
                : String(localized: "Window \(next + 1) of \(windowRects.count)"))
        case .nudgeSelection(let dx, let dy, let resize):
            guard let rect = selection else { return }
            let moved = CaptureGeometry.nudge(selection: rect, dx: dx, dy: dy, resize: resize, bounds: bounds)
            selection = moved
            layoutToolbar()
            needsDisplay = true
            announceSoon(resize
                ? String(localized: "\(Int(moved.width * scale)) by \(Int(moved.height * scale)) pixels")
                : String(localized: "Selection moved"))
        case .tool(let tool): run(.tool(tool))
        case .pointer: run(.pointer)
        case .toggleRow(let row): run(.toggle(row))
        case .color(let index): run(.color(index))
        case .size(let index): run(.size(index))
        case .togglePicker: session?.togglePicker()
        case .pickColor: pickColor(at: loupe?.pointer ?? mouseLocation)
        case .movePointer(let dx, let dy): movePointer(dx: dx, dy: dy)
        }
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

    // MARK: Color picker (R-38)

    /// The screen in sRGB, which is what the picker reads: ScreenCaptureKit's default image has
    /// no color space, and read as sRGB its colors were off (#15ABEF for #12ABEF, 2026-11-22).
    private var pickImage: CGImage?
    /// The loupe, a small view of its own: moving it redraws only it, and its shadow is the GPU's.
    private var loupe: LoupeView?

    override func mouseExited(with event: NSEvent) {
        guard state.picking else { return }
        moveLoupe(to: nil)
    }

    /// The picker went on or off: the dimming, the hint and the shown screen change.
    func pickerChanged() {
        hintModel.picking = state.picking
        hintModel.pickOnly = state.pickOnly
        if state.picking {
            windowMode = false
            hintModel.windowMode = false
            hovered = nil
            if window?.isKeyWindow == true {
                announce(state.pickOnly
                    ? String(localized: "Color picker. Move the pointer, click or press Return to copy the color, Esc to cancel.")
                    : String(localized: "Color picker. Move the pointer, click or press Return to copy the color, Esc to go back."))
            }
            // Opened by Pick Color, the frozen screen was taken in sRGB already.
            if pickImage == nil, state.pickOnly { pickImage = base }
            if pickImage == nil { grabForPicker() } else { show(pickImage) }
        } else {
            if window?.isKeyWindow == true { announce(String(localized: "Screenshot")) }
            show(base)
        }
        let point = mouseLocation
        moveLoupe(to: state.picking && bounds.contains(point) ? point : nil)
        needsDisplay = true
        updateCursor(point)
    }

    /// What is seen is what is picked: the picker shows its own image while it is on.
    private func show(_ image: CGImage?) {
        window?.contentView?.layer?.contents = image
        window?.contentView?.layer?.contentsGravity = .resize
    }

    /// The screen as it is now, in sRGB (the overlay itself is left out).
    private func grabForPicker() {
        guard !capturing else { return }
        capturing = true
        let screen = screen
        Task { [weak self] in
            let image = try? await ScreenGrabber.capture(screen, sRGB: true)
            guard let self else { return }
            self.capturing = false
            guard let image else {
                HUD.shared.show(String(localized: "Couldn't take the screenshot"), symbol: "exclamationmark.triangle.fill",
                                kind: .error, category: .screenshot)
                self.session?.cancel()
                return
            }
            self.pickImage = image
            guard self.state.picking else { return }
            self.show(image)
            let point = self.mouseLocation
            if self.bounds.contains(point) { self.moveLoupe(to: point) }
            self.updateCursor(point)
        }
    }

    private var pickScale: CGFloat { pickImage.map { CGFloat($0.width) / bounds.width } ?? scale }

    private func moveLoupe(to point: CGPoint?) {
        guard let point, let pickImage else {
            loupe?.removeFromSuperview()
            loupe = nil
            return
        }
        let view = loupe ?? LoupeView()
        if loupe == nil {
            addSubview(view)
            loupe = view
        }
        view.show(pointer: point, image: pickImage, scale: pickScale, in: bounds)
    }

    /// Arrows: the pointer moves by device pixels, for exact picking without a mouse (R-19).
    private func movePointer(dx: Int, dy: Int) {
        guard let window, let screen = window.screen else { return }
        let start = loupe?.pointer ?? mouseLocation
        let point = clamp(CGPoint(x: start.x + CGFloat(dx) / pickScale, y: start.y + CGFloat(dy) / pickScale))
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        CGWarpMouseCursorPosition(CGPoint(x: screen.frame.minX + point.x, y: primaryHeight - screen.frame.maxY + point.y))
        CGAssociateMouseAndMouseCursorPosition(1)
        moveLoupe(to: point)
        if let hex = loupe?.hex { announceSoon(hex) }
    }

    /// Copies the hex and closes, as Copy does (no visible confirmation, O-12).
    private func pickColor(at point: CGPoint) {
        guard let pickImage else { return }
        let pixel = ColorSample.pixel(point, scale: pickScale)
        guard let hex = ColorSample.hex(in: pickImage, x: pixel.x, y: pixel.y) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(hex, forType: .string)
        announce(String(localized: "Color \(hex) copied"))
        session?.cancel()
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
        guard state.recordMode, let selection, !capturing else { return }
        let region = CaptureGeometry.recordRegion(selection, bounds: bounds)
        guard region.width >= 8, region.height >= 8 else { return }
        var window: (id: CGWindowID, frame: CGRect)?
        if let recordWindow, case .window(let id, let rect)? = selectedTarget, id == recordWindow {
            window = (id, Self.globalFrame(rect, on: screen))
        }
        session?.record(screen: screen, rect: region, fullScreen: region == bounds, window: window,
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
        // A text typed again goes back to its place and depth; one undo step brings back the old
        // one, and nothing changes when it wasn't changed (QA, 2026-11-17).
        editor.endText(annotation)
        updateUndoState()
        textScale = 1
        needsDisplay = true
    }

    // MARK: Undo

    private func add(_ annotation: Annotation) {
        editor.add(annotation)
        updateUndoState()
    }

    /// A blur mark that moved or changed size shows the blurred screen under its new place.
    private func refreshBlur(_ index: Int) {
        guard annotations[index].tool == .blur else { return }
        let image = blurredPart(annotations[index].rect)
        editor.change(index) { $0.image = image }
    }

    private func undo() {
        guard let label = editor.undo() else { return }
        hoveredMark = nil
        updateUndoState()
        needsDisplay = true
        announce(String(localized: "Undone: \(label)"))
    }

    private func redo() {
        guard let label = editor.redo() else { return }
        hoveredMark = nil
        updateUndoState()
        needsDisplay = true
        announce(String(localized: "Redone: \(label)"))
    }

    private func updateUndoState() {
        state.canUndo = editor.canUndo
        state.canRedo = editor.canRedo
    }

    // MARK: Output

    /// The selected part of the screen (or the window/desktop alone) with the marks, at full
    /// resolution.
    private func render() -> (image: CGImage, scale: CGFloat)? {
        guard let selection, !capturing, let (background, scale) = selectionImage(),
              let image = CaptureRender.image(background: background, scale: scale, selection: selection, marks: annotations)
        else { return nil }
        return (image, scale)
    }

    /// Copy, Copy Text and Save close the editor; opened from a pin, the pin comes back with the
    /// changes (SS-70).
    private func finish() {
        if session?.editingPin == true, let capture = pinCapture() {
            session?.pin(capture)
        } else {
            session?.cancel()
        }
    }

    private func copyImage() {
        endText()
        guard let (image, scale) = render(), let png = CaptureOutput.png(image, scale: scale) else { return }
        CaptureOutput.copy(png)
        announce(String(localized: "Screenshot copied"))
        finish()
    }

    /// R-36: reads the text of the output image (marks included, so blurred text stays hidden)
    /// with Vision on the Mac, puts it on the clipboard as plain text and closes. Nothing found:
    /// an alert, and the screenshot stays open.
    private func copyText() {
        endText()
        guard !readingText, let (image, _) = render() else { return }
        readingText = true
        announce(String(localized: "Reading text…"))
        Task { [weak self] in
            let found = await CaptureOutput.copyText(image)
            guard let self else { return }
            self.readingText = false
            guard found else { return }
            self.announce(String(localized: "Text copied"))
            self.finish()
        }
    }

    private func saveImage() {
        endText()
        guard let (image, scale) = render(), let png = CaptureOutput.png(image, scale: scale) else { return }
        guard CaptureOutput.save(png) else { return }
        announce(String(localized: "Screenshot saved"))
        finish()
    }

    // MARK: Pin (R-40)

    /// Pin (button, ⌘P): the editor closes and the screenshot floats where it was taken.
    private func pinImage() {
        endText()
        guard let capture = pinCapture() else { return }
        announce(String(localized: "Screenshot pinned"))
        session?.pin(capture)
    }

    /// Everything a pin needs to show the screenshot and to open it again with its marks: the
    /// background on its own (a crop would keep the whole frozen screen alive), the marks and
    /// where it sits on the screen.
    private func pinCapture() -> PinnedCapture? {
        guard let selection, !capturing, let (background, scale) = selectionImage(),
              let alone = CaptureRender.image(background: background, scale: scale, selection: selection, marks: []),
              let image = CaptureRender.image(background: background, scale: scale, selection: selection, marks: annotations)
        else { return nil }
        let frame = CGRect(x: screen.frame.minX + selection.minX, y: screen.frame.maxY - selection.maxY,
                           width: selection.width, height: selection.height)
        return PinnedCapture(background: alone, image: image, scale: scale, selection: selection, marks: annotations, frame: frame)
    }

    /// SS-70: the editor opened on a pin: its image as a fixed selection at the pin's place (its
    /// original size), the marks moved along and still editable.
    func load(_ capture: PinnedCapture, at origin: CGPoint) {
        let size = capture.selection.size
        var rect = CGRect(x: origin.x - screen.frame.minX, y: screen.frame.maxY - origin.y,
                          width: size.width, height: size.height)
        rect.origin.x = min(max(rect.minX, 0), max(bounds.width - size.width, 0))
        rect.origin.y = min(max(rect.minY, 0), max(bounds.height - size.height, 0))
        let delta = CGVector(dx: rect.minX - capture.selection.minX, dy: rect.minY - capture.selection.minY)
        editor = MarkEditor(marks: capture.marks.map { var mark = $0; mark.move(by: delta); return mark })
        updateUndoState()
        session?.hideHints()
        targetImage = capture.background
        targetNSImage = NSImage(cgImage: capture.background, size: size)
        selection = rect
        needsDisplay = true
        announceSelection()
        showToolbar()
    }
}

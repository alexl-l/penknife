import AppKit

/// A pinned screenshot (R-40, SS-67…72): the finished image, and what the editor needs to open
/// it again with its marks still editable.
struct PinnedCapture {
    /// The selected part alone, without marks, at `scale` pixels per point.
    let background: CGImage
    /// The image with its marks, as Copy would give it.
    let image: CGImage
    let scale: CGFloat
    /// Where the selection was on its screen when pinned (canvas points); the marks are stored
    /// relative to it.
    let selection: CGRect
    let marks: [Annotation]
    /// Where the pin first appears, in global screen coordinates: exactly over the capture.
    let frame: CGRect

    var size: CGSize { selection.size }

    /// SS-69: the size a resize may give it, keeping its proportions: at least 64 pt on the short
    /// side, at most twice the original and the screen's visible frame.
    static func clampedSize(_ proposed: CGSize, original: CGSize, visible: CGSize) -> CGSize {
        guard original.width > 0, original.height > 0 else { return original }
        let ratio = original.width / original.height
        let shortest: CGFloat = 64
        // A capture already smaller than 64 pt can't be made smaller than it is.
        let minWidth = min(ratio >= 1 ? shortest * ratio : shortest, original.width)
        let maxWidth = max(min(original.width * 2, visible.width, visible.height * ratio), minWidth)
        let width = min(max(proposed.width, minWidth), maxWidth)
        return CGSize(width: width, height: width / ratio)
    }
}

/// Where a new pin goes (SS-73; user, 2026-11-23: "por defecto, se mueva a la esquina inferior
/// izquierda, pero el usuario puede elegir a qué esquina … o si se queda donde hiciste la captura").
enum PinPlace: String, CaseIterable {
    case bottomLeft, bottomRight, topLeft, topRight, captured

    static let key = "screenshot.pinPlace"
    static func current(in defaults: UserDefaults) -> Self {
        Self(rawValue: defaults.string(forKey: key) ?? "") ?? .bottomLeft
    }

    var title: String {
        switch self {
        case .bottomLeft: String(localized: "Bottom left")
        case .bottomRight: String(localized: "Bottom right")
        case .topLeft: String(localized: "Top left")
        case .topRight: String(localized: "Top right")
        case .captured: String(localized: "Where captured")
        }
    }

    static let margin: CGFloat = 16
    static let gap: CGFloat = 8

    /// The pin's frame (global, y up) in `visible` (the screen's visible frame): in its corner,
    /// 16 pt in, stacked past the `others` it would cover (upwards from a bottom corner,
    /// downwards from a top one). No room left: the corner itself.
    func frame(for size: CGSize, captured: CGRect, visible: CGRect, others: [CGRect]) -> CGRect {
        if self == .captured { return CGRect(origin: captured.origin, size: size) }
        let left = self == .bottomLeft || self == .topLeft
        let bottom = self == .bottomLeft || self == .bottomRight
        let x = left ? visible.minX + Self.margin : visible.maxX - Self.margin - size.width
        let corner = CGRect(x: x, y: bottom ? visible.minY + Self.margin : visible.maxY - Self.margin - size.height,
                            width: size.width, height: size.height)
        var rect = corner
        while let blocker = others.first(where: { $0.intersects(rect) }) {
            rect.origin.y = bottom ? blocker.maxY + Self.gap : blocker.minY - Self.gap - size.height
            if rect.minY < visible.minY || rect.maxY > visible.maxY { return corner }
        }
        return rect
    }
}

/// The open pins. They live in memory only: gone when Penknife quits or the module turns off.
@MainActor
final class PinBoard {
    static let shared = PinBoard()
    private(set) var pins: [PinnedWindow] = []
    /// Double-click or Edit: the module opens the editor on it (SS-70).
    var edit: ((PinnedWindow) -> Void)?

    /// A new pin appears over the capture and glides to its place (SS-73; no glide under Reduce
    /// Motion).
    func add(_ capture: PinnedCapture, defaults: UserDefaults = .standard) {
        let pin = PinnedWindow(capture: capture)
        let center = CGPoint(x: capture.frame.midX, y: capture.frame.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main
        let target = PinPlace.current(in: defaults).frame(for: capture.frame.size, captured: capture.frame,
                                                          visible: screen?.visibleFrame ?? capture.frame,
                                                          others: pins.filter(\.isVisible).map(\.frame))
        pins.append(pin)
        pin.orderFrontRegardless()
        guard target != capture.frame else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            pin.setFrame(target, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            pin.animator().setFrame(target, display: true)
        }
    }

    func remove(_ pin: PinnedWindow) {
        pins.removeAll { $0 === pin }
    }

    func closeAll() {
        for pin in pins { pin.orderOut(nil); pin.close() }
        pins.removeAll()
    }
}

/// A borderless floating panel with the screenshot. Never activates Penknife: clicking it makes
/// it take the keys (Esc, ⌘C) without taking the front app's active look.
final class PinnedWindow: NSPanel {
    private(set) var capture: PinnedCapture
    private let view: PinnedView

    init(capture: PinnedCapture) {
        self.capture = capture
        view = PinnedView(frame: CGRect(origin: .zero, size: capture.frame.size))
        super.init(contentRect: capture.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = false
        contentView = view
        view.pin = self
        view.image = capture.image
        setAccessibilityLabel(String(localized: "Pinned screenshot"))
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// The editor gave it back changed (SS-70): new image, its top-left corner at the editor's
    /// place, the size the pin had (a resized pin stays resized).
    func update(_ capture: PinnedCapture) {
        self.capture = capture
        view.image = capture.image
        let size = frame.size
        setFrame(CGRect(x: capture.frame.minX, y: capture.frame.maxY - size.height, width: size.width, height: size.height), display: true)
        reappear()
    }

    /// Back on screen after the editor closed.
    func reappear() {
        orderFrontRegardless()
        invalidateShadow()
    }

    /// The frame for a proposed size, kept in proportion, anchored at `anchor` (the corner that
    /// doesn't move while resizing).
    func resize(to proposed: CGSize, anchor: CGPoint, growsLeft: Bool, growsDown: Bool) {
        let visible = (screen ?? NSScreen.main)?.visibleFrame.size ?? proposed
        let size = PinnedCapture.clampedSize(proposed, original: capture.size, visible: visible)
        let origin = CGPoint(x: growsLeft ? anchor.x - size.width : anchor.x,
                             y: growsDown ? anchor.y - size.height : anchor.y)
        setFrame(CGRect(origin: origin, size: size), display: true)
        invalidateShadow()
    }

    // MARK: Actions (SS-71)

    @objc func copyPin() {
        guard let png = CaptureOutput.png(capture.image, scale: capture.scale) else { return }
        CaptureOutput.copy(png)
        announce(String(localized: "Screenshot copied"))
    }

    @objc func copyTextPin() {
        let image = capture.image
        Task {
            if await CaptureOutput.copyText(image) { self.announce(String(localized: "Text copied")) }
        }
    }

    @objc func savePin() {
        guard let png = CaptureOutput.png(capture.image, scale: capture.scale), CaptureOutput.save(png) else { return }
        announce(String(localized: "Screenshot saved"))
    }

    private func announce(_ message: String) {
        NSAccessibility.post(element: self, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    @objc func editPin() {
        PinBoard.shared.edit?(self)
    }

    @objc func closePin() {
        orderOut(nil)
        close()
        PinBoard.shared.remove(self)
    }

    override func cancelOperation(_ sender: Any?) { closePin() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "c" {
            copyPin()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        [NSAccessibilityCustomAction(name: String(localized: "Copy"), target: self, selector: #selector(copyPin)),
         NSAccessibilityCustomAction(name: String(localized: "Edit Screenshot"), target: self, selector: #selector(editPin)),
         NSAccessibilityCustomAction(name: String(localized: "Close"), target: self, selector: #selector(closePin))]
    }
}

/// The image with rounded corners and a hairline border; a ✕ on hover; drag moves it, the edges
/// resize it (12 pt, corners 24 pt), double-click edits it, right-click shows its menu.
final class PinnedView: NSView {
    weak var pin: PinnedWindow?
    var image: CGImage? {
        didSet { imageLayer.contents = image }
    }

    private let imageLayer = CALayer()
    private let closeButton = PinCloseButton()
    private enum Drag { case none, move, resize(left: Bool, right: Bool, bottom: Bool, top: Bool, start: CGPoint, frame: CGRect) }
    private var drag: Drag = .none

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        imageLayer.contentsGravity = .resize
        imageLayer.cornerCurve = .continuous
        imageLayer.masksToBounds = true
        imageLayer.borderWidth = 0.5
        layer?.addSublayer(imageLayer)
        closeButton.alphaValue = 0
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        addSubview(closeButton)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(String(localized: "Pinned screenshot"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        imageLayer.cornerRadius = min(bounds.width, bounds.height) < 40 ? 6 : 10
        imageLayer.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
        // 24 pt target, the 16 pt glyph still 8 pt in (designer).
        closeButton.frame = CGRect(x: 4, y: 4, width: 24, height: 24)
        updateBorder()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorder()
    }

    private func updateBorder() {
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        effectiveAppearance.performAsCurrentDrawingAppearance {
            imageLayer.borderColor = NSColor.labelColor.withAlphaComponent(contrast ? 1 : 0.15).cgColor
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, trackingAreas.isEmpty else { return }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate],
                                       owner: self))
    }

    // MARK: Hover ✕

    override func mouseEntered(with event: NSEvent) { showClose(true) }
    override func mouseExited(with event: NSEvent) {
        if case .none = drag { showClose(false) }
    }

    private func showClose(_ shown: Bool) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            closeButton.alphaValue = shown ? 1 : 0
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            closeButton.animator().alphaValue = shown ? 1 : 0
        }
    }

    @objc private func closeClicked() { pin?.closePin() }

    // MARK: Resize cursors (SS-69)

    /// Resize zones (user, 2026-11-23: "el borde para hacer re-size es muy pequeño"): 12 pt along
    /// each edge and 24 pt squares at the corners, smaller on a small pin so it can still be
    /// moved. The top-left corner keeps only its edges: the ✕ sits there.
    private var zones: (edge: CGFloat, corner: CGFloat) {
        let short = min(bounds.width, bounds.height)
        return (min(12, short / 6), min(24, short / 4))
    }

    /// Which sides a point drags: left, right, top, bottom (none = move).
    private func sides(at p: CGPoint) -> (left: Bool, right: Bool, top: Bool, bottom: Bool) {
        let (e, c) = zones, b = bounds
        var left = p.x < e, right = p.x > b.width - e, top = p.y < e, bottom = p.y > b.height - e
        let nearLeft = p.x < c, nearRight = p.x > b.width - c, nearTop = p.y < c, nearBottom = p.y > b.height - c
        if nearRight && nearTop { right = true; top = true }
        if nearLeft && nearBottom { left = true; bottom = true }
        if nearRight && nearBottom { right = true; bottom = true }
        return (left, right, top, bottom)
    }

    override func resetCursorRects() {
        let (e, c) = zones, b = bounds
        let nwse = NSCursor.frameResize(position: .topLeft, directions: .all)
        let nesw = NSCursor.frameResize(position: .topRight, directions: .all)
        // Corners first: where rectangles overlap, the first one added wins.
        addCursorRect(CGRect(x: b.width - c, y: 0, width: c, height: c), cursor: nesw)
        addCursorRect(CGRect(x: 0, y: b.height - c, width: c, height: c), cursor: nesw)
        addCursorRect(CGRect(x: b.width - c, y: b.height - c, width: c, height: c), cursor: nwse)
        addCursorRect(CGRect(x: 0, y: 0, width: e, height: e), cursor: nwse)
        addCursorRect(CGRect(x: 0, y: e, width: e, height: b.height - e - c), cursor: .resizeLeftRight)
        addCursorRect(CGRect(x: b.width - e, y: c, width: e, height: b.height - 2 * c), cursor: .resizeLeftRight)
        addCursorRect(CGRect(x: e, y: 0, width: b.width - e - c, height: e), cursor: .resizeUpDown)
        addCursorRect(CGRect(x: c, y: b.height - e, width: b.width - 2 * c, height: e), cursor: .resizeUpDown)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        if event.clickCount == 2 {
            drag = .none
            pin?.editPin()
            return
        }
        let (left, right, top, bottom) = sides(at: convert(event.locationInWindow, from: nil))
        if (left || right || top || bottom), let frame = window?.frame {
            drag = .resize(left: left, right: right, bottom: bottom, top: top, start: NSEvent.mouseLocation, frame: frame)
        } else {
            drag = .move
            window?.performDrag(with: event)
            drag = .none
            // The drag's own loop takes the mouse-up and may skip the exit: hide the ✕ if the
            // pointer ended outside.
            if let window, !window.frame.contains(NSEvent.mouseLocation) { showClose(false) }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard case let .resize(left, right, bottom, top, start, frame) = drag, let pin else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - start.x, dy = now.y - start.y
        // Proportions stay: an edge drives its own side; a corner follows the larger change.
        let ratio = frame.width / frame.height
        let byWidth = frame.width + (right ? dx : left ? -dx : 0)
        let byHeight = (frame.height + (top ? dy : bottom ? -dy : 0)) * ratio
        let horizontal = left || right, vertical = top || bottom
        let width = vertical && (!horizontal || abs(byHeight - frame.width) > abs(byWidth - frame.width)) ? byHeight : byWidth
        // The opposite corner stays (this view is flipped; the window's frame is not).
        let anchor = CGPoint(x: left ? frame.maxX : frame.minX, y: bottom ? frame.maxY : frame.minY)
        pin.resize(to: CGSize(width: width, height: width / ratio), anchor: anchor, growsLeft: left, growsDown: bottom)
    }

    override func mouseUp(with event: NSEvent) {
        drag = .none
        if let window, !window.frame.contains(NSEvent.mouseLocation) { showClose(false) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let pin else { return nil }
        let menu = NSMenu()
        func item(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = pin
            menu.addItem(item)
        }
        item(String(localized: "Copy"), #selector(PinnedWindow.copyPin))
        item(String(localized: "Copy Text"), #selector(PinnedWindow.copyTextPin))
        item(String(localized: "Save"), #selector(PinnedWindow.savePin))
        item(String(localized: "Edit Screenshot"), #selector(PinnedWindow.editPin))
        menu.addItem(.separator())
        item(String(localized: "Close"), #selector(PinnedWindow.closePin))
        return menu
    }
}

/// The ✕ on a pin: the same 16 pt symbol as a selected mark's ✕ (SS-61).
final class PinCloseButton: NSButton {
    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        title = ""
        setAccessibilityLabel(String(localized: "Close"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static let image: NSImage? = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white, .darkGray])))

    override func draw(_ dirtyRect: NSRect) {
        guard let image = Self.image else { return }
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 2
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.set()
        let size = image.size
        image.draw(in: CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height))
        NSGraphicsContext.restoreGraphicsState()
    }
}

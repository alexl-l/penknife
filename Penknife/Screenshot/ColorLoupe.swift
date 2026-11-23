import AppKit

/// R-38 color picker: the pixel under the pointer as `#RRGGBB` (sRGB, uppercase), read from the
/// screen image the overlay already holds (no new permission).
nonisolated enum ColorSample {
    /// The device pixel under a point of the canvas (top-left origin, points).
    static func pixel(_ point: CGPoint, scale: CGFloat) -> (x: Int, y: Int) {
        (Int((point.x * scale).rounded(.down)), Int((point.y * scale).rounded(.down)))
    }

    /// The pixel's color converted to sRGB, as web designers expect; nil outside the image.
    static func hex(in image: CGImage, x: Int, y: Int) -> String? {
        guard x >= 0, y >= 0, x < image.width, y < image.height,
              let one = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var bytes = [UInt8](repeating: 0, count: 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                          space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .none
            context.draw(one, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard drawn else { return nil }
        return String(format: "#%02X%02X%02X", bytes[0], bytes[1], bytes[2])
    }
}

/// The round loupe (variant A, chosen by the user 2026-11-22): magnified pixels centered on the
/// pointer, the center one outlined, and the hex in a capsule under it (over it near the bottom).
enum ColorLoupe {
    /// Pixels across; odd, so one is in the middle.
    static let cells = 11
    static let diameter: CGFloat = 110
    static let labelSize = CGSize(width: 88, height: 24)
    static let gap: CGFloat = 8
    /// Room for the shadow around what is drawn.
    static let margin: CGFloat = 14

    /// Where the loupe and its label go for a pointer (canvas coordinates, top-left origin).
    static func frames(pointer: CGPoint, bounds: CGRect) -> (loupe: CGRect, label: CGRect) {
        let loupe = CGRect(x: pointer.x - diameter / 2, y: pointer.y - diameter / 2, width: diameter, height: diameter)
        let below = loupe.maxY + gap + labelSize.height <= bounds.maxY
        let y = below ? loupe.maxY + gap : loupe.minY - gap - labelSize.height
        // The hex stays readable at the screen's sides (the loupe may go past them).
        let x = min(max(pointer.x - labelSize.width / 2, bounds.minX + 4), bounds.maxX - 4 - labelSize.width)
        let label = CGRect(x: x, y: y, width: labelSize.width, height: labelSize.height)
        return (loupe, label)
    }

    /// Everything drawn for a pointer, to redraw only that part.
    static func area(pointer: CGPoint, bounds: CGRect) -> CGRect {
        let f = frames(pointer: pointer, bounds: bounds)
        return f.loupe.union(f.label).insetBy(dx: -margin, dy: -margin)
    }

    /// An invisible pointer: the loupe's center square is the pointer while picking.
    static let blankCursor = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero)

    /// What never changes, drawn once (flipped, loupe-sized): the faint grid, the picked pixel's
    /// black-and-white square and the white rim.
    static let overlay: NSImage = NSImage(size: NSSize(width: diameter, height: diameter), flipped: true) { rect in
        let cell = diameter / CGFloat(cells)
        let half = CGFloat(cells / 2)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(ovalIn: rect).addClip()
        let grid = NSBezierPath()
        for i in 0...cells {
            let o = CGFloat(i) * cell
            grid.move(to: CGPoint(x: o, y: 0))
            grid.line(to: CGPoint(x: o, y: diameter))
            grid.move(to: CGPoint(x: 0, y: o))
            grid.line(to: CGPoint(x: diameter, y: o))
        }
        grid.lineWidth = 0.5
        NSColor.black.withAlphaComponent(0.08).setStroke()
        grid.stroke()
        NSGraphicsContext.restoreGraphicsState()

        let middle = CGRect(x: half * cell, y: half * cell, width: cell, height: cell)
        let outer = NSBezierPath(rect: middle.insetBy(dx: -1, dy: -1))
        outer.lineWidth = 2
        NSColor.black.setStroke()
        outer.stroke()
        let inner = NSBezierPath(rect: middle)
        inner.lineWidth = 1
        NSColor.white.setStroke()
        inner.stroke()

        let rim = NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5))
        rim.lineWidth = 3
        NSColor.white.setStroke()
        rim.stroke()
        let edge = NSBezierPath(ovalIn: rect.insetBy(dx: 0.25, dy: 0.25))
        edge.lineWidth = 0.5
        NSColor.black.withAlphaComponent(0.25).setStroke()
        edge.stroke()
        return true
    }
}

/// The loupe as a small view over the canvas (R-38). Following the pointer only moves layers and
/// swaps an 11×11-pixel image that the GPU enlarges (nearest neighbor); the canvas is not
/// redrawn. Measured 2026-11-22 at 125 moves/s: drawn into the canvas with `NSShadow` it took
/// ~50 % CPU (half of it the shadows' blur); drawn by CoreGraphics in its own view, ~30 %.
final class LoupeView: NSView {
    private(set) var pointer = CGPoint.zero
    private(set) var hex: String?
    /// The round window (black where the screen ends) and the enlarged pixels in it.
    private let pixels = CALayer()
    private let patch = CALayer()
    private let overlay = CALayer()
    private let label = CALayer()
    private let text = CATextLayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        guard let layer else { return }
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 0.35
        layer.shadowRadius = 6
        let d = ColorLoupe.diameter
        pixels.bounds = CGRect(x: 0, y: 0, width: d, height: d)
        pixels.cornerRadius = d / 2
        pixels.masksToBounds = true
        pixels.backgroundColor = NSColor.black.cgColor
        patch.magnificationFilter = .nearest
        patch.contentsGravity = .resize
        pixels.addSublayer(patch)
        overlay.bounds = pixels.bounds
        overlay.contents = ColorLoupe.overlay
        label.bounds = CGRect(origin: .zero, size: ColorLoupe.labelSize)
        label.cornerRadius = ColorLoupe.labelSize.height / 2
        label.borderWidth = 0.5
        text.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        text.fontSize = 12
        text.alignmentMode = .center
        text.bounds = CGRect(x: 0, y: 0, width: ColorLoupe.labelSize.width, height: 16)
        text.position = CGPoint(x: ColorLoupe.labelSize.width / 2, y: ColorLoupe.labelSize.height / 2)
        label.addSublayer(text)
        [pixels, overlay, label].forEach(layer.addSublayer)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Light or dark: the label follows the system look.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            label.backgroundColor = NSColor.windowBackgroundColor.cgColor
            // Increase Contrast: a stronger border, as the hint capsule does.
            let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            label.borderWidth = contrast ? 1 : 0.5
            label.borderColor = (contrast ? NSColor.labelColor.withAlphaComponent(0.4) : NSColor.separatorColor).cgColor
            text.foregroundColor = NSColor.labelColor.cgColor
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        text.contentsScale = window.backingScaleFactor
        overlay.contentsScale = window.backingScaleFactor
        viewDidChangeEffectiveAppearance()
    }

    /// `image` is the screen at `scale` pixels per point; `canvas` the canvas's bounds.
    func show(pointer: CGPoint, image: CGImage, scale: CGFloat, in canvas: CGRect) {
        self.pointer = pointer
        let pixel = ColorSample.pixel(pointer, scale: scale)
        hex = ColorSample.hex(in: image, x: pixel.x, y: pixel.y)
        let area = ColorLoupe.area(pointer: pointer, bounds: canvas)
        let f = ColorLoupe.frames(pointer: pointer, bounds: canvas)
        // A flipped view's layer goes down too: the view's coordinates, from its corner.
        let loupe = f.loupe.offsetBy(dx: -area.minX, dy: -area.minY)
        let labelRect = f.label.offsetBy(dx: -area.minX, dy: -area.minY)

        // The pixels around the pointer; at a screen edge the missing ones stay black.
        let cells = ColorLoupe.cells
        let cell = ColorLoupe.diameter / CGFloat(cells)
        let wanted = CGRect(x: pixel.x - cells / 2, y: pixel.y - cells / 2, width: cells, height: cells)
        let crop = wanted.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frame = area
        overlay.frame = loupe
        label.frame = labelRect
        text.string = hex ?? ""
        let path = CGMutablePath()
        path.addEllipse(in: loupe)
        path.addRoundedRect(in: labelRect, cornerWidth: labelRect.height / 2, cornerHeight: labelRect.height / 2)
        layer?.shadowPath = path
        layer?.shadowOffset = CGSize(width: 0, height: 3)
        pixels.frame = loupe
        if !crop.isNull, let part = image.cropping(to: crop) {
            patch.contents = part
            patch.frame = CGRect(x: (crop.minX - wanted.minX) * cell, y: (crop.minY - wanted.minY) * cell,
                                 width: crop.width * cell, height: crop.height * cell)
        } else {
            patch.contents = nil
        }
        CATransaction.commit()
    }
}

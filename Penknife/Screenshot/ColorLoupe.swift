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
        let label = CGRect(x: pointer.x - labelSize.width / 2, y: y, width: labelSize.width, height: labelSize.height)
        return (loupe, label)
    }

    /// Everything drawn for a pointer, to redraw only that part.
    static func area(pointer: CGPoint, bounds: CGRect) -> CGRect {
        let f = frames(pointer: pointer, bounds: bounds)
        return f.loupe.union(f.label).insetBy(dx: -margin, dy: -margin)
    }

    /// An invisible pointer: the loupe's center square is the pointer while picking.
    static let blankCursor = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero)

    /// Draws in a flipped view, at `loupe` and `labelRect`, the pixels around `pixel` of `image`.
    /// No shadows here: the view's layer casts them (on the GPU).
    static func draw(loupe: CGRect, labelRect: CGRect, pixel: (x: Int, y: Int), image: CGImage, hex: String) {
        let circle = NSBezierPath(ovalIn: loupe)

        // The pixels, square and unsmoothed.
        let cell = diameter / CGFloat(cells)
        let (cx, cy) = pixel
        let half = cells / 2
        let wanted = CGRect(x: cx - half, y: cy - half, width: cells, height: cells)
        let crop = wanted.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        NSGraphicsContext.saveGraphicsState()
        circle.addClip()
        NSColor.black.setFill()
        loupe.fill()
        if !crop.isNull, let part = image.cropping(to: crop) {
            NSGraphicsContext.current?.imageInterpolation = .none
            let target = CGRect(x: loupe.minX + (crop.minX - wanted.minX) * cell, y: loupe.minY + (crop.minY - wanted.minY) * cell,
                                width: crop.width * cell, height: crop.height * cell)
            NSImage(cgImage: part, size: crop.size).draw(in: target, from: .zero, operation: .copy, fraction: 1,
                                                       respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none.rawValue])
        }
        let grid = NSBezierPath()
        for i in 0...cells {
            let o = CGFloat(i) * cell
            grid.move(to: CGPoint(x: loupe.minX + o, y: loupe.minY))
            grid.line(to: CGPoint(x: loupe.minX + o, y: loupe.maxY))
            grid.move(to: CGPoint(x: loupe.minX, y: loupe.minY + o))
            grid.line(to: CGPoint(x: loupe.maxX, y: loupe.minY + o))
        }
        grid.lineWidth = 0.5
        NSColor.black.withAlphaComponent(0.08).setStroke()
        grid.stroke()
        NSGraphicsContext.restoreGraphicsState()

        // The picked pixel: black outside, white inside, visible on any color.
        let middle = CGRect(x: loupe.minX + CGFloat(half) * cell, y: loupe.minY + CGFloat(half) * cell, width: cell, height: cell)
        let outer = NSBezierPath(rect: middle.insetBy(dx: -1, dy: -1))
        outer.lineWidth = 2
        NSColor.black.setStroke()
        outer.stroke()
        let inner = NSBezierPath(rect: middle)
        inner.lineWidth = 1
        NSColor.white.setStroke()
        inner.stroke()

        let rim = NSBezierPath(ovalIn: loupe.insetBy(dx: 1.5, dy: 1.5))
        rim.lineWidth = 3
        NSColor.white.setStroke()
        rim.stroke()
        circle.lineWidth = 0.5
        NSColor.black.withAlphaComponent(0.25).setStroke()
        circle.stroke()

        // The hex.
        let capsule = NSBezierPath(roundedRect: labelRect, xRadius: labelRect.height / 2, yRadius: labelRect.height / 2)
        NSColor.windowBackgroundColor.setFill()
        capsule.fill()
        capsule.lineWidth = 0.5
        NSColor.separatorColor.setStroke()
        capsule.stroke()
        let text = NSAttributedString(string: hex, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ])
        let size = text.size()
        text.draw(at: CGPoint(x: labelRect.midX - size.width / 2, y: labelRect.midY - size.height / 2))
    }
}

/// The loupe as a small view over the canvas (R-38): following the pointer moves it and redraws
/// only its few points; the canvas under it is not redrawn. Measured 2026-11-22: drawn into the
/// canvas with `NSShadow`, the shadows' blur took about half of ~50 % CPU while moving.
final class LoupeView: NSView {
    private(set) var pointer = CGPoint.zero
    private(set) var hex: String?
    private var image: CGImage?
    private var pixel = (x: 0, y: 0)
    private var parts = (loupe: CGRect.zero, label: CGRect.zero)

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 6
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// `image` is the screen at `scale` pixels per point; `bounds` the canvas's.
    func show(pointer: CGPoint, image: CGImage, scale: CGFloat, in canvas: CGRect) {
        self.pointer = pointer
        self.image = image
        pixel = ColorSample.pixel(pointer, scale: scale)
        hex = ColorSample.hex(in: image, x: pixel.x, y: pixel.y)
        let area = ColorLoupe.area(pointer: pointer, bounds: canvas)
        let f = ColorLoupe.frames(pointer: pointer, bounds: canvas)
        parts = (f.loupe.offsetBy(dx: -area.minX, dy: -area.minY), f.label.offsetBy(dx: -area.minX, dy: -area.minY))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frame = area
        // The layer's own coordinates go up: the shapes are flipped for the shadow.
        let path = CGMutablePath()
        let flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: area.height)
        path.addEllipse(in: parts.loupe.applying(flip))
        let label = parts.label.applying(flip)
        path.addRoundedRect(in: label, cornerWidth: label.height / 2, cornerHeight: label.height / 2)
        layer?.shadowPath = path
        layer?.shadowOffset = CGSize(width: 0, height: -3)
        CATransaction.commit()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let image, let hex else { return }
        ColorLoupe.draw(loupe: parts.loupe, labelRect: parts.label, pixel: pixel, image: image, hex: hex)
    }
}

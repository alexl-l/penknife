import AppKit
import CoreImage

/// Annotation tools (R-8). Keys are single letters without modifiers, inactive while typing.
enum CaptureTool: String, CaseIterable, Identifiable {
    case arrow, line, rectangle, ellipse, pen, highlighter, text, blur, eraser

    var id: String { rawValue }

    var title: String {
        switch self {
        case .arrow: String(localized: "Arrow")
        case .line: String(localized: "Line")
        case .rectangle: String(localized: "Rectangle")
        case .ellipse: String(localized: "Circle")
        case .pen: String(localized: "Pen")
        case .highlighter: String(localized: "Highlighter")
        case .text: String(localized: "Text")
        case .blur: String(localized: "Blur")
        case .eraser: String(localized: "Eraser")
        }
    }

    var symbol: String {
        switch self {
        case .arrow: "arrow.up.right"
        case .line: "line.diagonal"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .pen: "pencil.tip"
        case .highlighter: "highlighter"
        case .text: "textformat"
        case .blur: "aqi.medium"
        case .eraser: "eraser"
        }
    }

    var key: String {
        switch self {
        case .arrow: "V"
        case .line: "L"
        case .rectangle: "R"
        case .ellipse: "O"
        case .pen: "P"
        case .highlighter: "H"
        case .text: "T"
        case .blur: "B"
        case .eraser: "E"
        }
    }

    /// Tools whose color matters.
    var usesColor: Bool { self != .blur && self != .eraser }
}

/// Annotation colors: system colors, keys 1–8.
enum CapturePalette {
    static let colors: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple, .white, .black]
    static let colorKey = "screenshot.defaultColor"
    /// The color each screenshot starts with (setting); blue unless changed.
    static var defaultIndex: Int { defaultIndex(in: .standard) }
    static func defaultIndex(in defaults: UserDefaults) -> Int {
        let index = defaults.object(forKey: colorKey) as? Int ?? 4
        return colors.indices.contains(index) ? index : 4
    }

    static func name(_ index: Int) -> String {
        switch index {
        case 0: String(localized: "Red")
        case 1: String(localized: "Orange")
        case 2: String(localized: "Yellow")
        case 3: String(localized: "Green")
        case 4: String(localized: "Blue")
        case 5: String(localized: "Purple")
        case 6: String(localized: "White")
        default: String(localized: "Black")
        }
    }

    /// Light colors get a dark checkmark.
    static func isLight(_ index: Int) -> Bool { index == 2 || index == 6 }
}

/// Line thickness and text size: four steps, keys - and +.
enum CaptureSize {
    static let count = 4
    static let defaultIndex = 1
    static let lineWidths: [CGFloat] = [2, 3.5, 6, 10]
    static let fontSizes: [CGFloat] = [15, 22, 32, 46]

    static func name(_ index: Int) -> String {
        switch index {
        case 0: String(localized: "Thin")
        case 1: String(localized: "Medium")
        case 2: String(localized: "Thick")
        default: String(localized: "Extra thick")
        }
    }

    static func font(_ index: Int) -> NSFont { .systemFont(ofSize: fontSizes[index], weight: .semibold) }
}

/// Where one eraser drag went over a mark (R-32), in the mark's coordinates: it moves and
/// resizes with the mark.
struct Erasure {
    var points: [CGPoint]
    let width: CGFloat
    /// The drag that made it (one drag = one erasure per mark).
    let stroke: Int

    /// Whether the eraser went over `point`.
    func covers(_ point: CGPoint) -> Bool {
        guard let first = points.first else { return false }
        if points.count == 1 { return hypot(point.x - first.x, point.y - first.y) <= width / 2 }
        return zip(points, points.dropFirst()).contains { Annotation.distance(point, $0, $1) <= width / 2 }
    }
}

/// One mark on the screenshot, in the overlay's coordinates (points, top-left origin).
struct Annotation {
    let tool: CaptureTool
    var color: NSColor
    var size: Int
    /// Arrow, rectangle, ellipse and blur: start and end. Pen and highlighter: the path. Text: its origin.
    var points: [CGPoint]
    var text = ""
    /// Blur: the blurred part of the screen.
    var image: CGImage?
    /// Text made bigger or smaller with its handles (R-32): font size × scale.
    var scale: CGFloat = 1
    /// What the eraser removed from it (R-32).
    var erasures: [Erasure] = []
    /// A blur in a recording: blurred live in each frame by the writer, so only its edge is drawn.
    var liveBlur = false
    /// Line and arrow: the control point of their curve (nil = straight), dragged by the handle
    /// in their middle (R-32, user: "la línea se debería poder curvar").
    var bend: CGPoint?

    var lineWidth: CGFloat { CaptureSize.lineWidths[size] }
    /// Rectangle and ellipse: where the middle of their line runs. Never empty, even when the
    /// shape is smaller than its line (it vanished then: QA, 2026-11-17).
    var strokeRect: CGRect {
        let r = rect
        return r.insetBy(dx: min(lineWidth / 2, r.width / 2), dy: min(lineWidth / 2, r.height / 2))
    }
    var font: NSFont { .systemFont(ofSize: CaptureSize.fontSizes[size] * scale, weight: .semibold) }
    var highlighterWidth: CGFloat { lineWidth * 4 + 6 }

    var rect: CGRect {
        guard let first = points.first, let last = points.last else { return .zero }
        return CGRect(x: min(first.x, last.x), y: min(first.y, last.y), width: abs(last.x - first.x), height: abs(last.y - first.y))
    }

    /// Everything the mark may paint, for partial redraws.
    var bounds: CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        // A curve stays within its ends and its control point.
        for point in points + (bend.map { [$0] } ?? []) {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        let pad = highlighterWidth + lineWidth * 5
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).insetBy(dx: -pad, dy: -pad)
    }

    /// Marks too small to be intended (a click without a drag) are dropped.
    var isMeaningful: Bool {
        switch tool {
        case .arrow, .line, .rectangle, .ellipse, .blur:
            let r = rect
            return max(r.width, r.height) > 4
        case .pen, .highlighter: return points.count > 1
        case .text: return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .eraser: return false
        }
    }

    static func textAttributes(_ color: NSColor, size: Int) -> [NSAttributedString.Key: Any] {
        textAttributes(color, font: CaptureSize.font(size))
    }

    static func textAttributes(_ color: NSColor, font: NSFont) -> [NSAttributedString.Key: Any] {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(color == .black ? 0 : 0.35)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        return [.font: font, .foregroundColor: color, .shadow: shadow]
    }

    /// What the mark paints, including the whole text (`bounds` covers only its origin).
    var paintedBounds: CGRect {
        guard tool == .text, let origin = points.first else { return bounds }
        return CGRect(origin: origin, size: textSize).insetBy(dx: -6, dy: -6)
    }

    /// Draws into the current graphics context, which must be flipped (top-left origin). What the
    /// eraser went over is cleared from the mark only (it is drawn in its own layer).
    func draw() {
        guard !erasures.isEmpty, let context = NSGraphicsContext.current?.cgContext else {
            drawMark()
            return
        }
        context.saveGState()
        context.beginTransparencyLayer(in: paintedBounds, auxiliaryInfo: nil)
        drawMark()
        context.setBlendMode(.clear)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for erasure in erasures {
            guard let first = erasure.points.first else { continue }
            context.setLineWidth(erasure.width)
            context.beginPath()
            context.move(to: first)
            for point in erasure.points.dropFirst() { context.addLine(to: point) }
            if erasure.points.count == 1 { context.addLine(to: first) }
            context.strokePath()
        }
        context.endTransparencyLayer()
        context.restoreGState()
    }

    private func drawMark() {
        switch tool {
        case .line:
            guard let from = points.first, let to = points.last else { return }
            color.set()
            let line = NSBezierPath()
            line.lineWidth = lineWidth
            line.lineCapStyle = .round
            line.move(to: from)
            curve(line, to: to)
            line.stroke()
        case .arrow:
            guard let from = points.first, let to = points.last else { return }
            color.set()
            // The head follows the end of the curve (its tangent there).
            let control = bend.flatMap { $0 == to ? nil : $0 } ?? from
            let angle = atan2(to.y - control.y, to.x - control.x)
            let head = max(lineWidth * 4.5, 12)
            let spread = CGFloat.pi / 7
            let line = NSBezierPath()
            line.lineWidth = lineWidth
            line.lineCapStyle = .round
            line.move(to: from)
            curve(line, to: CGPoint(x: to.x - cos(angle) * head * 0.6, y: to.y - sin(angle) * head * 0.6))
            line.stroke()
            let tip = NSBezierPath()
            tip.move(to: to)
            tip.line(to: CGPoint(x: to.x - head * cos(angle - spread), y: to.y - head * sin(angle - spread)))
            tip.line(to: CGPoint(x: to.x - head * cos(angle + spread), y: to.y - head * sin(angle + spread)))
            tip.close()
            tip.lineJoinStyle = .round
            tip.lineWidth = 1.5
            tip.fill()
            tip.stroke()
        case .rectangle, .ellipse:
            color.set()
            let inset = strokeRect
            let path = tool == .ellipse ? NSBezierPath(ovalIn: inset) : NSBezierPath(roundedRect: inset, xRadius: lineWidth, yRadius: lineWidth)
            path.lineWidth = lineWidth
            path.stroke()
        case .pen, .highlighter:
            guard let first = points.first else { return }
            let path = NSBezierPath()
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: first)
            for point in points.dropFirst() { path.line(to: point) }
            if tool == .highlighter {
                path.lineWidth = highlighterWidth
                color.withAlphaComponent(0.4).set()
            } else {
                path.lineWidth = lineWidth
                color.set()
            }
            path.stroke()
        case .text:
            guard let origin = points.first else { return }
            NSAttributedString(string: text, attributes: Self.textAttributes(color, font: font)).draw(at: origin)
        case .eraser:
            break
        case .blur:
            // Frosted glass (chosen by the user): soft shadow, rounded corners, light tint and a
            // hairline of light.
            guard let image else {
                if liveBlur {
                    drawLiveBlurEdge()
                } else {
                    // No blurred pixels (they couldn't be made): hide it all rather than show it.
                    NSColor(white: 0.25, alpha: 1).setFill()
                    NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
                }
                return
            }
            let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
            shadow.shadowBlurRadius = 10
            shadow.shadowOffset = NSSize(width: 0, height: -2)
            shadow.set()
            NSColor.black.setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            NSImage(cgImage: image, size: rect.size)
                .draw(in: rect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
            NSColor.white.withAlphaComponent(0.08).setFill()
            rect.fill(using: .sourceOver)
            NSGraphicsContext.restoreGraphicsState()
            let edge = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
            edge.lineWidth = 1
            NSColor.white.withAlphaComponent(0.3).setStroke()
            edge.stroke()
        }
    }

    /// A straight segment, or the quadratic curve through `bend` drawn as its cubic equivalent.
    private func curve(_ path: NSBezierPath, to end: CGPoint) {
        guard let bend, let start = points.first else {
            path.line(to: end)
            return
        }
        path.curve(to: end,
                   controlPoint1: CGPoint(x: start.x + (bend.x - start.x) * 2 / 3, y: start.y + (bend.y - start.y) * 2 / 3),
                   controlPoint2: CGPoint(x: end.x + (bend.x - end.x) * 2 / 3, y: end.y + (bend.y - end.y) * 2 / 3))
    }

    /// A blur while recording (R-32): its inside stays clear, so the screen under it is captured
    /// and then blurred in each frame; only the shadow around it and its hairline are drawn.
    private func drawLiveBlurEdge() {
        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        NSGraphicsContext.saveGraphicsState()
        let outside = NSBezierPath(rect: rect.insetBy(dx: -40, dy: -40))
        outside.append(path)
        outside.windingRule = .evenOdd
        outside.addClip()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.shadowBlurRadius = 10
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.set()
        NSColor.black.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        let edge = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        edge.lineWidth = 1
        NSColor.white.withAlphaComponent(0.3).setStroke()
        edge.stroke()
    }

    /// `base` (covering `area`, in points) strongly blurred, so text under it can't be read.
    static func blur(_ base: CGImage, scale: CGFloat, context: CIContext) -> CGImage? {
        let input = CIImage(cgImage: base)
        let output = input.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 9 * scale])
            .cropped(to: input.extent)
        return context.createCGImage(output, from: input.extent)
    }
}

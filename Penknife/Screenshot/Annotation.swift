import AppKit
import CoreImage

/// Annotation tools (R-8). Keys are single letters without modifiers, inactive while typing.
enum CaptureTool: String, CaseIterable, Identifiable {
    case arrow, rectangle, ellipse, pen, highlighter, text, blur

    var id: String { rawValue }

    var title: String {
        switch self {
        case .arrow: String(localized: "Arrow")
        case .rectangle: String(localized: "Rectangle")
        case .ellipse: String(localized: "Circle")
        case .pen: String(localized: "Pen")
        case .highlighter: String(localized: "Highlighter")
        case .text: String(localized: "Text")
        case .blur: String(localized: "Blur")
        }
    }

    var symbol: String {
        switch self {
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .pen: "pencil.tip"
        case .highlighter: "highlighter"
        case .text: "textformat"
        case .blur: "aqi.medium"
        }
    }

    var key: String {
        switch self {
        case .arrow: "V"
        case .rectangle: "R"
        case .ellipse: "O"
        case .pen: "P"
        case .highlighter: "H"
        case .text: "T"
        case .blur: "B"
        }
    }

    /// Tools whose color and size matter.
    var usesColor: Bool { self != .blur }
}

/// Annotation colors: system colors, keys 1–8.
enum CapturePalette {
    static let colors: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple, .white, .black]
    static let colorKey = "screenshot.defaultColor"
    /// The color each screenshot starts with (setting); blue unless changed.
    static var defaultIndex: Int {
        let index = UserDefaults.standard.object(forKey: colorKey) as? Int ?? 4
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

/// One mark on the screenshot, in the overlay's coordinates (points, top-left origin).
struct Annotation {
    let tool: CaptureTool
    let color: NSColor
    let size: Int
    /// Arrow, rectangle, ellipse and blur: start and end. Pen and highlighter: the path. Text: its origin.
    var points: [CGPoint]
    var text = ""
    /// Blur: the blurred part of the screen.
    var image: CGImage?

    var lineWidth: CGFloat { CaptureSize.lineWidths[size] }
    var highlighterWidth: CGFloat { lineWidth * 4 + 6 }

    var rect: CGRect {
        guard let first = points.first, let last = points.last else { return .zero }
        return CGRect(x: min(first.x, last.x), y: min(first.y, last.y), width: abs(last.x - first.x), height: abs(last.y - first.y))
    }

    /// Everything the mark may paint, for partial redraws.
    var bounds: CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        let pad = highlighterWidth + lineWidth * 5
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).insetBy(dx: -pad, dy: -pad)
    }

    /// Marks too small to be intended (a click without a drag) are dropped.
    var isMeaningful: Bool {
        switch tool {
        case .arrow, .rectangle, .ellipse, .blur:
            let r = rect
            return max(r.width, r.height) > 4
        case .pen, .highlighter: return points.count > 1
        case .text: return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    static func textAttributes(_ color: NSColor, size: Int) -> [NSAttributedString.Key: Any] {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(color == .black ? 0 : 0.35)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        return [.font: CaptureSize.font(size), .foregroundColor: color, .shadow: shadow]
    }

    /// Draws into the current graphics context, which must be flipped (top-left origin).
    func draw() {
        switch tool {
        case .arrow:
            guard let from = points.first, let to = points.last else { return }
            color.set()
            let angle = atan2(to.y - from.y, to.x - from.x)
            let head = max(lineWidth * 4.5, 12)
            let spread = CGFloat.pi / 7
            let line = NSBezierPath()
            line.lineWidth = lineWidth
            line.lineCapStyle = .round
            line.move(to: from)
            line.line(to: CGPoint(x: to.x - cos(angle) * head * 0.6, y: to.y - sin(angle) * head * 0.6))
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
            let inset = rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
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
            NSAttributedString(string: text, attributes: Self.textAttributes(color, size: size)).draw(at: origin)
        case .blur:
            // Frosted glass (chosen by the user): soft shadow, rounded corners, light tint and a
            // hairline of light.
            guard let image else { return }
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

    /// `base` (covering `area`, in points) strongly blurred, so text under it can't be read.
    static func blur(_ base: CGImage, scale: CGFloat, context: CIContext) -> CGImage? {
        let input = CIImage(cgImage: base)
        let output = input.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 9 * scale])
            .cropped(to: input.extent)
        return context.createCGImage(output, from: input.extent)
    }
}

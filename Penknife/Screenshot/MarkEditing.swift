import AppKit

// Changing marks after they are drawn (R-32, variant 1 of the live demo, chosen by the user):
// click a mark's line to select it; drag to move it, its handles to resize it, its ✕ (or Delete)
// to remove it; color and size apply to it; the eraser removes only where it goes. Shared by the
// screenshot editor and the drawings while recording.

extension Annotation {
    /// The text's size, as drawn.
    var textSize: CGSize {
        NSAttributedString(string: text.isEmpty ? " " : text, attributes: Self.textAttributes(color, font: font)).size()
    }

    /// Line and arrow can bend.
    var bends: Bool { tool == .arrow || tool == .line }

    /// Points along a line or arrow: its two ends, or its curve when bent.
    var curvePoints: [CGPoint] {
        guard let from = points.first, let to = points.last else { return [] }
        guard let bend else { return [from, to] }
        return (0...32).map { index in
            let t = CGFloat(index) / 32, u = 1 - t
            return CGPoint(x: u * u * from.x + 2 * u * t * bend.x + t * t * to.x,
                           y: u * u * from.y + 2 * u * t * bend.y + t * t * to.y)
        }
    }

    /// The middle of a line or arrow, where its bend handle sits.
    var curveMiddle: CGPoint {
        guard let from = points.first, let to = points.last else { return .zero }
        let control = bend ?? CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
        return CGPoint(x: 0.25 * from.x + 0.5 * control.x + 0.25 * to.x, y: 0.25 * from.y + 0.5 * control.y + 0.25 * to.y)
    }

    /// Bends a line or arrow so it passes through `point` (straight again when close to it).
    mutating func bend(through point: CGPoint) {
        guard let from = points.first, let to = points.last else { return }
        let middle = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
        bend = hypot(point.x - middle.x, point.y - middle.y) < 3 ? nil : CGPoint(x: 2 * point.x - middle.x, y: 2 * point.y - middle.y)
    }

    /// The shape itself, without its line.
    var box: CGRect {
        switch tool {
        case .arrow, .line:
            guard bend != nil else { return rect }
            let curve = curvePoints
            let xs = curve.map(\.x), ys = curve.map(\.y)
            guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return rect }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        case .text:
            return CGRect(origin: points.first ?? .zero, size: textSize)
        case .pen, .highlighter:
            guard let first = points.first else { return .zero }
            var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
            for point in points {
                minX = min(minX, point.x); maxX = max(maxX, point.x)
                minY = min(minY, point.y); maxY = max(maxY, point.y)
            }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        default:
            return rect
        }
    }

    /// How far the paint goes past the shape's line (half its width).
    var reach: CGFloat {
        switch tool {
        case .highlighter: highlighterWidth / 2
        case .text, .blur, .eraser: 0
        default: lineWidth / 2
        }
    }

    /// Distance from `point` to the mark's line (0 inside text and blur).
    func distance(to point: CGPoint) -> CGFloat {
        switch tool {
        case .arrow, .line:
            let curve = curvePoints
            guard curve.count > 1 else { return .infinity }
            return zip(curve, curve.dropFirst()).map { Self.distance(point, $0, $1) }.min() ?? .infinity
        case .rectangle:
            let r = strokeRect
            let corners = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
            return (0..<4).map { Self.distance(point, corners[$0], corners[($0 + 1) % 4]) }.min() ?? .infinity
        case .ellipse:
            // Along its outline (a scaled formula was far too generous at the ends of a long, thin
            // ellipse: QA, 2026-11-17).
            let outline = ellipsePoints(64)
            return zip(outline, outline.dropFirst()).map { Self.distance(point, $0, $1) }.min() ?? .infinity
        case .pen, .highlighter:
            guard let first = points.first else { return .infinity }
            guard points.count > 1 else { return hypot(point.x - first.x, point.y - first.y) }
            return zip(points, points.dropFirst()).map { Self.distance(point, $0, $1) }.min() ?? .infinity
        case .text, .blur:
            let r = box
            return hypot(max(r.minX - point.x, 0, point.x - r.maxX), max(r.minY - point.y, 0, point.y - r.maxY))
        case .eraser:
            return .infinity
        }
    }

    /// A click at `point` selects this mark: on (or near) its line, not where it was erased.
    func hit(_ point: CGPoint) -> Bool {
        // Far from everything it paints: no need to measure (checked on every pointer move).
        guard paintedBounds.insetBy(dx: -MarkEditing.slop, dy: -MarkEditing.slop).contains(point) else { return false }
        return distance(to: point) <= reach + MarkEditing.slop && !erasures.contains { $0.covers(point) }
    }

    static func distance(_ point: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = dx * dx + dy * dy
        guard length > 0 else { return hypot(point.x - a.x, point.y - a.y) }
        let t = max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / length))
        return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
    }

    mutating func move(by delta: CGVector) {
        func moved(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + delta.dx, y: p.y + delta.dy) }
        points = points.map(moved)
        bend = bend.map(moved)
        for index in erasures.indices { erasures[index].points = erasures[index].points.map(moved) }
    }

    /// Stretches the mark (and what was erased from it) from box `from` to box `to`. Lines keep
    /// their width; text changes its size.
    mutating func map(from: CGRect, to: CGRect) {
        let sx = from.width > 0.5 ? to.width / from.width : 1
        let sy = from.height > 0.5 ? to.height / from.height : 1
        func mapped(_ p: CGPoint) -> CGPoint { CGPoint(x: to.minX + (p.x - from.minX) * sx, y: to.minY + (p.y - from.minY) * sy) }
        points = points.map(mapped)
        bend = bend.map(mapped)
        for index in erasures.indices { erasures[index].points = erasures[index].points.map(mapped) }
        if tool == .text { scale = min(max(scale * sy, 0.3), 8) }
    }

    /// One step of an eraser drag (`from` nil at its start). True when it touched this mark.
    mutating func erase(from: CGPoint?, to: CGPoint, width: CGFloat, stroke: Int) -> Bool {
        guard tool != .eraser else { return false }
        if let index = erasures.firstIndex(where: { $0.stroke == stroke }) {
            erasures[index].points.append(to)
            return true
        }
        // Points along the step, so a fast drag doesn't jump over a thin line.
        let start = from ?? to
        let count = min(max(Int(hypot(to.x - start.x, to.y - start.y) / max(width / 4, 2)), 1), 60)
        let touched = (0...count).contains { step in
            let t = CGFloat(step) / CGFloat(count)
            let p = CGPoint(x: start.x + (to.x - start.x) * t, y: start.y + (to.y - start.y) * t)
            return distance(to: p) <= width / 2 + reach
        }
        guard touched else { return false }
        erasures.append(Erasure(points: from.map { [$0, to] } ?? [to], width: width, stroke: stroke))
        return true
    }

    /// `count` points around the ellipse's line, the first repeated at the end.
    private func ellipsePoints(_ count: Int) -> [CGPoint] {
        let r = strokeRect
        return (0...count).map { index in
            let angle = CGFloat(index) / CGFloat(count) * 2 * .pi
            return CGPoint(x: r.midX + r.width / 2 * cos(angle), y: r.midY + r.height / 2 * sin(angle))
        }
    }

    /// The eraser went over all of it: nothing worth keeping (it is then removed).
    var isFullyErased: Bool {
        guard !erasures.isEmpty else { return false }
        return samples.allSatisfy { point in erasures.contains { $0.covers(point) } }
    }

    /// Points along the mark's line (inside text and blur), at most a few hundred.
    private var samples: [CGPoint] {
        func along(_ a: CGPoint, _ b: CGPoint, step: CGFloat) -> [CGPoint] {
            let count = max(Int(hypot(b.x - a.x, b.y - a.y) / step), 1)
            return (0...count).map { CGPoint(x: a.x + (b.x - a.x) * CGFloat($0) / CGFloat(count), y: a.y + (b.y - a.y) * CGFloat($0) / CGFloat(count)) }
        }
        switch tool {
        case .arrow, .line:
            let curve = curvePoints
            guard curve.count > 1 else { return curve }
            let length = zip(curve, curve.dropFirst()).reduce(CGFloat(0)) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
            let step = max(length / 200, 3)
            return zip(curve, curve.dropFirst()).flatMap { along($0, $1, step: step) }
        case .rectangle:
            let r = strokeRect
            let corners = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
            let step = max((r.width + r.height) * 2 / 300, 3)
            return (0..<4).flatMap { along(corners[$0], corners[($0 + 1) % 4], step: step) }
        case .ellipse:
            return ellipsePoints(240)
        case .pen, .highlighter:
            guard points.count > 1 else { return points }
            let length = zip(points, points.dropFirst()).reduce(CGFloat(0)) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
            let step = max(length / 300, 3)
            return zip(points, points.dropFirst()).flatMap { along($0, $1, step: step) }
        case .text, .blur:
            let r = box.insetBy(dx: 2, dy: 2)
            let columns = min(max(Int(r.width / 6), 1), 30), rows = min(max(Int(r.height / 6), 1), 12)
            return (0...rows).flatMap { row in
                (0...columns).map { column in
                    CGPoint(x: r.minX + r.width * CGFloat(column) / CGFloat(columns), y: r.minY + r.height * CGFloat(row) / CGFloat(rows))
                }
            }
        case .eraser:
            return []
        }
    }
}

/// The look and the hit areas of a selected mark, shared by both canvases.
enum MarkEditing {
    /// How close to a line a click selects it.
    static let slop: CGFloat = 6
    /// Handles on the selection box, as fractions: corners and edge midpoints (the same order as
    /// the screenshot selection's, so their pointer shapes match).
    static let fractions: [(CGFloat, CGFloat)] = [(0, 0), (0.5, 0), (1, 0), (1, 0.5), (1, 1), (0.5, 1), (0, 1), (0, 0.5)]
    /// Eraser diameters for the four sizes.
    static let eraserSizes: [CGFloat] = [10, 18, 28, 40]

    /// The topmost mark under `point`.
    static func topmost(at point: CGPoint, in marks: [Annotation]) -> Int? {
        marks.indices.reversed().first { marks[$0].hit(point) }
    }

    /// The selection box: the shape and its line, with a little room.
    static func frame(_ mark: Annotation) -> CGRect {
        let room = mark.reach + 4
        return mark.box.insetBy(dx: -room, dy: -room)
    }

    /// Line and arrow: their two ends (0 = start, 1 = end) and the bend handle in the middle
    /// (2). Text: 4 corners. The rest: 8 handles.
    static func handles(_ mark: Annotation) -> [(index: Int, point: CGPoint)] {
        if mark.bends {
            guard let from = mark.points.first, let to = mark.points.last else { return [] }
            return [(0, from), (1, to), (2, mark.curveMiddle)]
        }
        let r = frame(mark)
        let all = fractions.enumerated().map { (index: $0.offset, point: CGPoint(x: r.minX + r.width * $0.element.0, y: r.minY + r.height * $0.element.1)) }
        return mark.tool == .text ? all.filter { $0.index % 2 == 0 } : all
    }

    static func handle(at point: CGPoint, of mark: Annotation) -> Int? {
        handles(mark).first { abs($0.point.x - point.x) <= 7 && abs($0.point.y - point.y) <= 7 }?.index
    }

    /// The ✕: just outside the box's top-right corner; inside it when that would leave `bounds`.
    static func closeCenter(_ mark: Annotation, within bounds: CGRect) -> CGPoint {
        let r = frame(mark)
        var center = CGPoint(x: r.maxX + 8, y: r.minY - 8)
        if center.x + 10 > bounds.maxX { center.x = r.maxX - 10 }
        if center.y - 10 < bounds.minY { center.y = r.minY + 10 }
        return center
    }

    static func isOnClose(_ point: CGPoint, of mark: Annotation, within bounds: CGRect) -> Bool {
        let center = closeCenter(mark, within: bounds)
        return hypot(point.x - center.x, point.y - center.y) <= 10
    }

    /// Everything the mark and its selection paint, for partial redraws.
    static func area(_ mark: Annotation) -> CGRect {
        mark.paintedBounds.union(frame(mark)).insetBy(dx: -24, dy: -24)
    }

    /// The pointer over a selected mark's handle (`nil` elsewhere).
    static func cursor(forHandle index: Int, of mark: Annotation) -> NSCursor {
        guard !mark.bends else { return .crosshair }
        return switch index {
        case 1, 5: .frameResize(position: index == 1 ? .top : .bottom, directions: .all)
        case 3, 7: .frameResize(position: index == 3 ? .right : .left, directions: .all)
        case 0: .frameResize(position: .topLeft, directions: .all)
        case 2: .frameResize(position: .topRight, directions: .all)
        case 4: .frameResize(position: .bottomRight, directions: .all)
        default: .frameResize(position: .bottomLeft, directions: .all)
        }
    }

    // MARK: Drawing (into a flipped context)

    /// A faint outline under the pointer: this mark can be clicked.
    static func drawHover(_ mark: Annotation) {
        NSColor.controlAccentColor.withAlphaComponent(0.5).setStroke()
        if mark.bends, let first = mark.curvePoints.first {
            let line = NSBezierPath()
            line.move(to: first)
            for point in mark.curvePoints.dropFirst() { line.line(to: point) }
            line.lineJoinStyle = .round
            line.lineWidth = mark.lineWidth + 6
            NSColor.controlAccentColor.withAlphaComponent(0.25).setStroke()
            line.lineCapStyle = .round
            line.stroke()
            return
        }
        let path = NSBezierPath(rect: frame(mark).insetBy(dx: 0.5, dy: 0.5))
        path.lineWidth = 1
        path.stroke()
    }

    /// The box (none for lines and arrows), white handles and the ✕. The bend handle of a line
    /// or arrow has a thicker ring and a hollow dot: it moves differently.
    static func drawSelection(_ mark: Annotation, within bounds: CGRect) {
        if !mark.bends {
            NSColor.controlAccentColor.setStroke()
            let box = NSBezierPath(rect: frame(mark).insetBy(dx: 0.5, dy: 0.5))
            box.lineWidth = 1
            box.stroke()
        }
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = .zero
        for handle in handles(mark) {
            let dot = CGRect(x: handle.point.x - 4, y: handle.point.y - 4, width: 8, height: 8)
            NSGraphicsContext.saveGraphicsState()
            shadow.set()
            NSColor.white.setFill()
            NSBezierPath(ovalIn: dot).fill()
            NSGraphicsContext.restoreGraphicsState()
            NSColor.controlAccentColor.setStroke()
            let ring = NSBezierPath(ovalIn: dot)
            let bendHandle = mark.bends && handle.index == 2
            ring.lineWidth = bendHandle ? 1.5 : 1
            ring.stroke()
            if bendHandle {
                let center = NSBezierPath(ovalIn: CGRect(x: handle.point.x - 1.5, y: handle.point.y - 1.5, width: 3, height: 3))
                center.lineWidth = 1
                center.stroke()
            }
        }
        let center = closeCenter(mark, within: bounds)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: CGRect(x: center.x - 7, y: center.y - 7, width: 14, height: 14)).fill()
        NSGraphicsContext.restoreGraphicsState()
        if let close = closeImage {
            let size = close.size
            close.draw(in: CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    private static let closeImage: NSImage? = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white, .darkGray])))

    // MARK: Changing a mark

    /// `original` with handle `index` dragged to `point`. ⇧ (and always for text, from a corner)
    /// keeps the proportions.
    static func resized(_ original: Annotation, handle index: Int, to point: CGPoint, keepRatio: Bool) -> Annotation {
        var mark = original
        if mark.bends {
            guard mark.points.count >= 2 else { return mark }
            if index == 2 {
                mark.bend(through: point)
                return mark
            }
            let moving = index == 0 ? 0 : mark.points.count - 1
            let other = mark.points[index == 0 ? mark.points.count - 1 : 0]
            mark.points[moving] = keepRatio ? snapped(point, from: other) : point
            return mark
        }
        let start = frame(original)
        let room = original.reach + 4
        let least = room * 2 + max(4, original.lineWidth + 1)
        let (fx, fy) = fractions[index]
        var minX = start.minX, maxX = start.maxX, minY = start.minY, maxY = start.maxY
        if fx == 0 { minX = min(point.x, maxX - least) } else if fx == 1 { maxX = max(point.x, minX + least) }
        if fy == 0 { minY = min(point.y, maxY - least) } else if fy == 1 { maxY = max(point.y, minY + least) }
        var r = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        let corner = fx != 0.5 && fy != 0.5
        if corner, keepRatio || original.tool == .text {
            let box = original.box
            var k = max((r.width - room * 2) / max(box.width, 1), (r.height - room * 2) / max(box.height, 1))
            // Text: its size stays within 0.3–8×, limited here so the fixed corner stays put
            // (limiting it after mapping moved the text: QA, 2026-11-17).
            if original.tool == .text { k = min(max(k, 0.3 / original.scale), 8 / original.scale) }
            let width = box.width * k + room * 2, height = box.height * k + room * 2
            r = CGRect(x: fx == 0 ? start.maxX - width : start.minX, y: fy == 0 ? start.maxY - height : start.minY, width: width, height: height)
            if original.tool == .text {
                // Text doesn't grow exactly in proportion to its font: it is placed from its real
                // new size, against the corner that doesn't move (QA, 2026-11-17).
                mark.map(from: box, to: r.insetBy(dx: room, dy: room))
                mark.scale = original.scale * k
                let size = mark.textSize
                mark.points[0] = CGPoint(x: fx == 0 ? box.maxX - size.width : box.minX,
                                         y: fy == 0 ? box.maxY - size.height : box.minY)
                return mark
            }
        }
        mark.map(from: original.box, to: r.insetBy(dx: room, dy: room))
        return mark
    }

    /// ⌥ arrow keys: bigger or smaller from the bottom-right corner (an arrow moves its tip).
    static func grown(_ original: Annotation, by delta: CGVector) -> Annotation {
        var mark = original
        if mark.bends, let tip = mark.points.last {
            mark.points[mark.points.count - 1] = CGPoint(x: tip.x + delta.dx, y: tip.y + delta.dy)
            return mark
        }
        let box = original.box
        var to = box
        if original.tool == .text {
            let grown = delta.dx != 0 ? (box.width + delta.dx) / max(box.width, 1) : (box.height + delta.dy) / max(box.height, 1)
            let k = min(max(grown, 0.3 / original.scale), 8 / original.scale)
            to.size = CGSize(width: box.width * k, height: box.height * k)
        } else {
            to.size = CGSize(width: max(box.width + delta.dx, box.width > 0.5 ? 4 : 0), height: max(box.height + delta.dy, box.height > 0.5 ? 4 : 0))
        }
        mark.map(from: box, to: to)
        return mark
    }

    // MARK: Eraser

    private static var eraserCursors: [Int: NSCursor] = [:]

    /// A ring as big as the eraser: shows exactly what it will take.
    static func eraserCursor(size index: Int) -> NSCursor {
        if let cursor = eraserCursors[index] { return cursor }
        let diameter = eraserSizes[min(max(index, 0), eraserSizes.count - 1)]
        let side = diameter + 4
        let image = NSImage(size: CGSize(width: side, height: side), flipped: false) { rect in
            let ring = rect.insetBy(dx: 2, dy: 2)
            NSColor.black.withAlphaComponent(0.6).setStroke()
            let outer = NSBezierPath(ovalIn: ring.insetBy(dx: -1, dy: -1))
            outer.lineWidth = 1
            outer.stroke()
            NSColor.white.setStroke()
            let inner = NSBezierPath(ovalIn: ring)
            inner.lineWidth = 1
            inner.stroke()
            return true
        }
        let cursor = NSCursor(image: image, hotSpot: CGPoint(x: side / 2, y: side / 2))
        eraserCursors[index] = cursor
        return cursor
    }

    /// ⇧ while drawing a line or arrow, or dragging one of its ends: angles in 45° steps.
    static func snapped(_ point: CGPoint, from origin: CGPoint) -> CGPoint {
        let dx = point.x - origin.x, dy = point.y - origin.y
        let length = hypot(dx, dy)
        let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
        return CGPoint(x: origin.x + cos(angle) * length, y: origin.y + sin(angle) * length)
    }

    /// The palette index of a mark's color (for the toolbar while it is selected).
    static func colorIndex(of mark: Annotation) -> Int? {
        CapturePalette.colors.firstIndex { $0 == mark.color }
    }
}

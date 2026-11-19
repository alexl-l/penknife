import CoreGraphics
import Foundation

/// One window as CoreGraphics lists it (global top-left coordinates). Missing values stay nil:
/// the rules below treat them exactly as the raw dictionary read did.
nonisolated struct WindowInfo: Equatable {
    var id: CGWindowID
    var layer: Int?
    var ownerPID: pid_t?
    var alpha: Double?
    var bounds: CGRect
}

/// The overlay's geometry as plain rules (docs/requirements/screenshot.md SS-12, 14, 17, 18, 21,
/// 26, 48). Canvas coordinates: points, top-left origin. The canvas calls these with the same
/// values it used to compute inline.
nonisolated enum CaptureGeometry {

    // MARK: Area selection (SS-12)

    /// A point kept on the screen.
    static func clamp(_ point: CGPoint, to bounds: CGRect) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), bounds.width), y: min(max(point.y, 0), bounds.height))
    }

    /// The rectangle a drag spans, whichever way it goes.
    static func dragRect(from start: CGPoint, to point: CGPoint) -> CGRect {
        CGRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(point.x - start.x), height: abs(point.y - start.y))
    }

    /// On release: smaller than 4 pt either way is dropped.
    static func keepsDrag(_ rect: CGRect) -> Bool {
        rect.width >= 4 && rect.height >= 4
    }

    /// A chosen region: rounded out to whole points and kept on the screen.
    static func chosen(_ rect: CGRect, bounds: CGRect) -> CGRect {
        rect.integral.intersection(bounds)
    }

    // MARK: Changing the selection (SS-17)

    /// Handle positions as fractions of the selection: corners and edge midpoints.
    static let handles: [(CGFloat, CGFloat)] = [(0, 0), (0.5, 0), (1, 0), (1, 0.5), (1, 1), (0.5, 1), (0, 1), (0, 0.5)]

    static func handlePoints(_ rect: CGRect) -> [CGPoint] {
        handles.map { CGPoint(x: rect.minX + rect.width * $0.0, y: rect.minY + rect.height * $0.1) }
    }

    /// The handle grabbed at `point` (within 8 pt), if any.
    static func handle(at point: CGPoint, of rect: CGRect) -> Int? {
        handlePoints(rect).firstIndex { abs($0.x - point.x) <= 8 && abs($0.y - point.y) <= 8 }
    }

    /// The selection moved to `origin`, kept inside the screen.
    static func moved(_ rect: CGRect, to origin: CGPoint, bounds: CGRect) -> CGRect {
        var rect = rect
        rect.origin.x = min(max(origin.x, 0), bounds.width - rect.width)
        rect.origin.y = min(max(origin.y, 0), bounds.height - rect.height)
        return rect
    }

    /// A handle dragged to `point`: crossing over flips the side, never thinner than 1 pt.
    static func resizeSelection(handle: Int, original: CGRect, to point: CGPoint) -> CGRect {
        let (fx, fy) = handles[handle]
        var minX = original.minX, maxX = original.maxX, minY = original.minY, maxY = original.maxY
        if fx == 0 { minX = point.x } else if fx == 1 { maxX = point.x }
        if fy == 0 { minY = point.y } else if fy == 1 { maxY = point.y }
        return CGRect(x: min(minX, maxX), y: min(minY, maxY), width: max(abs(maxX - minX), 1), height: max(abs(maxY - minY), 1))
    }

    /// Arrow keys: move inside the screen, or (⌥) resize from the bottom-right corner, at least
    /// 8 pt and within the screen.
    static func nudge(selection rect: CGRect, dx: CGFloat, dy: CGFloat, resize: Bool, bounds: CGRect) -> CGRect {
        guard resize else { return moved(rect, to: CGPoint(x: rect.minX + dx, y: rect.minY + dy), bounds: bounds) }
        var rect = rect
        rect.size.width = min(max(rect.width + dx, 8), bounds.width - rect.minX)
        rect.size.height = min(max(rect.height + dy, 8), bounds.height - rect.minY)
        return rect
    }

    // MARK: Window mode (SS-14)

    /// The windows window mode can choose on one screen, front to back, in its canvas coordinates:
    /// layer 0, not Penknife's, not transparent, bigger than 40 × 40 pt and showing at least
    /// 40 × 40 pt on that screen. `screenFrame` is in AppKit coordinates (bottom-left origin).
    static func windowTargets(list: [WindowInfo], ownPID: pid_t, screenFrame: CGRect, primaryHeight: CGFloat) -> [CaptureTarget] {
        let top = primaryHeight - screenFrame.maxY
        let local = CGRect(origin: .zero, size: screenFrame.size)
        return list.compactMap { info in
            guard info.layer == 0, info.ownerPID != ownPID, (info.alpha ?? 1) > 0,
                  info.bounds.width > 40, info.bounds.height > 40 else { return nil }
            let converted = info.bounds.offsetBy(dx: -screenFrame.minX, dy: -top)
            let visible = converted.intersection(local)
            return visible.isNull || visible.width < 40 || visible.height < 40 ? nil : .window(info.id, converted)
        }
    }

    /// Arrows in window mode: the next of `count` targets (the windows, then the desktop),
    /// wrapping both ways; with none highlighted, as if just before the first.
    static func nextTarget(current: Int?, count: Int, forward: Bool) -> Int {
        ((current ?? -1) + (forward ? 1 : -1) + count) % count
    }

    // MARK: Toolbar and size label (SS-18, SS-21)

    /// Below the selection; above when there's no room; inside its bottom when neither fits.
    /// Kept 8 pt from the sides and from the top.
    static func toolbarFrame(selection: CGRect, size: CGSize, bounds: CGRect) -> CGRect {
        var y = selection.maxY + 10
        if y + size.height > bounds.height - 8 {
            y = selection.minY - 10 - size.height
            if y < 8 { y = selection.maxY - size.height - 10 }
        }
        var x = selection.midX - size.width / 2
        x = min(max(x, 8), bounds.width - size.width - 8)
        return CGRect(x: x, y: max(y, 8), width: size.width, height: size.height)
    }

    /// "1600 × 900": the output pixels.
    static func sizeText(selection: CGRect, scale: CGFloat) -> String {
        "\(Int((selection.width * scale).rounded())) × \(Int((selection.height * scale).rounded()))"
    }

    /// The pill behind the size text: 12 pt above the top-left corner, inside it when there's no
    /// room, 4 pt from the sides.
    static func sizeLabelFrame(selection: CGRect, textSize size: CGSize, bounds: CGRect) -> CGRect {
        var pill = CGRect(x: selection.minX, y: selection.minY - size.height - 12, width: size.width + 14, height: size.height + 6)
        if pill.minY < 4 { pill.origin.y = selection.minY + 6; pill.origin.x += 6 }
        pill.origin.x = min(max(pill.minX, 4), bounds.width - pill.width - 4)
        return pill
    }

    // MARK: Scroll wheel (SS-26)

    /// One size step (+1 thicker, −1 thinner, 0 none) per wheel notch or per 24 pt of trackpad
    /// scrolling, by the physical direction. `accumulated` is the trackpad's leftover.
    static func scrollStep(delta: CGFloat, inverted: Bool, precise: Bool, accumulated: CGFloat, upThinner: Bool) -> (step: Int, accumulated: CGFloat) {
        // Physical direction: undo natural scrolling's inversion.
        var delta = delta * (inverted ? -1 : 1)
        if upThinner { delta = -delta }
        var accumulated = accumulated
        if precise {
            accumulated += delta
            guard abs(accumulated) >= 24 else { return (0, accumulated) }
            delta = accumulated
            accumulated = 0
        }
        guard delta != 0 else { return (0, accumulated) }
        return (delta > 0 ? 1 : -1, accumulated)
    }

    // MARK: Save (SS-48)

    /// "Screenshot 2026-11-19 at 10.00.00.png" in `folder`; " 2", " 3"… when the name is taken.
    static func saveURL(folder: URL, date: Date, exists: (URL) -> Bool) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: date)
        formatter.dateFormat = "HH.mm.ss"
        let time = formatter.string(from: date)
        var url = folder.appendingPathComponent(String(localized: "Screenshot \(day) at \(time)") + ".png")
        var copyNumber = 2
        while exists(url) {
            url = folder.appendingPathComponent(String(localized: "Screenshot \(day) at \(time)") + " \(copyNumber).png")
            copyNumber += 1
        }
        return url
    }
}

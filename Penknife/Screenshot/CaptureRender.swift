import AppKit

/// The screenshot's output (SS-34, SS-45): the selected part of the screen at full resolution,
/// with the marks drawn on it by the same code as on screen.
enum CaptureRender {
    /// `background` is the selected part at `scale` pixels per point; `selection` is where it
    /// sits on the screen, in points (the marks are stored in screen points).
    static func image(background: CGImage, scale: CGFloat, selection: CGRect, marks: [Annotation]) -> CGImage? {
        guard let context = CGContext(data: nil, width: background.width, height: background.height, bitsPerComponent: 8, bytesPerRow: 0,
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
        for mark in marks { mark.draw() }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }
}

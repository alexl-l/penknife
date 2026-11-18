import AVFoundation
import CoreImage

/// Blur while recording (R-32): the areas of the blur marks are blurred in every frame before it
/// is written, as strongly as the screenshot's blur (radius 9 pt), corner to corner, with its
/// light tint. Only the areas go through Core Image (on the GPU); the rest of the frame is copied
/// as is. Used on the writer's queue, only while there is a blur mark.
nonisolated final class FrameBlur {
    private let context = CIContext(options: [.cacheIntermediates: false, .name: "Penknife.recording.blur"])
    private let radius: CGFloat
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
    private var pool: CVPixelBufferPool?
    private var poolKey: (width: Int, height: Int, format: OSType)?

    /// `scale`: pixels per point of the recording.
    init(scale: CGFloat) {
        radius = 9 * scale
    }

    /// A copy of `sample` with `areas` (pixels, top-left origin) blurred, same timing. Nil when
    /// it can't be made: the caller then drops the frame rather than writing it unblurred.
    func apply(_ areas: [CGRect], to sample: CMSampleBuffer) -> CMSampleBuffer? {
        guard let source = sample.imageBuffer else { return nil }
        let width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source)
        guard let destination = makeBuffer(width: width, height: height, format: CVPixelBufferGetPixelFormatType(source)),
              copy(source, to: destination) else { return nil }
        CVBufferPropagateAttachments(source, destination)

        let image = CIImage(cvPixelBuffer: source)
        let extent = image.extent
        for area in areas {
            // Core Image's origin is bottom-left; even edges for the 4:2:0 color planes.
            let flipped = CGRect(x: area.minX, y: CGFloat(height) - area.maxY, width: area.width, height: area.height)
            let rect = Self.even(flipped.intersection(extent))
            guard rect.width >= 2, rect.height >= 2 else { continue }
            let blurred = image.cropped(to: rect.insetBy(dx: -radius * 3, dy: -radius * 3)).clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
                .cropped(to: rect)
            // The WHOLE rect, corners included: rounded corners left a few sharp pixels at each
            // corner of the file (security review, 2026-11-17).
            let patch = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.08)).cropped(to: rect).composited(over: blurred)
            context.render(patch, to: destination, bounds: rect, colorSpace: colorSpace)
        }

        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: destination, formatDescriptionOut: &format) == noErr,
              let format else { return nil }
        var timing = CMSampleTimingInfo()
        guard CMSampleBufferGetSampleTimingInfo(sample, at: 0, timingInfoOut: &timing) == noErr else { return nil }
        var result: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: destination, formatDescription: format,
                                                       sampleTiming: &timing, sampleBufferOut: &result) == noErr else { return nil }
        return result
    }

    /// Frees the buffers (no blur left).
    func reset() {
        pool = nil
        poolKey = nil
        context.clearCaches()
    }

    private func makeBuffer(width: Int, height: Int, format: OSType) -> CVPixelBuffer? {
        if poolKey?.width != width || poolKey?.height != height || poolKey?.format != format {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: format,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ]
            var created: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 3] as CFDictionary,
                                    attributes as CFDictionary, &created)
            pool = created
            poolKey = (width, height, format)
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess else { return nil }
        return buffer
    }

    /// Plane by plane, row by row (the rows may be padded differently).
    private func copy(_ source: CVPixelBuffer, to destination: CVPixelBuffer) -> Bool {
        guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        guard CVPixelBufferLockBaseAddress(destination, []) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(destination, []) }
        let planes = CVPixelBufferGetPlaneCount(source)
        guard planes == CVPixelBufferGetPlaneCount(destination) else { return false }
        if planes == 0 {
            guard let from = CVPixelBufferGetBaseAddress(source), let to = CVPixelBufferGetBaseAddress(destination) else { return false }
            Self.copyRows(from: from, fromStride: CVPixelBufferGetBytesPerRow(source), to: to,
                          toStride: CVPixelBufferGetBytesPerRow(destination), rows: CVPixelBufferGetHeight(source))
            return true
        }
        for plane in 0..<planes {
            guard let from = CVPixelBufferGetBaseAddressOfPlane(source, plane),
                  let to = CVPixelBufferGetBaseAddressOfPlane(destination, plane) else { return false }
            Self.copyRows(from: from, fromStride: CVPixelBufferGetBytesPerRowOfPlane(source, plane), to: to,
                          toStride: CVPixelBufferGetBytesPerRowOfPlane(destination, plane),
                          rows: CVPixelBufferGetHeightOfPlane(source, plane))
        }
        return true
    }

    private static func copyRows(from: UnsafeMutableRawPointer, fromStride: Int, to: UnsafeMutableRawPointer, toStride: Int, rows: Int) {
        if fromStride == toStride {
            to.copyMemory(from: from, byteCount: fromStride * rows)
            return
        }
        let length = min(fromStride, toStride)
        for row in 0..<rows {
            (to + row * toStride).copyMemory(from: from + row * fromStride, byteCount: length)
        }
    }

    private static func even(_ rect: CGRect) -> CGRect {
        guard !rect.isNull else { return .zero }
        let minX = (rect.minX / 2).rounded(.down) * 2, minY = (rect.minY / 2).rounded(.down) * 2
        let maxX = (rect.maxX / 2).rounded(.up) * 2, maxY = (rect.maxY / 2).rounded(.up) * 2
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

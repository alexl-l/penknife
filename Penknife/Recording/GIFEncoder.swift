import CoreGraphics
import Foundation

/// An endless-loop GIF written to its file one frame at a time (R-29), so memory holds one frame.
/// Each frame stores only what changed since the one before: the changed rectangle, with the
/// pixels that didn't change left transparent, and its own palette made from the changed pixels
/// (median cut, no dithering). Measured 2026-11-18: ImageIO's GIF encoder turned whole areas of a
/// dark gray background into black patches (5,488 black pixels in the frame, 38,024 in its GIF)
/// and stored every frame whole.
nonisolated final class GIFEncoder {
    let width: Int
    let height: Int
    private let handle: FileHandle
    private let step: Double
    private let context: CGContext
    /// Per pixel, the color on screen now (5 bits a channel; 0xFFFF: nothing yet).
    private var shown: [UInt16]
    private var current: [UInt16]
    private var indices: [UInt8]
    /// The last frame, waiting for its delay (known when a different frame comes).
    private var pending: (body: [UInt8], transparent: UInt8?)?
    private var frames = 0
    private var writtenHundredths = 0
    // Palette building, reused.
    private var counts = [UInt64](repeating: 0, count: 1 << 15)
    private var sums = [UInt64](repeating: 0, count: 3 << 15)
    private var lookup = [UInt8](repeating: 0, count: 1 << 15)
    // LZW dictionary: (prefix << 8 | index) → generation << 12 | code; a new generation empties it.
    private var dictionary = [UInt32](repeating: 0, count: 1 << 20)
    private var generation: UInt32 = 0

    /// `step`: seconds each source frame lasts.
    init(url: URL, width: Int, height: Int, step: Double) throws {
        guard width > 0, height > 0, width < 65_536, height < 65_536,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              FileManager.default.createFile(atPath: url.path, contents: nil) else { throw RecordingError.export }
        self.width = width
        self.height = height
        self.step = step
        self.context = context
        shown = [UInt16](repeating: 0xFFFF, count: width * height)
        current = [UInt16](repeating: 0, count: width * height)
        indices = [UInt8](repeating: 0, count: width * height)
        handle = try FileHandle(forWritingTo: url)
        var header = Array("GIF89a".utf8)
        header += Self.little(width) + Self.little(height)
        header += [0x00, 0x00, 0x00]                                       // no global palette
        header += [0x21, 0xFF, 0x0B] + Array("NETSCAPE2.0".utf8)            // loop forever
        header += [0x03, 0x01, 0x00, 0x00, 0x00]
        try handle.write(contentsOf: Data(header))
    }

    /// The next frame (`step` seconds long).
    func add(_ image: CGImage) throws {
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { throw RecordingError.export }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = y * width
            for x in 0..<width {
                let p = (row + x) * 4
                let key = UInt16(pixels[p] >> 3) << 10 | UInt16(pixels[p + 1] >> 3) << 5 | UInt16(pixels[p + 2] >> 3)
                current[row + x] = key
                if key != shown[row + x] {
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                    minY = min(minY, y)
                    maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= 0 else {
            repeatLast()                                                   // nothing changed
            return
        }
        try flush()
        pending = encode(rect: (minX, minY, maxX - minX + 1, maxY - minY + 1), pixels: pixels)
        frames += 1
    }

    /// The frame shown stays one `step` longer (a frame that couldn't be read, or didn't change).
    func repeatLast() {
        if pending != nil { frames += 1 }
    }

    func finish() throws {
        try flush()
        try handle.write(contentsOf: Data([0x3B]))
        try handle.close()
    }

    func close() throws { try handle.close() }

    // MARK: Private

    /// Writes the pending frame. Delays are whole hundredths: each frame ends at its rounded time,
    /// so they never drift.
    private func flush() throws {
        guard let frame = pending else { return }
        pending = nil
        let end = Int((Double(frames) * step * 100).rounded())
        let delay = min(max(end - writtenHundredths, 1), 65_535)
        writtenHundredths = end
        var bytes: [UInt8] = [0x21, 0xF9, 0x04, 0x04 | (frame.transparent == nil ? 0 : 0x01),   // keep the frame under it
                              UInt8(delay & 0xFF), UInt8(delay >> 8), frame.transparent ?? 0, 0x00]
        bytes += frame.body
        try handle.write(contentsOf: Data(bytes))
    }

    private func encode(rect: (x: Int, y: Int, width: Int, height: Int), pixels: UnsafeMutablePointer<UInt8>) -> (body: [UInt8], transparent: UInt8?) {
        // The changed pixels' colors.
        var used: [Int] = []
        var unchanged = false
        for y in rect.y..<rect.y + rect.height {
            for x in rect.x..<rect.x + rect.width {
                let i = y * width + x
                let key = Int(current[i])
                guard current[i] != shown[i] else {
                    unchanged = true
                    continue
                }
                if counts[key] == 0 { used.append(key) }
                counts[key] += 1
                let p = i * 4
                sums[key * 3] += UInt64(pixels[p])
                sums[key * 3 + 1] += UInt64(pixels[p + 1])
                sums[key * 3 + 2] += UInt64(pixels[p + 2])
            }
        }
        let palette = makePalette(&used, colors: unchanged ? 255 : 256)
        for key in used {
            counts[key] = 0
            sums[key * 3] = 0
            sums[key * 3 + 1] = 0
            sums[key * 3 + 2] = 0
        }
        let transparent: UInt8? = unchanged ? UInt8(palette.count / 3) : nil
        // The frame's pixels as palette indices; what changed is now on screen.
        var count = 0
        for y in rect.y..<rect.y + rect.height {
            for x in rect.x..<rect.x + rect.width {
                let i = y * width + x
                if current[i] == shown[i], let transparent {
                    indices[count] = transparent
                } else {
                    indices[count] = lookup[Int(current[i])]
                    shown[i] = current[i]
                }
                count += 1
            }
        }
        let entries = palette.count / 3 + (transparent == nil ? 0 : 1)
        var bits = 1
        while 1 << bits < entries { bits += 1 }
        var body: [UInt8] = [0x2C] + Self.little(rect.x) + Self.little(rect.y) + Self.little(rect.width) + Self.little(rect.height)
        body.append(0x80 | UInt8(bits - 1))                               // its own palette
        body += palette
        body += [UInt8](repeating: 0, count: 3 << bits - palette.count)
        let minimum = max(2, bits)
        body.append(UInt8(minimum))
        let compressed = lzw(count: count, minimum: minimum)
        var start = 0
        while start < compressed.count {
            let length = min(255, compressed.count - start)
            body.append(UInt8(length))
            body += compressed[start..<start + length]
            start += length
        }
        body.append(0x00)
        return (body, transparent)
    }

    /// Median cut of the used colors into at most `colors` boxes; each box's color is the average
    /// of its pixels. Fills `lookup` (color → index) and returns the palette (RGB).
    private func makePalette(_ used: inout [Int], colors: Int) -> [UInt8] {
        func channel(_ key: Int, _ c: Int) -> Int { key >> (10 - 5 * c) & 31 }
        struct Box { var start: Int, end: Int, count: UInt64, channel = 0, range = 0 }
        func measured(_ start: Int, _ end: Int, _ count: UInt64) -> Box {
            var low = [31, 31, 31], high = [0, 0, 0]
            for key in used[start..<end] {
                for c in 0..<3 {
                    low[c] = min(low[c], channel(key, c))
                    high[c] = max(high[c], channel(key, c))
                }
            }
            let c = (0..<3).max { high[$0] - low[$0] < high[$1] - low[$1] } ?? 0
            return Box(start: start, end: end, count: count, channel: c, range: high[c] - low[c])
        }
        var boxes = [measured(0, used.count, used.reduce(0) { $0 + counts[$1] })]
        while boxes.count < colors {
            // Split the box with the most pixels times the widest spread.
            var best = -1
            var bestScore = 0.0
            var bestChannel = 0
            for (index, box) in boxes.enumerated() where box.range > 0 {
                let score = Double(box.count) * Double(box.range)
                if score > bestScore {
                    best = index
                    bestScore = score
                    bestChannel = box.channel
                }
            }
            guard best >= 0 else { break }
            let box = boxes[best]
            used[box.start..<box.end].sort { (channel($0, bestChannel), $0) < (channel($1, bestChannel), $1) }
            var half: UInt64 = 0
            var split = box.start + 1
            for index in box.start..<box.end - 1 {
                half += counts[used[index]]
                split = index + 1
                if half * 2 >= box.count { break }
            }
            boxes[best] = measured(box.start, split, half)
            boxes.append(measured(split, box.end, box.count - half))
        }
        var palette: [UInt8] = []
        palette.reserveCapacity(boxes.count * 3)
        for (index, box) in boxes.enumerated() {
            var r: UInt64 = 0, g: UInt64 = 0, b: UInt64 = 0
            for key in used[box.start..<box.end] {
                r += sums[key * 3]
                g += sums[key * 3 + 1]
                b += sums[key * 3 + 2]
                lookup[key] = UInt8(index)
            }
            let count = max(box.count, 1)
            palette += [UInt8(r / count), UInt8(g / count), UInt8(b / count)]
        }
        return palette
    }

    /// GIF's LZW compression of the first `count` indices.
    private func lzw(count: Int, minimum: Int) -> [UInt8] {
        let clear = 1 << minimum, end = clear + 1
        var next = end + 1, size = minimum + 1
        var out: [UInt8] = []
        out.reserveCapacity(count / 2)
        var buffer: UInt64 = 0, bits = 0
        func emit(_ code: Int) {
            buffer |= UInt64(code) << bits
            bits += size
            while bits >= 8 {
                out.append(UInt8(buffer & 0xFF))
                buffer >>= 8
                bits -= 8
            }
        }
        func restart() {
            generation += 1
            if generation >= 1 << 20 {
                dictionary = [UInt32](repeating: 0, count: 1 << 20)
                generation = 1
            }
        }
        restart()
        emit(clear)
        var prefix = Int(indices[0])
        for i in 1..<max(count, 1) {
            let index = Int(indices[i])
            let key = prefix << 8 | index
            let entry = dictionary[key]
            if entry >> 12 == generation {
                prefix = Int(entry & 0xFFF)
                continue
            }
            emit(prefix)
            if next == 4096 {
                emit(clear)
                next = end + 1
                size = minimum + 1
                restart()
            } else {
                if next >= 1 << size { size += 1 }
                dictionary[key] = generation << 12 | UInt32(next)
                next += 1
            }
            prefix = index
        }
        emit(prefix)
        emit(end)
        if bits > 0 { out.append(UInt8(buffer & 0xFF)) }
        return out
    }

    private static func little(_ value: Int) -> [UInt8] { [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)] }
}

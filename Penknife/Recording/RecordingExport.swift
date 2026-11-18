import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Turns a finished recording into the files the user keeps (R-29): one MP4 with a single sound
/// track (so every player hears both the Mac and the voice), and a GIF.
nonisolated enum RecordingExport {
    /// The movie plus every sound stretch, mixed into one track, as `output` (MP4). The video is
    /// copied as it is (no new encoding).
    @concurrent
    static func movie(_ recording: RecordingWriter.Output, to output: URL) async throws {
        let videoAsset = AVURLAsset(url: recording.video)
        guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first else { throw RecordingError.export }
        let length = min(try await videoAsset.load(.duration), recording.duration.isValid ? recording.duration : CMTime.positiveInfinity)
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw RecordingError.export
        }
        try video.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: videoTrack, at: .zero)

        if !recording.segments.isEmpty {
            let mixed = output.deletingLastPathComponent().appendingPathComponent("sound.m4a")
            try? FileManager.default.removeItem(at: mixed)
            try await mix(recording.segments, length: length, to: mixed)
            let mixedAsset = AVURLAsset(url: mixed)
            if let mixedTrack = try await mixedAsset.loadTracks(withMediaType: .audio).first,
               let sound = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                let soundLength = min(try await mixedAsset.load(.duration), length)
                try sound.insertTimeRange(CMTimeRange(start: .zero, duration: soundLength), of: mixedTrack, at: .zero)
            }
        }

        try? FileManager.default.removeItem(at: output)
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw RecordingError.export
        }
        session.shouldOptimizeForNetworkUse = true
        try await session.export(to: output, as: .mp4)
    }

    /// The stretches placed on one timeline from 0 to `length` and mixed into one AAC track
    /// (silence where there was no sound).
    private static func mix(_ segments: [RecordingWriter.Segment], length: CMTime, to output: URL) async throws {
        let composition = AVMutableComposition()
        for segment in segments where segment.start < length {
            let asset = AVURLAsset(url: segment.url)
            guard let track = try await asset.loadTracks(withMediaType: .audio).first,
                  let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            let duration = min(try await asset.load(.duration), length - segment.start)
            try target.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: segment.start)
        }
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw RecordingError.export
        }
        session.timeRange = CMTimeRange(start: .zero, duration: length)
        try await session.export(to: output, as: .m4a)
    }

    /// The part of `movie` within `range` (R-33), without re-encoding: the cut is exact on
    /// playback (the file keeps an edit list from the keyframe before).
    @concurrent
    static func trim(_ movie: URL, range: CMTimeRange, to output: URL) async throws {
        try? FileManager.default.removeItem(at: output)
        guard let session = AVAssetExportSession(asset: AVURLAsset(url: movie), presetName: AVAssetExportPresetPassthrough) else {
            throw RecordingError.export
        }
        session.timeRange = range
        try await session.export(to: output, as: .mp4)
    }

    /// An endless-loop GIF of `movie`, at most `maxSize` pixels, `frameRate` frames a second.
    /// Frames that don't change are merged into one longer frame, which keeps still screens small.
    /// `progress` gets 0…1 (from this task, whole percents only).
    @concurrent
    static func gif(from movie: URL, to output: URL, maxSize: CGSize, frameRate: Double = 12,
                    progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let asset = AVURLAsset(url: movie)
        let duration = try await asset.load(.duration).seconds
        let count = max(1, Int((duration * frameRate).rounded(.up)))
        let step = 1 / frameRate
        let generator = AVAssetImageGenerator(asset: asset)
        generator.maximumSize = maxSize
        generator.appliesPreferredTrackTransform = true
        let tolerance = CMTime(seconds: step / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        try? FileManager.default.removeItem(at: output)
        var gif: GIFStream?
        var held: (image: CGImage, pixels: Data?, frames: Int)?
        // Delays are whole hundredths: each frame ends at its rounded time, so they never drift.
        var frameCount = 0
        var writtenHundredths = 0
        func write(_ frame: (image: CGImage, pixels: Data?, frames: Int)) throws {
            frameCount += frame.frames
            let end = Int((Double(frameCount) * step * 100).rounded())
            let stream = try gif ?? GIFStream(url: output, width: frame.image.width, height: frame.image.height)
            gif = stream
            try stream.add(frame.image, delay: end - writtenHundredths)
            writtenHundredths = end
        }
        do {
            // One at a time: asking for all the frames at once failed to decode about a third of
            // them (measured 2026-11-17).
            var percent = -1
            for index in 0..<count {
                try Task.checkCancellation()
                let done = index * 100 / count
                if done != percent {
                    percent = done
                    progress?(Double(done) / 100)
                }
                let image = try? await generator.image(at: CMTime(seconds: Double(index) * step, preferredTimescale: 600)).image
                let pixels = image?.dataProvider?.data as Data?
                if var current = held, image == nil || (pixels != nil && current.pixels == pixels) {
                    current.frames += 1
                    held = current
                    continue
                }
                guard let image else { continue }
                if let current = held { try write(current) }
                held = (image, pixels, 1)
            }
            if let current = held { try write(current) }
            guard let gif else { throw RecordingError.export }
            try gif.finish()
        } catch {
            try? gif?.close()
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }
}

/// An animated GIF written to its file one frame at a time, so memory holds one frame, not the
/// whole clip (ImageIO's own animated GIF keeps every frame until the end: 1.3 GB for 30 s of a
/// busy 720p screen, measured 2026-11-17). Each frame is still encoded by ImageIO on its own
/// (palette and compression); its image is then moved into this file with its own palette.
nonisolated final class GIFStream {
    private let handle: FileHandle

    init(url: URL, width: Int, height: Int) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw RecordingError.export }
        handle = try FileHandle(forWritingTo: url)
        var header = Data("GIF89a".utf8)
        header.append(contentsOf: Self.little(width) + Self.little(height))
        header.append(contentsOf: [0x00, 0x00, 0x00])                      // no global palette
        header.append(contentsOf: [0x21, 0xFF, 0x0B])                      // loop forever
        header.append(contentsOf: Data("NETSCAPE2.0".utf8))
        header.append(contentsOf: [0x03, 0x01, 0x00, 0x00, 0x00])
        try handle.write(contentsOf: header)
    }

    /// `delay`: hundredths of a second this frame stays.
    func add(_ image: CGImage, delay: Int) throws {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, 1, nil) else {
            throw RecordingError.export
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw RecordingError.export }
        try handle.write(contentsOf: Self.frame(from: data as Data, delay: min(max(delay, 1), 65_535)))
    }

    func finish() throws {
        try handle.write(contentsOf: Data([0x3B]))
        try handle.close()
    }

    func close() throws { try handle.close() }

    /// From a one-frame GIF: a new Graphic Control Extension (delay, transparency kept) and its
    /// image, with the file's palette moved next to the image.
    static func frame(from gif: Data, delay: Int) throws -> Data {
        let bytes = [UInt8](gif)
        guard bytes.count > 13, bytes[0] == 0x47, bytes[1] == 0x49, bytes[2] == 0x46 else { throw RecordingError.export }
        var index = 13
        var globalTable: [UInt8] = []
        var globalBits: UInt8 = 0
        if bytes[10] & 0x80 != 0 {
            globalBits = bytes[10] & 0x07
            let size = 3 << (Int(globalBits) + 1)
            guard index + size <= bytes.count else { throw RecordingError.export }
            globalTable = Array(bytes[index..<index + size])
            index += size
        }
        var transparent: UInt8?
        func skipSubBlocks() throws {
            while index < bytes.count, bytes[index] != 0 { index += Int(bytes[index]) + 1 }
            guard index < bytes.count else { throw RecordingError.export }
            index += 1
        }
        while index < bytes.count {
            switch bytes[index] {
            case 0x21:                                                     // extension
                guard index + 1 < bytes.count else { throw RecordingError.export }
                if bytes[index + 1] == 0xF9, index + 6 < bytes.count, bytes[index + 3] & 0x01 != 0 {
                    transparent = bytes[index + 6]
                }
                index += 2
                try skipSubBlocks()
            case 0x2C:                                                     // the image
                guard index + 10 <= bytes.count else { throw RecordingError.export }
                var descriptor = Array(bytes[index..<index + 10])
                index += 10
                var table: [UInt8] = []
                if descriptor[9] & 0x80 != 0 {
                    let size = 3 << (Int(descriptor[9] & 0x07) + 1)
                    guard index + size <= bytes.count else { throw RecordingError.export }
                    table = Array(bytes[index..<index + size])
                    index += size
                } else {
                    guard !globalTable.isEmpty else { throw RecordingError.export }
                    descriptor[9] = 0x80 | (descriptor[9] & 0x40) | globalBits
                    table = globalTable
                }
                let start = index
                index += 1                                                 // LZW code size
                try skipSubBlocks()
                var frame: [UInt8] = [0x21, 0xF9, 0x04, 0x04 | (transparent == nil ? 0 : 0x01),
                                      UInt8(delay & 0xFF), UInt8(delay >> 8), transparent ?? 0, 0x00]
                frame += descriptor + table
                frame += bytes[start..<index]
                return Data(frame)
            default:
                throw RecordingError.export
            }
        }
        throw RecordingError.export
    }

    private static func little(_ value: Int) -> [UInt8] { [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)] }
}

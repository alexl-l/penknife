import AVFoundation

/// Turns a finished recording into the files the user keeps (R-29): one MP4 with a single sound
/// track (so every player hears both the Mac and the voice), and a GIF.
nonisolated enum RecordingExport {
    /// The movie plus every sound stretch, mixed into one track, as `output` (MP4). The video is
    /// copied as it is (no new encoding). When the sound can't be prepared the movie is made
    /// without it rather than lost (B-16); returns false then.
    @concurrent @discardableResult
    static func movie(_ recording: RecordingWriter.Output, to output: URL) async throws -> Bool {
        let videoAsset = AVURLAsset(url: recording.video)
        guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first else { throw RecordingError.export }
        let length = min(try await videoAsset.load(.duration), recording.duration.isValid ? recording.duration : CMTime.positiveInfinity)
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw RecordingError.export
        }
        try video.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: videoTrack, at: .zero)

        var soundKept = true
        if !recording.segments.isEmpty {
            let mixed = output.deletingLastPathComponent().appendingPathComponent("sound.m4a")
            try? FileManager.default.removeItem(at: mixed)
            var added: AVMutableCompositionTrack?
            do {
                try await mix(recording.segments, length: length, to: mixed)
                let mixedAsset = AVURLAsset(url: mixed)
                if let mixedTrack = try await mixedAsset.loadTracks(withMediaType: .audio).first,
                   let sound = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                    added = sound
                    let soundLength = min(try await mixedAsset.load(.duration), length)
                    try sound.insertTimeRange(CMTimeRange(start: .zero, duration: soundLength), of: mixedTrack, at: .zero)
                }
            } catch {
                RecordingLog.log.error("Sound not prepared, video kept without it: \(error.localizedDescription, privacy: .public)")
                if let added { composition.removeTrack(added) }
                soundKept = false
            }
        }

        try? FileManager.default.removeItem(at: output)
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw RecordingError.export
        }
        session.shouldOptimizeForNetworkUse = true
        try await session.export(to: output, as: .mp4)
        return soundKept
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
    /// Each frame keeps only what changed (`GIFEncoder`); frames that don't change make the frame
    /// before them last longer, which keeps still screens small.
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
        var gif: GIFEncoder?
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
                guard let image = try? await generator.image(at: CMTime(seconds: Double(index) * step, preferredTimescale: 600)).image else {
                    gif?.repeatLast()
                    continue
                }
                let encoder = try gif ?? GIFEncoder(url: output, width: image.width, height: image.height, step: step)
                gif = encoder
                try encoder.add(image)
            }
            guard let gif else { throw RecordingError.export }
            try gif.finish()
        } catch {
            try? gif?.close()
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }
}

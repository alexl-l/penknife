import AVFoundation
import OSLog

nonisolated enum RecordingLog {
    static let log = Logger(subsystem: "Penknife", category: "Recording")
}

nonisolated enum RecordingError: Error {
    case writer, noDisplay, export
}

/// Writes one recording (R-29): the screen to a movie (hardware H.264) and each stretch of
/// sound (Mac or microphone) to its own audio file, all on one timeline with the pauses cut out.
/// Everything happens on `queue`, where the samples arrive too. Times come in on the host clock.
nonisolated final class RecordingWriter: @unchecked Sendable {
    enum Source: Hashable, Sendable { case sound, mic }

    /// A stretch of sound without gaps, starting at `start` on the recording's timeline.
    struct Segment: Sendable {
        let url: URL
        let start: CMTime
    }

    struct Output: Sendable {
        let video: URL
        let segments: [Segment]
        let duration: CMTime
    }

    let queue = DispatchQueue(label: "Penknife.recording", qos: .userInitiated)
    let folder: URL
    private let videoURL: URL
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput

    /// Host time of the recording's start (t = 0), set when the countdown ends.
    private var origin: CMTime?
    /// Host time after which nothing is kept (set at Stop, before the drawings go away).
    private var cut: CMTime?
    private var pauses: [(start: CMTime, end: CMTime?)] = []
    private var sessionStarted = false
    /// The newest frame before the start: the screen only sends a frame when something changes,
    /// so this one opens the movie.
    private var pendingFrame: CMSampleBuffer?
    /// The newest frame during a pause: shown from the resume on (the screen may have changed
    /// during the pause and then stayed still, sending nothing more).
    private var pausedFrame: CMSampleBuffer?
    private var lastFrameTime = CMTime.invalid
    private var enabled: Set<Source> = []
    private var tracks: [Source: AudioTrack] = [:]
    private var segments: [Segment] = []
    private var segmentCount = 0
    private var finishing = false
    private var failedAppends = 0
    private let group = DispatchGroup()
    /// R-32: the areas blurred in every frame (pixels, top-left origin), and what blurs them.
    private var blurAreas: [CGRect] = []
    private let blur: FrameBlur
    private var failedBlurs = 0

    private final class AudioTrack: @unchecked Sendable {
        let writer: AVAssetWriter
        let input: AVAssetWriterInput
        let segment: Segment
        var next: CMTime

        init(writer: AVAssetWriter, input: AVAssetWriterInput, segment: Segment) {
            self.writer = writer
            self.input = input
            self.segment = segment
            next = segment.start
        }
    }

    /// `scale`: pixels per point (for the blur's strength).
    init(folder: URL, width: Int, height: Int, scale: CGFloat, frameRate: Int = 30) throws {
        self.folder = folder
        blur = FrameBlur(scale: scale)
        videoURL = folder.appendingPathComponent("video.mov")
        writer = try AVAssetWriter(outputURL: videoURL, fileType: .mov)
        let pixels = Double(width * height)
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                // Screens are mostly still: about 3 bits per pixel per second is sharp enough.
                AVVideoAverageBitRateKey: Int(min(max(pixels * 3, 2_000_000), 24_000_000)),
                AVVideoExpectedSourceFrameRateKey: frameRate,
                AVVideoMaxKeyFrameIntervalKey: frameRate * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoAllowFrameReorderingKey: false,
            ],
        ])
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else { throw RecordingError.writer }
        writer.add(videoInput)
        guard writer.startWriting() else { throw writer.error ?? RecordingError.writer }
    }

    // MARK: Control (any thread)

    func begin(at host: CMTime) {
        queue.async { [self] in
            origin = host
            if let frame = pendingFrame { appendFrame(frame, at: .zero) }
            pendingFrame = nil
        }
    }

    func pause(at host: CMTime) {
        queue.async { [self] in
            guard pauses.last.map({ $0.end != nil }) ?? true else { return }
            pauses.append((host, nil))
        }
    }

    func resume(at host: CMTime) {
        queue.async { [self] in
            guard let last = pauses.indices.last, pauses[last].end == nil else { return }
            pauses[last].end = host
            if let frame = pausedFrame, let time = time(at: host) { appendFrame(frame, at: time) }
            pausedFrame = nil
        }
    }

    /// Whether the Mac's sound or the microphone goes into the recording from now on.
    func setEnabled(_ source: Source, _ on: Bool) {
        queue.async { [self] in
            if on {
                enabled.insert(source)
            } else {
                enabled.remove(source)
                close(source)
            }
        }
    }

    /// Nothing captured after `host` is kept.
    func cut(at host: CMTime) {
        queue.async { [self] in if cut == nil { cut = host } }
    }

    // MARK: Samples (on `queue`)

    func appendVideo(_ buffer: CMSampleBuffer) {
        guard !finishing else { return }
        let host = buffer.presentationTimeStamp
        if let cut, host > cut { return }
        guard origin != nil else {
            pendingFrame = buffer
            return
        }
        guard let time = time(at: host) else {
            if let last = pauses.last, last.end == nil, host >= last.start { pausedFrame = buffer }
            return
        }
        appendFrame(buffer, at: time)
    }

    /// `host`: the buffer's start on the host clock, when it uses another clock.
    func appendAudio(_ buffer: CMSampleBuffer, from source: Source, host: CMTime? = nil) {
        let host = host ?? buffer.presentationTimeStamp
        guard !finishing, enabled.contains(source), cut.map({ host <= $0 }) ?? true, let time = time(at: host) else {
            close(source)
            return
        }
        // A jump (the source was off, or samples were lost) starts a new stretch.
        if let track = tracks[source], abs((time - track.next).seconds) > 0.2 { close(source) }
        guard let track = tracks[source] ?? open(source, buffer: buffer, at: time) else { return }
        guard track.input.isReadyForMoreMediaData, let copy = Self.retimed(buffer, to: time) else { return }
        if track.input.append(copy) {
            let duration = CMSampleBufferGetDuration(buffer)
            track.next = time + (duration.isValid ? duration : .zero)
        }
    }

    // MARK: Finish

    /// Ends the recording at the cut (or now); stopping while paused ends it where the pause began.
    func finish(at host: CMTime) async -> Output? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                finishing = true
                pendingFrame = nil
                pausedFrame = nil
                var end = cut ?? host
                if let last = pauses.last, last.end == nil {
                    end = last.start
                    pauses.removeLast()
                }
                let duration = max(time(at: end) ?? .zero, lastFrameTime.isValid ? lastFrameTime : .zero)
                for source in Array(tracks.keys) { close(source) }
                guard sessionStarted else {
                    writer.cancelWriting()
                    group.notify(queue: queue) { continuation.resume(returning: nil) }
                    return
                }
                videoInput.markAsFinished()
                writer.endSession(atSourceTime: duration)
                group.enter()
                writer.finishWriting { [self] in group.leave() }
                group.notify(queue: queue) { [self] in
                    guard writer.status == .completed else {
                        RecordingLog.log.error("Movie not written: \(String(describing: self.writer.error), privacy: .public)")
                        continuation.resume(returning: nil)
                        return
                    }
                    let sorted = segments.sorted { $0.start < $1.start }
                    RecordingLog.log.info("Recorded \(duration.seconds, format: .fixed(precision: 1)) s, \(sorted.count) sound stretches")
                    continuation.resume(returning: Output(video: videoURL, segments: sorted, duration: duration))
                }
            }
        }
    }

    /// Stops without keeping anything.
    func discard() {
        queue.async { [self] in
            finishing = true
            pendingFrame = nil
            pausedFrame = nil
            for (_, track) in tracks { track.writer.cancelWriting() }
            tracks.removeAll()
            if writer.status == .writing { writer.cancelWriting() }
        }
    }

    /// The blur marks' areas, from now on (pixels, top-left origin; empty: none).
    func setBlurAreas(_ areas: [CGRect]) {
        queue.async { [self] in
            if areas.isEmpty, !blurAreas.isEmpty { blur.reset() }
            blurAreas = areas
        }
    }

    // MARK: Private (on `queue`)

    private func appendFrame(_ buffer: CMSampleBuffer, at time: CMTime) {
        if lastFrameTime.isValid, time <= lastFrameTime { return }
        guard videoInput.isReadyForMoreMediaData else { return }
        var frame = buffer
        if !blurAreas.isEmpty {
            // A frame that can't be blurred is dropped, never written as it was.
            guard let blurred = blur.apply(blurAreas, to: buffer) else {
                failedBlurs += 1
                if failedBlurs == 1 { RecordingLog.log.error("Frame not blurred: dropped") }
                return
            }
            frame = blurred
        }
        guard let copy = Self.retimed(frame, to: time) else { return }
        if !sessionStarted {
            writer.startSession(atSourceTime: .zero)
            sessionStarted = true
        }
        if videoInput.append(copy) {
            lastFrameTime = time
        } else {
            failedAppends += 1
            if failedAppends == 1 {
                RecordingLog.log.error("Frame not written: \(String(describing: self.writer.error), privacy: .public)")
            }
        }
    }

    /// Where a host-clock instant falls on the recording's timeline (pauses cut out); nil before
    /// the start or inside a pause.
    private func time(at host: CMTime) -> CMTime? {
        guard let origin, host >= origin else { return nil }
        var paused = CMTime.zero
        for pause in pauses where host >= pause.start {
            guard let end = pause.end, host >= end else { return nil }
            paused = paused + (end - pause.start)
        }
        return host - origin - paused
    }

    private func open(_ source: Source, buffer: CMSampleBuffer, at time: CMTime) -> AudioTrack? {
        guard let format = CMSampleBufferGetFormatDescription(buffer) else { return nil }
        let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
        let channels = min(max(Int(description?.mChannelsPerFrame ?? 2), 1), 2)
        segmentCount += 1
        let url = folder.appendingPathComponent("audio-\(segmentCount).m4a")
        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: channels == 1 ? 96_000 : 160_000,
            ], sourceFormatHint: format)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { return nil }
            writer.add(input)
            guard writer.startWriting() else { return nil }
            writer.startSession(atSourceTime: time)
            let track = AudioTrack(writer: writer, input: input, segment: Segment(url: url, start: time))
            tracks[source] = track
            return track
        } catch {
            RecordingLog.log.error("Sound not written: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func close(_ source: Source) {
        guard let track = tracks.removeValue(forKey: source) else { return }
        guard track.next > track.segment.start else {
            track.writer.cancelWriting()
            return
        }
        track.input.markAsFinished()
        track.writer.endSession(atSourceTime: track.next)
        group.enter()
        track.writer.finishWriting { [self] in
            queue.async { [self] in
                if track.writer.status == .completed { segments.append(track.segment) }
                group.leave()
            }
        }
    }

    /// The same samples, moved to `time` (every timing entry shifted alike).
    static func retimed(_ buffer: CMSampleBuffer, to time: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count) == noErr,
              count > 0 else { return nil }
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: count, arrayToFill: &timings, entriesNeededOut: &count) == noErr else { return nil }
        let offset = time - buffer.presentationTimeStamp
        for index in timings.indices {
            timings[index].presentationTimeStamp = timings[index].presentationTimeStamp + offset
            timings[index].decodeTimeStamp = .invalid
        }
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: buffer, sampleTimingEntryCount: count,
                                                           sampleTimingArray: &timings, sampleBufferOut: &copy)
        return status == noErr ? copy : nil
    }
}

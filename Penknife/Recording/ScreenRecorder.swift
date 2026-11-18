import AVFoundation
@preconcurrency import ScreenCaptureKit

/// The live capture behind a recording (R-29): ScreenCaptureKit for the screen and the Mac's
/// sound, an AVCaptureSession for the microphone (only while its switch is on, so macOS shows
/// the microphone in use only then). Samples go straight to the writer's queue.
nonisolated final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, AVCaptureAudioDataOutputSampleBufferDelegate,
    @unchecked Sendable {
    let writer: RecordingWriter
    private let filter: SCContentFilter
    private let configuration: SCStreamConfiguration
    private var stream: SCStream?
    private let micQueue = DispatchQueue(label: "Penknife.recording.mic")
    private let lock = NSLock()
    /// Guarded by `lock`: read on the writer's queue for each microphone sample.
    private var mic: AVCaptureSession?
    /// Called (on any thread) when macOS stops the capture, e.g. from its own menu.
    var onStop: (@Sendable (any Error) -> Void)?
    /// Called (on any thread) when the microphone couldn't start (none, or not allowed).
    var onMicrophoneFailed: (@Sendable () -> Void)?

    static var hostNow: CMTime { CMClockGetTime(CMClockGetHostTimeClock()) }

    init(filter: SCContentFilter, configuration: SCStreamConfiguration, writer: RecordingWriter) {
        self.filter = filter
        self.configuration = configuration
        self.writer = writer
    }

    /// Starts capturing; nothing is kept until `begin()`.
    func start() async throws {
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: writer.queue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: writer.queue)
        self.stream = stream
        try await stream.startCapture()
    }

    func begin() { writer.begin(at: Self.hostNow) }
    func pause() { writer.pause(at: Self.hostNow) }
    func resume() { writer.resume(at: Self.hostNow) }

    /// The Mac's sound: captured only while its switch is on.
    func setSound(_ on: Bool) {
        writer.setEnabled(.sound, on)
        guard configuration.capturesAudio != on, let stream else { return }
        configuration.capturesAudio = on
        stream.updateConfiguration(configuration) { error in
            if let error { RecordingLog.log.error("Mac sound not switched: \(error.localizedDescription, privacy: .public)") }
        }
    }

    func setMicrophone(_ on: Bool) {
        writer.setEnabled(.mic, on)
        micQueue.async { [self] in
            guard on else {
                stopMicrophone()
                return
            }
            if !startMicrophone() {
                writer.setEnabled(.mic, false)
                onMicrophoneFailed?()
            }
        }
    }

    /// Nothing captured from now on is kept.
    func cut() { writer.cut(at: Self.hostNow) }

    /// Stops capturing and writes the files (up to the cut, or now).
    func finish() async -> RecordingWriter.Output? {
        let end = Self.hostNow
        writer.cut(at: end)
        await stopCapture()
        return await writer.finish(at: end)
    }

    func cancel() async {
        writer.discard()
        await stopCapture()
    }

    private func stopCapture() async {
        if let stream { try? await stream.stopCapture() }
        stream = nil
        await withCheckedContinuation { continuation in
            micQueue.async { [self] in
                stopMicrophone()
                continuation.resume()
            }
        }
    }

    // MARK: Microphone (on micQueue)

    /// False when there's no microphone or it can't be opened.
    private func startMicrophone() -> Bool {
        guard lock.withLock({ mic == nil }) else { return true }
        guard let device = AVCaptureDevice.default(for: .audio), let input = try? AVCaptureDeviceInput(device: device) else {
            RecordingLog.log.error("No microphone to record")
            return false
        }
        let session = AVCaptureSession()
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        output.setSampleBufferDelegate(self, queue: writer.queue)
        guard session.canAddInput(input), session.canAddOutput(output) else {
            RecordingLog.log.error("Microphone can't be opened")
            return false
        }
        session.addInput(input)
        session.addOutput(output)
        lock.withLock { mic = session }
        session.startRunning()
        return true
    }

    private func stopMicrophone() {
        let session = lock.withLock { () -> AVCaptureSession? in
            defer { mic = nil }
            return mic
        }
        session?.stopRunning()
    }

    // MARK: Samples (on the writer's queue)

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .screen:
            guard Self.isComplete(sampleBuffer) else { return }
            writer.appendVideo(sampleBuffer)
        case .audio:
            writer.appendAudio(sampleBuffer, from: .sound)
        default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        RecordingLog.log.error("Capture stopped: \(error.localizedDescription, privacy: .public)")
        onStop?(error)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // The microphone's samples are timed on the capture session's clock: moved to the host
        // clock, which the screen uses.
        let host = CMClockGetHostTimeClock()
        var time = sampleBuffer.presentationTimeStamp
        if let clock = lock.withLock({ mic?.synchronizationClock }), !CFEqual(clock, host) {
            time = CMSyncConvertTime(time, from: clock, to: host)
        }
        writer.appendAudio(sampleBuffer, from: .mic, host: time)
    }

    /// Only frames with new content (not "nothing changed" notices).
    private static func isComplete(_ buffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return false }
        return status == .complete
    }
}

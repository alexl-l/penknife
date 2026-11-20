import AVFoundation
import Foundation
import Testing
@testable import Penknife

/// Screen recording rules (docs/requirements/recording.md). Each test names the rule it checks.
/// Nothing here records the screen, opens a window or touches the user's folders: movies are
/// made from synthetic frames and a sine tone in a temp folder, removed at the end.
@MainActor
@Suite("Recording rules")
struct RecordingRulesTests {

    // MARK: Helpers

    nonisolated static func seconds(_ value: Double) -> CMTime { CMTime(seconds: value, preferredTimescale: 600) }

    nonisolated static func range(_ start: Double, _ end: Double) -> CMTimeRange {
        CMTimeRange(start: seconds(start), end: seconds(end))
    }

    /// A temp folder ("PenknifeTests-Recording-…").
    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "PenknifeTests-Recording-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// An MP4 of `length` seconds: 64×64 H.264 at 30 fps, plus (when `tone` is set) a mono AAC
    /// sine at that frequency, as the recording's own movie is (one video, one sound track).
    nonisolated static func movie(length: Double, tone: Double?, in folder: URL) async throws -> URL {
        let video = folder.appending(path: "video.mp4")
        let writer = try AVAssetWriter(outputURL: video, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64,
        ])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let frames = Int(length * 30)
        for index in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            let pixels = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels), Int32(index * 4 % 256), CVPixelBufferGetDataSize(pixels))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard let tone else { return video }

        let sound = folder.appending(path: "tone.m4a")
        let rate = 44_100.0
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let file = try AVAudioFile(forWriting: sound, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
        ])
        let count = AVAudioFrameCount(length * rate)
        let samples = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count))
        samples.frameLength = count
        for index in 0..<Int(count) {
            samples.floatChannelData![0][index] = Float(0.5 * sin(2 * .pi * tone * Double(index) / rate))
        }
        try file.write(from: samples)
        file.close()

        let composition = AVMutableComposition()
        // The assets are kept in variables: a track whose asset is gone can't be exported.
        let videoAsset = AVURLAsset(url: video), soundAsset = AVURLAsset(url: sound)
        let videoTrack = try #require(try await videoAsset.loadTracks(withMediaType: .video).first)
        let all = try await videoTrack.load(.timeRange)
        let soundTrack = try #require(try await soundAsset.loadTracks(withMediaType: .audio).first)
        try composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
            .insertTimeRange(all, of: videoTrack, at: .zero)
        let soundLength = min(try await soundAsset.load(.duration), all.duration)
        try composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
            .insertTimeRange(CMTimeRange(start: .zero, duration: soundLength), of: soundTrack, at: .zero)
        let movie = folder.appending(path: "movie.mp4")
        let session = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        try await session.export(to: movie, as: .mp4)
        return movie
    }

    /// The main frequency of the file's sound (rising zero crossings a second), away from both ends.
    nonisolated static func frequency(of url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let rate = 44_100.0
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
            AVNumberOfChannelsKey: 1, AVSampleRateKey: rate,
        ])
        reader.add(output)
        #expect(reader.startReading())
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            var chunk = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / 4)
            chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
            samples += chunk
        }
        let skip = Int(0.2 * rate)
        let middle = samples.dropFirst(skip).dropLast(skip)
        let crossings = zip(middle, middle.dropFirst()).count { $0 < 0 && $1 >= 0 }
        return Double(crossings) / (Double(middle.count) / rate)
    }

    nonisolated static func duration(_ url: URL, _ type: AVMediaType) async throws -> Double? {
        guard let track = try await AVURLAsset(url: url).loadTracks(withMediaType: type).first else { return nil }
        return try await track.load(.timeRange).duration.seconds
    }

    // MARK: REC-50 Speed

    // REC-50: the speed menu's names: "1×", "1.5×" ("1,5×" in Spanish), "2×", "4×".
    @Test("REC-50 speed names")
    func speedNames() {
        #expect(RecordingEndWindow.speedName(1) == "1×")
        #expect(["1.5×", "1,5×"].contains(RecordingEndWindow.speedName(1.5)))
        #expect(RecordingEndWindow.speedName(2) == "2×")
        #expect(RecordingEndWindow.speedName(4) == "4×")
    }

    // REC-50 / R-33: at 1× without a trim the note shows length and size; at another speed the
    // length it will last and the speed, never the size (unknown until made, so not even read);
    // with a trim, the trim in the recording's own time.
    @Test("REC-50 R-33 the note: length it will last, speed, trim")
    func note() {
        let twelve = Self.seconds(12)
        var read = 0
        func bytes() -> Int64 { read += 1; return 3_000_000 }

        let normal = RecordingEndWindow.notes(length: twelve, trim: nil, speed: 1, bytes: bytes())
        #expect(normal.note.hasPrefix("0:12 · "))
        #expect(normal.note.contains("MB"))
        #expect(normal.trimNote == "")
        #expect(read == 1)

        let fast = RecordingEndWindow.notes(length: twelve, trim: nil, speed: 2, bytes: bytes())
        #expect(fast.note == "0:06")
        #expect(fast.trimNote == "(2× of 0:12)")

        let trimmed = RecordingEndWindow.notes(length: twelve, trim: Self.range(2, 8), speed: 2, bytes: bytes())
        #expect(trimmed.note == "0:03")
        #expect(trimmed.trimNote == "(2× · trimmed from 0:12) · 0:02 → 0:08")

        let fourTimes = RecordingEndWindow.notes(length: twelve, trim: nil, speed: 4, bytes: bytes())
        #expect(fourTimes.note == "0:03")

        let trimOnly = RecordingEndWindow.notes(length: twelve, trim: Self.range(2, 8), speed: 1, bytes: bytes())
        #expect(trimOnly.note == "0:06")
        #expect(trimOnly.trimNote == "(trimmed from 0:12) · 0:02 → 0:08")
        #expect(read == 1)
    }

    // REC-50: the trimmed part at that speed: the video retimed, the sound as long as the video
    // and at its own pitch (a 440 Hz tone stays 440 Hz).
    @Test("REC-50 a trimmed part at 2× and all of it at 4×: lengths and pitch kept")
    func speedExport() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let movie = try await Self.movie(length: 6, tone: 440, in: folder)

        let twice = folder.appending(path: "twice.mp4")
        try await RecordingExport.speed(movie, range: Self.range(1, 5), speed: 2, to: twice)
        let twiceVideo = try #require(try await Self.duration(twice, .video))
        let twiceSound = try #require(try await Self.duration(twice, .audio))
        #expect(abs(twiceVideo - 2) < 0.05)
        #expect(abs(twiceSound - twiceVideo) < 0.1)
        #expect(abs(try await Self.frequency(of: twice) - 440) < 10)

        let fourTimes = folder.appending(path: "four.mp4")
        try await RecordingExport.speed(movie, range: nil, speed: 4, to: fourTimes)
        let fourVideo = try #require(try await Self.duration(fourTimes, .video))
        #expect(abs(fourVideo - 1.5) < 0.05)
        #expect(abs(try await Self.frequency(of: fourTimes) - 440) < 10)
        // Its own sound file is removed once in the movie.
        #expect(!FileManager.default.fileExists(atPath: fourTimes.deletingPathExtension().appendingPathExtension("m4a").path))
    }

    // REC-50: a recording without sound sped up stays without sound.
    @Test("REC-50 a recording without sound at 1.5×")
    func speedWithoutSound() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let movie = try await Self.movie(length: 3, tone: nil, in: folder)
        let output = folder.appending(path: "fast.mp4")
        try await RecordingExport.speed(movie, range: nil, speed: 1.5, to: output)
        #expect(abs(try #require(try await Self.duration(output, .video)) - 2) < 0.05)
        #expect(try await Self.duration(output, .audio) == nil)
    }
}

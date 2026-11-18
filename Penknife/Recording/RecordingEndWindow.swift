import AVKit
import SwiftUI

/// What the end window shows.
@Observable
final class RecordingResult {
    enum Work: Equatable { case saving, copying, gif(Double) }

    var player: AVPlayer?
    var note = String(localized: "Preparing the video…")
    /// After trimming: "(trimmed from 0:20) · 0:03 → 0:15", shown dimmer after the note.
    var trimNote = ""
    var ready = false
    /// Saving, copying or making the GIF (with its progress): shown in the note line.
    var work: Work?
    /// The trim bar is open (R-33: our compact copy of AppKit's, over the bottom of the video).
    var trimming = false
    /// While trimming: the part being chosen and the whole length (seconds), the playhead, and
    /// the filmstrip.
    var editStart = 0.0
    var editEnd = 0.0
    var length = 0.0
    var playhead = 0.0
    var playing = false
    var thumbnails: [NSImage] = []
    /// The part kept (R-33); nil = all of it.
    var trim: CMTimeRange?
    /// Saved or copied at least once: closing doesn't ask.
    var kept = false
    var failed = false

    var busy: Bool { work != nil }
}

enum RecordingEndCommand: Equatable {
    case saveVideo, saveGIF, copy, trim, undoTrim, cancelGIF
    case trimDone, trimCancel, trimPlay, trimScrub(Double), trimReleased
}

/// The window after a recording (R-29): a preview, Save as Video (default), Save as GIF, Copy.
/// It stays open after saving, so both can be made; Esc closes it, asking first if nothing was
/// kept. Trim (R-33) uses AppKit's own trim bar on the preview; what is saved, made into a GIF or
/// copied is the trimmed part. The preview is big (55 % of the screen's width, 640–1040 pt, at
/// most twice the recording's size) and the window can be resized. The files are deleted when it
/// closes.
final class RecordingEndWindow: NSObject, NSWindowDelegate {
    private static var open: [RecordingEndWindow] = []
    /// Room for everything under the preview, and around it.
    private static let controlsHeight: CGFloat = 150
    private static let margin: CGFloat = 16

    private let window: EndPanel
    private let model = RecordingResult()
    private let output: RecordingWriter.Output
    private let folder: URL
    private let gifSize: CGSize
    private let name: String
    private let movie: URL
    private let playerView = AVPlayerView()
    private var task: Task<Void, Never>?
    /// The playhead while trimming (20 times a second, only then), and the filmstrip's frames.
    private var timeObserver: Any?
    private var thumbnailTask: Task<Void, Never>?
    /// The trimmed file and the part it holds (made once per trim).
    private var trimmedMovie: (url: URL, range: CMTimeRange)?
    private var trimCount = 0
    /// Closed while saving or copying: it closes when that ends.
    private var closeWhenDone = false

    /// `videoSize`: the recorded region, in points.
    static func show(_ output: RecordingWriter.Output, folder: URL, gifSize: CGSize, videoSize: CGSize, screen: NSScreen?) {
        let window = RecordingEndWindow(output: output, folder: folder, gifSize: gifSize, videoSize: videoSize, screen: screen)
        open.append(window)
        window.present()
    }

    private init(output: RecordingWriter.Output, folder: URL, gifSize: CGSize, videoSize: CGSize, screen: NSScreen?) {
        self.output = output
        self.folder = folder
        self.gifSize = gifSize
        movie = folder.appendingPathComponent("Recording.mp4")
        name = PastableImage.timestampName { String(localized: "Screen Recording \($0) at \($1)") }
        let aspect = videoSize.height > 0 ? max(videoSize.width / videoSize.height, 0.2) : 16 / 9
        let preview = Self.previewSize(aspect: aspect, video: videoSize, screen: screen ?? NSScreen.main)
        let content = CGSize(width: max(preview.width, 448) + Self.margin * 2, height: preview.height + Self.controlsHeight)
        window = EndPanel(contentRect: CGRect(origin: .zero, size: content),
                          styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = String(localized: "Screen Recording")
        // Not by its background: the trim bar's handles are dragged there, and a drag on the
        // background moved the whole window instead (user, 2026-11-17). The title bar moves it.
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.onEscape = { [weak self] in self?.requestClose() }
        window.contentMinSize = CGSize(width: 480, height: 270 + Self.controlsHeight)
        playerView.controlsStyle = .inline
        playerView.videoGravity = .resizeAspect
        let duration = Self.time(output.duration)
        let host = NSHostingView(rootView: RecordingEndView(model: model, playerView: playerView, aspect: aspect, duration: duration) { [weak self] in
            self?.run($0)
        })
        // The window decides the size (it can be resized); the view only sets the minimum.
        host.sizingOptions = [.minSize]
        window.contentView = host
        window.setContentSize(content)
    }

    /// 55 % of the screen's visible width, within 640–1040 pt and at most twice the recording;
    /// short enough for the window to fit 85 % of the screen's height (portrait recordings too).
    private static func previewSize(aspect: CGFloat, video: CGSize, screen: NSScreen?) -> CGSize {
        let visible = screen?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        var width = min(max(visible.width * 0.55, 640), 1040)
        if video.width > 0 { width = min(width, video.width * 2) }
        var height = width / aspect
        let maxHeight = visible.height * 0.85 - controlsHeight
        if height > maxHeight {
            height = maxHeight
            width = height * aspect
        }
        return CGSize(width: width.rounded(), height: height.rounded())
    }

    private func present() {
        window.center()
        window.makeKeyAndOrderFront(nil)
        // The cooperative `activate()` was refused after a recording (measured 2026-11-17: the
        // recorded app stayed in front, so Return and Esc didn't reach this window), as in Settings.
        NSApp.activate(ignoringOtherApps: true)
        let output = output, movie = movie
        task = Task { [weak self] in
            do {
                try await RecordingExport.movie(output, to: movie)
                guard let self else { return }
                let player = AVPlayer(url: movie)
                model.player = player
                playerView.player = player
                updateNote()
                model.ready = true
                announce(String(localized: "Recording ready. Save as video, save as GIF, or copy."))
            } catch {
                RecordingLog.log.error("Video not prepared: \(error.localizedDescription, privacy: .public)")
                guard let self else { return }
                model.note = String(localized: "Couldn't prepare the video")
                model.failed = true
            }
        }
    }

    private func run(_ command: RecordingEndCommand) {
        switch command {
        case .cancelGIF: cancelGIF(); return
        case .trimDone: endTrim(keep: true); return
        case .trimCancel: endTrim(keep: false); return
        case .trimPlay: playInTrim(); return
        case .trimScrub(let seconds): scrub(to: seconds); return
        case .trimReleased: trimReleased(); return
        default: break
        }
        guard model.ready, !model.trimming, !model.busy else { return }
        switch command {
        case .saveVideo: saveVideo()
        case .saveGIF: saveGIF()
        case .copy: copyVideo()
        case .trim: trim()
        case .undoTrim: undoTrim()
        default: break
        }
    }

    // MARK: Trim (R-33)

    /// The whole recording. The player's item has no duration until it is ready (it is
    /// indefinite, NaN seconds: converting that to Int crashed the app, 2026-11-17), so the
    /// writer's duration is used until then.
    private var length: CMTime {
        if let duration = model.player?.currentItem?.duration, duration.isNumeric { return duration }
        return output.duration
    }

    /// "0:07"; an indefinite time shows as 0:00 instead of trapping.
    private static func time(_ time: CMTime) -> String {
        let seconds = time.seconds
        return RecordingState.time(seconds.isFinite ? Int(seconds.rounded()) : 0)
    }

    /// The trim bar over the bottom of the video (user's pick: AppKit's look, but one row and
    /// shorter). It opens on the current trim, so it also adjusts it.
    private func trim() {
        guard let player = model.player else { return }
        let full = length.seconds
        guard full.isFinite, full > 0.6 else { return }
        model.length = full
        model.editStart = model.trim?.start.seconds ?? 0
        model.editEnd = model.trim?.end.seconds ?? full
        model.playhead = model.editStart
        player.pause()
        playerView.controlsStyle = .none
        model.trimming = true
        if model.thumbnails.isEmpty { makeThumbnails() }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { [weak self, weak player] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.model.playhead = time.seconds
                self.model.playing = (player?.rate ?? 0) != 0
            }
        }
        keepOnly(model.editStart, model.editEnd)
        seek(to: model.editStart)
        announce(String(localized: "Trim. Drag the yellow handles, then press Return; Esc cancels."))
    }

    /// Trim (Return) keeps what is between the handles; Cancel (Esc) leaves the trim as it was.
    private func endTrim(keep: Bool) {
        guard model.trimming else { return }
        model.player?.pause()
        if let timeObserver { model.player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        model.trimming = false
        model.playing = false
        playerView.controlsStyle = .inline
        if keep {
            let whole = model.editStart < 0.05 && model.length - model.editEnd < 0.05
            model.trim = whole ? nil : CMTimeRange(start: CMTime(seconds: model.editStart, preferredTimescale: 600),
                                                   end: CMTime(seconds: model.editEnd, preferredTimescale: 600))
            if let trim = model.trim { announce(String(localized: "Trimmed to \(Self.time(trim.duration))")) }
        }
        if let trim = model.trim {
            keepOnly(trim.start.seconds, trim.end.seconds)
        } else {
            model.player?.currentItem?.reversePlaybackEndTime = .invalid
            model.player?.currentItem?.forwardPlaybackEndTime = .invalid
        }
        updateNote()
    }

    private func playInTrim() {
        guard let player = model.player else { return }
        if player.rate != 0 {
            player.pause()
            return
        }
        if player.currentTime().seconds >= model.editEnd - 0.05 { seek(to: model.editStart) }
        player.play()
    }

    /// While a handle is dragged the video shows that moment.
    private func scrub(to seconds: Double) {
        model.player?.pause()
        seek(to: seconds)
    }

    private func trimReleased() {
        keepOnly(model.editStart, model.editEnd)
        seek(to: model.editStart)
    }

    /// The player plays only this part.
    private func keepOnly(_ start: Double, _ end: Double) {
        guard let item = model.player?.currentItem else { return }
        item.reversePlaybackEndTime = CMTime(seconds: start, preferredTimescale: 600)
        item.forwardPlaybackEndTime = CMTime(seconds: end, preferredTimescale: 600)
    }

    private func seek(to seconds: Double) {
        model.player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Ten frames for the filmstrip, made once.
    private func makeThumbnails() {
        let full = model.length, movie = movie
        thumbnailTask = Task { [weak self] in
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: movie))
            generator.maximumSize = CGSize(width: 240, height: 140)
            generator.appliesPreferredTrackTransform = true
            var images: [NSImage] = []
            for index in 0..<10 {
                let time = CMTime(seconds: full * (Double(index) + 0.5) / 10, preferredTimescale: 600)
                guard let image = try? await generator.image(at: time).image else { continue }
                images.append(NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height)))
            }
            self?.model.thumbnails = images
        }
    }

    private func undoTrim() {
        guard model.trim != nil, let item = model.player?.currentItem else { return }
        item.reversePlaybackEndTime = .invalid
        item.forwardPlaybackEndTime = .invalid
        model.trim = nil
        updateNote()
        announce(String(localized: "Trim undone"))
    }

    /// Length and size, or the trimmed length with what it was cut from.
    private func updateNote() {
        let full = Self.time(length)
        guard let trim = model.trim else {
            model.trimNote = ""
            let size = (try? movie.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
            model.note = "\(full) · \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))"
            return
        }
        model.note = Self.time(trim.duration)
        let from = Self.time(trim.start), to = Self.time(trim.end)
        model.trimNote = String(localized: "(trimmed from \(full)) · \(from) → \(to)")
    }

    /// The file to save, turn into a GIF or copy: the trimmed part when there is a trim.
    private func outputMovie() async throws -> URL {
        guard let trim = model.trim else { return movie }
        if let trimmedMovie, trimmedMovie.range == trim { return trimmedMovie.url }
        trimCount += 1
        let url = folder.appendingPathComponent("Recording trimmed \(trimCount).mp4")
        try await RecordingExport.trim(movie, range: trim, to: url)
        trimmedMovie = (url, trim)
        return url
    }

    // MARK: Saving

    private func saveVideo() {
        model.work = .saving
        let destination = ScreenshotModule.folder
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let source = try await outputMovie()
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: source, to: Self.unique(name, extension: "mp4", in: destination))
                finished(kept: String(localized: "Saved as video in \(FileManager.default.displayName(atPath: destination.path))"))
            } catch {
                finished(failed: String(localized: "Couldn't save the video in \(FileManager.default.displayName(atPath: destination.path))"))
            }
        }
    }

    private func saveGIF() {
        model.work = .gif(0)
        let gifSize = gifSize
        let temporary = folder.appendingPathComponent("Recording.gif")
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let source = try await outputMovie()
                try await RecordingExport.gif(from: source, to: temporary, maxSize: gifSize) { [weak self] value in
                    Task { @MainActor in
                        guard let self, case .gif = self.model.work else { return }
                        self.model.work = .gif(value)
                    }
                }
                let destination = ScreenshotModule.folder
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: temporary, to: Self.unique(name, extension: "gif", in: destination))
                finished(kept: String(localized: "Saved as GIF in \(FileManager.default.displayName(atPath: destination.path))"))
            } catch {
                if Task.isCancelled || error is CancellationError {
                    model.work = nil
                    updateNote()
                    announce(String(localized: "GIF cancelled"))
                } else {
                    finished(failed: String(localized: "Couldn't make the GIF"))
                }
            }
        }
    }

    private func cancelGIF() {
        guard case .gif = model.work else { return }
        task?.cancel()
    }

    private func copyVideo() {
        model.work = .copying
        task = Task { [weak self] in
            guard let self else { return }
            guard let source = try? await outputMovie(), PastableImage.copyFile(source, named: name) else {
                finished(failed: String(localized: "Too big to copy. Save it instead."))
                return
            }
            finished(kept: String(localized: "Video copied. Paste it in a message or a Finder folder."))
        }
    }

    private func finished(kept note: String) {
        model.work = nil
        model.kept = true
        model.note = note
        model.trimNote = ""
        announce(note)
        if closeWhenDone { window.close() }
    }

    private func finished(failed note: String) {
        model.work = nil
        model.note = note
        model.trimNote = ""
        announce(note)
        if closeWhenDone {
            closeWhenDone = false
            requestClose()
        }
    }

    // MARK: Closing

    private func requestClose() {
        guard window.attachedSheet == nil else { return }
        switch model.work {
        case .saving?, .copying?:
            // Short: it closes as soon as it is done.
            closeWhenDone = true
            return
        case .gif?:
            ask(String(localized: "Stop making the GIF?"),
                detail: model.kept ? nil : String(localized: "The recording hasn't been saved."),
                confirm: String(localized: "Stop and Close"), cancel: String(localized: "Continue"))
            return
        case nil:
            break
        }
        if model.kept || model.failed {
            window.close()
            return
        }
        // Also while the trim bar is open: the usual question.
        ask(String(localized: "Discard the recording?"), detail: String(localized: "It hasn't been saved."),
            confirm: String(localized: "Discard"), cancel: String(localized: "Cancel"))
    }

    private func ask(_ message: String, detail: String?, confirm: String, cancel: String) {
        let alert = NSAlert()
        alert.messageText = message
        if let detail { alert.informativeText = detail }
        alert.addButton(withTitle: confirm).hasDestructiveAction = true
        alert.addButton(withTitle: cancel)
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            model.kept = true
            task?.cancel()
            window.close()
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if (model.kept || model.failed) && !model.busy { return true }
        requestClose()
        return false
    }

    func windowWillClose(_ notification: Notification) {
        task?.cancel()
        thumbnailTask?.cancel()
        if let timeObserver { model.player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        model.player?.pause()
        model.player = nil
        playerView.player = nil
        let folder = folder
        DispatchQueue.global(qos: .utility).async { try? FileManager.default.removeItem(at: folder) }
        DispatchQueue.main.async { Self.open.removeAll { $0 === self } }
    }

    private static func unique(_ name: String, extension ext: String, in folder: URL) -> URL {
        var url = folder.appendingPathComponent(name).appendingPathExtension(ext)
        var number = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(name) \(number)").appendingPathExtension(ext)
            number += 1
        }
        return url
    }

    private func announce(_ message: String) {
        NSAccessibility.post(element: window, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}

/// Esc closes (asking first when needed); while the trim bar is open, Esc belongs to it.
private final class EndPanel: NSWindow {
    var onEscape: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

/// AppKit's own player (it also has the trim bar). SwiftUI's VideoPlayer crashed the app: it
/// needs AVKit loaded, and with nothing else using AVKit the linker left it out — measured
/// 2026-11-17.
private struct PlayerView: NSViewRepresentable {
    let view: AVPlayerView

    func makeNSView(context: Context) -> AVPlayerView { view }
    func updateNSView(_ view: AVPlayerView, context: Context) {}
}

private struct RecordingEndView: View {
    let model: RecordingResult
    let playerView: AVPlayerView
    let aspect: CGFloat
    let duration: String
    let run: (RecordingEndCommand) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // The video as big as the window allows, in its own proportions.
            ZStack(alignment: .bottom) {
                PlayerView(view: playerView)
                if model.player == nil {
                    Color.black
                    if !model.failed { ProgressView().controlSize(.small) }
                }
                if model.trimming {
                    TrimBar(model: model, run: run)
                        .padding([.horizontal, .bottom], 12)
                }
            }
            .aspectRatio(aspect, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel(String(localized: "Preview, \(duration)"))
            noteLine
                .frame(height: 22)
            HStack(spacing: 8) {
                Button(String(localized: "Save as Video")) { run(.saveVideo) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(model.trimming ? nil : .defaultAction)
                Button(String(localized: "Save as GIF")) { run(.saveGIF) }
                Spacer()
                Button { run(.copy) } label: { Label(String(localized: "Copy"), systemImage: "doc.on.doc") }
                    .keyboardShortcut("c")
            }
            .controlSize(.large)
            .disabled(!model.ready || model.trimming || model.busy)
            Text("The GIF has no sound.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .padding(.top, 12)
        .frame(minWidth: 480, maxWidth: .infinity, minHeight: 420, maxHeight: .infinity)
    }

    /// The note, then Trim (always there, so the trim can be adjusted) and, once trimmed, a
    /// separate Undo Trim to its left (designer + user, 2026-11-17). While saving, copying or
    /// making the GIF: what is happening, with a spinner or the GIF's progress.
    @ViewBuilder private var noteLine: some View {
        HStack(spacing: 8) {
            switch model.work {
            case .gif(let value)?:
                ProgressView(value: value)
                    .progressViewStyle(.linear)
                    .frame(width: 120)
                Text(String(localized: "Making the GIF… \(Int((value * 100).rounded())) %"))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button(String(localized: "Cancel")) { run(.cancelGIF) }
                    .controlSize(.small)
            case let work?:
                ProgressView().controlSize(.small)
                Text(work == .saving ? String(localized: "Saving…") : String(localized: "Copying…"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
            case nil:
                (Text(verbatim: model.note) + Text(verbatim: model.trimNote.isEmpty ? "" : "  " + model.trimNote).foregroundStyle(.tertiary))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Group {
                    if model.trim != nil {
                        Button { run(.undoTrim) } label: {
                            Image(systemName: "arrow.uturn.backward").frame(width: 16)
                        }
                        .keyboardShortcut("z")
                        .help(String(localized: "Undo Trim (⌘Z)"))
                        .accessibilityLabel(String(localized: "Undo Trim"))
                        .accessibilityHint(String(localized: "Restores the full recording"))
                        .transition(.opacity)
                    }
                    Button { run(.trim) } label: { Label(String(localized: "Trim"), systemImage: "scissors") }
                        .help(String(localized: "Trim the start and the end"))
                }
                .controlSize(.small)
                .disabled(!model.ready || model.trimming)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: model.trim != nil)
    }
}

/// Trimming (R-33): a compact copy of AppKit's trim bar, over the bottom of the video, in one
/// row: play, the filmstrip with the kept part framed in yellow between two handles, Cancel and
/// Trim side by side (the user's pick over the native bar, whose stacked buttons made it tall).
private struct TrimBar: View {
    let model: RecordingResult
    let run: (RecordingEndCommand) -> Void
    /// Where the dragged handle was when the drag began: the drag moves it by the pointer's
    /// travel along the strip (measured in the strip's own space, which doesn't move). Measuring
    /// in the handle's space, which moves with it, multiplied every move (user, 2026-11-17).
    @State private var dragOrigin: Double?
    private static let yellow = Color(nsColor: .systemYellow)
    private static let stripHeight: CGFloat = 32
    private static let handle: CGFloat = 10
    private static let radius: CGFloat = 6

    var body: some View {
        HStack(spacing: 10) {
            Button { run(.trimPlay) } label: {
                Image(systemName: model.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(model.playing ? String(localized: "Pause") : String(localized: "Play"))
            .accessibilityLabel(model.playing ? String(localized: "Pause") : String(localized: "Play"))
            strip
            HStack(spacing: 8) {
                Button(String(localized: "Cancel")) { run(.trimCancel) }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                    .frame(minWidth: 60)
                Button(String(localized: "Trim")) { run(.trimDone) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .frame(minWidth: 60)
            }
            .controlSize(.regular)
        }
        .padding(8)
        .frame(height: 48)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
        .environment(\.colorScheme, .dark)
    }

    private var strip: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = Self.stripHeight, handle = Self.handle, radius = Self.radius
            let x = { (seconds: Double) -> CGFloat in CGFloat(seconds / max(model.length, 0.01)) * width }
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    if model.thumbnails.isEmpty {
                        Rectangle().fill(.quaternary)
                    } else {
                        ForEach(model.thumbnails.indices, id: \.self) { index in
                            Image(nsImage: model.thumbnails[index])
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: width / CGFloat(model.thumbnails.count), height: height)
                                .clipped()
                        }
                    }
                }
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .accessibilityHidden(true)
                // Outside the kept part: dimmed.
                Rectangle().fill(Color.black.opacity(0.5))
                    .frame(width: max(x(model.editStart), 0), height: height)
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: radius, bottomLeadingRadius: radius, style: .continuous))
                    .accessibilityHidden(true)
                Rectangle().fill(Color.black.opacity(0.5))
                    .frame(width: max(width - x(model.editEnd), 0), height: height)
                    .clipShape(UnevenRoundedRectangle(bottomTrailingRadius: radius, topTrailingRadius: radius, style: .continuous))
                    .offset(x: x(model.editEnd))
                    .accessibilityHidden(true)
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Self.yellow, lineWidth: 2)
                    .frame(width: max(x(model.editEnd) - x(model.editStart), handle * 2), height: height)
                    .offset(x: x(model.editStart))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                handleView(start: true)
                    .offset(x: x(model.editStart))
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space)).onChanged { value in
                        let origin = dragOrigin ?? model.editStart
                        dragOrigin = origin
                        let seconds = origin + Double(value.translation.width / max(width, 1)) * model.length
                        model.editStart = min(max(seconds, 0), model.editEnd - 0.5)
                        run(.trimScrub(model.editStart))
                    }.onEnded { _ in
                        dragOrigin = nil
                        run(.trimReleased)
                    })
                handleView(start: false)
                    .offset(x: x(model.editEnd) - handle)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space)).onChanged { value in
                        let origin = dragOrigin ?? model.editEnd
                        dragOrigin = origin
                        let seconds = origin + Double(value.translation.width / max(width, 1)) * model.length
                        model.editEnd = max(min(seconds, model.length), model.editStart + 0.5)
                        run(.trimScrub(model.editEnd))
                    }.onEnded { _ in
                        dragOrigin = nil
                        run(.trimReleased)
                    })
                Rectangle().fill(Color.white)
                    .frame(width: 2, height: height + 4)
                    .shadow(color: .black.opacity(0.5), radius: 0.5)
                    .offset(x: min(max(x(model.playhead) - 1, x(model.editStart) + handle), x(model.editEnd) - handle - 2), y: -2)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .frame(height: height)
            .coordinateSpace(.named(Self.space))
            .frame(maxHeight: .infinity)
        }
    }

    private static let space = "trimStrip"

    /// A yellow handle with two grip lines; for VoiceOver an adjustable "Trim start/end".
    private func handleView(start: Bool) -> some View {
        UnevenRoundedRectangle(topLeadingRadius: start ? Self.radius : 0, bottomLeadingRadius: start ? Self.radius : 0,
                               bottomTrailingRadius: start ? 0 : Self.radius, topTrailingRadius: start ? 0 : Self.radius, style: .continuous)
            .fill(Self.yellow)
            .frame(width: Self.handle, height: Self.stripHeight)
            .overlay {
                HStack(spacing: 2) {
                    Rectangle().fill(Color.black.opacity(0.5)).frame(width: 1, height: 8)
                    Rectangle().fill(Color.black.opacity(0.5)).frame(width: 1, height: 8)
                }
            }
            .contentShape(Rectangle().inset(by: -6))
            .accessibilityElement()
            .accessibilityLabel(start ? String(localized: "Trim start") : String(localized: "Trim end"))
            .accessibilityValue(RecordingState.time(Int((start ? model.editStart : model.editEnd).rounded())))
            .accessibilityAdjustableAction { direction in
                let step = direction == .increment ? 0.5 : -0.5
                if start {
                    model.editStart = min(max(model.editStart + step, 0), model.editEnd - 0.5)
                    run(.trimScrub(model.editStart))
                } else {
                    model.editEnd = max(min(model.editEnd + step, model.length), model.editStart + 0.5)
                    run(.trimScrub(model.editEnd))
                }
                run(.trimReleased)
            }
    }
}

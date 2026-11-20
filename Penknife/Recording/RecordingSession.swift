import AppKit
import AVFoundation
import KeyboardShortcuts
@preconcurrency import ScreenCaptureKit

/// What to record, as chosen in the screenshot overlay.
struct RecordingRequest {
    let screen: NSScreen
    /// On `screen`, in points with a top-left origin (as the overlay's canvas).
    let rect: CGRect
    let fullScreen: Bool
    /// A window to bring forward first, with its frame in global top-left coordinates.
    let window: (id: CGWindowID, frame: CGRect)?
    /// Marks made in the screenshot editor: they stay, fixed, in the recording.
    let marks: [Annotation]
    let microphone: Bool
    let macSound: Bool
    let previousApp: NSRunningApplication?
}

/// One recording (R-29) from the 3-2-1 to the end window. The drawings live in a window the
/// recording includes; the toolbar, the region's edge, the countdown and alerts in windows it
/// excludes. Nothing runs before or after: everything is released when the end window closes.
final class RecordingSession {
    enum Stage { case countdown, recording, finishing, done }

    let state = RecordingState()
    private(set) var stage = Stage.countdown
    private let request: RecordingRequest
    private let folder: URL
    private let onFinish: () -> Void

    private var countdownPanel: OverlayPanel?
    /// The capsule with "Recording in 3" and the sound switches (O-18).
    private var capsulePanel: OverlayPanel?
    /// SS-62: every button's key, above the toolbar.
    private let hints = ShortcutHintModel()
    private var hintsPanel: OverlayPanel?
    private var hintObservers: [NSObjectProtocol] = []
    /// A switch touched during the countdown restarts it at 3, once (O-18).
    private var countdownRestarted = false
    private var strokePanel: OverlayPanel?
    private var canvas: StrokeCanvas?
    private var inputPanel: OverlayPanel?
    private var input: DrawingInputView?
    private var framePanel: OverlayPanel?
    private var frameView: RegionFrameView?
    private var toolbarPanel: OverlayPanel?
    /// Frosted glass over the blur marks, on screen only (R-32).
    private var blurPanel: OverlayPanel?
    private var recorder: ScreenRecorder?
    private var ready = false
    private var counted = false
    private var timer: Timer?
    private var started = Date()
    private var pausedAt: Date?
    private var pausedTotal: TimeInterval = 0
    private var drawShortcut: Task<Void, Never>?
    /// The app with the keyboard before drawing took it, to give it back.
    private var appBeforeDrawing: NSRunningApplication?

    init(request: RecordingRequest, onFinish: @escaping () -> Void) {
        self.request = request
        self.onFinish = onFinish
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("Penknife Recording \(UUID().uuidString)", isDirectory: true)
        state.macSound = request.macSound
    }

    var isActive: Bool { stage == .countdown || stage == .recording }

    /// The region in AppKit's global coordinates (bottom-left origin).
    private var region: CGRect {
        let screen = request.screen.frame
        return CGRect(x: screen.minX + request.rect.minX, y: screen.maxY - request.rect.maxY,
                      width: request.rect.width, height: request.rect.height)
    }

    // MARK: Start

    func start() {
        Task { [weak self] in
            guard let self else { return }
            if request.microphone { state.microphone = await Self.microphoneAllowed() }
            guard stage == .countdown else { return }
            if state.microphone { MicrophoneModule.openForRecording() }
            if let window = request.window {
                await WindowFocus.focus(window.id, frame: window.frame)
            } else {
                request.previousApp?.activate()
            }
            guard stage == .countdown else { return }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            } catch {
                fail()
                return
            }
            showStrokes()
            showCountdown()
            prepare()
        }
    }

    /// The drawing layer: on screen before the capture starts, so the capture can include it.
    private func showStrokes() {
        let panel = OverlayPanel(frame: region, level: .statusBar)
        panel.ignoresMouseEvents = true
        let canvas = StrokeCanvas(frame: CGRect(origin: .zero, size: region.size))
        panel.contentView = canvas
        panel.orderFrontRegardless()
        strokePanel = panel
        self.canvas = canvas
        canvas.onBlursChanged = { [weak self] in self?.updateBlurs() }
        // Marks from the screenshot editor stay, fixed.
        for mark in Self.carried(request.marks, into: request.rect) { canvas.add(mark, fade: 0) }
    }

    /// The editor's marks (screen points) placed in the region's own points: the whole mark
    /// moves, with its bend and what was erased from it (B-15).
    static func carried(_ marks: [Annotation], into rect: CGRect) -> [Annotation] {
        marks.map { mark in
            var moved = mark
            moved.move(by: CGVector(dx: -rect.minX, dy: -rect.minY))
            return moved
        }
    }

    /// What a ⌘ key does while drawing (B-13): ⌘Z undoes the newest drawing; while a text is
    /// typed the Edit menu's keys reach it (undo, cut, copy, paste, select all); every other ⌘ key
    /// stays here, so ⌘Q or ⌘, can't quit Penknife or open Settings in the middle of a recording.
    enum CommandKey: Equatable { case undo, duplicate, stop, toText, swallow }
    static func commandKey(_ key: String, shift: Bool = false, typing: Bool) -> CommandKey {
        // ⇧⌘R stops (user: "el mismo comando que activa la grabación la para"), also while typing.
        // Only here, never global: other apps keep their own ⇧⌘R (REC-48).
        if key == "r", shift { return .stop }
        if typing { return ["z", "x", "c", "v", "a"].contains(key) ? .toText : .swallow }
        switch key {
        case "z": return .undo
        case "d": return .duplicate   // SS-61, same as the editor
        case ".": return .stop        // ⌘. (R is the rectangle), besides the global Record Screen
        default: return .swallow
        }
    }

    /// The Stop button's keys (REC-48): the global Record Screen shortcut, then ⇧⌘R (only
    /// while Penknife has the keyboard). Separated by a space: one key cap each.
    static func stopKeys(_ recordScreen: String) -> String {
        recordScreen.isEmpty ? "⇧⌘R" : "\(recordScreen) ⇧⌘R"
    }

    private func showCountdown() {
        let screen = request.screen.frame
        let panel = OverlayPanel(frame: screen, level: NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 3))
        panel.keyable = true
        let local = region.offsetBy(dx: -screen.minX, dy: -screen.minY)
        // Under the menu bar (and the camera housing), as the hint was.
        let top = max(screen.maxY - request.screen.visibleFrame.maxY, request.screen.safeAreaInsets.top)
        panel.ignoresMouseEvents = true
        panel.contentView = CountdownView(frame: CGRect(origin: .zero, size: screen.size), region: local)
        panel.orderFrontRegardless()
        countdownPanel = panel

        let host = FirstClickHostingView(rootView: CountdownCapsule(state: state) { [weak self] in self?.run($0) })
        let size = host.fittingSize
        let capsule = OverlayPanel(frame: CGRect(x: screen.midX - size.width / 2, y: screen.maxY - top - 12 - size.height,
                                                 width: size.width, height: size.height),
                                   level: NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 4))
        capsule.keyable = true
        capsule.contentView = host
        capsule.onKey = { [weak self] event in self?.countdownKey(event) ?? false }
        capsule.orderFrontRegardless()
        capsule.makeKey()
        capsulePanel = capsule

        state.countdown = 3
        announce(String(localized: "Recording in 3 seconds. M: microphone, S: Mac sound, Esc cancels."))
        startCountdownTimer()
    }

    private func startCountdownTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.countdownTick() }
        }
        timer?.tolerance = 0.05
    }

    /// Keys during the countdown: Esc cancels, M and S flip the switches (O-18); ⌘ keys stay
    /// here, as while drawing (B-13).
    private func countdownKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        if event.keyCode == 53 {
            cancel()
            return true
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { return true }
        guard flags.isDisjoint(with: [.control, .option]), !event.isARepeat else { return false }
        switch Self.countdownCommand(event.charactersIgnoringModifiers ?? "") {
        case .some(let command): run(command); return true
        case .none: return false
        }
    }

    /// M → microphone, S → Mac sound (either case); nothing else (O-18).
    static func countdownCommand(_ key: String) -> RecordingCommand? {
        switch key.lowercased() {
        case "m": .microphone
        case "s": .macSound
        default: nil
        }
    }

    /// The user is setting up: give them 3 s again, once per recording (O-18).
    private func restartCountdownOnce() {
        guard stage == .countdown, !countdownRestarted else { return }
        countdownRestarted = true
        state.countdown = 3
        startCountdownTimer()
    }

    private func countdownTick() {
        guard stage == .countdown else { return }
        if state.countdown > 1 {
            state.countdown -= 1
            return
        }
        timer?.invalidate()
        timer = nil
        countdownPanel?.orderOut(nil)
        countdownPanel = nil
        capsulePanel?.orderOut(nil)
        capsulePanel = nil
        counted = true
        if ready { go() }
    }

    /// Starts the capture during the countdown, so the recording begins right at "go".
    private func prepare() {
        Task { [weak self] in
            guard let self, let strokePanel else { return }
            do {
                // All windows, so the brand-new drawing layer is surely listed.
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let display = content.displays.first(where: { $0.displayID == self.request.screen.displayID }) else {
                    throw RecordingError.noDisplay
                }
                let own = content.applications.filter { $0.processID == getpid() }
                let drawings = content.windows.filter { $0.windowID == CGWindowID(strokePanel.windowNumber) }
                if drawings.isEmpty { RecordingLog.log.error("Drawing layer not available to the capture") }
                // Penknife's windows stay out (toolbar, edge, alerts), except the drawings.
                let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: drawings)
                let size = pixelSize
                let configuration = SCStreamConfiguration()
                configuration.width = size.width
                configuration.height = size.height
                if !request.fullScreen { configuration.sourceRect = request.rect }
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
                configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                configuration.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
                configuration.colorSpaceName = CGColorSpace.sRGB
                configuration.showsCursor = true
                configuration.queueDepth = 6
                configuration.capturesAudio = state.macSound
                configuration.excludesCurrentProcessAudio = true
                configuration.sampleRate = 48_000
                configuration.channelCount = 2
                guard stage == .countdown else { return }
                let writer = try RecordingWriter(folder: folder, width: size.width, height: size.height,
                                                 scale: CGFloat(size.width) / request.rect.width)
                let recorder = ScreenRecorder(filter: filter, configuration: configuration, writer: writer)
                recorder.onStop = { [weak self] _ in
                    Task { @MainActor in self?.captureStopped() }
                }
                recorder.onMicrophoneFailed = { [weak self] in
                    Task { @MainActor in self?.microphoneFailed() }
                }
                try await recorder.start()
                guard stage == .countdown else {
                    await recorder.cancel()
                    return
                }
                recorder.setSound(state.macSound)
                recorder.setMicrophone(state.microphone)
                self.recorder = recorder
                updateBlurs()
                ready = true
                RecordingLog.log.info("Capture ready: \(size.width)×\(size.height), drawings included: \(!drawings.isEmpty)")
                if counted { go() }
            } catch {
                // Cancelled meanwhile: nothing to report.
                guard stage == .countdown else { return }
                RecordingLog.log.error("Capture not started: \(error.localizedDescription, privacy: .public)")
                fail()
            }
        }
    }

    /// The recording's size in pixels: the region at the screen's resolution, within what the
    /// hardware H.264 encoder takes (4096 wide, 4096 × 2304 pixels), even numbers.
    private var pixelSize: (width: Int, height: Int) {
        let scale = request.screen.backingScaleFactor
        var width = request.rect.width * scale, height = request.rect.height * scale
        let shrink = min(1, 4096 / max(width, height), (4096 * 2304 / (width * height)).squareRoot())
        width *= shrink
        height *= shrink
        return (max(64, Int(width) & ~1), max(64, Int(height) & ~1))
    }

    private func go() {
        guard stage == .countdown, let recorder else { return }
        stage = .recording
        recorder.begin()
        started = Date()
        showFrame()
        showToolbar()
        updateIndicator()
        startClock()
        drawShortcut = Task { [weak self] in
            for await _ in KeyboardShortcuts.events(.keyUp, for: .recordingDraw) {
                // Mouse ⇄ Edit in one press, even with a tool armed (user: "tengo que oprimir
                // control option d dos veces"); Edit starts with no tool (REC-17).
                guard let self else { return }
                self.setDrawing(!self.state.drawing)
            }
        }
        // The countdown took the keyboard: give it back.
        if let window = request.window, let app = Self.app(owning: window.id) {
            app.activate()
        } else {
            request.previousApp?.activate()
        }
        announce(String(localized: "Recording"))
    }

    // MARK: While recording

    private func showFrame() {
        let full = request.fullScreen
        let frame = full ? request.screen.frame : region.insetBy(dx: -RegionFrameView.outset, dy: -RegionFrameView.outset)
        let panel = OverlayPanel(frame: frame, level: NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1))
        panel.ignoresMouseEvents = true
        let view = RegionFrameView(frame: CGRect(origin: .zero, size: frame.size), fullScreen: full)
        panel.contentView = view
        panel.orderFrontRegardless()
        framePanel = panel
        frameView = view
    }

    private func showToolbar() {
        let host = HintTrackingHostingView(rootView: RecordingToolbar(state: state, hints: hints) { [weak self] in self?.run($0) })
        host.hints = hints
        let size = host.fittingSize
        let panel = OverlayPanel(frame: CGRect(origin: .zero, size: size), level: NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2))
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = host
        panel.setAccessibilityLabel(String(localized: "Recording controls"))
        toolbarPanel = panel
        placeToolbar(size)
        panel.orderFrontRegardless()
        showHints(over: panel)
    }

    /// The blur marks (R-32): blurred in every frame of the file by the writer, frosted on screen.
    private func updateBlurs() {
        guard let canvas else { return }
        let rects = canvas.blurRects
        let size = pixelSize
        let sx = CGFloat(size.width) / request.rect.width, sy = CGFloat(size.height) / request.rect.height
        recorder?.writer.setBlurAreas(rects.map { CGRect(x: $0.minX * sx, y: $0.minY * sy, width: $0.width * sx, height: $0.height * sy) })
        guard !rects.isEmpty else {
            // No blur left: the frosted panel goes too (performance review, 2026-11-17).
            blurPanel?.orderOut(nil)
            blurPanel?.close()
            blurPanel = nil
            return
        }
        let panel = blurPanel ?? {
            // Above the drawings (a drawing under a blur is blurred in the file too), below the rest.
            let panel = OverlayPanel(frame: region, level: .statusBar)
            panel.ignoresMouseEvents = true
            panel.contentView = BlurOverlay(frame: CGRect(origin: .zero, size: region.size))
            panel.orderFrontRegardless()
            blurPanel = panel
            return panel
        }()
        (panel.contentView as? BlurOverlay)?.show(rects)
    }

    /// The color or size choices close when one is picked.
    private func closeChoices() {
        guard state.expanded != nil else { return }
        state.expanded = nil
        resizeToolbar()
    }

    /// The capsule's width changes when a choice row opens or closes: it stays centered where it is.
    /// SS-62: the keys above the toolbar, in a window that never takes the pointer; it follows
    /// the toolbar when it moves (dragged) or changes size (a row opens).
    private func showHints(over toolbar: OverlayPanel) {
        let panel = OverlayPanel(frame: .zero, level: NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2))
        panel.ignoresMouseEvents = true
        panel.contentView = PassThroughHostingView(rootView: ShortcutHints(model: hints))
        hintsPanel = panel
        toolbar.addChildWindow(panel, ordered: .above)
        placeHints()
        let center = NotificationCenter.default
        hintObservers = [NSWindow.didMoveNotification, NSWindow.didResizeNotification].map { name in
            center.addObserver(forName: name, object: toolbar, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.placeHints() }
            }
        }
    }

    private func placeHints() {
        guard let toolbar = toolbarPanel, let hintsPanel else { return }
        let side = ShortcutHintModel.overhang
        hintsPanel.setFrame(CGRect(x: toolbar.frame.minX - side, y: toolbar.frame.maxY,
                                   width: toolbar.frame.width + side * 2, height: ShortcutHintModel.headroom), display: true)
    }

    private func resizeToolbar() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = toolbarPanel, let host = panel.contentView else { return }
            let size = host.fittingSize
            let visible = request.screen.visibleFrame
            let x = min(max(panel.frame.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
            panel.setFrame(CGRect(x: x, y: panel.frame.minY, width: size.width, height: size.height), display: true)
        }
    }

    /// Below the region; above it when there's no room; inside its bottom when neither fits
    /// (it is never in the file). Full screen: bottom center. It can be dragged.
    private func placeToolbar(_ size: CGSize) {
        guard let panel = toolbarPanel else { return }
        let visible = request.screen.visibleFrame
        let region = region
        let gap: CGFloat = 12
        let x = min(max(region.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        var y = region.minY - gap - size.height
        if request.fullScreen || y < visible.minY + 4 {
            let above = region.maxY + gap
            if !request.fullScreen, above + size.height < visible.maxY - 4 {
                y = above
            } else {
                y = max(region.minY, visible.minY) + 24
            }
        }
        panel.setFrame(CGRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    /// The elapsed time, once a second; stopped while paused.
    private func startClock() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer?.tolerance = 0.1
    }

    private func tick() {
        guard stage == .recording else { return }
        let paused = pausedAt.map { Date().timeIntervalSince($0) } ?? 0
        let elapsed = Int(Date().timeIntervalSince(started) - pausedTotal - paused)
        if state.elapsed != elapsed { state.elapsed = elapsed }
        updateIndicator()
    }

    private func updateIndicator() {
        RecordingIndicator.shared.show(time: state.time, paused: state.paused) { [weak self] in self?.stop() }
    }

    private func run(_ command: RecordingCommand) {
        switch command {
        case .stop: stop()
        case .pause: togglePause()
        case .pointer:
            // The Mouse ⇄ Edit slot (REC-16, user's pick A): Mouse → Edit with no tool; a tool
            // armed → disarmed; Edit with no tool → Mouse.
            switch Self.pointerStep(drawing: state.drawing, tool: state.tool) {
            case .edit: setDrawing(true)
            case .disarm: armTool(nil)
            case .mouse: setDrawing(false)
            }
        case .tool(let tool):
            armTool(tool)
            setDrawing(true)
        case .toggle(let row):
            state.expanded = state.expanded == row ? nil : row
            resizeToolbar()
        case .color(let index):
            state.colorIndex = index
            closeChoices()
            input?.styleText()
            input?.restyleSelected(color: true)
            announce(CapturePalette.name(index))
        case .size(let index):
            state.sizeIndex = index
            closeChoices()
            input?.sizeChanged()
            input?.restyleSelected(color: false)
            announce(CaptureSize.name(index))
        case .fade(let seconds):
            state.fade = seconds
            RecordingPrefs.fade = seconds
        case .microphone:
            restartCountdownOnce()
            toggleMicrophone()
        case .macSound:
            restartCountdownOnce()
            state.macSound.toggle()
            RecordingPrefs.macSound = state.macSound
            recorder?.setSound(state.macSound)
            announce(state.macSound ? String(localized: "Mac sound on") : String(localized: "Mac sound off"))
        case .erase:
            input?.endText()
            input?.cancelMark()
            canvas?.eraseAll()
            announce(String(localized: "Drawings erased"))
        }
    }

    private func togglePause() {
        guard stage == .recording, let recorder else { return }
        if let pausedAt {
            pausedTotal += Date().timeIntervalSince(pausedAt)
            self.pausedAt = nil
            recorder.resume()
            state.paused = false
            startClock()
            announce(String(localized: "Recording resumed"))
        } else {
            pausedAt = Date()
            recorder.pause()
            state.paused = true
            timer?.invalidate()
            timer = nil
            tick()
            announce(String(localized: "Recording paused"))
        }
        updateIndicator()
    }

    private func toggleMicrophone() {
        if state.microphone {
            state.microphone = false
            RecordingPrefs.microphone = false
            recorder?.setMicrophone(false)
            MicrophoneModule.closeAfterRecording()
            announce(String(localized: "Microphone off"))
            return
        }
        Task { [weak self] in
            guard await Self.microphoneAllowed(), let self, stage == .countdown || stage == .recording else { return }
            state.microphone = true
            RecordingPrefs.microphone = true
            MicrophoneModule.openForRecording()
            recorder?.setMicrophone(true)
            announce(String(localized: "Microphone on"))
        }
    }

    enum PointerStep: Equatable { case edit, disarm, mouse }
    static func pointerStep(drawing: Bool, tool: CaptureTool?) -> PointerStep {
        guard drawing else { return .edit }
        return tool == nil ? .mouse : .disarm
    }

    private func armTool(_ tool: CaptureTool?) {
        guard tool != state.tool else { return }
        state.tool = tool
        input?.toolChanged()
        announce(tool?.title ?? String(localized: "Edit: select and move drawings"))
    }

    /// Edit on: the pointer and keys act on the region (a tool or none). Mouse: they reach the apps.
    func setDrawing(_ on: Bool) {
        guard on != state.drawing, !on || stage == .recording else { return }
        state.drawing = on
        frameView?.drawing = on
        if on {
            let front = NSWorkspace.shared.frontmostApplication
            appBeforeDrawing = front?.processIdentifier == getpid() ? nil : front
            let panel = inputPanel ?? makeInputPanel()
            panel.orderFrontRegardless()
            panel.makeKey()
            if state.tool == nil { announce(String(localized: "Edit on. Esc goes back to the mouse.")) }
        } else {
            input?.endText()
            input?.cancelMark()
            inputPanel?.orderOut(nil)
            appBeforeDrawing?.activate()
            appBeforeDrawing = nil
            state.tool = nil  // back in Edit, nothing armed
            announce(String(localized: "Mouse: clicks go to your apps"))
        }
    }

    private func makeInputPanel() -> OverlayPanel {
        let panel = OverlayPanel(frame: region, level: NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1))
        panel.keyable = true
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        let view = DrawingInputView(frame: CGRect(origin: .zero, size: region.size), state: state, canvas: canvas!)
        view.onMark = { [weak self] mark in
            guard let self else { return }
            canvas?.add(mark, fade: state.fade)
        }
        view.announce = { [weak self] in self?.announce($0) }
        view.onModifiers = { [weak self] in self?.hints.modifiersChanged($0) }
        view.onScroll = { [weak self] step in
            guard let self else { return }
            let next = min(max(state.sizeIndex + step, 0), CaptureSize.count - 1)
            if next != state.sizeIndex { run(.size(next)) }
        }
        panel.contentView = view
        panel.initialFirstResponder = view
        panel.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        inputPanel = panel
        input = view
        return panel
    }

    /// Keys while drawing (the text being typed gets its own first, except Esc and ⌘ keys).
    private func handleKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, let input else { return false }
        hints.keyPressed()
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if event.keyCode == 53 {
            // Esc: ends the text, then lets the selected mark go, then disarms the tool, then Mouse.
            if input.isTyping {
                input.endText()
            } else if input.hasSelection {
                input.select(nil)
            } else if state.tool != nil {
                armTool(nil)
            } else {
                setDrawing(false)
            }
            return true
        }
        if flags.contains(.command) {
            switch Self.commandKey(key, shift: flags.contains(.shift), typing: input.isTyping) {
            case .toText: return false
            case .swallow: return true
            case .undo:
                input.select(nil)
                if canvas?.undo() == true { announce(String(localized: "Undone")) }
                return true
            case .duplicate:
                input.duplicateSelected()
                return true
            case .stop:
                stop()
                return true
            }
        }
        guard !input.isTyping else { return false }
        // R-32: Tab selects the next mark; arrows move the selected one (⇧ by 10, ⌥ resize).
        if event.keyCode == 48, flags.isDisjoint(with: [.control, .option]) {
            input.selectNext(backward: flags.contains(.shift))
            return true
        }
        if (123...126).contains(event.keyCode), input.hasSelection, !flags.contains(.control) {
            let step: CGFloat = flags.contains(.shift) ? 10 : 1
            input.nudge(CGVector(dx: event.keyCode == 123 ? -step : event.keyCode == 124 ? step : 0,
                                 dy: event.keyCode == 126 ? -step : event.keyCode == 125 ? step : 0),
                        grow: flags.contains(.option))
            return true
        }
        guard flags.isDisjoint(with: [.control, .option]) else { return false }
        // ⇧⌫ erases all drawings (the trash button); Delete removes the selected mark, else the newest.
        if event.keyCode == 51 || event.keyCode == 117, flags.contains(.shift) {
            run(.erase)
            return true
        }
        if event.keyCode == 51 || event.keyCode == 117 {
            if !input.deleteSelected(), canvas?.undo() == true { announce(String(localized: "Undone")) }
            return true
        }
        switch CaptureKeys.toolKey(key, isRepeat: event.isARepeat) {
        case .tool(let tool)?:
            run(.tool(tool))
            return true
        case .placeMark(let tool)?:
            // Same as the editor (O-15): the shape's letter places it in the middle, selected.
            run(.tool(tool))
            input.place(tool)
            return true
        case .swallow?: return true
        default: break
        }
        if let command = Self.drawingKey(key, keyCode: event.keyCode, isRepeat: event.isARepeat,
                                         sizesOpen: state.expanded == .sizes, fade: state.fade) {
            if case .fade(let seconds) = command {
                announce(seconds == 0 ? String(localized: "Drawings: fixed") : String(localized: "Drawings: fade after \(Int(seconds)) s"))
            }
            run(command)
            return true
        }
        if let digit = Int(key), (1...CapturePalette.colors.count).contains(digit) {
            run(.color(digit - 1))
            return true
        }
        if key == "-" {
            run(.size(max(state.sizeIndex - 1, 0)))
            return true
        }
        if key == "+" || key == "=" {
            run(.size(min(state.sizeIndex + 1, CaptureSize.count - 1)))
            return true
        }
        return false
    }

    /// The toolbar's other buttons while drawing (every button has its key, user IMPERATIVE
    /// 2026-11-19; same letters as the editor where both have the button): Q Pointer, C colors,
    /// W sizes (then 1–4), F next fade, M microphone, S Mac sound, Space pause. ⇧⌫ and ⌘. are
    /// handled with Delete and the ⌘ keys.
    static func drawingKey(_ key: String, keyCode: UInt16, isRepeat: Bool, sizesOpen: Bool, fade: Double) -> RecordingCommand? {
        if keyCode == 49 { return isRepeat ? nil : .pause }
        switch CaptureKeys.rowKey(key) {
        case .pointer?: return .pointer
        case .toggleRow(let row)?: return .toggle(row)
        default: break
        }
        if sizesOpen, let digit = Int(key), (1...CaptureSize.count).contains(digit) { return .size(digit - 1) }
        guard !isRepeat else { return nil }
        switch key.lowercased() {
        case "f":
            let fades = RecordingPrefs.fades
            return .fade(fades[((fades.firstIndex(of: fade) ?? 0) + 1) % fades.count])
        case "m": return .microphone
        case "s": return .macSound
        default: return nil
        }
    }

    // MARK: End

    /// The record shortcut: cancels the countdown, stops a recording.
    func stop() {
        switch stage {
        case .countdown:
            cancel()
        case .recording:
            stage = .finishing
            guard let recorder else {
                fail()
                return
            }
            self.recorder = nil
            // The capture is cut before the drawings go away, so they stay to the last frame.
            recorder.cut()
            closeWindows()
            Task { [weak self] in
                let output = await recorder.finish()
                self?.finished(output)
            }
        case .finishing, .done:
            break
        }
    }

    private func finished(_ output: RecordingWriter.Output?) {
        guard stage == .finishing else { return }
        stage = .done
        guard let output else {
            HUD.shared.show(String(localized: "Couldn't record the screen"), symbol: "exclamationmark.triangle.fill",
                            kind: .error, category: .screenshot)
            removeFiles()
            onFinish()
            return
        }
        let maxGIF = CGSize(width: min(request.rect.width, 960), height: min(request.rect.height, 960))
        RecordingEndWindow.show(output, folder: folder, gifSize: maxGIF, videoSize: request.rect.size, screen: request.screen)
        onFinish()
    }

    /// No microphone (or it couldn't be opened): the switch turns off and an alert says so.
    private func microphoneFailed() {
        guard state.microphone else { return }
        state.microphone = false
        HUD.shared.show(String(localized: "Recording without the microphone"), detail: String(localized: "No microphone could be opened"),
                        symbol: "mic.slash.fill", kind: .error, category: .screenshot)
    }

    /// Recordings left behind by a crash or a forced quit (they can hold private screens and
    /// voice): removed at launch and on quit. None is in use then.
    nonisolated static func removeLeftovers() {
        let temporary = FileManager.default.temporaryDirectory
        guard let entries = try? FileManager.default.contentsOfDirectory(at: temporary, includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix("Penknife Recording ") {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    /// macOS stopped the capture (its own menu, a display change): keep what was recorded.
    private func captureStopped() {
        switch stage {
        case .recording: stop()
        case .countdown: fail()
        default: break
        }
    }

    /// Ends everything without keeping anything (Esc in the countdown, the module turned off).
    func cancel() {
        guard stage != .done else { return }
        stage = .done
        let recorder = recorder
        self.recorder = nil
        closeWindows()
        let folder = folder
        Task {
            await recorder?.cancel()
            try? FileManager.default.removeItem(at: folder)
        }
        onFinish()
    }

    private func fail() {
        guard stage != .done else { return }
        HUD.shared.show(String(localized: "Couldn't record the screen"), symbol: "exclamationmark.triangle.fill",
                        kind: .error, category: .screenshot)
        cancel()
    }

    private func closeWindows() {
        // The Mac's microphone goes back to muted if Penknife opened it for this recording.
        MicrophoneModule.closeAfterRecording()
        timer?.invalidate()
        timer = nil
        drawShortcut?.cancel()
        drawShortcut = nil
        if state.drawing {
            input?.endText()
            state.drawing = false
            appBeforeDrawing?.activate()
        }
        hintObservers.forEach(NotificationCenter.default.removeObserver)
        hintObservers = []
        hints.reset()
        for panel in [countdownPanel, capsulePanel, strokePanel, blurPanel, inputPanel, framePanel, hintsPanel, toolbarPanel] {
            panel?.orderOut(nil)
            panel?.close()
        }
        blurPanel = nil
        countdownPanel = nil
        capsulePanel = nil
        strokePanel = nil
        canvas = nil
        inputPanel = nil
        input = nil
        framePanel = nil
        frameView = nil
        toolbarPanel = nil
        hintsPanel = nil
        RecordingIndicator.shared.hide()
    }

    private func removeFiles() {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Helpers

    /// Asks the first time; when denied, the recording goes on without the voice and an alert
    /// says where to allow it.
    static func microphoneAllowed() async -> Bool {
        let allowed: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: allowed = true
        case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .audio)
        default: allowed = false
        }
        if !allowed {
            HUD.shared.show(String(localized: "Recording without the microphone"),
                            detail: String(localized: "Allow Penknife in System Settings › Privacy & Security › Microphone"),
                            symbol: "mic.slash.fill", kind: .permission, category: .screenshot)
        }
        return allowed
    }

    private static func app(owning window: CGWindowID) -> NSRunningApplication? {
        guard let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, window) as? [[String: Any]],
              let pid = list.first?[kCGWindowOwnerPID as String] as? pid_t else { return nil }
        return NSRunningApplication(processIdentifier: pid)
    }

    private func announce(_ message: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}

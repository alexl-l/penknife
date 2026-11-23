import AppKit
@preconcurrency import ScreenCaptureKit

/// What the screen does while you select: frozen at the moment of the shortcut (as Lightshot)
/// or live until the selection is made (setting, R-8).
enum ScreenshotMode: String, CaseIterable {
    case frozen, live

    var title: String {
        switch self {
        case .frozen: String(localized: "Frozen")
        case .live: String(localized: "Live")
        }
    }

    static var current: Self { current(in: .standard) }
    static func current(in defaults: UserDefaults) -> Self {
        Self(rawValue: defaults.string(forKey: ScreenshotModule.modeKey) ?? "") ?? .frozen
    }
}

/// How the overlay opens: for a screenshot, straight in record mode (R-29) or straight in the
/// color picker (R-38).
enum CaptureStart: Equatable {
    case screenshot, record, pickColor
}

/// The overlay and the recording as the module drives them (tests pass fakes).
protocol CaptureOverlay: AnyObject {
    func show()
    func cancel()
    func enterRecordMode()
    func togglePicker()
}

protocol CaptureRecording: AnyObject {
    func start()
    func stop()
    func cancel()
}

extension CaptureSession: CaptureOverlay {}
extension RecordingSession: CaptureRecording {}

/// Everything the module touches outside itself (S6): `live` is the real Mac; tests pass fakes.
struct CaptureEnvironment {
    var defaults: UserDefaults
    var hasPermission: () -> Bool
    var requestPermission: () -> Void
    var open: (URL) -> Void
    var frontApp: () -> NSRunningApplication?
    var grabAll: (_ sRGB: Bool) async throws -> [CGDirectDisplayID: CGImage]
    var hud: (_ title: String, _ detail: String?, _ symbol: String, _ kind: AlertKind) -> Void
    var makeOverlay: (_ mode: ScreenshotMode, _ images: [CGDirectDisplayID: CGImage], _ previous: NSRunningApplication?,
                      _ start: CaptureStart, _ onRecord: @escaping (RecordingRequest) -> Void,
                      _ onFinish: @escaping () -> Void) -> CaptureOverlay
    var makeRecording: (_ request: RecordingRequest, _ onFinish: @escaping () -> Void) -> CaptureRecording

    static var live: Self {
        Self(defaults: .standard,
             hasPermission: { CGPreflightScreenCaptureAccess() },
             requestPermission: { CGRequestScreenCaptureAccess() },
             open: { NSWorkspace.shared.open($0) },
             frontApp: { NSWorkspace.shared.frontmostApplication },
             grabAll: { try await ScreenGrabber.captureAll(sRGB: $0) },
             hud: { HUD.shared.show($0, detail: $1, symbol: $2, kind: $3, category: .screenshot) },
             makeOverlay: { CaptureSession(mode: $0, images: $1, previousApp: $2, start: $3, onRecord: $4, onFinish: $5) },
             makeRecording: { RecordingSession(request: $0, onFinish: $1) })
    }
}

/// Screenshots with annotations (R-8, replaces Lightshot). Nothing runs until the shortcut is
/// pressed; the session's windows and images are released when it closes. Nothing is uploaded.
final class ScreenshotModule: Module {
    let id = ModuleID.screenshot
    static let modeKey = "screenshot.mode"
    static let folderKey = "screenshot.folder"
    static let scrollKey = "screenshot.scrollUpThinner"
    static let copyFileKey = "screenshot.copyFile"

    /// Copy also offers the screenshot as a file, for pasting into Finder folders (on by default).
    static var copiesFile: Bool { copiesFile(in: .standard) }
    static func copiesFile(in defaults: UserDefaults) -> Bool { defaults.object(forKey: copyFileKey) as? Bool ?? true }

    /// Scrolling up makes lines and text thicker (default) or thinner (setting).
    static var scrollUpThinner: Bool { scrollUpThinner(in: .standard) }
    static func scrollUpThinner(in defaults: UserDefaults) -> Bool { defaults.bool(forKey: scrollKey) }
    static let askedKey = "screenshot.askedPermission"
    /// O-33: holding the Screenshot key or Touch Bar button opens the overlay in record mode.
    static let holdKey = "screenshot.holdToRecord"
    static let holdSecondsKey = "screenshot.holdSeconds"
    static let holdChoices: [Double] = [1, 1.5, 2, 3]
    static func holdToRecord(in defaults: UserDefaults) -> Bool { defaults.object(forKey: holdKey) as? Bool ?? true }
    /// Seconds to hold (default 2, user 2026-11-19); nil when the hold is off.
    static func holdSeconds(in defaults: UserDefaults) -> Double? {
        guard holdToRecord(in: defaults) else { return nil }
        let value = defaults.object(forKey: holdSecondsKey) as? Double ?? 2
        return holdChoices.contains(value) ? value : 2
    }
    static let screenRecordingSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

    private let environment: CaptureEnvironment
    private(set) var session: CaptureOverlay?
    private(set) var starting = false
    /// A recording from its countdown until it stops (R-29); its end window lives on its own.
    private(set) var recording: CaptureRecording?

    init(environment: CaptureEnvironment = .live) {
        self.environment = environment
    }

    var actions: [ModuleAction] {
        [
            ModuleAction(shortcut: .screenshot, title: String(localized: "Screenshot"), symbol: id.symbol,
                         holdDelay: { [weak self] in self.flatMap { Self.holdSeconds(in: $0.environment.defaults) } },
                         onHold: { [weak self] in self?.holdToRecord() },
                         perform: { [weak self] in self?.begin() }),
            ModuleAction(shortcut: .recordScreen, title: String(localized: "Record Screen"), symbol: "record.circle",
                         perform: { [weak self] in self?.toggleRecording() }),
            ModuleAction(shortcut: .pickColor, title: String(localized: "Pick Color"), symbol: "eyedropper",
                         perform: { [weak self] in self?.pickColor() }),
        ]
    }

    func start() {
        PinBoard.shared.edit = { [weak self] in self?.edit($0) }
    }

    func stop() {
        session?.cancel()
        session = nil
        PinBoard.shared.closeAll()
        recording?.cancel()
        recording = nil
    }

    /// SS-70: a pin's double-click or Edit opens the editor on it; the pin hides meanwhile and
    /// comes back when the editor closes (also when it couldn't open).
    func edit(_ pin: PinnedWindow) {
        guard session == nil, !starting, recording == nil else { return }
        pin.orderOut(nil)
        if begin(.screenshot, editing: pin) == nil { pin.reappear() }
    }

    /// The record shortcut: stops a recording; with the overlay open, switches it to record mode;
    /// otherwise opens it in record mode.
    func toggleRecording() {
        if let recording {
            recording.stop()
        } else if let session {
            session.enterRecordMode()
        } else {
            begin(.record)
        }
    }

    /// The Pick Color shortcut (R-38): with the overlay open, turns its picker on or off;
    /// otherwise opens it straight in the picker, over the frozen screen. Not while recording.
    func pickColor() {
        if let session {
            session.togglePicker()
        } else {
            begin(.pickColor)
        }
    }

    /// Holding the Screenshot key or Touch Bar button (SS-02): opens the overlay in record mode;
    /// with the overlay already open, switches it to recording as Record Screen does (SS-51; user
    /// 2026-11-22: "okay" — the Touch Bar fill filled up and then nothing happened). Never stops a
    /// running recording.
    func holdToRecord() {
        guard recording == nil, !starting else { return }
        if let session { session.enterRecordMode() } else { begin(.record) }
    }

    private func startRecording(_ request: RecordingRequest) {
        let recording = environment.makeRecording(request) { [weak self] in self?.recording = nil }
        self.recording = recording
        recording.start()
    }

    /// Where Save puts screenshots: the folder chosen in Settings, else the system's screenshot
    /// folder, else the Desktop.
    static var folder: URL {
        folder(in: .standard,
               systemLocation: UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"),
               isFolder: { url in
                   var isDirectory: ObjCBool = false
                   return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
               },
               desktop: FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0])
    }

    /// `folder` from plain inputs: the system location (`com.apple.screencapture` `location`) and
    /// the Desktop are read only when needed, as before.
    static func folder(in defaults: UserDefaults, systemLocation: @autoclosure () -> String?,
                       isFolder: (URL) -> Bool, desktop: @autoclosure () -> URL) -> URL {
        if let path = defaults.string(forKey: folderKey) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        if let system = systemLocation() {
            let url = URL(fileURLWithPath: (system as NSString).expandingTildeInPath, isDirectory: true)
            if isFolder(url) { return url }
        }
        return desktop()
    }

    /// `.record`: straight in record mode, over the live screen. `.pickColor`: straight in the
    /// color picker, always over the frozen screen (it reads its pixels).
    /// Returns the task that grabs the screen and opens the overlay (nil when nothing starts).
    @discardableResult
    func begin(_ start: CaptureStart = .screenshot, editing pin: PinnedWindow? = nil) -> Task<Void, Never>? {
        guard session == nil, !starting, recording == nil else { return nil }
        guard environment.hasPermission() else {
            requestPermission()
            return nil
        }
        starting = true
        let mode: ScreenshotMode = switch start {
        case .record: .live
        case .pickColor: .frozen
        case .screenshot: ScreenshotMode.current(in: environment.defaults)
        }
        let previous = environment.frontApp()
        let environment = environment
        return Task { [weak self] in
            defer { self?.starting = false }
            var images: [CGDirectDisplayID: CGImage] = [:]
            if mode == .frozen {
                do {
                    images = try await environment.grabAll(start == .pickColor)
                } catch {
                    environment.hud(String(localized: "Couldn't take the screenshot"), nil, "exclamationmark.triangle.fill", .error)
                    pin?.reappear()
                    return
                }
            }
            guard let self else { return }
            let session = environment.makeOverlay(mode, images, previous, start,
                                                  { [weak self] in self?.startRecording($0) },
                                                  { [weak self] in self?.session = nil })
            self.session = session
            session.show()
            if let pin, let editor = session as? CaptureSession { editor.edit(pin) }
        }
    }

    /// The first time, macOS shows its own prompt; after that, System Settings is opened.
    private func requestPermission() {
        let defaults = environment.defaults
        if defaults.bool(forKey: Self.askedKey) {
            environment.hud(String(localized: "Screen Recording needed"), String(localized: "Allow it in System Settings, then reopen Penknife"),
                            "lock.fill", .permission)
            environment.open(Self.screenRecordingSettings)
        } else {
            defaults.set(true, forKey: Self.askedKey)
            environment.requestPermission()
        }
    }
}

/// Screen images through ScreenCaptureKit, at the display's full resolution, without the
/// pointer and without Penknife's own windows.
enum ScreenGrabber {
    struct Failure: Error {}

    /// `sRGB`: the image is tagged sRGB, so its pixels read as true colors (the color picker,
    /// R-38). Without it ScreenCaptureKit's image has no color space (screenshots as before).
    static func captureAll(sRGB: Bool = false) async throws -> [CGDirectDisplayID: CGImage] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        var images: [CGDirectDisplayID: CGImage] = [:]
        for screen in NSScreen.screens {
            images[screen.displayID] = try await capture(screen, content: content, sRGB: sRGB)
        }
        return images
    }

    static func capture(_ screen: NSScreen, sRGB: Bool = false) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        return try await capture(screen, content: content, sRGB: sRGB)
    }

    /// One window alone, as macOS does: its rounded corners transparent, no shadow, nothing over it.
    static func captureWindow(_ id: CGWindowID, size: CGSize, scale: CGFloat) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == id }) else { throw Failure() }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(size.width * scale)
        configuration.height = Int(size.height * scale)
        configuration.showsCursor = false
        configuration.captureResolution = .best
        configuration.ignoreShadowsSingleWindow = true
        configuration.backgroundColor = .clear
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    /// The desktop of one screen (wallpaper and icons) without any window.
    static func captureDesktop(_ screen: NSScreen) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else { throw Failure() }
        let desktop = content.windows.filter { $0.windowLayer < 0 && $0.frame.intersects(display.frame) }
        let filter = SCContentFilter(display: display, including: desktop)
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration(for: screen))
    }

    private static func configuration(for screen: NSScreen) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        let scale = screen.backingScaleFactor
        configuration.width = Int(screen.frame.width * scale)
        configuration.height = Int(screen.frame.height * scale)
        configuration.showsCursor = false
        configuration.captureResolution = .best
        return configuration
    }

    private static func capture(_ screen: NSScreen, content: SCShareableContent, sRGB: Bool) async throws -> CGImage {
        guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else { throw Failure() }
        let own = content.applications.filter { $0.processID == getpid() }
        let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        let configuration = configuration(for: screen)
        if sRGB { configuration.colorSpaceName = CGColorSpace.sRGB }
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

/// Gives a window the focus: its app becomes active and the window comes to the front, so it
/// draws as active. Uses Accessibility to raise that exact window (without the permission, only
/// the app is activated).
enum WindowFocus {
    static func focus(_ id: CGWindowID, frame: CGRect) async {
        guard let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]],
              let pid = list.first?[kCGWindowOwnerPID as String] as? pid_t,
              let app = NSRunningApplication(processIdentifier: pid) else { return }
        if AXIsProcessTrusted() {
            let element = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(element, 0.3)
            var windows: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windows) == .success,
               let windows = windows as? [AXUIElement],
               let window = windows.first(where: { matches($0, frame) }) {
                AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            }
        }
        app.activate()
        // Give the window a moment to redraw as active.
        try? await Task.sleep(for: .milliseconds(180))
    }

    private static func matches(_ window: AXUIElement, _ frame: CGRect) -> Bool {
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success else { return false }
        var origin = CGPoint.zero, extent = CGSize.zero
        guard let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID(),
              AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return false }
        return abs(origin.x - frame.minX) < 3 && abs(origin.y - frame.minY) < 3
            && abs(extent.width - frame.width) < 3 && abs(extent.height - frame.height) < 3
    }
}

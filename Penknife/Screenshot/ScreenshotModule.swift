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

    static var current: Self {
        Self(rawValue: UserDefaults.standard.string(forKey: ScreenshotModule.modeKey) ?? "") ?? .frozen
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
    static var copiesFile: Bool { UserDefaults.standard.object(forKey: copyFileKey) as? Bool ?? true }

    /// Scrolling up makes lines and text thicker (default) or thinner (setting).
    static var scrollUpThinner: Bool { UserDefaults.standard.bool(forKey: scrollKey) }
    private static let askedKey = "screenshot.askedPermission"

    private var session: CaptureSession?
    private var starting = false

    var actions: [ModuleAction] {
        [ModuleAction(shortcut: .screenshot, title: String(localized: "Screenshot"), symbol: id.symbol,
                      perform: { [weak self] in self?.begin() })]
    }

    func start() {}

    func stop() {
        session?.cancel()
        session = nil
    }

    /// Where Save puts screenshots: the folder chosen in Settings, else the system's screenshot
    /// folder, else the Desktop.
    static var folder: URL {
        if let path = UserDefaults.standard.string(forKey: folderKey) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        if let system = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location") {
            let url = URL(fileURLWithPath: (system as NSString).expandingTildeInPath, isDirectory: true)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return url
            }
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }

    private func begin() {
        guard session == nil, !starting else { return }
        guard CGPreflightScreenCaptureAccess() else {
            requestPermission()
            return
        }
        starting = true
        let mode = ScreenshotMode.current
        let previous = NSWorkspace.shared.frontmostApplication
        Task { [weak self] in
            defer { self?.starting = false }
            var images: [CGDirectDisplayID: CGImage] = [:]
            if mode == .frozen {
                do {
                    images = try await ScreenGrabber.captureAll()
                } catch {
                    HUD.shared.show(String(localized: "Couldn't take the screenshot"), symbol: "exclamationmark.triangle.fill",
                                    kind: .error, category: .screenshot)
                    return
                }
            }
            guard let self else { return }
            let session = CaptureSession(mode: mode, images: images, previousApp: previous) { [weak self] in
                self?.session = nil
            }
            self.session = session
            session.show()
        }
    }

    /// The first time, macOS shows its own prompt; after that, System Settings is opened.
    private func requestPermission() {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: Self.askedKey) {
            HUD.shared.show(String(localized: "Screen Recording needed"),
                            detail: String(localized: "Allow Penknife, then reopen it"),
                            symbol: "lock.fill", kind: .permission, category: .screenshot)
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        } else {
            defaults.set(true, forKey: Self.askedKey)
            CGRequestScreenCaptureAccess()
        }
    }
}

/// Screen images through ScreenCaptureKit, at the display's full resolution, without the
/// pointer and without Penknife's own windows.
enum ScreenGrabber {
    struct Failure: Error {}

    static func captureAll() async throws -> [CGDirectDisplayID: CGImage] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        var images: [CGDirectDisplayID: CGImage] = [:]
        for screen in NSScreen.screens {
            images[screen.displayID] = try await capture(screen, content: content)
        }
        return images
    }

    static func capture(_ screen: NSScreen) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        return try await capture(screen, content: content)
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

    private static func capture(_ screen: NSScreen, content: SCShareableContent) async throws -> CGImage {
        guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else { throw Failure() }
        let own = content.applications.filter { $0.processID == getpid() }
        let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration(for: screen))
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

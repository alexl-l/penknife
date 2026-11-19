import AppKit
import ApplicationServices
import AVFoundation
import CoreLocation
import Observation

/// Accessibility permission state. Updated by the system notification, never polled.
@Observable
final class Permissions {
    static let shared = Permissions()

    private(set) var accessibilityGranted = AXIsProcessTrusted()

    /// Called when the permission changes (e.g. to start the dialog observers).
    @ObservationIgnored var onChange: [() -> Void] = []
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var prompted = false

    private init() {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            // The new value is visible a moment after the notification arrives.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
    }

    func refresh() {
        let granted = AXIsProcessTrusted()
        guard granted != accessibilityGranted else { return }
        accessibilityGranted = granted
        onChange.forEach { $0() }
    }

    /// Shows the system prompt that leads to System Settings → Privacy & Security → Accessibility.
    func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        accessibilityGranted = AXIsProcessTrustedWithOptions(options)
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// For actions that post keyboard or mouse events: shows the system prompt once per launch
    /// if the permission is missing (Settings → General keeps the button for later).
    @discardableResult
    func ensureAccessibility() -> Bool {
        refresh()
        if !accessibilityGranted && !prompted {
            prompted = true
            requestAccessibility()
        }
        return accessibilityGranted
    }
}

/// The five macOS permissions Penknife uses, as Settings › Permissions shows them (GN-21, O-31).
/// Names are macOS 26's own (Privacy & Security). States are read when the page shows or the app
/// becomes active again, never polled.
enum PrivacyPermission: CaseIterable, Identifiable {
    case deviceControl, screenRecording, microphone, location, automation

    var id: Self { self }

    /// What a row can say about a permission.
    enum Access: Equatable { case granted, notAsked, denied, unknown }
    /// The row's trailing control.
    enum Control: Equatable { case granted, allow, openSettings }

    /// GN-21: granted → "Granted"; never asked → "Allow…" (macOS's prompt); denied or not
    /// readable (Automation) → "Open System Settings". Never a "Granted" Penknife can't read.
    static func control(for access: Access) -> Control {
        switch access {
        case .granted: .granted
        case .notAsked: .allow
        case .denied, .unknown: .openSettings
        }
    }

    var title: String {
        switch self {
        case .deviceControl: String(localized: "Device Control and Data Access")
        case .screenRecording: String(localized: "Screen & System Audio Recording")
        case .microphone: String(localized: "Microphone")
        case .location: String(localized: "Location Services")
        case .automation: String(localized: "Automation")
        }
    }

    var detail: String {
        switch self {
        case .deviceControl: String(localized: "To press keys and detect dialogs: mouse jiggler, meeting mute and Siri watch, pasting from history, music keys, Touch Bar dialogs and lock screen.")
        case .screenRecording: String(localized: "For screenshots and screen recordings.")
        case .microphone: String(localized: "Adds your voice to recordings, only when you turn the microphone on.")
        case .location: String(localized: "For the weather. Approximate location only (about 11 km).")
        case .automation: String(localized: "Controls Spotify and Music, and reads the active Safari or Chrome tab to find your meeting.")
        }
    }

    /// Privacy & Security pane of each permission.
    var settingsURL: URL {
        let pane = switch self {
        case .deviceControl: "Privacy_Accessibility"
        case .screenRecording: "Privacy_ScreenCapture"
        case .microphone: "Privacy_Microphone"
        case .location: "Privacy_LocationServices"
        case .automation: "Privacy_Automation"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    }

    static func microphoneAccess(_ status: AVAuthorizationStatus) -> Access {
        switch status {
        case .authorized: .granted
        case .notDetermined: .notAsked
        default: .denied
        }
    }

    static func locationAccess(_ status: CLAuthorizationStatus) -> Access {
        switch status {
        case .authorizedAlways: .granted
        case .notDetermined: .notAsked
        default: .denied
        }
    }

    /// Screen Recording has no "not asked" state of its own: Penknife remembers whether it asked
    /// (the same flag the Screenshot module sets).
    static func screenAccess(granted: Bool, asked: Bool) -> Access {
        granted ? .granted : asked ? .denied : .notAsked
    }

    /// Reads the current state without showing any prompt.
    var access: Access {
        switch self {
        case .deviceControl: AXIsProcessTrusted() ? .granted : .denied
        case .screenRecording:
            Self.screenAccess(granted: CGPreflightScreenCaptureAccess(),
                              asked: UserDefaults.standard.bool(forKey: ScreenshotModule.askedKey))
        case .microphone: Self.microphoneAccess(AVCaptureDevice.authorizationStatus(for: .audio))
        case .location: Self.locationAccess(CLLocationManager().authorizationStatus)
        case .automation: .unknown
        }
    }

    /// Kept while macOS's location prompt is open (it needs a living manager).
    private static var locationAsker: CLLocationManager?

    /// "Allow…": shows macOS's own prompt; `done` runs once the answer can be read again.
    func ask(done: @escaping () -> Void) {
        switch self {
        case .deviceControl:
            Permissions.shared.requestAccessibility()
            done()
        case .screenRecording:
            UserDefaults.standard.set(true, forKey: ScreenshotModule.askedKey)
            _ = CGRequestScreenCaptureAccess()
            done()
        case .microphone:
            Task {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
                done()
            }
        case .location:
            let manager = CLLocationManager()
            Self.locationAsker = manager
            manager.requestWhenInUseAuthorization()
            done()
        case .automation:
            NSWorkspace.shared.open(settingsURL)
        }
    }

    /// "Open System Settings": Device Control also asks first, as before (GN-21).
    func openSettings() {
        if self == .deviceControl { Permissions.shared.requestAccessibility() }
        NSWorkspace.shared.open(settingsURL)
    }
}

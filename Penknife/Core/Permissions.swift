import AppKit
import ApplicationServices
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

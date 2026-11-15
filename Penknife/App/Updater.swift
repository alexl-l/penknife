import AppKit
import Sparkle

/// Updates with Sparkle (R-17). Settings live in Penknife-Info.plist: one automatic check a day,
/// and Sparkle's window always asks before installing. The feed is the appcast on GitHub Pages;
/// each update is signed with the EdDSA key kept in this Mac's Keychain.
final class Updater: NSObject, SPUStandardUserDriverDelegate {
    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)

    func start() {
        _ = controller
    }

    /// False while a check is already running.
    var canCheck: Bool { controller.updater.canCheckForUpdates }

    /// From the menu bar menu. A menu bar app is not active, so bring Sparkle's window to the front.
    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    // MARK: SPUStandardUserDriverDelegate

    // A menu bar app has no Dock icon to badge, so a scheduled check that finds an update
    // shows Sparkle's window in front.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if handleShowingUpdate, !state.userInitiated {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

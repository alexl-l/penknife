import AppKit
import os

/// Which app the music controls drive (R-5): any app the user picks, identified by bundle id.
/// `bundleID == nil` means "any app": media keys go to whatever is playing.
struct MusicPlayer: Hashable, Identifiable {
    let bundleID: String?

    static let key = "music.player"
    static let anyAppID = "mediaKeys"
    static let anyApp = MusicPlayer(bundleID: nil)
    static let spotify = MusicPlayer(bundleID: "com.spotify.client")

    /// Offered in Settings when installed, in this order.
    private static let known = [
        "com.spotify.client",         // Spotify
        "com.apple.Music",            // Apple Music
        "com.apple.iTunes",           // iTunes (older macOS)
        "com.github.th-ch.youtube-music", // YouTube Music (desktop app)
        "com.amazon.music",           // Amazon Music
    ]
    /// Apps that understand playpause / next track / previous track Apple Events.
    private static let scriptable: Set = ["com.spotify.client", "com.apple.Music", "com.apple.iTunes"]
    static let appleMusicIDs: Set = ["com.apple.Music", "com.apple.iTunes"]

    var id: String { bundleID ?? Self.anyAppID }
    var usesAppleEvents: Bool { bundleID.map(Self.scriptable.contains) ?? false }
    var isAppleMusic: Bool { bundleID.map(Self.appleMusicIDs.contains) ?? false }
    var url: URL? { bundleID.flatMap(NSWorkspace.shared.urlForApplication(withBundleIdentifier:)) }

    var title: String {
        guard let bundleID else { return String(localized: "Any app (media keys)") }
        guard let url else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    init(bundleID: String?) { self.bundleID = bundleID }

    init(id: String) {
        // Earlier builds stored names instead of bundle ids.
        switch id {
        case Self.anyAppID: bundleID = nil
        case "spotify": bundleID = "com.spotify.client"
        case "appleMusic": bundleID = "com.apple.Music"
        default: bundleID = id
        }
    }

    static var current: MusicPlayer {
        get { MusicPlayer(id: UserDefaults.standard.string(forKey: key) ?? defaultID) }
        set { UserDefaults.standard.set(newValue.id, forKey: key) }
    }

    /// Until the user chooses: the first installed known player, else "any app".
    static var defaultID: String {
        known.first { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil } ?? anyAppID
    }

    /// Installed known players, the current one (even if it is another app) and "any app".
    static func choices(including current: MusicPlayer) -> [MusicPlayer] {
        var list = known.map(MusicPlayer.init(bundleID:)).filter { $0.url != nil }
        if current.bundleID != nil, !list.contains(current) { list.append(current) }
        list.append(.anyApp)
        return list
    }
}

/// Music (R-5): play/pause, next and previous on the chosen player; opens it if it is closed.
/// Spotify and Apple Music/iTunes get Apple Events (exact app); other apps get media keys once
/// they are open; "any app" sends media keys to whatever is playing.
/// Nothing runs between presses.
final class MusicModule: Module {
    let id = ModuleID.music
    var needsAccessibility: Bool { !MusicPlayer.current.usesAppleEvents }

    private let log = Logger(subsystem: "Penknife", category: "Music")
    private var taps = 0
    private var tapTimer: Timer?

    enum Command { case playPause, next, previous }

    var actions: [ModuleAction] {
        [
            ModuleAction(shortcut: .playPause, title: String(localized: "Play or pause"), symbol: "playpause",
                         perform: { [weak self] in self?.send(.playPause) }),
            ModuleAction(shortcut: .nextTrack, title: String(localized: "Next track"), symbol: "forward",
                         perform: { [weak self] in self?.send(.next) }),
            ModuleAction(shortcut: .previousTrack, title: String(localized: "Previous track"), symbol: "backward",
                         perform: { [weak self] in self?.send(.previous) }),
        ]
    }

    func start() {}

    func stop() {
        tapTimer?.invalidate()
        tapTimer = nil
        taps = 0
    }

    /// Touch Bar button: 1 tap play/pause, 2 taps next, 3 taps previous (as in Hammerspoon).
    func tap() {
        if openPlayerIfClosed() { return }
        taps += 1
        tapTimer?.invalidate()
        tapTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let taps = self.taps
                self.taps = 0
                self.send(taps == 1 ? .playPause : taps == 2 ? .next : .previous)
            }
        }
    }

    func send(_ command: Command) {
        if openPlayerIfClosed() { return }
        let player = MusicPlayer.current
        guard player.usesAppleEvents, let bundleID = player.bundleID else {
            guard Permissions.shared.ensureAccessibility() else { return }
            switch command {
            case .playPause: EventPoster.media(.play)
            case .next: EventPoster.media(.next)
            case .previous: EventPoster.media(.previous)
            }
            return
        }
        let verb = switch command {
        case .playPause: "playpause"
        case .next: "next track"
        case .previous: "previous track"
        }
        let source = "tell application id \"\(bundleID)\" to \(verb)"
        let log = log
        // Apple Events can wait for the other app; keep them off the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            if let error { log.error("\(source, privacy: .public): \(error, privacy: .public)") }
        }
    }

    /// Opens the chosen player when it isn't running. Returns true if it did (the press only opens it).
    private func openPlayerIfClosed() -> Bool {
        let player = MusicPlayer.current
        guard let bundleID = player.bundleID,
              NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else { return false }
        guard let url = player.url else {
            HUD.shared.show(String(localized: "\(player.title) is not installed"))
            return true
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        return true
    }
}

/// Block Apple Music (R-6, as noTunes): closes Apple Music or iTunes as soon as it launches (e.g.
/// when the play key wakes it up). Paused while one of them is the chosen player, so the two never
/// clash. Event-driven.
final class BlockAppleMusicModule: Module {
    let id = ModuleID.blockAppleMusic
    let actions: [ModuleAction] = []
    private var observer: NSObjectProtocol?

    func start() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let id = app.bundleIdentifier, ["com.apple.Music", "com.apple.iTunes"].contains(id) else { return }
            MainActor.assumeIsolated {
                guard !MusicPlayer.current.isAppleMusic else { return }
                // Ask nicely first; force it only if it is still there 2 s later.
                app.terminate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    if !app.isTerminated { app.forceTerminate() }
                }
            }
        }
    }

    func stop() {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
    }
}

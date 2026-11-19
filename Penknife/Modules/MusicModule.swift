import AppKit
import CoreAudio
import MediaPlayer
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

    /// Whether an app with this bundle id is installed (the real check; tests pass their own).
    static let isInstalled: (String) -> Bool = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }

    static var current: MusicPlayer {
        get { current(in: .standard) }
        set { UserDefaults.standard.set(newValue.id, forKey: key) }
    }

    static func current(in defaults: UserDefaults, installed: (String) -> Bool = isInstalled) -> MusicPlayer {
        MusicPlayer(id: defaults.string(forKey: key) ?? defaultID(installed: installed))
    }

    /// Until the user chooses: the first installed known player, else "any app".
    static var defaultID: String { defaultID(installed: isInstalled) }

    static func defaultID(installed: (String) -> Bool) -> String {
        known.first(where: installed) ?? anyAppID
    }

    /// Installed known players, the current one (even if it is another app) and "any app".
    static func choices(including current: MusicPlayer, installed: (String) -> Bool = isInstalled) -> [MusicPlayer] {
        var list = known.filter(installed).map(MusicPlayer.init(bundleID:))
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
    var needsAccessibility: Bool { Self.needsAccessibility(for: MusicPlayer.current) }
    static func needsAccessibility(for player: MusicPlayer) -> Bool { !player.usesAppleEvents }

    private let log = Logger(subsystem: "Penknife", category: "Music")
    private var taps = 0
    private var tapTimer: Timer?

    enum Command { case playPause, play, pause, next, previous }

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
                self.send(MusicTaps.command(for: taps))
            }
        }
    }

    func send(_ command: Command) {
        if openPlayerIfClosed() { return }
        let player = MusicPlayer.current
        guard player.usesAppleEvents, let bundleID = player.bundleID else {
            guard Permissions.shared.ensureAccessibility() else {
                HUD.shared.showPermissionNeeded(.music) // O-25
                return
            }
            switch command {
            case .playPause, .play, .pause: EventPoster.media(.play)
            case .next: EventPoster.media(.next)
            case .previous: EventPoster.media(.previous)
            }
            return
        }
        let source = Self.script(bundleID: bundleID, command: command)
        let log = log
        // Apple Events can wait for the other app; keep them off the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            guard let error else { return }
            log.error("\(source, privacy: .public): \(error, privacy: .public)")
            guard Self.isNotPermitted(error) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { MusicModule.automationRefused(player) }
            }
        }
    }

    /// The Automation permission for this player was refused (errAEEventNotPermitted, -1743).
    nonisolated static func isNotPermitted(_ error: NSDictionary) -> Bool {
        (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue == -1743
    }

    /// Players already told about this session: the alert shows once per player per launch (O-26).
    private static var toldRefused: Set<String> = []

    private static func automationRefused(_ player: MusicPlayer) {
        guard let bundleID = player.bundleID, toldRefused.insert(bundleID).inserted else { return }
        HUD.shared.show(AlertCategory.music.title,
                        detail: String(localized: "Allow Penknife to control \(player.title) in System Settings › Privacy & Security › Automation"),
                        symbol: "lock.fill", kind: .permission, category: .music)
    }

    /// The Apple Event sent to a scriptable player (MU-05).
    static func script(bundleID: String, command: Command) -> String {
        let verb = switch command {
        case .playPause: "playpause"
        case .play: "play"
        case .pause: "pause"
        case .next: "next track"
        case .previous: "previous track"
        }
        return "tell application id \"\(bundleID)\" to \(verb)"
    }

    /// Headphone clicks (R-6 Now Playing): sent only while the chosen player is running, so
    /// connecting headphones never opens anything. Returns false when it is closed.
    func sendFromHeadphones(_ command: Command) -> Bool {
        guard let bundleID = MusicPlayer.current.bundleID,
              !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else { return false }
        send(command)
        return true
    }

    /// Opens the chosen player when it isn't running. Returns true if it did (the press only opens it).
    private func openPlayerIfClosed() -> Bool {
        let player = MusicPlayer.current
        guard let bundleID = player.bundleID,
              NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else { return false }
        guard let url = player.url else {
            HUD.shared.show(String(localized: "\(player.title) is not installed"), symbol: "exclamationmark.triangle.fill",
                            kind: .error, category: .music)
            return true
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        return true
    }
}

/// Touch Bar taps (MU-03): 1 play/pause, 2 next, 3 or more previous.
enum MusicTaps {
    static func command(for taps: Int) -> MusicModule.Command {
        taps == 1 ? .playPause : taps == 2 ? .next : .previous
    }
}

/// Whether an Apple Music launch is the user's (MU-10): a click or key press just before, and no
/// audio route change (headphones) just before. Seconds since each.
enum AppleMusicLaunch {
    /// Dock/Spotlight launches measured at ~0.8 s; 3 s let a headphone click right after a
    /// menu click pass as the user's.
    static let inputWindow: TimeInterval = 1.5
    /// A launch this close after an audio route change (headphones) is automatic.
    static let routeWindow: TimeInterval = 4

    static func byUser(click: TimeInterval, key: TimeInterval, route: TimeInterval) -> Bool {
        min(click, key) <= inputWindow && route > routeWindow
    }
}

/// Block Apple Music (R-6, like noTunes, but smarter): closes Apple Music or iTunes only when it
/// opens by itself — headphones connecting, a headphone click, the play key. Opening it yourself
/// (Dock, Spotlight, Finder) works: such a launch follows a click or a key press, while automatic
/// ones follow an audio route change or no input at all. "Allow Apple Music" in the menu turns
/// the block off until Penknife quits (noTunes' toggle). Paused while Apple Music is the chosen
/// player. Event-driven: launch notifications and CoreAudio route listeners only.
final class BlockAppleMusicModule: Module {
    let id = ModuleID.blockAppleMusic

    private let nowPlaying: NowPlayingBridge
    private var defaultsObserver: NSObjectProtocol?

    init(music: MusicModule) { nowPlaying = NowPlayingBridge(music: music) }

    var actions: [ModuleAction] {
        [ModuleAction(shortcut: .allowAppleMusic, title: String(localized: "Allow Apple Music"), symbol: "music.note",
                      state: { [weak self] in self?.allowed ?? false },
                      perform: { [weak self] in self?.allowed.toggle() })]
    }

    /// Menu toggle: Apple Music may open freely until Penknife quits.
    var allowed = false

    private var observer: NSObjectProtocol?
    private var routeListener: AudioObjectPropertyListenerBlock?
    private var lastRouteChange = Date.distantPast
    private let log = Logger(subsystem: "Penknife", category: "BlockAppleMusic")

    nonisolated private static let bundleIDs: Set<String> = ["com.apple.Music", "com.apple.iTunes"]
    private static let routeAddresses = [
        AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                   mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain),
        AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                   mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain),
    ]

    func start() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let id = app.bundleIdentifier, Self.bundleIDs.contains(id) else { return }
            MainActor.assumeIsolated { self?.launched(app) }
        }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.lastRouteChange = Date() }
        }
        for var address in Self.routeAddresses {
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        }
        routeListener = listener
        nowPlaying.update()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.nowPlaying.update() }
        }
    }

    func stop() {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
        if let routeListener {
            for var address in Self.routeAddresses {
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, routeListener)
            }
        }
        routeListener = nil
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        defaultsObserver = nil
        nowPlaying.unregister()
        allowed = false
    }

    private func launched(_ app: NSRunningApplication) {
        guard !MusicPlayer.current.isAppleMusic else { return }
        if allowed {
            log.info("Apple Music opened: allowed from the menu")
            return
        }
        let click = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDown)
        let key = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        let route = Date().timeIntervalSince(lastRouteChange)
        let byUser = AppleMusicLaunch.byUser(click: click, key: key, route: route)
        let reason = String(format: "click %.1f s ago, key %.1f s ago, audio route change %.1f s ago", click, key, route)
        guard !byUser else {
            log.info("Apple Music opened by the user, kept (\(reason, privacy: .public))")
            return
        }
        log.info("Apple Music opened by itself, closed (\(reason, privacy: .public))")
        // Forced at once, as noTunes: a polite quit lets its window show up first.
        app.forceTerminate()
    }
}

/// Penknife as the paused Now Playing app (R-6, tested with AirPods 2026-11-13): headphone
/// clicks reach Penknife instead of launching Apple Music, and go to the chosen player.
/// A playing app (Spotify) still takes Now Playing over while it plays. Only for players driven
/// by Apple Events: media keys would come straight back to Penknife. Not while Apple Music is
/// the player. No timers, no audio: only command targets.
@MainActor
final class NowPlayingBridge {
    private let music: MusicModule
    private var registeredFor: String?
    private var targets: [(MPRemoteCommand, Any)] = []
    private let log = Logger(subsystem: "Penknife", category: "BlockAppleMusic")

    init(music: MusicModule) { self.music = music }

    /// Registers, re-registers or unregisters for the current player choice.
    func update() {
        let player = MusicPlayer.current
        let wanted = Self.wanted(for: player)
        guard wanted != registeredFor else { return }
        unregister()
        guard let wanted else { return }
        register(player)
        registeredFor = wanted
    }

    /// The player Now Playing registers for (MU-13): only Apple Events players that are not Apple Music.
    static func wanted(for player: MusicPlayer) -> String? {
        player.usesAppleEvents && !player.isAppleMusic ? player.bundleID : nil
    }

    func unregister() {
        guard registeredFor != nil else { return }
        for (command, target) in targets {
            command.removeTarget(target)
            command.isEnabled = false
        }
        targets = []
        let info = MPNowPlayingInfoCenter.default()
        info.nowPlayingInfo = nil
        info.playbackState = .stopped
        registeredFor = nil
        log.info("Now Playing: unregistered")
    }

    private func register(_ player: MusicPlayer) {
        let center = MPRemoteCommandCenter.shared()
        let map: [(MPRemoteCommand, MusicModule.Command)] = [
            (center.togglePlayPauseCommand, .playPause),
            (center.playCommand, .play),
            (center.pauseCommand, .pause),
            (center.nextTrackCommand, .next),
            (center.previousTrackCommand, .previous),
        ]
        for (remote, command) in map {
            remote.isEnabled = true
            let target = remote.addTarget { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return .commandFailed }
                    let sent = self.music.sendFromHeadphones(command)
                    self.log.info("Headphone \(String(describing: command), privacy: .public): \(sent ? "sent to the player" : "ignored, player closed", privacy: .public)")
                    return sent ? .success : .noActionableNowPlayingItem
                }
            }
            targets.append((remote, target))
        }
        let info = MPNowPlayingInfoCenter.default()
        info.nowPlayingInfo = [MPMediaItemPropertyTitle: player.title, MPNowPlayingInfoPropertyPlaybackRate: 0.0]
        info.playbackState = .paused
        log.info("Now Playing: registered for \(player.title, privacy: .public)")
    }
}

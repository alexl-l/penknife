import Foundation
import KeyboardShortcuts
import Testing
@testable import Penknife

/// Music and Block Apple Music rules (docs/requirements/music.md). Each test names the rule it
/// checks. Nothing here sends Apple Events or media keys, opens or quits an app, registers with
/// Now Playing, listens to the system or writes the user's settings.
@MainActor
@Suite("Music rules")
struct MusicRulesTests {

    /// Settings that only live in memory.
    final class MemoryDefaults: UserDefaults {
        var values: [String: Any] = [:]

        convenience init(_ values: [String: Any] = [:]) {
            self.init(suiteName: "PenknifeTests.memory.\(UUID().uuidString)")!
            self.values = values
        }

        override func object(forKey key: String) -> Any? { values[key] }
        override func string(forKey key: String) -> String? { values[key] as? String }
        override func set(_ value: Any?, forKey key: String) { values[key] = value }
    }

    static let spotify = "com.spotify.client"
    static let music = "com.apple.Music"
    static let iTunes = "com.apple.iTunes"
    static let youTube = "com.github.th-ch.youtube-music"
    static let amazon = "com.amazon.music"

    static func only(_ ids: Set<String>) -> (String) -> Bool { { ids.contains($0) } }

    // MARK: A. The module and its actions

    @Test("MU-14 O-26 only a refused Automation permission (-1743) counts as refused")
    func automationRefused() {
        #expect(MusicModule.isNotPermitted([NSAppleScript.errorNumber: -1743] as NSDictionary))
        #expect(!MusicModule.isNotPermitted([NSAppleScript.errorNumber: -600] as NSDictionary))
        #expect(!MusicModule.isNotPermitted([:] as NSDictionary))
    }

    @Test("MU-01 MU-09 modules on by default with their symbols")
    func modules() {
        #expect(ModuleID.music.symbol == "music.note" && ModuleID.music.defaultOn)
        #expect(ModuleID.blockAppleMusic.symbol == "nosign" && ModuleID.blockAppleMusic.defaultOn)
    }

    @Test("MU-01 Accessibility only for players driven by media keys")
    func needsAccessibility() {
        for id in [Self.spotify, Self.music, Self.iTunes] {
            #expect(!MusicModule.needsAccessibility(for: MusicPlayer(bundleID: id)))
        }
        for player in [MusicPlayer(bundleID: Self.youTube), MusicPlayer(bundleID: "com.apple.Safari"), .anyApp] {
            #expect(MusicModule.needsAccessibility(for: player))
        }
    }

    @Test("MU-02 three actions in order, no default keys")
    func actions() {
        let actions = MusicModule().actions
        #expect(actions.map(\.shortcut) == [.playPause, .nextTrack, .previousTrack])
        #expect(actions.map(\.symbol) == ["playpause", "forward", "backward"])
        for name: KeyboardShortcuts.Name in [.playPause, .nextTrack, .previousTrack, .allowAppleMusic] { #expect(name.defaultShortcut == nil) }
    }

    @Test("MU-03 one tap plays or pauses, two next, three or more previous")
    func taps() {
        #expect(MusicTaps.command(for: 1) == .playPause)
        #expect(MusicTaps.command(for: 2) == .next)
        #expect(MusicTaps.command(for: 3) == .previous)
        #expect(MusicTaps.command(for: 5) == .previous)
    }

    // MARK: B. The player

    @Test("MU-05 Apple Events only for Spotify, Apple Music and iTunes, with these sentences")
    func appleEvents() {
        #expect([Self.spotify, Self.music, Self.iTunes, Self.youTube, Self.amazon]
            .map { MusicPlayer(bundleID: $0).usesAppleEvents } == [true, true, true, false, false])
        #expect(!MusicPlayer.anyApp.usesAppleEvents)
        let commands: [MusicModule.Command] = [.playPause, .play, .pause, .next, .previous]
        #expect(commands.map { MusicModule.script(bundleID: Self.spotify, command: $0) } == [
            "tell application id \"com.spotify.client\" to playpause",
            "tell application id \"com.spotify.client\" to play",
            "tell application id \"com.spotify.client\" to pause",
            "tell application id \"com.spotify.client\" to next track",
            "tell application id \"com.spotify.client\" to previous track",
        ])
    }

    @Test("MU-07 installed known players in order, another app once, any app last")
    func choices() {
        let all = Self.only([Self.spotify, Self.music, Self.iTunes, Self.youTube, Self.amazon])
        #expect(MusicPlayer.choices(including: .anyApp, installed: all).map(\.id) ==
                [Self.spotify, Self.music, Self.iTunes, Self.youTube, Self.amazon, "mediaKeys"])
        let some = Self.only([Self.amazon, Self.music])
        #expect(MusicPlayer.choices(including: MusicPlayer(bundleID: Self.music), installed: some).map(\.id) ==
                [Self.music, Self.amazon, "mediaKeys"])
        #expect(MusicPlayer.choices(including: MusicPlayer(bundleID: "com.x.y"), installed: some).map(\.id) ==
                [Self.music, Self.amazon, "com.x.y", "mediaKeys"])
        #expect(MusicPlayer.choices(including: .anyApp, installed: Self.only([])).map(\.id) == ["mediaKeys"])
    }

    @Test("MU-08 stored value, old names, and the default until the user chooses")
    func stored() {
        #expect(MusicPlayer(id: "mediaKeys") == .anyApp)
        #expect(MusicPlayer(id: "spotify").bundleID == Self.spotify)
        #expect(MusicPlayer(id: "appleMusic").bundleID == Self.music)
        #expect(MusicPlayer(id: "com.x.y").bundleID == "com.x.y")
        #expect(MusicPlayer(id: "spotify").id == Self.spotify && MusicPlayer.anyApp.id == "mediaKeys")

        #expect(MusicPlayer.defaultID(installed: Self.only([Self.music])) == Self.music)
        #expect(MusicPlayer.defaultID(installed: Self.only([])) == "mediaKeys")
        #expect(MusicPlayer.defaultID(installed: Self.only([Self.music, Self.spotify])) == Self.music)
        #expect(MusicPlayer.defaultID(installed: Self.only([Self.amazon, Self.spotify])) == Self.spotify)

        let none = Self.only([Self.amazon])
        #expect(MusicPlayer.current(in: MemoryDefaults(), installed: none).bundleID == Self.amazon)
        #expect(MusicPlayer.current(in: MemoryDefaults([MusicPlayer.key: "spotify"]), installed: none).bundleID == Self.spotify)
    }

    // MARK: C. Block Apple Music

    @Test("MU-10 a launch is the user's after a click or key and no headphone change")
    func launch() {
        #expect(AppleMusicLaunch.byUser(click: 0.8, key: 60, route: 10))
        #expect(AppleMusicLaunch.byUser(click: 60, key: 0.3, route: 100))
        #expect(!AppleMusicLaunch.byUser(click: 2, key: 3, route: 100))
        #expect(!AppleMusicLaunch.byUser(click: 0.5, key: 60, route: 1))
        #expect(AppleMusicLaunch.byUser(click: 1.5, key: 60, route: 4.1))
        #expect(!AppleMusicLaunch.byUser(click: 1.5, key: 60, route: 4.0))
        // Penknife's own media key (Touch Bar tap, shortcut, menu) counts, even after headphones.
        #expect(AppleMusicLaunch.byUser(click: 60, key: 60, route: 1, command: 0.4))
        #expect(!AppleMusicLaunch.byUser(click: 60, key: 60, route: 100, command: 2))
        #expect([Self.music, Self.iTunes].allSatisfy { MusicPlayer(bundleID: $0).isAppleMusic })
        #expect(!MusicPlayer(bundleID: Self.spotify).isAppleMusic && !MusicPlayer.anyApp.isAppleMusic)
    }

    @Test("MU-12 Allow Apple Music is off again when the module stops")
    func allow() throws {
        let block = BlockAppleMusicModule(music: MusicModule())
        let action = try #require(block.actions.first)
        #expect(action.shortcut == .allowAppleMusic && action.symbol == "music.note")
        block.allowed = true
        #expect(action.state?() == true)
        block.stop()
        #expect(!block.allowed)
    }

    @Test("MU-13 Now Playing only for Apple Events players that are not Apple Music")
    func nowPlaying() {
        #expect(NowPlayingBridge.wanted(for: MusicPlayer(bundleID: Self.spotify)) == Self.spotify)
        for player in [Self.music, Self.iTunes, Self.youTube, "com.x.y"].map(MusicPlayer.init(bundleID:)) + [.anyApp] {
            #expect(NowPlayingBridge.wanted(for: player) == nil)
        }
    }
}

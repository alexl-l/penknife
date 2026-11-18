import AppKit
import AudioToolbox
import CoreAudio

/// Tells when the built-in display's brightness changes, whoever changes it (keys, Control
/// Center, our slider). Private DisplayServices notification; nothing is polled (R-25).
final class BrightnessWatcher {
    private typealias Register = @convention(c) (CGDirectDisplayID, UnsafeRawPointer?, CFNotificationCallback) -> Int32
    private typealias Unregister = @convention(c) (CGDirectDisplayID, UnsafeRawPointer?) -> Int32

    private static let calls: (register: Register, unregister: Unregister)? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
              let register = dlsym(handle, "DisplayServicesRegisterForBrightnessChangeNotifications"),
              let unregister = dlsym(handle, "DisplayServicesUnregisterForBrightnessChangeNotifications") else { return nil }
        return (unsafeBitCast(register, to: Register.self), unsafeBitCast(unregister, to: Unregister.self))
    }()

    private let onChange: () -> Void
    private var display: CGDirectDisplayID?

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    func start() {
        guard display == nil, let calls = Self.calls else { return }
        let display = DisplayBrightness.display
        let observer = Unmanaged.passUnretained(self).toOpaque()
        let status = calls.register(display, observer) { _, observer, _, _, _ in
            guard let observer else { return }
            let watcher = Unmanaged<BrightnessWatcher>.fromOpaque(observer).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { watcher.onChange() } }
        }
        if status == 0 { self.display = display }
    }

    var isWatching: Bool { display != nil }

    func stop() {
        guard let display, let calls = Self.calls else { return }
        _ = calls.unregister(display, Unmanaged.passUnretained(self).toOpaque())
        self.display = nil
    }
}

/// Tells when the keyboard backlight changes (keys, auto-dimming, our slider). Private
/// CoreBrightness block notification (R-25).
final class KeyboardLightWatcher {
    private typealias Register = @convention(c) (AnyObject, Selector, NSArray, UInt64, @escaping @convention(block) (AnyObject?, AnyObject?) -> Void) -> Void
    private typealias Unregister = @convention(c) (AnyObject, Selector) -> Void

    private static let registerSelector = NSSelectorFromString("registerNotificationForKeys:keyboardID:block:")
    private static let unregisterSelector = NSSelectorFromString("unregisterKeyboardNotificationBlock")

    private let onChange: () -> Void
    private var client: NSObject?

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    func start() {
        guard client == nil, let (object, keyboard) = KeyboardBrightness.clientAndKeyboard,
              object.responds(to: Self.registerSelector), object.responds(to: Self.unregisterSelector) else { return }
        let register = unsafeBitCast(object.method(for: Self.registerSelector), to: Register.self)
        register(object, Self.registerSelector, ["KeyboardBacklightBrightness"], keyboard) { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.onChange() } }
        }
        client = object
    }

    var isWatching: Bool { client != nil }

    func stop() {
        guard let client else { return }
        let unregister = unsafeBitCast(client.method(for: Self.unregisterSelector), to: Unregister.self)
        unregister(client, Self.unregisterSelector)
        self.client = nil
    }
}

/// Tells when the output volume or mute changes, and when the default output device changes
/// (public CoreAudio listeners, as `MicrophoneWatcher` does for the input).
final class VolumeWatcher {
    private let onChange: () -> Void
    private var device: AudioObjectID?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var defaultListener: AudioObjectPropertyListenerBlock?

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    func start() {
        guard defaultListener == nil else { return }
        var address = Self.defaultOutputAddress
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.watchDevice()
                self?.onChange()
            }
        }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        defaultListener = listener
        watchDevice()
    }

    var isWatching: Bool { defaultListener != nil }

    func stop() {
        unwatchDevice()
        guard let defaultListener else { return }
        var address = Self.defaultOutputAddress
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, defaultListener)
        self.defaultListener = nil
    }

    private static let defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    private static let addresses = [
        AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                   mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain),
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                   mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain),
    ]

    private func watchDevice() {
        unwatchDevice()
        guard let device = OutputVolume.device else { return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.onChange() }
        }
        for var address in Self.addresses where AudioObjectHasProperty(device, &address) {
            AudioObjectAddPropertyListenerBlock(device, &address, .main, listener)
        }
        self.device = device
        deviceListener = listener
    }

    private func unwatchDevice() {
        guard let device, let deviceListener else { return }
        for var address in Self.addresses {
            AudioObjectRemovePropertyListenerBlock(device, &address, .main, deviceListener)
        }
        self.device = nil
        self.deviceListener = nil
    }
}

/// Whether the chosen player is playing, from the notifications Spotify and Apple Music post
/// on every change (no polling). Other players don't post one, so they always show "paused".
final class PlaybackWatcher {
    private let onChange: () -> Void
    private var observers: [NSObjectProtocol] = []
    private(set) var isPlaying = false

    private static let notifications: [String: String] = [
        "com.spotify.client.PlaybackStateChanged": "com.spotify.client",
        "com.apple.Music.playerInfo": "com.apple.Music",
        "com.apple.iTunes.playerInfo": "com.apple.iTunes",
    ]

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    func start() {
        guard observers.isEmpty else { return }
        let distributed = DistributedNotificationCenter.default()
        for (name, bundleID) in Self.notifications {
            observers.append(distributed.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] note in
                let state = note.userInfo?["Player State"] as? String
                MainActor.assumeIsolated {
                    guard MusicPlayer.current.bundleID == bundleID else { return }
                    self?.set(state == "Playing")
                }
            })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                if app?.bundleIdentifier == MusicPlayer.current.bundleID { self?.set(false) }
            }
        })
    }

    var isWatching: Bool { !observers.isEmpty }

    func stop() {
        for observer in observers {
            DistributedNotificationCenter.default().removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers = []
        isPlaying = false
    }

    /// The chosen player changed: its state is unknown until it posts again.
    func reset() { set(false) }

    private func set(_ playing: Bool) {
        guard playing != isPlaying else { return }
        isPlaying = playing
        onChange()
    }
}

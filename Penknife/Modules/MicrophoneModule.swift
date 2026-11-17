import AppKit
import CoreAudio
import os

/// Microphone toggle (R-3, R-28): mutes the current meeting with its own shortcut, or the Mac's
/// default input device. Only a workspace notification runs between presses.
final class MicrophoneModule: Module {
    let id = ModuleID.microphone
    var needsAccessibility: Bool { true }

    private let log = Logger(subsystem: "Penknife", category: "Microphone")
    /// Input volume before muting, for devices without a mute control.
    private var savedVolume: Float32?

    var actions: [ModuleAction] {
        [ModuleAction(shortcut: .toggleMicrophone, title: String(localized: "Mute Microphone"), symbol: "mic.slash",
                      state: { [weak self] in self?.isMuted ?? false },
                      perform: { [weak self] in self?.toggle() })]
    }

    private let meetings = MeetingTracker()

    func start() {
        meetings.start()
    }

    func stop() {
        meetings.stop()
    }

    static let alsoMuteMacKey = "microphone.alsoMuteMac"
    /// Off by default: with a meeting found, only that meeting is muted (R-28).
    static var alsoMuteMac: Bool { UserDefaults.standard.bool(forKey: alsoMuteMacKey) }

    /// The REAL state of the device (user, 2026-11-16: the Touch Bar and the dot must show what
    /// the microphone is doing, never what Penknife thinks), read from the control `toggle()` changes. Some devices report a mute
    /// property they don't let anyone set; reading it made every press mute again (volume 0).
    var isMuted: Bool {
        guard let device = Self.defaultInputDevice() else { return false }
        if Self.isSettable(device, kAudioDevicePropertyMute), let mute: UInt32 = Self.get(device, kAudioDevicePropertyMute) {
            return mute != 0
        }
        if let volume: Float32 = Self.get(device, kAudioDevicePropertyVolumeScalar) { return volume == 0 }
        if let mute: UInt32 = Self.get(device, kAudioDevicePropertyMute) { return mute != 0 }
        return false
    }

    /// Mutes the current meeting (the one in front, or the last one used) with its own shortcut;
    /// with no meeting, or when the setting asks for it, also the Mac's microphone (R-28).
    func toggle() {
        meetings.findCurrent { [weak self] target in
            guard let self else { return }
            guard let target else { return self.toggleMac() }
            guard Permissions.shared.ensureAccessibility() else { return }
            self.log.notice("Meeting: \(target.platform.rawValue, privacy: .public)")
            self.meetings.send(to: target)
            if Self.alsoMuteMac {
                self.toggleMac()
            } else {
                HUD.shared.show(target.platform.name, detail: String(localized: "Microphone toggled"),
                                symbol: "mic.badge.xmark", kind: .on, category: .microphone)
            }
        }
    }

    private func toggleMac() {
        // While Siri listens the mic is open whatever the mute says, and Siri puts back the state
        // it found when it ends: a press then does nothing (user, 2026-11-16).
        guard !Self.isSiriListening else {
            log.notice("Toggle ignored: Siri is listening")
            return
        }
        guard let device = Self.defaultInputDevice() else {
            HUD.shared.show(String(localized: "No microphone found"), symbol: "exclamationmark.triangle.fill", kind: .error, category: .microphone)
            return
        }
        let mute = !isMuted
        log.notice("Toggle: \(mute ? "mute" : "unmute", privacy: .public), mute settable: \(Self.isSettable(device, kAudioDevicePropertyMute)), volume settable: \(Self.isSettable(device, kAudioDevicePropertyVolumeScalar))")

        if Self.isSettable(device, kAudioDevicePropertyMute) {
            Self.set(device, kAudioDevicePropertyMute, UInt32(mute ? 1 : 0))
        } else if Self.isSettable(device, kAudioDevicePropertyVolumeScalar) {
            if mute {
                savedVolume = Self.get(device, kAudioDevicePropertyVolumeScalar)
                Self.set(device, kAudioDevicePropertyVolumeScalar, Float32(0))
            } else {
                Self.set(device, kAudioDevicePropertyVolumeScalar, savedVolume ?? Float32(1))
            }
        }

        if mute {
            HUD.shared.show(String(localized: "Microphone muted"), symbol: "mic.slash.fill", kind: .off, category: .microphone)
        } else {
            HUD.shared.show(String(localized: "Microphone unmuted"), symbol: "mic.fill", kind: .on, category: .microphone)
        }
    }

    // MARK: CoreAudio

    private static func address(_ selector: AudioObjectPropertySelector, _ object: AudioObjectID? = nil) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: object == nil ? kAudioObjectPropertyScopeGlobal : kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
    }

    /// Siri's bundle ID as CoreAudio reports it.
    private static let siriBundleID = "com.apple.CoreSpeech"

    /// Siri records even with the microphone muted, and clears the mute while it listens, then
    /// restores it (measured 2026-11-16). Read only when the user presses, never polled.
    static var isSiriListening: Bool { MeetingTracker.appsUsingMicrophone().contains(siriBundleID) }

    static func defaultInputDevice() -> AudioObjectID? {
        var address = address(kAudioHardwarePropertyDefaultInputDevice)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    static func get<T: BitwiseCopyable>(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        var address = address(selector, device)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer) == noErr else { return nil }
        return pointer.pointee
    }

    static func isSettable(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
        var address = address(selector, device)
        var settable: DarwinBoolean = false
        return AudioObjectHasProperty(device, &address)
            && AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    static func set<T: BitwiseCopyable>(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: T) {
        var address = address(selector, device)
        var value = value
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<T>.size), &value)
    }
}

/// Calls `onChange` when the default input is muted or unmuted from anywhere (Penknife, Teams,
/// Control Center) or when the default input device changes. CoreAudio listeners cost nothing
/// between changes. Used by the Touch Bar button and the menu bar dot.
final class MicrophoneWatcher {
    private let onChange: () -> Void
    private var device: AudioObjectID?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var defaultListener: AudioObjectPropertyListenerBlock?

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    var isWatching: Bool { defaultListener != nil }

    func start() {
        guard !isWatching else { return }
        var address = Self.defaultInputAddress
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

    func stop() {
        unwatchDevice()
        guard let defaultListener else { return }
        var address = Self.defaultInputAddress
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, defaultListener)
        self.defaultListener = nil
    }

    private static let defaultInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    private static let selectors = [kAudioDevicePropertyMute, kAudioDevicePropertyVolumeScalar]

    private func watchDevice() {
        unwatchDevice()
        guard let device = MicrophoneModule.defaultInputDevice() else { return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.onChange() }
        }
        for selector in Self.selectors {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeInput,
                                                     mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(device, &address, .main, listener)
        }
        self.device = device
        deviceListener = listener
    }

    private func unwatchDevice() {
        guard let device, let deviceListener else { return }
        for selector in Self.selectors {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeInput,
                                                     mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(device, &address, .main, deviceListener)
        }
        self.device = nil
        self.deviceListener = nil
    }
}

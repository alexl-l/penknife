import AppKit
import CoreAudio
import os

/// Microphone toggle (R-3, R-28): mutes the current meeting with its own shortcut, or the Mac's
/// default input device. Between presses: a workspace notification, plus CoreAudio listeners
/// while "Keep the microphone muted" is on (R-34). Rules: docs/requirements/microphone.md.
final class MicrophoneModule: Module {
    let id = ModuleID.microphone
    var needsAccessibility: Bool { true }

    private let log = Logger(subsystem: "Penknife", category: "Microphone")
    /// Input volume before muting, for devices without a mute control.
    private var savedVolume: Float32?
    /// R-34: watches the microphone while "Keep the microphone muted" is on.
    private var keeper: MicrophoneWatcher?
    private var lastMuted = false
    /// Penknife itself changes the mute until then (never undone).
    private var ownChangeUntil = Date.distantPast
    /// When the Mac last started playing a sound (the speakers or headphones began running).
    private var outputStarted = Date.distantPast
    private var outputWatcher: OutputWatcher?
    private var defaultsObserver: NSObjectProtocol?

    var actions: [ModuleAction] {
        [ModuleAction(shortcut: .toggleMicrophone, title: String(localized: "Mute Microphone"), symbol: "mic.slash",
                      state: { [weak self] in self?.isMuted ?? false },
                      perform: { [weak self] in self?.toggle() })]
    }

    private let meetings = MeetingTracker()

    func start() {
        meetings.start()
        updateKeeper()
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil,
                                                                  queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateKeeper() }
        }
    }

    func stop() {
        meetings.stop()
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        defaultsObserver = nil
        keeper?.stop()
        keeper = nil
        // R-15: a module that is off holds nothing (B-1: this listener used to stay behind).
        outputWatcher?.stop()
        outputWatcher = nil
    }

    /// For tests (R-15, MIC-80): whether the module still holds an observer or listener.
    var holdsObservers: Bool { keeper != nil || outputWatcher != nil || defaultsObserver != nil }

    // MARK: Keep muted (R-34)

    static let keepMutedKey = "microphone.keepMuted"
    /// On by default (designer + user, 2026-11-17): a mute that doesn't stay muted breaks the
    /// promise. With "Listen for Siri" on, every sound the Mac plays makes Siri clear the mute and
    /// listen ~5.5 s (measured 2026-11-17).
    static var keepMuted: Bool { UserDefaults.standard.object(forKey: keepMutedKey) as? Bool ?? true }

    /// Whether macOS listens for "Hey Siri" (what opens the microphone on every sound).
    static var heySiriOn: Bool { UserDefaults(suiteName: "com.apple.Siri")?.bool(forKey: "VoiceTriggerUserEnabled") ?? false }

    /// CoreAudio tells us when the mute changes: no polling, nothing between changes.
    private func updateKeeper() {
        guard Self.keepMuted else {
            keeper?.stop()
            keeper = nil
            outputWatcher?.stop()
            outputWatcher = nil
            return
        }
        guard keeper == nil else { return }
        lastMuted = isMuted
        let watcher = MicrophoneWatcher { [weak self] in self?.microphoneChanged() }
        watcher.start()
        keeper = watcher
        let output = OutputWatcher { [weak self] in self?.outputStarted = Date() }
        output.start()
        outputWatcher = output
    }

    /// Something cleared the mute. Siri on its own clears it right after the Mac starts playing
    /// a sound (measured: 0.05 s after); when the user calls Siri, it clears it with nothing
    /// playing, and its answer starts after (0.13–0.17 s). So: cleared within half a second of a
    /// sound starting, not by Penknife, with nothing but Siri on the microphone → muted again at
    /// once. Called Siri listens as before, and puts the mute back itself when it ends (user,
    /// 2026-11-17: "quiero las dos cosas").
    private func microphoneChanged() {
        let muted = isMuted
        defer { lastMuted = isMuted }
        guard Self.shouldRemute(wasMuted: lastMuted, isMuted: muted, now: Date(), ownChangeUntil: ownChangeUntil,
                                outputStarted: outputStarted,
                                recorders: MeetingTracker.appsUsingMicrophone().map(\.bundleID)),
              let device = Self.defaultInputDevice() else { return }
        if Self.isSettable(device, kAudioDevicePropertyMute) {
            Self.set(device, kAudioDevicePropertyMute, UInt32(1))
        } else if Self.isSettable(device, kAudioDevicePropertyVolumeScalar) {
            Self.set(device, kAudioDevicePropertyVolumeScalar, Float32(0))
        }
        log.debug("Kept muted: the mute was cleared by someone else")
    }

    static let alsoMuteMacKey = "microphone.alsoMuteMac"
    /// On by default (user, 2026-11-16): a meeting app's own mute state can't be read (Teams'
    /// local API was retired in June 2026), so the Mac's microphone is muted too and the icon,
    /// which follows the Mac's microphone, matches the call.
    static var alsoMuteMac: Bool { UserDefaults.standard.object(forKey: alsoMuteMacKey) as? Bool ?? true }

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
    /// What a press does is decided by `route`, `afterSend` and `macGate` (tested).
    func toggle() {
        meetings.findCurrent { [weak self] target in
            guard let self else { return }
            let alsoMac = Self.alsoMuteMac
            let route = Self.route(meeting: target.map { ($0.platform, $0.isBrowser) },
                                   axGranted: Permissions.shared.ensureAccessibility(),
                                   alsoMac: alsoMac, teamsConsent: TeamsConsent.isEnabled)
            switch route {
            case .mac: self.toggleMac()
            case .nothing: break
            case .meeting(let how): if let target { self.press(target, how, alsoMac: alsoMac) }
            }
        }
    }

    private func press(_ target: MeetingTracker.Target, _ how: MeetingPress, alsoMac: Bool) {
        log.notice("Meeting: \(target.platform.rawValue, privacy: .public)")
        let macMuted = isMuted
        let send: @MainActor () -> Void = { [weak self] in self?.meetings.send(to: target) }
        let after: @MainActor (Bool?) -> Void = { [weak self] appMuted in
            guard let self else { return }
            switch Self.afterSend(alsoMac: alsoMac, appMuted: appMuted, macMuted: macMuted) {
            case .setMac(let muted):
                self.setMac(muted: muted)
            case .showToggled:
                HUD.shared.show(target.platform.name, detail: String(localized: "Microphone toggled"),
                                symbol: "mic.badge.xmark", kind: .on, category: .microphone)
            }
        }
        switch how {
        case .teamsConsent:
            // R-31: one Accessibility session reads the call, sends the shortcut and answers
            // the consent alert that an unmute opens.
            TeamsConsent.press(target.app, send: send, sent: after)
        case .readAndSend:
            meetings.readMuted(target) { appMuted in
                send()
                after(appMuted)
            }
        case .sendOnly:
            send()
            after(nil)
        }
    }

    private func toggleMac() {
        setMac(muted: Self.newMacMuted(appMuted: nil, macMuted: isMuted))
    }

    private func setMac(muted mute: Bool) {
        let device: AudioObjectID
        switch Self.macGate(siriListening: Self.isSiriListening, device: Self.defaultInputDevice()) {
        case .siriListening:
            log.notice("Toggle ignored: Siri is listening")
            return
        case .noDevice:
            HUD.shared.show(String(localized: "No microphone found"), symbol: "exclamationmark.triangle.fill", kind: .error, category: .microphone)
            return
        case .write(let input):
            device = input
        }
        log.notice("Toggle: \(mute ? "mute" : "unmute", privacy: .public), mute settable: \(Self.isSettable(device, kAudioDevicePropertyMute)), volume settable: \(Self.isSettable(device, kAudioDevicePropertyVolumeScalar))")
        // Our own change: "Keep the microphone muted" never undoes it.
        ownChangeUntil = Date().addingTimeInterval(1)

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

    // MARK: Press rules (S1: plain values in, decision out; PenknifeTests checks them)

    /// What a press does once the meeting search is done.
    enum PressRoute: Equatable {
        /// No call: the Mac's microphone toggles (MIC-03), without asking for Accessibility (MIC-07).
        case mac
        /// A call, but no Accessibility: only the system prompt, once per launch (MIC-36).
        case nothing
        case meeting(MeetingPress)
    }

    enum MeetingPress: Equatable {
        /// Teams desktop with "Remember my choice for Teams' unmute dialog" on (MIC-53).
        case teamsConsent
        /// Read the call's mic button, send the shortcut, the Mac follows the call (MIC-28).
        case readAndSend
        /// "Also mute the Mac's microphone" off: the shortcut alone (MIC-35).
        case sendOnly
    }

    /// `axGranted` is evaluated only when there is a call: the no-call press never prompts.
    static func route(meeting: (platform: MeetingPlatform, isBrowser: Bool)?, axGranted: @autoclosure () -> Bool,
                      alsoMac: Bool, teamsConsent: Bool) -> PressRoute {
        guard let meeting else { return .mac }
        guard axGranted() else { return .nothing }
        if teamsConsent, meeting.platform == .teams, !meeting.isBrowser { return .meeting(.teamsConsent) }
        return .meeting(alsoMac ? .readAndSend : .sendOnly)
    }

    /// What follows the meeting's shortcut: the Mac's microphone, or only the "toggled" alert (MIC-35).
    enum AfterSend: Equatable {
        case setMac(muted: Bool)
        case showToggled
    }

    static func afterSend(alsoMac: Bool, appMuted: Bool?, macMuted: Bool) -> AfterSend {
        alsoMac ? .setMac(muted: newMacMuted(appMuted: appMuted, macMuted: macMuted)) : .showToggled
    }

    /// Self-healing (R-28, MIC-29): every press leaves the call and the Mac equal. The CALL decides
    /// when its mic button can be read (user, 2026-11-17: Teams mutes everyone when a recording
    /// starts while the Mac stays open; deciding by the Mac made that press mute the Mac instead
    /// of unmuting the call). Unreadable button, or no call → the opposite of the Mac's microphone.
    static func newMacMuted(appMuted: Bool?, macMuted: Bool) -> Bool {
        appMuted.map { !$0 } ?? !macMuted
    }

    /// Whether a press may write the Mac's microphone, checked in this order.
    enum MacGate: Equatable {
        /// While Siri listens the mic is open whatever the mute says, and Siri puts back the state
        /// it found when it ends: a press then does nothing (user, 2026-11-16; MIC-39).
        case siriListening
        /// "No microphone found" (MIC-06).
        case noDevice
        case write(AudioObjectID)
    }

    static func macGate(siriListening: Bool, device: AudioObjectID?) -> MacGate {
        if siriListening { return .siriListening }
        guard let device else { return .noDevice }
        return .write(device)
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
    /// restores it (measured 2026-11-16). But Siri also records alongside ANY app using the
    /// microphone, for the whole call (measured 2026-11-16 with Meet in Chrome Dev and Safari),
    /// so it counts as listening only when nothing else records. Read only at the press.
    static var isSiriListening: Bool {
        isSiriListening(recorders: MeetingTracker.appsUsingMicrophone().map(\.bundleID))
    }

    /// S2 (tested): `recorders` = bundle IDs of the processes recording now.
    static func isSiriListening(recorders: [String]) -> Bool {
        recorders.contains(siriBundleID) && recorders.allSatisfy { $0 == siriBundleID }
    }

    /// S2 (tested): whether "Keep the microphone muted" puts the mute back (see `microphoneChanged`).
    /// `recorders` is read only when everything else holds (a CoreAudio query).
    static func shouldRemute(wasMuted: Bool, isMuted: Bool, now: Date, ownChangeUntil: Date, outputStarted: Date,
                             recorders: @autoclosure () -> [String]) -> Bool {
        guard wasMuted, !isMuted, now > ownChangeUntil, now.timeIntervalSince(outputStarted) < 0.5 else { return false }
        return recorders().allSatisfy { $0 == siriBundleID }
    }

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

/// Calls `onStart` when the default output device starts running (the Mac begins playing a
/// sound), following the default output when it changes. Listeners only: nothing between events.
final class OutputWatcher {
    private let onStart: () -> Void
    private var device: AudioObjectID?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var defaultListener: AudioObjectPropertyListenerBlock?

    private static let defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    private static let runningAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    init(onStart: @escaping () -> Void) {
        self.onStart = onStart
    }

    func start() {
        guard defaultListener == nil else { return }
        var address = Self.defaultOutputAddress
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.watchDevice() }
        }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        defaultListener = listener
        watchDevice()
    }

    func stop() {
        unwatchDevice()
        guard let defaultListener else { return }
        var address = Self.defaultOutputAddress
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, defaultListener)
        self.defaultListener = nil
    }

    private func watchDevice() {
        unwatchDevice()
        var address = Self.defaultOutputAddress
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, let device = self.device else { return }
                var address = Self.runningAddress
                var running: UInt32 = 0
                var size = UInt32(MemoryLayout<UInt32>.size)
                if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr, running != 0 { self.onStart() }
            }
        }
        var running = Self.runningAddress
        AudioObjectAddPropertyListenerBlock(device, &running, .main, listener)
        self.device = device
        deviceListener = listener
    }

    private func unwatchDevice() {
        guard let device, let deviceListener else { return }
        var address = Self.runningAddress
        AudioObjectRemovePropertyListenerBlock(device, &address, .main, deviceListener)
        self.device = nil
        self.deviceListener = nil
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

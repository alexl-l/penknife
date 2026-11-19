import AppKit
import CoreAudio
import os

/// The default input's two controls as the device rules read them (S4): CoreAudio in the app, a
/// plain struct in PenknifeTests. Each one is read only when a rule asks; nil = missing or unreadable.
protocol MicControls {
    var muteSettable: Bool { get }
    var volumeSettable: Bool { get }
    var mute: UInt32? { get }
    var volume: Float32? { get }
}

/// The real default input, read through CoreAudio at each access.
struct InputDevice: MicControls {
    let id: AudioObjectID
    var muteSettable: Bool { MicrophoneModule.isSettable(id, kAudioDevicePropertyMute) }
    var volumeSettable: Bool { MicrophoneModule.isSettable(id, kAudioDevicePropertyVolumeScalar) }
    var mute: UInt32? { MicrophoneModule.get(id, kAudioDevicePropertyMute) }
    var volume: Float32? { MicrophoneModule.get(id, kAudioDevicePropertyVolumeScalar) }
}

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
    /// B-2: tells when the user called Siri, who hears them with the mute left on.
    private var siri: SiriWatcher?
    /// Posted when what `showsMuted` says changes without the device changing (a Siri session).
    static let shownStateChanged = Notification.Name("PenknifeMicrophoneShownStateChanged")

    var actions: [ModuleAction] {
        [ModuleAction(shortcut: .toggleMicrophone, title: String(localized: "Mute Microphone"), symbol: "mic.slash",
                      state: { [weak self] in self?.showsMuted ?? false },
                      isAvailable: { [weak self] in self?.hasInput ?? true },
                      perform: { [weak self] in self?.toggle() })]
    }

    private let meetings = MeetingTracker()

    init() {
        // B-2: Siri's panel can be watched only with Accessibility.
        Permissions.shared.onChange.append { [weak self] in self?.siri?.attach() }
    }

    func start() {
        meetings.start()
        if siri == nil {
            let watcher = SiriWatcher { NotificationCenter.default.post(name: Self.shownStateChanged, object: nil) }
            watcher.start()
            siri = watcher
        }
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
        siri?.stop()
        siri = nil
    }

    /// For tests (R-15, MIC-80): whether the module still holds an observer or listener.
    var holdsObservers: Bool { keeper != nil || outputWatcher != nil || defaultsObserver != nil || siri != nil }

    // MARK: Keep muted (R-34)

    static let keepMutedKey = "microphone.keepMuted"
    /// On by default (designer + user, 2026-11-17): a mute that doesn't stay muted breaks the
    /// promise. With "Listen for Siri" on, every sound the Mac plays makes Siri clear the mute and
    /// listen ~5.5 s (measured 2026-11-17).
    static var keepMuted: Bool { keepMuted(in: .standard) }
    static func keepMuted(in defaults: UserDefaults) -> Bool { defaults.object(forKey: keepMutedKey) as? Bool ?? true }

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
        // MIC-48: the same control a press writes; the volume saved by the last press stays.
        Self.write(Self.writePlan(InputDevice(id: device), mute: true, savedVolume: savedVolume).write, to: device)
        log.debug("Kept muted: the mute was cleared by someone else")
    }

    static let alsoMuteMacKey = "microphone.alsoMuteMac"
    /// On by default (user, 2026-11-16): a meeting app's own mute state can't be read (Teams'
    /// local API was retired in June 2026), so the Mac's microphone is muted too and the icon,
    /// which follows the Mac's microphone, matches the call.
    static var alsoMuteMac: Bool { alsoMuteMac(in: .standard) }
    static func alsoMuteMac(in defaults: UserDefaults) -> Bool { defaults.object(forKey: alsoMuteMacKey) as? Bool ?? true }

    /// The REAL state of the device (user, 2026-11-16: the Touch Bar and the dot must show what
    /// the microphone is doing, never what Penknife thinks), read from the control a press writes (`readMuted`).
    var isMuted: Bool { Self.readMuted(Self.defaultInputDevice().map(InputDevice.init)) }

    /// What the Touch Bar button, the menu bar dot and the menu's checkmark show (TRUTHFUL, R-28):
    /// the device, and open while a called Siri hears the user (B-2). Presses decide by `isMuted`.
    var showsMuted: Bool { Self.shownMuted(deviceMuted: isMuted, siriHears: siri?.hears ?? false) }

    /// There is an input device to mute (O-1: without one the button and the menu item are dimmed).
    var hasInput: Bool { Self.defaultInputDevice() != nil }

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
            case .nothing: HUD.shared.showPermissionNeeded(.microphone) // O-3, MIC-36
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
            HUD.shared.show(String(localized: "No microphone"), detail: String(localized: "Connect one to mute it"),
                            symbol: "mic.slash", kind: .error, category: .microphone)
            return
        case .write(let input):
            device = input
        }
        let input = InputDevice(id: device)
        log.notice("Toggle: \(mute ? "mute" : "unmute", privacy: .public), mute settable: \(input.muteSettable), volume settable: \(input.volumeSettable)")
        // Our own change: "Keep the microphone muted" never undoes it.
        ownChangeUntil = Date().addingTimeInterval(1)

        let plan = Self.writePlan(input, mute: mute, savedVolume: savedVolume)
        savedVolume = plan.savedVolume
        Self.write(plan.write, to: device)

        // O-2: never claim a change that wasn't made.
        if plan.write == .nothing {
            HUD.shared.show(String(localized: "This microphone can't be muted"),
                            symbol: "exclamationmark.triangle.fill", kind: .error, category: .microphone)
            return
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

    // MARK: Device rules (S4: a press writes the control the icon reads; PenknifeTests checks them)

    /// MIC-64 (D: Mic state bug): a settable mute → the mute; else the input volume (0 = muted);
    /// else a read-only mute; else open. Some devices report a mute nobody can set: reading it
    /// made every press mute again. No input device → open (open decision O-1).
    static func readMuted(_ input: (some MicControls)?) -> Bool {
        guard let input else { return false }
        if input.muteSettable, let mute = input.mute { return mute != 0 }
        if let volume = input.volume { return volume == 0 }
        if let mute = input.mute { return mute != 0 }
        return false
    }

    /// What a write to the Mac's microphone changes.
    enum MicWrite: Equatable {
        case mute(UInt32)
        case volume(Float32)
        /// The input volume is already as asked (B-4).
        case unchanged
        /// Neither control can be set: nothing is written, and the alert says so (O-2).
        case nothing
    }

    /// MIC-04: a settable mute → the mute; else a settable input volume: muting remembers the
    /// volume and writes 0, unmuting writes the remembered volume, or 1.0 if none (after a
    /// relaunch). An input volume already as asked is left alone (B-4: a call press makes the Mac
    /// follow the call even when it already matches; muting an input at 0 remembered 0, and the
    /// next unmute left it muted). Returns the volume to remember from then on.
    static func writePlan(_ input: some MicControls, mute: Bool,
                          savedVolume: Float32?) -> (write: MicWrite, savedVolume: Float32?) {
        if input.muteSettable { return (.mute(mute ? 1 : 0), savedVolume) }
        guard input.volumeSettable else { return (.nothing, savedVolume) }
        let volume = input.volume
        if mute {
            return volume == 0 ? (.unchanged, savedVolume) : (.volume(0), volume ?? savedVolume)
        }
        if let volume, volume > 0 { return (.unchanged, savedVolume) }
        return (.volume(savedVolume ?? 1), savedVolume)
    }

    // MARK: Recording with the microphone (REC-27, user 2026-11-19)

    /// What to write so a recording with the microphone hears the user: a muted Mac microphone
    /// records silence. nil = already open, or it can't be unmuted.
    static func unmuteForRecording(_ input: some MicControls) -> MicWrite? {
        guard readMuted(input) else { return nil }
        let write = writePlan(input, mute: false, savedVolume: nil).write
        return write == .nothing || write == .unchanged ? nil : write
    }

    /// The device Penknife unmuted for the running recording; muted again when it ends.
    private(set) static var unmutedForRecording: AudioObjectID?

    /// The recording's microphone switch is on: open the Mac's microphone if it is muted,
    /// with the usual alert. Never touched when the switch is off.
    static func openForRecording() {
        guard unmutedForRecording == nil, let device = defaultInputDevice(),
              let write = unmuteForRecording(InputDevice(id: device)) else { return }
        Self.write(write, to: device)
        unmutedForRecording = device
        HUD.shared.show(String(localized: "Microphone unmuted"), symbol: "mic.fill", kind: .on, category: .microphone)
    }

    /// The switch went off or the recording ended: mute again only what Penknife opened, and
    /// only if it is still the default input.
    static func closeAfterRecording() {
        guard let device = unmutedForRecording else { return }
        unmutedForRecording = nil
        guard defaultInputDevice() == device else { return }
        let input = InputDevice(id: device)
        guard !readMuted(input) else { return }
        Self.write(writePlan(input, mute: true, savedVolume: nil).write, to: device)
        HUD.shared.show(String(localized: "Microphone muted"), symbol: "mic.slash.fill", kind: .off, category: .microphone)
    }

    static func write(_ write: MicWrite, to device: AudioObjectID) {
        switch write {
        case .mute(let value): set(device, kAudioDevicePropertyMute, value)
        case .volume(let value): set(device, kAudioDevicePropertyVolumeScalar, value)
        case .unchanged, .nothing: break
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

    /// B-2 (tested): Siri hears the user while its panel is on screen and it records. A sound the
    /// Mac plays makes Siri record but never shows the panel (R-34: stays muted); "Type to Siri"
    /// shows the panel without recording.
    static func siriHears(panelShown: Bool, recorders: [String]) -> Bool {
        panelShown && recorders.contains(siriBundleID)
    }

    static func shownMuted(deviceMuted: Bool, siriHears: Bool) -> Bool {
        deviceMuted && !siriHears
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

/// B-2: tells when Siri hears the user. A called Siri listens with the mute left on (measured
/// 2026-11-18), and CoreAudio announces nothing that tells it apart (with music, Siri records all
/// the time). Its panel is announced: macOS 26 draws it in Notification Center as an element
/// identified "SiriWindow" (a notification banner is another element), and Accessibility reports
/// windows created and destroyed there. Bursts collapse into one look 0.15 s after the last one.
/// Nothing runs between those announcements.
final class SiriWatcher {
    private let onChange: () -> Void
    private(set) var hears = false
    private var panelShown = false
    private let log = Logger(subsystem: "Penknife", category: "Microphone")
    private var observer: AXObserver?
    private var observed: AXUIElement?
    private var observedPID: pid_t?
    /// Drops a look that finished after a newer one started.
    private var generation = 0
    private var launchObserver: NSObjectProtocol?
    private var pendingCheck: DispatchWorkItem?

    nonisolated private static let bundleID = "com.apple.notificationcenterui"
    private static let notifications = [kAXWindowCreatedNotification, kAXUIElementDestroyedNotification]

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    func start() {
        guard launchObserver == nil else { return }
        // Notification Center restarted (rare): watch the new one.
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == Self.bundleID else { return }
            MainActor.assumeIsolated { self?.attach() }
        }
        attach()
    }

    func stop() {
        if let launchObserver { NSWorkspace.shared.notificationCenter.removeObserver(launchObserver) }
        launchObserver = nil
        detach()
        pendingCheck?.cancel()
        pendingCheck = nil
        hears = false
    }

    /// Also called when Accessibility is granted.
    func attach() {
        guard launchObserver != nil else { return }
        detach()
        guard AXIsProcessTrusted(),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first else { return }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.2)
        var newObserver: AXObserver?
        guard AXObserverCreate(app.processIdentifier, Self.callback, &newObserver) == .success, let newObserver else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in Self.notifications {
            AXObserverAddNotification(newObserver, element, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(newObserver), .defaultMode)
        observer = newObserver
        observed = element
        observedPID = app.processIdentifier
        scheduleCheck()
    }

    private func detach() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
            if let observed {
                for name in Self.notifications {
                    AXObserverRemoveNotification(observer, observed, name as CFString)
                }
            }
        }
        observer = nil
        observed = nil
        observedPID = nil
    }

    private static let callback: AXObserverCallback = { _, _, _, refcon in
        guard let refcon else { return }
        let watcher = Unmanaged<SiriWatcher>.fromOpaque(refcon).takeUnretainedValue()
        MainActor.assumeIsolated { watcher.scheduleCheck() }
    }

    private func scheduleCheck() {
        pendingCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.check() } }
        pendingCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// The look runs off the main thread (MIC-79): a hung Notification Center can't freeze Penknife.
    private func check() {
        guard let pid = observedPID else { return }
        generation += 1
        let mine = generation
        let apply: @MainActor @Sendable (Bool) -> Void = { [weak self] shown in self?.apply(shown: shown, generation: mine) }
        DispatchQueue.global(qos: .userInitiated).async {
            let shown = Self.siriPanelShown(pid: pid)
            DispatchQueue.main.async { apply(shown) }
        }
    }

    private func apply(shown: Bool, generation: Int) {
        guard generation == self.generation, observed != nil else { return }
        let next = MicrophoneModule.siriHears(panelShown: shown,
                                              recorders: shown ? MeetingTracker.appsUsingMicrophone().map(\.bundleID) : [])
        if shown != panelShown || next != hears {
            log.debug("Siri panel: \(shown ? "shown" : "gone", privacy: .public), hears you: \(next)")
        }
        panelShown = shown
        guard next != hears else { return }
        hears = next
        onChange()
    }

    /// Looks for Siri's panel among Notification Center's windows: identifiers only, breadth-first,
    /// at most 6 levels and 300 elements, 0.2 s per element, 0.5 s in all.
    nonisolated private static func siriPanelShown(pid: pid_t) -> Bool {
        let deadline = Date().addingTimeInterval(0.5)
        func children(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return [] }
            return value as? [AXUIElement] ?? []
        }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var level = children(app, kAXWindowsAttribute)
        var seen = 0
        for _ in 0..<6 where !level.isEmpty {
            var next: [AXUIElement] = []
            for element in level {
                seen += 1
                guard seen <= 300, Date() < deadline else { return false }
                AXUIElementSetMessagingTimeout(element, 0.2)
                var identifier: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXIdentifierAttribute as CFString, &identifier) == .success,
                   identifier as? String == "SiriWindow" { return true }
                next += children(element, kAXChildrenAttribute)
            }
            level = next
        }
        return false
    }
}

/// Calls `onChange` when the default input is muted or unmuted from anywhere (Penknife, Teams,
/// Control Center) or when the default input device changes. CoreAudio listeners cost nothing
/// between changes. Used by the Touch Bar button and the menu bar dot, which with `followsSiri`
/// also hear when a called Siri session starts or ends (B-2).
final class MicrophoneWatcher {
    private let onChange: () -> Void
    private let followsSiri: Bool
    private var device: AudioObjectID?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var defaultListener: AudioObjectPropertyListenerBlock?
    private var siriObserver: NSObjectProtocol?

    init(followsSiri: Bool = false, onChange: @escaping () -> Void) {
        self.followsSiri = followsSiri
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
        if followsSiri {
            siriObserver = NotificationCenter.default.addObserver(forName: MicrophoneModule.shownStateChanged, object: nil,
                                                                  queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onChange() }
            }
        }
    }

    func stop() {
        unwatchDevice()
        if let siriObserver { NotificationCenter.default.removeObserver(siriObserver) }
        siriObserver = nil
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

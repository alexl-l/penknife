import AppKit
import CoreAudio
import os

/// Microphone toggle (R-3): mutes the default input device and keeps Microsoft Teams and
/// Google Meet (Chrome) in the same state. Nothing runs between presses.
final class MicrophoneModule: Module {
    let id = ModuleID.microphone
    var needsAccessibility: Bool { true }

    private let log = Logger(subsystem: "Penknife", category: "Microphone")
    /// Input volume before muting, for devices without a mute control.
    private var savedVolume: Float32?

    var actions: [ModuleAction] {
        [ModuleAction(shortcut: .toggleMicrophone, title: String(localized: "Mute microphone"), symbol: "mic.slash",
                      state: { [weak self] in self?.isMuted ?? false },
                      perform: { [weak self] in self?.toggle() })]
    }

    func start() {}
    func stop() {}

    var isMuted: Bool {
        guard let device = Self.defaultInputDevice() else { return false }
        if let mute: UInt32 = Self.get(device, kAudioDevicePropertyMute) { return mute != 0 }
        if let volume: Float32 = Self.get(device, kAudioDevicePropertyVolumeScalar) { return volume == 0 }
        return false
    }

    func toggle() {
        guard let device = Self.defaultInputDevice() else {
            HUD.shared.show(String(localized: "No microphone found"))
            return
        }
        let mute = !isMuted

        syncTeams()
        syncMeet(muted: mute)

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

        HUD.shared.show(mute ? String(localized: "Microphone muted") : String(localized: "Microphone unmuted"))
    }

    // MARK: Apps

    /// Teams mute shortcut as used before (⌘⇧Ñ, or ⌘⇧M if the layout has no Ñ), sent straight
    /// to its process so it works in the background.
    private func syncTeams() {
        guard let teams = NSRunningApplication.runningApplications(withBundleIdentifier: "com.microsoft.teams2").first
                ?? NSRunningApplication.runningApplications(withBundleIdentifier: "com.microsoft.teams").first,
              Permissions.shared.ensureAccessibility() else { return }
        let keyCode = EventPoster.keyCode(for: "ñ") ?? EventPoster.keyCode(for: "m") ?? 46
        EventPoster.key(keyCode, flags: [.maskCommand, .maskShift], toPid: teams.processIdentifier)
    }

    /// Clicks Meet's microphone button in Chrome only if its state differs. Requires Chrome's
    /// View → Developer → Allow JavaScript from Apple Events. Never launches Chrome.
    private func syncMeet(muted: Bool) {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").isEmpty else { return }
        let source = """
        tell application id "com.google.Chrome"
          set meetTab to missing value
          repeat with w in windows
            repeat with t in tabs of w
              if (URL of t starts with "https://meet.google.com/") then
                set meetTab to t
                exit repeat
              end if
            end repeat
            if meetTab is not missing value then exit repeat
          end repeat
          if meetTab is missing value then return "MEET_NOT_FOUND"
          return execute meetTab javascript "(() => { const b = Array.from(document.querySelectorAll('button')).find(b => (b.getAttribute('aria-label') || '').toLowerCase().includes('microphone')); if (!b) return 'BUTTON_NOT_FOUND'; const m = b.getAttribute('aria-label') === 'Turn on microphone'; if (m !== \(muted)) b.click(); return 'OK'; })()"
        end tell
        """
        let log = log
        // AppleScript can take a moment; keep it off the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue
            if let error {
                log.error("Meet: \(error, privacy: .public)")
            } else if let result, result != "OK", result != "MEET_NOT_FOUND" {
                log.info("Meet: \(result, privacy: .public)")
            }
        }
    }

    // MARK: CoreAudio

    private static func address(_ selector: AudioObjectPropertySelector, _ object: AudioObjectID? = nil) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: object == nil ? kAudioObjectPropertyScopeGlobal : kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
    }

    static func defaultInputDevice() -> AudioObjectID? {
        var address = address(kAudioHardwarePropertyDefaultInputDevice)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    private static func get<T: BitwiseCopyable>(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        var address = address(selector, device)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer) == noErr else { return nil }
        return pointer.pointee
    }

    private static func isSettable(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
        var address = address(selector, device)
        var settable: DarwinBoolean = false
        return AudioObjectHasProperty(device, &address)
            && AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    private static func set<T: BitwiseCopyable>(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: T) {
        var address = address(selector, device)
        var value = value
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<T>.size), &value)
    }
}

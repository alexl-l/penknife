import AppKit
import AudioToolbox
import CoreAudio

/// Something with a 0…1 level the Touch Bar sliders drive.
protocol LevelControl {
    var level: Float? { get }
    func setLevel(_ value: Float)
}

extension LevelControl {
    /// What a slider sets is kept within 0…1 (TB-32).
    static func clamped(_ value: Float) -> Float { min(max(value, 0), 1) }
}

/// Built-in display brightness via private DisplayServices: on Apple silicon there is no public
/// call that sets the panel's brightness (only simulated brightness keys, in steps).
struct DisplayBrightness: LevelControl {
    private typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias Set = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let calls: (get: Get, set: Set)? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
              let get = dlsym(handle, "DisplayServicesGetBrightness"),
              let set = dlsym(handle, "DisplayServicesSetBrightness") else { return nil }
        return (unsafeBitCast(get, to: Get.self), unsafeBitCast(set, to: Set.self))
    }()

    /// The built-in panel (the one the Touch Bar belongs to), else the main display.
    static var display: CGDirectDisplayID {
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        var count: UInt32 = 0
        if CGGetOnlineDisplayList(8, &ids, &count) == .success,
           let builtin = ids.prefix(Int(count)).first(where: { CGDisplayIsBuiltin($0) != 0 }) {
            return builtin
        }
        return CGMainDisplayID()
    }

    var level: Float? {
        guard let calls = Self.calls else { return nil }
        var value: Float = 0
        return calls.get(Self.display, &value) == 0 ? value : nil
    }

    func setLevel(_ value: Float) {
        _ = Self.calls?.set(Self.display, Self.clamped(value))
    }
}

/// Keyboard backlight via private CoreBrightness `KeyboardBrightnessClient`.
struct KeyboardBrightness: LevelControl {
    private typealias CopyIDs = @convention(c) (AnyObject, Selector) -> NSArray?
    private typealias Get = @convention(c) (AnyObject, Selector, UInt64) -> Float
    private typealias Set = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool
    private typealias SetAuto = @convention(c) (AnyObject, Selector, Bool, UInt64) -> Bool

    private struct Client {
        let object: NSObject
        let keyboard: UInt64
        let get: Get
        let set: Set
        let setAuto: SetAuto?
    }

    private static let getSelector = NSSelectorFromString("brightnessForKeyboard:")
    private static let setSelector = NSSelectorFromString("setBrightness:forKeyboard:")
    private static let autoSelector = NSSelectorFromString("enableAutoBrightness:forKeyboard:")

    /// Auto-brightness is turned off on the first manual change of each slider session.
    nonisolated(unsafe) static var autoTurnedOff = false

    private static let client: Client? = {
        guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY) != nil,
              let type = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else { return nil }
        let object = type.init()
        let idsSelector = NSSelectorFromString("copyKeyboardBacklightIDs")
        guard object.responds(to: idsSelector), object.responds(to: getSelector), object.responds(to: setSelector) else { return nil }
        let ids = unsafeBitCast(object.method(for: idsSelector), to: CopyIDs.self)(object, idsSelector)
        let setAuto = object.responds(to: autoSelector)
            ? unsafeBitCast(object.method(for: autoSelector), to: SetAuto.self) : nil
        return Client(object: object,
                      keyboard: (ids?.firstObject as? NSNumber)?.uint64Value ?? 1,
                      get: unsafeBitCast(object.method(for: getSelector), to: Get.self),
                      set: unsafeBitCast(object.method(for: setSelector), to: Set.self),
                      setAuto: setAuto)
    }()

    /// The client object and keyboard id, for `KeyboardLightWatcher`.
    static var clientAndKeyboard: (NSObject, UInt64)? {
        client.map { ($0.object, $0.keyboard) }
    }

    var level: Float? {
        guard let client = Self.client else { return nil }
        return client.get(client.object, Self.getSelector, client.keyboard)
    }

    func setLevel(_ value: Float) {
        guard let client = Self.client else { return }
        // With "Adjust keyboard brightness in low light" on, a bright room keeps the light off
        // and ignores manual changes, so a manual change turns that option off.
        if !Self.autoTurnedOff {
            _ = client.setAuto?(client.object, Self.autoSelector, false, client.keyboard)
            Self.autoTurnedOff = true
        }
        _ = client.set(client.object, Self.setSelector, Self.clamped(value), client.keyboard)
    }
}

/// Output volume of the default output device (public CoreAudio).
struct OutputVolume: LevelControl {
    static var device: AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != 0 ? device : nil
    }

    private static var volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)

    private static var muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)

    var level: Float? {
        guard let device = Self.device else { return nil }
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = Self.volumeAddress
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    var isMuted: Bool {
        guard let device = Self.device else { return false }
        var mute = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = Self.muteAddress
        guard AudioObjectHasProperty(device, &address) else { return false }
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &mute) == noErr && mute != 0
    }

    /// Like the volume keys: sliding to zero mutes, sliding up unmutes (TB-32).
    static func mute(for volume: Float) -> UInt32 { volume == 0 ? 1 : 0 }

    func setLevel(_ value: Float) {
        guard let device = Self.device else { return }
        var volume = Float32(Self.clamped(value))
        var address = Self.volumeAddress
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &volume)
        var mute = Self.mute(for: volume)
        var muteAddress = Self.muteAddress
        if AudioObjectHasProperty(device, &muteAddress) {
            AudioObjectSetPropertyData(device, &muteAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &mute)
        }
    }
}

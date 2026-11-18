import Carbon.HIToolbox
import KeyboardShortcuts

/// F keys pressed on the Touch Bar (or with Fn) arrive with the Fn modifier, which
/// KeyboardShortcuts drops, so a plain "F12" shortcut never fires from there. For every
/// shortcut that is a bare F key, this registers the same key + Fn as a twin hotkey.
/// Carbon hotkeys cost nothing until pressed.
final class FnHotKeys {
    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var handler: EventHandlerRef?
    private var nextID: UInt32 = 0

    private static let signature: OSType = 0x506B_466E // "PkFn"
    private static let functionKeys: Set<Int> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    /// TB-58: only a bare F key (F1–F20, no modifiers) gets an Fn twin.
    static func needsTwin(carbonKeyCode: Int, carbonModifiers: Int) -> Bool {
        carbonModifiers == 0 && functionKeys.contains(carbonKeyCode)
    }

    /// Replaces all twins with the given shortcuts' current values.
    func set(_ entries: [(name: KeyboardShortcuts.Name, action: () -> Void)]) {
        removeAll()
        for entry in entries {
            guard let shortcut = KeyboardShortcuts.getShortcut(for: entry.name),
                  Self.needsTwin(carbonKeyCode: shortcut.carbonKeyCode, carbonModifiers: shortcut.carbonModifiers) else { continue }
            installHandlerIfNeeded()
            nextID += 1
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(shortcut.carbonKeyCode), UInt32(kEventKeyModifierFnMask),
                EventHotKeyID(signature: Self.signature, id: nextID), GetEventDispatcherTarget(), 0, &ref)
            if status == noErr, let ref {
                refs.append(ref)
                actions[nextID] = entry.action
            }
        }
    }

    func removeAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        actions = [:]
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == FnHotKeys.signature else { return OSStatus(eventNotHandledErr) }
            let me = Unmanaged<FnHotKeys>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { me.actions[id.id]?() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
}

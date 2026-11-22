import AppKit
import Carbon.HIToolbox

/// Synthetic keyboard and mouse events. Needs the Accessibility permission.
enum EventPoster {
    /// Stamped on every key Penknife posts, so its own watchers (a running macro's Esc) can tell
    /// them from the user's.
    static let marker: Int64 = 0x504B_4E46

    static func isOurs(_ event: NSEvent) -> Bool {
        event.cgEvent?.getIntegerValueField(.eventSourceUserData) == marker
    }

    static func key(_ keyCode: CGKeyCode, flags: CGEventFlags = [], toPid pid: pid_t? = nil) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down) else { continue }
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: marker)
            if let pid {
                event.postToPid(pid)
            } else {
                event.post(tap: .cghidEventTap)
            }
        }
    }

    static func moveMouse(to point: CGPoint) {
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    /// Types text as key presses (for fields that block paste), a few characters per event.
    static func type(_ text: String) {
        let units = Array(text.utf16)
        var index = 0
        while index < units.count {
            var end = min(index + 16, units.count)
            // Never split a surrogate pair (emoji) between two events.
            if end < units.count, UTF16.isLeadSurrogate(units[end - 1]) { end -= 1 }
            let chunk = Array(units[index..<end])
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else { continue }
                event.flags = []
                event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                event.setIntegerValueField(.eventSourceUserData, value: marker)
                event.post(tap: .cghidEventTap)
            }
            index = end
        }
    }

    static var mouseLocation: CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    /// Key code that types `character` in the current keyboard layout (e.g. "ñ" on a Spanish layout).
    static func keyCode(for character: String) -> CGKeyCode? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> CGKeyCode? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            for code in 0..<128 {
                var deadKeys: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                                            OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
                if status == noErr, length > 0, String(utf16CodeUnits: chars, count: length) == character {
                    return CGKeyCode(code)
                }
            }
            return nil
        }
    }
}

extension EventPoster {
    /// Media keys (NX_KEYTYPE_*), as the keyboard sends them; they reach the app playing now.
    enum MediaKey: Int { case play = 16, next = 17, previous = 18 }

    static func media(_ key: MediaKey) {
        for down in [true, false] {
            let flags = down ? 0xA00 : 0xB00
            NSEvent.otherEvent(with: .systemDefined, location: .zero,
                               modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags)),
                               timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                               data1: key.rawValue << 16 | flags, data2: -1)?
                .cgEvent?.post(tap: .cghidEventTap)
        }
    }
}

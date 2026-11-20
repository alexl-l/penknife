import AppKit
import KeyboardShortcuts
import Observation

/// What the user last chose for recordings (R-29): remembered between recordings.
enum RecordingPrefs {
    static let micKey = "recording.microphone"
    static let soundKey = "recording.macSound"
    static let fadeKey = "recording.fade"
    /// Seconds a drawing stays before it fades; 0 = it stays until erased.
    static let fades: [Double] = [0, 1, 3, 5, 10]

    static var microphone: Bool {
        get { microphone(in: .standard) }
        set { UserDefaults.standard.set(newValue, forKey: micKey) }
    }

    static func microphone(in defaults: UserDefaults) -> Bool { defaults.bool(forKey: micKey) }

    static var macSound: Bool {
        get { UserDefaults.standard.bool(forKey: soundKey) }
        set { UserDefaults.standard.set(newValue, forKey: soundKey) }
    }

    static var fade: Double {
        get {
            let value = UserDefaults.standard.object(forKey: fadeKey) as? Double ?? 5
            return fades.contains(value) ? value : 5
        }
        set { UserDefaults.standard.set(newValue, forKey: fadeKey) }
    }

    /// "⌃⌥R" style text of a shortcut, for tooltips; empty when it has none.
    static func keys(_ name: KeyboardShortcuts.Name) -> String {
        KeyboardShortcuts.getShortcut(for: name)?.description ?? ""
    }
}

/// State of one recording, shared by its toolbar, its drawing layer and the session.
@Observable
final class RecordingState {
    var countdown = 3
    var elapsed = 0
    var paused = false
    var drawing = false
    /// nil = Edit with no tool: clicks select and move the drawings (REC-16, user's pick A).
    var tool: CaptureTool?
    var colorIndex = CapturePalette.defaultIndex
    var sizeIndex = CaptureSize.defaultIndex
    /// Which choice row (colors or sizes) is open in the capsule.
    var expanded: StyleRow?
    var fade = RecordingPrefs.fade
    var microphone = false
    var macSound = false

    var color: NSColor { CapturePalette.colors[colorIndex] }
    var time: String { Self.time(elapsed) }

    /// "0:05", "12:40", "1:02:03".
    static func time(_ seconds: Int) -> String {
        let hours = seconds / 3600, minutes = seconds / 60 % 60, rest = seconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }

    /// Drawing tools while recording: the same as the screenshot's (blur is applied to every frame).
    static let tools = CaptureTool.allCases
}

enum RecordingCommand: Equatable {
    case stop, pause, pointer, tool(CaptureTool), toggle(StyleRow), color(Int), size(Int), fade(Double), microphone, macSound, erase
}

/// What the menu bar icon shows while recording (R-29): the session sets it, StatusMenu follows it.
@Observable
final class RecordingIndicator {
    static let shared = RecordingIndicator()

    /// Elapsed time while recording; nil when not recording.
    private(set) var time: String?
    private(set) var paused = false
    @ObservationIgnored private var stopAction: (() -> Void)?

    func show(time: String, paused: Bool, stop: @escaping () -> Void) {
        if self.time != time { self.time = time }
        if self.paused != paused { self.paused = paused }
        stopAction = stop
    }

    func hide() {
        time = nil
        paused = false
        stopAction = nil
    }

    func stop() { stopAction?() }
}

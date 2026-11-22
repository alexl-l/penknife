import AppKit
import Carbon.HIToolbox
import Observation

/// One key press of a macro (R-35): a key code and its modifiers (⌘A, Tab, Return…).
struct MacroKey: Codable, Equatable, Hashable {
    var code: Int
    /// `NSEvent.ModifierFlags` raw value, device-independent part only.
    var modifiers: UInt = 0

    static let tab = MacroKey(code: kVK_Tab)
    static let returnKey = MacroKey(code: kVK_Return)
    static let escape = MacroKey(code: kVK_Escape)
    static let up = MacroKey(code: kVK_UpArrow)
    static let down = MacroKey(code: kVK_DownArrow)
    static let left = MacroKey(code: kVK_LeftArrow)
    static let right = MacroKey(code: kVK_RightArrow)
    static let space = MacroKey(code: kVK_Space)
    /// The keys offered without recording, in the editor's menu.
    static let common: [MacroKey] = [.tab, .returnKey, .escape, .up, .down, .left, .right, .space]

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers).intersection([.command, .option, .control, .shift]) }

    var cgFlags: CGEventFlags {
        var result: CGEventFlags = []
        if flags.contains(.command) { result.insert(.maskCommand) }
        if flags.contains(.option) { result.insert(.maskAlternate) }
        if flags.contains(.control) { result.insert(.maskControl) }
        if flags.contains(.shift) { result.insert(.maskShift) }
        return result
    }

    private static let names: [Int: (symbol: String, name: String)] = [
        kVK_Tab: ("⇥", "Tab"), kVK_Return: ("↩", "Return"), kVK_ANSI_KeypadEnter: ("⌤", "Enter"),
        kVK_Escape: ("⎋", "Esc"), kVK_Space: ("␣", String(localized: "Space")),
        kVK_Delete: ("⌫", String(localized: "Delete")), kVK_ForwardDelete: ("⌦", String(localized: "Forward Delete")),
        kVK_UpArrow: ("↑", String(localized: "Up Arrow")), kVK_DownArrow: ("↓", String(localized: "Down Arrow")),
        kVK_LeftArrow: ("←", String(localized: "Left Arrow")), kVK_RightArrow: ("→", String(localized: "Right Arrow")),
        kVK_Home: ("↖", String(localized: "Home")), kVK_End: ("↘", String(localized: "End")),
        kVK_PageUp: ("⇞", String(localized: "Page Up")), kVK_PageDown: ("⇟", String(localized: "Page Down")),
        kVK_F1: ("F1", "F1"), kVK_F2: ("F2", "F2"), kVK_F3: ("F3", "F3"), kVK_F4: ("F4", "F4"), kVK_F5: ("F5", "F5"),
        kVK_F6: ("F6", "F6"), kVK_F7: ("F7", "F7"), kVK_F8: ("F8", "F8"), kVK_F9: ("F9", "F9"), kVK_F10: ("F10", "F10"),
        kVK_F11: ("F11", "F11"), kVK_F12: ("F12", "F12"),
    ]

    private var modifierSymbols: String {
        (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "")
            + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "")
    }

    /// As on a key cap: "⇥", "↩", "⌘A".
    var symbol: String { modifierSymbols + (Self.names[code]?.symbol ?? Self.character(code)) }

    /// Spoken and shown beside the cap: "Tab", "Return", "⌘A".
    var name: String {
        if let named = Self.names[code] { return modifierSymbols + named.name }
        return modifierSymbols + Self.character(code)
    }

    /// The character the key types on the current layout, uppercased ("A", "Ñ").
    private static func character(_ code: Int) -> String {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "?" }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> String in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return "?" }
            var deadKeys: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
            guard status == noErr, length > 0 else { return "?" }
            return String(utf16CodeUnits: chars, count: length).uppercased()
        }
    }
}

/// One step of a macro (R-35).
struct MacroStep: Identifiable, Codable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case text, key, wait, waitForMe, file, pinned
    }

    /// File step: paste the file itself, or type its path (⌘⇧G in Open dialogs).
    enum FileMode: String, Codable { case paste, path }

    var id = UUID()
    var kind: Kind
    /// Text to type (with variables) for `.text`.
    var text = ""
    var key: MacroKey?
    /// Milliseconds for `.wait`.
    var milliseconds = 300
    var file: URL?
    var fileMode = FileMode.paste
    /// `.pinned`: the clipboard pin it follows, and the last value used (plan B prefill).
    var pin: UUID?
    var lastValue: String?

    static func text(_ text: String) -> MacroStep { MacroStep(kind: .text, text: text) }
    static func key(_ key: MacroKey) -> MacroStep { MacroStep(kind: .key, key: key) }
    static func wait(_ ms: Int) -> MacroStep { MacroStep(kind: .wait, milliseconds: ms) }

    init(kind: Kind, text: String = "", key: MacroKey? = nil, milliseconds: Int = 300) {
        self.kind = kind
        self.text = text
        self.key = key ?? (kind == .key ? .tab : nil)
        self.milliseconds = milliseconds
    }

    /// Fields added later never make a saved macro unreadable.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try values.decode(Kind.self, forKey: .kind)
        text = try values.decodeIfPresent(String.self, forKey: .text) ?? ""
        key = try values.decodeIfPresent(MacroKey.self, forKey: .key)
        milliseconds = try values.decodeIfPresent(Int.self, forKey: .milliseconds) ?? 300
        file = try values.decodeIfPresent(URL.self, forKey: .file)
        fileMode = try values.decodeIfPresent(FileMode.self, forKey: .fileMode) ?? .paste
        pin = try values.decodeIfPresent(UUID.self, forKey: .pin)
        lastValue = try values.decodeIfPresent(String.self, forKey: .lastValue)
    }

    /// A copy with a new id (Duplicate).
    var duplicate: MacroStep {
        var copy = self
        copy.id = UUID()
        return copy
    }
}

extension MacroStep.Kind {
    var title: String {
        switch self {
        case .text: String(localized: "Type Text")
        case .key: String(localized: "Key")
        case .wait: String(localized: "Wait")
        case .waitForMe: String(localized: "Wait for Me")
        case .file: String(localized: "File")
        case .pinned: String(localized: "Pinned Item")
        }
    }

    var symbol: String {
        switch self {
        case .text: "text.cursor"
        case .key: "keyboard"
        case .wait: "timer"
        case .waitForMe: "hand.raised"
        case .file: "doc"
        case .pinned: "pin"
        }
    }
}

/// A table pasted into a macro (R-35 "data rows"): the first line names the columns, each run
/// uses the next row.
struct MacroData: Codable, Equatable {
    var columns: [String] = []
    var rows: [[String]] = []
    /// 0-based row the next run uses.
    var next = 0
    /// After the last row: start again at row 1 (on) or don't run and say so (off).
    var repeats = true
    /// The text as pasted, so the editor shows it back as it was.
    var source = ""

    var isEmpty: Bool { columns.isEmpty || rows.isEmpty }

    /// Tabs (spreadsheets), else semicolons, else commas separate the columns.
    static func parse(_ text: String) -> (columns: [String], rows: [[String]]) {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let first = lines.first else { return ([], []) }
        let separator: Character = first.contains("\t") ? "\t" : first.contains(";") ? ";" : ","
        func cells(_ line: String) -> [String] {
            line.split(separator: separator, omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
        }
        let columns = cells(first)
        let rows = lines.dropFirst().map { line in
            let values = cells(line)
            return columns.indices.map { $0 < values.count ? values[$0] : "" }
        }
        return (columns, rows)
    }

    mutating func update(from text: String) {
        source = text
        let parsed = Self.parse(text)
        if parsed.columns != columns || parsed.rows.count != rows.count { next = 0 }
        columns = parsed.columns
        rows = parsed.rows
    }

    /// The row this run uses, or nil when the rows ran out and don't repeat.
    func rowForRun() -> (index: Int, values: [String: String])? {
        guard !isEmpty else { return (0, [:]) }
        var index = next
        if index >= rows.count {
            guard repeats else { return nil }
            index = 0
        }
        var values: [String: String] = [:]
        for (column, name) in columns.enumerated() where !name.isEmpty {
            values[name.lowercased()] = rows[index][column]
        }
        return (index, values)
    }
}

struct Macro: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var steps: [MacroStep] = []
    /// Paste the text (default) or type it key by key, for fields that block paste.
    var typesText = false
    var data = MacroData()
    /// `{n}`: goes up on each run.
    var counter = 0
    /// Apps it was run in (bundle ids), for the "In <app>" section of the list.
    var apps: [String] = []
    var lastRun: Date?
    /// `{ask:Name}` answers from the last run, to prefill the prompt.
    var lastAnswers: [String: String] = [:]

    init(name: String, steps: [MacroStep] = [], typesText: Bool = false) {
        self.name = name
        self.steps = steps
        self.typesText = typesText
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? ""
        steps = try values.decodeIfPresent([MacroStep].self, forKey: .steps) ?? []
        typesText = try values.decodeIfPresent(Bool.self, forKey: .typesText) ?? false
        data = try values.decodeIfPresent(MacroData.self, forKey: .data) ?? MacroData()
        counter = try values.decodeIfPresent(Int.self, forKey: .counter) ?? 0
        apps = try values.decodeIfPresent([String].self, forKey: .apps) ?? []
        lastRun = try values.decodeIfPresent(Date.self, forKey: .lastRun)
        lastAnswers = try values.decodeIfPresent([String: String].self, forKey: .lastAnswers) ?? [:]
    }

    /// `{ask:Name}` questions in the order they first appear.
    var questions: [String] {
        var seen: [String] = []
        for step in steps where step.kind == .text {
            for question in MacroText.questions(in: step.text) where !seen.contains(question) { seen.append(question) }
        }
        return seen
    }
}

/// Variables inside a text step (R-35): `{date}`/`{fecha}`, `{time}`/`{hora}`, `{n}`,
/// `{random}`/`{aleatorio}`, `{clipboard}`/`{portapapeles}`, `{ask:Name}`/`{preguntar:Nombre}`
/// and the data columns by name. Unknown names are left as typed.
enum MacroText {
    struct Context {
        var date = Date.now
        var counter = 0
        var clipboard = ""
        var answers: [String: String] = [:]
        var columns: [String: String] = [:]
        var random: () -> String = { String(format: "%06d", Int.random(in: 0...999_999)) }
    }

    private static let askPrefixes = ["ask:", "preguntar:"]

    /// The variables offered by the editor's {} menu, in the user's language.
    static var offered: [(token: String, title: String)] {
        let spanish = Locale.current.language.languageCode?.identifier == "es"
        return [
            (spanish ? "{fecha}" : "{date}", String(localized: "Date")),
            (spanish ? "{hora}" : "{time}", String(localized: "Time")),
            ("{n}", String(localized: "Counter (goes up on each run)")),
            (spanish ? "{aleatorio}" : "{random}", String(localized: "Random digits")),
            (spanish ? "{portapapeles}" : "{clipboard}", String(localized: "Clipboard text")),
            (spanish ? "{preguntar:Nombre}" : "{ask:Name}", String(localized: "Ask when run")),
        ]
    }

    /// Names inside {…}, in order.
    private static func tokens(in text: String) -> [(range: Range<String.Index>, name: String)] {
        var result: [(Range<String.Index>, String)] = []
        var index = text.startIndex
        while let open = text[index...].firstIndex(of: "{"),
              let close = text[text.index(after: open)...].firstIndex(of: "}") {
            let name = String(text[text.index(after: open)..<close])
            if !name.isEmpty, !name.contains("{") {
                result.append((open..<text.index(after: close), name))
                index = text.index(after: close)
            } else {
                index = text.index(after: open)
            }
        }
        return result
    }

    static func questions(in text: String) -> [String] {
        tokens(in: text).compactMap { question($0.name) }
    }

    private static func question(_ name: String) -> String? {
        for prefix in askPrefixes where name.lowercased().hasPrefix(prefix) {
            let question = name.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            return question.isEmpty ? nil : question
        }
        return nil
    }

    static func expand(_ text: String, _ context: Context) -> String {
        var result = ""
        var index = text.startIndex
        for token in tokens(in: text) {
            result += text[index..<token.range.lowerBound]
            result += value(token.name, context) ?? String(text[token.range])
            index = token.range.upperBound
        }
        return result + text[index...]
    }

    private static func value(_ name: String, _ context: Context) -> String? {
        if let question = question(name) { return context.answers[question] ?? "" }
        switch name.lowercased() {
        case "date", "fecha": return context.date.formatted(date: .numeric, time: .omitted)
        case "time", "hora": return context.date.formatted(date: .omitted, time: .shortened)
        case "n": return String(context.counter)
        case "random", "aleatorio": return context.random()
        case "clipboard", "portapapeles": return context.clipboard
        default: return context.columns[name.lowercased()]
        }
    }

    /// "Create from text" (R-35): `KEY=value` lines become key, Tab, value, Return; plain lines
    /// become one text each, with Tab between them.
    static func steps(from text: String, pairs: Bool) -> [MacroStep] {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var steps: [MacroStep] = []
        for (index, line) in lines.enumerated() {
            if pairs {
                let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let key = parts[0].trimmingCharacters(in: .whitespaces)
                let value = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
                steps += [.text(key), .key(.tab), .text(value), .key(.returnKey)]
            } else {
                if index > 0 { steps.append(.key(.tab)) }
                steps.append(.text(line))
            }
        }
        return steps
    }
}

/// The saved macros: one JSON file in Application Support/Penknife, owner-only, like the pins.
@Observable
final class MacroStore {
    private(set) var macros: [Macro] = []

    @ObservationIgnored private let file: URL
    @ObservationIgnored private var saveWork: DispatchWorkItem?

    init(folder: URL = ClipboardStore.defaultFolder) {
        file = folder.appending(path: "Macros.json")
        load()
    }

    func macro(_ id: Macro.ID) -> Macro? { macros.first { $0.id == id } }

    @discardableResult
    func add(_ macro: Macro) -> Macro.ID {
        macros.append(macro)
        save()
        return macro.id
    }

    func update(_ macro: Macro) {
        guard let index = macros.firstIndex(where: { $0.id == macro.id }), macros[index] != macro else { return }
        macros[index] = macro
        save()
    }

    func edit(_ id: Macro.ID, _ change: (inout Macro) -> Void) {
        guard let index = macros.firstIndex(where: { $0.id == id }) else { return }
        change(&macros[index])
        save()
    }

    func remove(_ id: Macro.ID) {
        macros.removeAll { $0.id == id }
        save()
    }

    @discardableResult
    func duplicate(_ id: Macro.ID) -> Macro.ID? {
        guard let index = macros.firstIndex(where: { $0.id == id }) else { return nil }
        var copy = macros[index]
        copy.id = UUID()
        copy.name = String(localized: "\(copy.name) copy")
        copy.steps = copy.steps.map(\.duplicate)
        macros.insert(copy, at: index + 1)
        save()
        return copy.id
    }

    /// A name not used yet: "New Macro", "New Macro 2"…
    func freshName(_ base: String = String(localized: "New Macro")) -> String {
        var name = base
        var number = 2
        while macros.contains(where: { $0.name == name }) {
            name = "\(base) \(number)"
            number += 1
        }
        return name
    }

    // MARK: Export / import

    struct Export: Codable {
        var format = "penknife.macros"
        var version = 1
        var macros: [Macro]
    }

    /// Run state (counter, row, apps, answers) stays on this Mac: only what the macro does goes out.
    func exportData(_ ids: [Macro.ID]? = nil) throws -> Data {
        let chosen = macros.filter { ids?.contains($0.id) ?? true }.map { macro in
            var clean = Macro(name: macro.name, steps: macro.steps, typesText: macro.typesText)
            clean.data = macro.data
            clean.data.next = 0
            clean.steps = clean.steps.map { step in
                var step = step
                step.lastValue = nil
                return step
            }
            return clean
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Export(macros: chosen))
    }

    static func imported(_ data: Data) throws -> [Macro] {
        try JSONDecoder().decode(Export.self, from: data).macros.map { macro in
            var fresh = macro
            fresh.id = UUID()
            fresh.steps = fresh.steps.map(\.duplicate)
            return fresh
        }
    }

    /// Adds imported macros; `replace` swaps one of the same name, else both are kept.
    func addImported(_ macro: Macro, replacing existing: Macro.ID?) {
        if let existing, let index = macros.firstIndex(where: { $0.id == existing }) {
            var macro = macro
            macro.id = existing
            macros[index] = macro
        } else {
            var macro = macro
            if macros.contains(where: { $0.name == macro.name }) { macro.name = freshName(macro.name) }
            macros.append(macro)
        }
        save()
    }

    // MARK: Disk

    private func load() {
        guard let data = try? Data(contentsOf: file) else { return }
        do {
            macros = try JSONDecoder().decode([Macro].self, from: data)
        } catch {
            // Never written over: kept aside as it is, and the list starts empty.
            let aside = file.deletingLastPathComponent().appending(path: "Macros (unreadable \(Int(Date.now.timeIntervalSince1970))).json")
            try? FileManager.default.moveItem(at: file, to: aside)
            NSLog("Penknife: macros file unreadable, set aside: \(error.localizedDescription)")
        }
    }

    /// Saved a moment after the last change (typing in the editor doesn't write on every key).
    private func save() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        let manager = FileManager.default
        let folder = file.deletingLastPathComponent()
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if macros.isEmpty {
                try? manager.removeItem(at: file)
                return
            }
            let data = try JSONEncoder().encode(macros)
            let previous = umask(0o077)
            defer { umask(previous) }
            try data.write(to: file, options: [.atomic])
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            NSLog("Penknife: saving macros: \(error.localizedDescription)")
        }
    }
}

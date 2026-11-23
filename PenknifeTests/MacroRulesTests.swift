import AppKit
import Foundation
import Testing
@testable import Penknife

/// Macros rules (docs/requirements/macros.md). Each test names the rule it checks. Nothing here
/// presses keys, runs a macro or touches the user's clipboard, macros or pins: stores live in
/// temp folders and pasteboards are private.
@MainActor
@Suite("Macro rules")
struct MacroRulesTests {

    static func tempFolder() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "PenknifeTests-Macros-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    static let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("MAC-10 variables: date, time, counter, random, clipboard, in English and Spanish")
    func variables() {
        let context = MacroText.Context(date: Self.fixedDate, counter: 7, clipboard: "copied", random: { "123456" })
        #expect(MacroText.expand("test+{n}@x.com", context) == "test+7@x.com")
        #expect(MacroText.expand("{random}-{aleatorio}", context) == "123456-123456")
        #expect(MacroText.expand("{clipboard}/{portapapeles}", context) == "copied/copied")
        let date = Self.fixedDate.formatted(date: .numeric, time: .omitted)
        #expect(MacroText.expand("{date} {fecha}", context) == "\(date) \(date)")
        #expect(MacroText.expand("{hora}", context) == Self.fixedDate.formatted(date: .omitted, time: .shortened))
    }

    @Test("MAC-11 unknown names and lone braces are typed as written")
    func unknownVariables() {
        let context = MacroText.Context(counter: 1)
        #expect(MacroText.expand("{nope} { } {n", context) == "{nope} { } {n")
        #expect(MacroText.expand("a{{n}}b", context) == "a{1}b")
    }

    @Test("MAC-12 ask: questions are found once, in order, and filled with the answers")
    func askQuestions() {
        var macro = Macro(name: "m", steps: [.text("{ask:Name} {preguntar:ID}"), .key(.tab), .text("{ask:Name}")])
        #expect(macro.questions == ["Name", "ID"])
        let context = MacroText.Context(answers: ["Name": "Ana", "ID": "42"])
        #expect(MacroText.expand(macro.steps[0].text, context) == "Ana 42")
        macro.steps = [.text("{ask:}")]
        #expect(macro.questions.isEmpty)
    }

    @Test("MAC-20 data: first line names the columns; tabs, semicolons or commas")
    func dataParse() {
        let tabs = MacroData.parse("name\temail\nAna\tana@x.com\nLuis\tluis@x.com\n")
        #expect(tabs.columns == ["name", "email"])
        #expect(tabs.rows == [["Ana", "ana@x.com"], ["Luis", "luis@x.com"]])
        #expect(MacroData.parse("a;b\n1;2").rows == [["1", "2"]])
        #expect(MacroData.parse("a,b\n1").rows == [["1", ""]])
    }

    @Test("MAC-21 data: each run uses the next row; columns fill {name} case-insensitively")
    func dataRows() {
        var data = MacroData()
        data.update(from: "Name,Email\nAna,a@x\nLuis,l@x")
        let first = data.rowForRun()
        #expect(first?.index == 0)
        #expect(MacroText.expand("{name} {EMAIL}", MacroText.Context(columns: first?.values ?? [:])) == "Ana a@x")
        data.next = 1
        #expect(data.rowForRun()?.values["name"] == "Luis")
    }

    @Test("MAC-22 after the last row: Repeat Rows on starts again, off doesn't run")
    func repeatRows() {
        var data = MacroData()
        data.update(from: "n\n1\n2")
        data.next = 2
        data.repeats = true
        #expect(data.rowForRun()?.index == 0)
        data.repeats = false
        #expect(data.rowForRun() == nil)
    }

    @Test("MAC-23 a changed table starts again at row 1; no table runs without rows")
    func dataReset() {
        var data = MacroData()
        data.update(from: "n\n1\n2")
        data.next = 2
        data.update(from: "n\n1\n2\n3")
        #expect(data.next == 0)
        #expect(MacroData().rowForRun()?.values.isEmpty == true)
    }

    @Test("MAC-30 create from text: KEY=value lines become key, Tab, value, Return")
    func createPairs() {
        let steps = MacroText.steps(from: "API_KEY=abc=1\n\nDEBUG = true", pairs: true)
        #expect(steps.map(\.kind) == [.text, .key, .text, .key, .text, .key, .text, .key])
        #expect(steps.map(\.text).filter { !$0.isEmpty } == ["API_KEY", "abc=1", "DEBUG", "true"])
        #expect(steps[1].key == .tab && steps[3].key == .returnKey)
    }

    @Test("MAC-31 create from text: one text per line, Tab between them")
    func createLines() {
        let steps = MacroText.steps(from: "a\nb\nc", pairs: false)
        #expect(steps.map(\.kind) == [.text, .key, .text, .key, .text])
    }

    @Test("MAC-40 macros are saved owner-only and read back")
    func storeSaves() throws {
        let folder = Self.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = MacroStore(folder: folder)
        store.add(Macro(name: "Form", steps: [.text("x"), .key(.tab), .wait(300)]))
        store.saveNow()
        let file = folder.appending(path: "Macros.json")
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        let again = MacroStore(folder: folder)
        #expect(again.macros.count == 1)
        #expect(again.macros[0].steps.map(\.kind) == [.text, .key, .wait])
    }

    @Test("MAC-41 a file that can't be read is set aside, never written over")
    func unreadable() throws {
        let folder = Self.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: folder.appending(path: "Macros.json"))
        let store = MacroStore(folder: folder)
        #expect(store.macros.isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(names.contains { $0.hasPrefix("Macros (unreadable") })
    }

    @Test("MAC-42 export keeps what the macro does, not this Mac's run state")
    func exportClean() throws {
        let folder = Self.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = MacroStore(folder: folder)
        var macro = Macro(name: "Env", steps: [.text("{ask:Who}")])
        macro.counter = 9
        macro.apps = ["com.apple.Safari"]
        macro.lastAnswers = ["Who": "secret"]
        macro.allowsSecureInput = true
        macro.data.update(from: "a\n1\n2")
        macro.data.next = 1
        var pinned = MacroStep(kind: .pinned)
        pinned.lastValue = "ID-77"
        pinned.pin = UUID()
        pinned.text = "ID-77"
        macro.steps.append(pinned)
        store.add(macro)
        let imported = try MacroStore.imported(store.exportData())
        #expect(imported.count == 1)
        let copy = imported[0]
        #expect(copy.id != macro.id)
        #expect(copy.counter == 0 && copy.apps.isEmpty && copy.lastAnswers.isEmpty)
        #expect(!copy.allowsSecureInput) // MAC-78: an import never skips the warning
        #expect(copy.data.rows.count == 2 && copy.data.next == 0)
        #expect(copy.steps[1].lastValue == nil && copy.steps[1].pin == nil && copy.steps[1].text.isEmpty)
    }

    @Test("MAC-44 import: run state dropped, bad key codes become Tab, too big is refused, risks are listed")
    func importSafety() throws {
        let json = """
        {"format":"penknife.macros","version":1,"macros":[{"name":"x","counter":5,"apps":["a"],
         "lastAnswers":{"Who":"me"},"steps":[{"kind":"key","key":{"code":70000,"modifiers":1048576}},
         {"kind":"wait","milliseconds":999999},{"kind":"text","text":"{clipboard}"},{"kind":"file","file":"file:///tmp/a"}]}]}
        """
        let macros = try MacroStore.imported(Data(json.utf8))
        #expect(macros[0].counter == 0 && macros[0].apps.isEmpty && macros[0].lastAnswers.isEmpty)
        #expect(macros[0].steps[0].key?.code == 48)
        #expect(macros[0].steps[1].milliseconds == 60_000)
        #expect(MacroStore.risks(macros).count == 3)
        let big = Macro(name: "big", steps: Array(repeating: .text("a"), count: MacroStore.maxSteps + 1))
        let data = try JSONEncoder().encode(MacroStore.Export(macros: [big]))
        #expect(throws: MacroStore.ImportError.self) { try MacroStore.imported(data) }
    }

    @Test("MAC-43 import with the same name: keep both renames, replace keeps the id")
    func importNames() throws {
        let folder = Self.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = MacroStore(folder: folder)
        let id = store.add(Macro(name: "Form"))
        store.addImported(Macro(name: "Form", steps: [.text("a")]), replacing: nil)
        #expect(store.macros.map(\.name) == ["Form", "Form 2"])
        store.addImported(Macro(name: "Form", steps: [.text("b")]), replacing: id)
        #expect(store.macro(id)?.steps.first?.text == "b")
        #expect(store.macros.count == 2)
    }

    @Test("MAC-50 Update Value: a text pin takes the typed text and keeps its id, icon and place")
    func updatePin() {
        let folder = Self.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ClipboardStore(folder: folder, limit: { 100_000_000 })
        store.add(.text("first"))
        store.add(.text("ID-1"))
        store.add(.text("last"))
        let id = store.history[1].id
        store.togglePin(store.history[2].id)   // "first"
        store.togglePin(id)                     // "ID-1", second pin
        store.setIcon(id, PinIcon(glyph: "I", color: .blue))
        let changed = store.setPinText(id, "  ID-2\n")
        let empty = store.setPinText(id, "   ")
        let same = store.setPinText(id, "ID-2")
        #expect(changed && !empty && !same)
        #expect(store.pinned.map(\.text) == ["first", "ID-2"])
        #expect(store.pinned[1].id == id)
        #expect(store.pinned[1].icon?.glyph == "I")
        #expect(store.pinned[1].key == ClipItem.text("ID-2").key)
        let reloaded = ClipboardStore(folder: folder, limit: { 100_000_000 })
        #expect(reloaded.item(id)?.text == "ID-2")
    }

    @Test("MAC-51 pins reorder and the order is kept")
    func movePin() {
        let folder = Self.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ClipboardStore(folder: folder, limit: { 100_000_000 })
        for text in ["a", "b", "c"] { store.add(.text(text)) }
        for item in store.history.reversed() { store.togglePin(item.id) }
        #expect(store.pinned.map(\.text) == ["a", "b", "c"])
        store.movePin(store.pinned[2].id, to: 0)
        store.savePinOrder()
        #expect(store.pinned.map(\.text) == ["c", "a", "b"])
        #expect(ClipboardStore(folder: folder, limit: { 100_000_000 }).pinned.map(\.text) == ["c", "a", "b"])
    }

    @Test("MAC-52 panel keys: ⌘U edits the pin's value, ⌥⌘↑/↓ move it, plain arrows still move the selection")
    func pinKeys() {
        #expect(ClipboardKeys.action(keyCode: 32, characters: "u", flags: .command) == .editValue)
        #expect(ClipboardKeys.action(keyCode: 126, characters: nil, flags: [.command, .option]) == .movePin(-1))
        #expect(ClipboardKeys.action(keyCode: 125, characters: nil, flags: [.command, .option]) == .movePin(1))
        #expect(ClipboardKeys.action(keyCode: 125, characters: nil, flags: []) == .move(1))
    }

    @Test("MAC-60 the user's clipboard comes back as it was, every type of every item")
    func restoreClipboard() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("PenknifeTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("mine", forType: .string)
        pasteboard.setData(Data("{\\rtf1 mine}".utf8), forType: .rtf)
        let snapshot = MacroRunner.take(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("macro text", forType: .string)
        MacroRunner.restore(snapshot, to: pasteboard)
        #expect(pasteboard.string(forType: .string) == "mine")
        #expect(pasteboard.data(forType: .rtf) == Data("{\\rtf1 mine}".utf8))
    }

    @Test("MAC-61 key steps show as key caps")
    func keyNames() {
        #expect(MacroKey.tab.symbol == "⇥")
        #expect(MacroKey.returnKey.name == "Return")
        #expect(MacroKey(code: 0, modifiers: NSEvent.ModifierFlags.command.rawValue).symbol.hasPrefix("⌘"))
    }

    @Test("MAC-06 a default name clears on click; only New Macro and New Macro N count")
    func defaultName() {
        let base = String(localized: "New Macro")
        #expect(MacroStore.isDefaultName(base))
        #expect(MacroStore.isDefaultName(base + " 2"))
        #expect(MacroStore.isDefaultName(base + " 12"))
        #expect(!MacroStore.isDefaultName(base + " "))
        #expect(!MacroStore.isDefaultName(base + " x"))
        #expect(!MacroStore.isDefaultName("Login"))
    }

    @Test("MAC-24 renaming a column renames {old} in the text steps; empty or repeated names are refused")
    func renameColumn() {
        var macro = Macro(name: "m", steps: [MacroStep(kind: .text)])
        macro.steps[0].text = "Hi {Mail}, {mail}! {mailbox}"
        macro.data.update(from: "mail,name\na,b")
        let renamed = macro.renameColumn(0, to: " mail {address} ")
        #expect(renamed)
        #expect(macro.data.columns == ["mail address", "name"])
        #expect(macro.steps[0].text == "Hi {mail address}, {mail address}! {mailbox}")
        let taken = macro.renameColumn(0, to: "NAME")
        let empty = macro.renameColumn(0, to: "  ")
        #expect(!taken && !empty)
        #expect(macro.data.columns[0] == "mail address")
    }

    @Test("MAC-25 table editing: add/remove columns and rows; a pasted block spreads over the cells")
    func tableEditing() {
        var data = MacroData()
        data.addColumn()
        data.addColumn()
        #expect(data.columns.count == 2 && data.columns[0] != data.columns[1])
        data.addRow()
        data.set("a\tb\tc\nd\te\n", row: 0, column: 0)
        #expect(data.rows == [["a", "b"], ["d", "e"]])
        data.set("dX\tY", row: 1, column: 0)
        #expect(data.rows[1] == ["X", "Y"])
        data.set("d\te", row: 1, column: 0)
        data.next = 1
        data.removeRow(0)
        #expect(data.rows == [["d", "e"]] && data.next == 0)
        data.removeColumn(0)
        #expect(data.columns.count == 1 && data.rows == [["e"]])
        data.removeColumn(0)
        #expect(data.columns.isEmpty && data.rows.isEmpty)
    }

    @Test("MAC-76 a new step goes below the selected one, else at the end")
    func insertBelowSelected() {
        let steps = (0..<5).map { _ in MacroStep(kind: .text) }
        #expect(MacroStep.insertionIndex(after: [steps[2].id], in: steps) == 3)
        #expect(MacroStep.insertionIndex(after: [steps[4].id], in: steps) == 5)
        #expect(MacroStep.insertionIndex(after: [], in: steps) == 5)
        #expect(MacroStep.insertionIndex(after: [MacroStep(kind: .key).id], in: steps) == 5)
        #expect(MacroStep.insertionIndex(after: [], in: []) == 0)
        // MAC-79: several selected → below the lowest one.
        #expect(MacroStep.insertionIndex(after: [steps[3].id, steps[1].id], in: steps) == 4)
    }

    @Test("MAC-79 ⇧-click range, copy keeps list order")
    func selectRangeAndCopy() {
        let steps = (0..<5).map { _ in MacroStep(kind: .text) }
        let ids = steps.map(\.id)
        #expect(MacroStep.range(from: ids[3], to: ids[1], in: steps) == Set(ids[1...3]))
        #expect(MacroStep.range(from: ids[1], to: ids[3], in: steps) == Set(ids[1...3]))
        #expect(MacroStep.range(from: nil, to: ids[2], in: steps) == [ids[2]])
        #expect(MacroStep.copy([ids[4], ids[0], ids[2]], from: steps).map(\.id) == [ids[0], ids[2], ids[4]])
    }

    @Test("MAC-78 password fields are off unless allowed, also for macros saved before")
    func secureInputDefault() throws {
        #expect(!Macro(name: "A").allowsSecureInput)
        let old = try JSONDecoder().decode(Macro.self, from: Data(#"{"name":"Old"}"#.utf8))
        #expect(!old.allowsSecureInput)
    }
}

import AppKit
import CoreImage
import Foundation
import KeyboardShortcuts
import Testing
@testable import Penknife

/// Screenshot rules (docs/requirements/screenshot.md). Each test names the rule it checks.
/// Nothing here opens an overlay (no Screenshot or Record Screen action, `begin`, `show()` or
/// `requestPermission`), touches `NSPasteboard.general`, the Caches folder or the user's settings.
@MainActor
@Suite("Screenshot rules")
struct ScreenshotRulesTests {

    // MARK: Helpers

    /// Settings that only live in memory: nothing is written to disk or to the user's settings.
    final class MemoryDefaults: UserDefaults {
        var values: [String: Any] = [:]

        convenience init(_ values: [String: Any] = [:]) {
            self.init(suiteName: "PenknifeTests.memory.\(UUID().uuidString)")!
            self.values = values
        }

        override func object(forKey key: String) -> Any? { values[key] }
        override func string(forKey key: String) -> String? { values[key] as? String }
        override func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
        override func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
        override func set(_ value: Any?, forKey key: String) { Issue.record("a test wrote \(key)") }
    }

    /// The Spanish value of an English catalog key.
    static let spanish: [String: String] = {
        let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Penknife/Resources/Localizable.xcstrings")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let strings = json["strings"] as? [String: [String: Any]] else { return [:] }
        return strings.compactMapValues { entry in
            ((entry["localizations"] as? [String: Any])?["es"] as? [String: Any])
                .flatMap { $0["stringUnit"] as? [String: Any] }?["value"] as? String
        }
    }()

    /// `shown` is the English text or its Spanish translation (the test host runs in either
    /// language), and the catalog translates `english` as `es`.
    func expectText(_ shown: String, english: String, es: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(Self.spanish[english] == es, "catalog: \(english)", sourceLocation: sourceLocation)
        #expect(shown == english || shown == es, "\(shown) is neither \(english) nor \(es)", sourceLocation: sourceLocation)
    }

    static func mark(_ tool: CaptureTool, _ points: [CGPoint], size: Int = 1, color: NSColor = .systemRed, text: String = "") -> Annotation {
        Annotation(tool: tool, color: color, size: size, points: points, text: text)
    }

    static func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

    /// RGBA bytes of `image` drawn into a plain 8-bit sRGB bitmap of its own size.
    static func pixels(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                    bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    // MARK: A. Module

    // SS-01: two actions in this order; F1 is tested by TB-58.
    @Test("SS-01 the module's two actions and shortcuts")
    func moduleActions() {
        let actions = ScreenshotModule().actions
        #expect(actions.map(\.shortcut) == [.screenshot, .recordScreen])
        #expect(actions.map(\.symbol) == ["camera.viewfinder", "record.circle"])
        expectText(actions[0].title, english: "Screenshot", es: "Captura de pantalla")
        expectText(actions[1].title, english: "Record Screen", es: "Grabar pantalla")
        #expect(KeyboardShortcuts.Name.recordScreen.defaultShortcut == .init(.r, modifiers: [.control, .option]))
        #expect(KeyboardShortcuts.Name.recordingDraw.defaultShortcut == .init(.d, modifiers: [.control, .option]))
        #expect(ModuleID.screenshot.symbol == "camera.viewfinder")
    }

    // MARK: S1 settings

    // SS-54 (with SS-01, 07, 23, 24, 26, 46, 47, 49, 55): what a Mac that never opened Settings gets.
    @Test("SS-54 SS-01 SS-55 defaults on a fresh Mac")
    func freshDefaults() throws {
        let empty = try TouchBarRulesTests.emptySuite(keys: [
            "module.screenshot.enabled", ScreenshotModule.modeKey, ScreenshotModule.folderKey, ScreenshotModule.scrollKey,
            ScreenshotModule.copyFileKey, CapturePalette.colorKey, PastableImage.limitKey, AlertCategory.screenshot.key,
        ])
        #expect(ModuleManager.isOn(.screenshot, in: empty))
        #expect(ScreenshotMode.current(in: empty) == .frozen)
        #expect(CapturePalette.defaultIndex(in: empty) == 4)
        #expect(!ScreenshotModule.scrollUpThinner(in: empty))
        #expect(ScreenshotModule.copiesFile(in: empty))
        #expect(PastableImage.limitMB(in: empty) == 500)
        let desktop = URL(filePath: "/Desk", directoryHint: .isDirectory)
        #expect(ScreenshotModule.folder(in: empty, systemLocation: nil, isFolder: { _ in true }, desktop: desktop) == desktop)
        #expect(AlertCategory.screenshot.key == "alerts.screenshot")
        #expect(AlertCategory.screenshot.isShown(in: empty))
        #expect(KeyboardShortcuts.Name.screenshot.defaultShortcut == .init(.f1))
    }

    // SS-07: frozen unless the setting says "live".
    @Test("SS-07 screen while selecting", arguments: [(nil, ScreenshotMode.frozen), ("live", .live), ("frozen", .frozen), ("bogus", .frozen)])
    func screenMode(stored: String?, expected: ScreenshotMode) {
        let defaults = MemoryDefaults(stored.map { [ScreenshotModule.modeKey: $0] } ?? [:])
        #expect(ScreenshotMode.current(in: defaults) == expected)
        expectText(ScreenshotMode.frozen.title, english: "Frozen", es: "Congelada")
        expectText(ScreenshotMode.live.title, english: "Live", es: "En vivo")
    }

    // SS-23: each overlay starts on the Pointer, the default color and Medium.
    @Test("SS-23 the editor starts on the Pointer, the default color and Medium")
    func editorStart() {
        let fresh = CaptureEditorState(defaults: MemoryDefaults())
        #expect(fresh.tool == nil)
        #expect(fresh.colorIndex == 4)
        #expect(fresh.sizeIndex == 1)
        #expect(fresh.expanded == nil && !fresh.canUndo && !fresh.canRedo && !fresh.recordMode)
        #expect(CaptureEditorState(defaults: MemoryDefaults([CapturePalette.colorKey: 0])).colorIndex == 0)
    }

    // SS-24: the starting color is a setting; out of range → blue.
    @Test("SS-24 default color setting", arguments: [(nil, 4), (0, 0), (7, 7), (8, 4), (9, 4), (-1, 4)])
    func defaultColor(stored: Int?, expected: Int) {
        let defaults = MemoryDefaults(stored.map { [CapturePalette.colorKey: $0] } ?? [:])
        #expect(CapturePalette.defaultIndex(in: defaults) == expected)
    }

    // SS-26: scrolling up = thicker unless the setting says thinner.
    @Test("SS-26 scroll direction setting")
    func scrollSetting() {
        #expect(!ScreenshotModule.scrollUpThinner(in: MemoryDefaults()))
        #expect(ScreenshotModule.scrollUpThinner(in: MemoryDefaults([ScreenshotModule.scrollKey: true])))
    }

    // SS-46: Copy also offers a file unless turned off.
    @Test("SS-46 copy also as a file setting")
    func copyFileSetting() {
        #expect(ScreenshotModule.copiesFile(in: MemoryDefaults()))
        #expect(!ScreenshotModule.copiesFile(in: MemoryDefaults([ScreenshotModule.copyFileKey: false])))
    }

    // SS-47: the space for pastable files; the five choices, ≤ 0 → 500.
    @Test("SS-47 space for images to paste as files", arguments: [(nil, 500), (0, 500), (-5, 500), (100, 100), (2000, 2000)])
    func pastableLimit(stored: Int?, expected: Int) {
        #expect(PastableImage.limits == [100, 250, 500, 1000, 2000])
        let defaults = MemoryDefaults(stored.map { [PastableImage.limitKey: $0] } ?? [:])
        #expect(PastableImage.limitMB(in: defaults) == expected)
    }

    // SS-49: chosen folder, else the system location if it is a folder, else the Desktop; the
    // system location and the Desktop are read only when needed.
    @Test("SS-49 save folder")
    func saveFolder() {
        let desktop = URL(filePath: "/Desk", directoryHint: .isDirectory)
        var reads: [String] = []
        func folder(_ values: [String: Any], system: String?, isFolder: Bool) -> URL {
            reads = []
            return ScreenshotModule.folder(in: MemoryDefaults(values),
                                           systemLocation: { reads.append("system"); return system }(),
                                           isFolder: { _ in reads.append("check"); return isFolder },
                                           desktop: { reads.append("desktop"); return desktop }())
        }
        let chosen = folder([ScreenshotModule.folderKey: "/Chosen"], system: "/Sys", isFolder: true)
        #expect(chosen == URL(filePath: "/Chosen", directoryHint: .isDirectory))
        #expect(reads.isEmpty)

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let system = folder([:], system: "~/Pictures/Shots", isFolder: true)
        #expect(system.path == home + "/Pictures/Shots")
        #expect(reads == ["system", "check"])

        #expect(folder([:], system: "~/Pictures/Shots", isFolder: false) == desktop)
        #expect(reads == ["system", "check", "desktop"])
        #expect(folder([:], system: nil, isFolder: true) == desktop)
        #expect(reads == ["system", "desktop"])
    }

    // MARK: D/E. Tools, colors, sizes

    // SS-19 / SS-27: the tools in toolbar order, their symbols, titles and keys.
    @Test("SS-19 SS-27 tools in order, symbols, titles and keys")
    func tools() {
        #expect(CaptureTool.allCases == [.arrow, .line, .rectangle, .ellipse, .pen, .highlighter, .text, .blur, .eraser])
        #expect(CaptureTool.allCases.map(\.symbol) == ["arrow.up.right", "line.diagonal", "rectangle", "circle", "pencil.tip",
                                                         "highlighter", "textformat", "aqi.medium", "eraser"])
        #expect(CaptureTool.allCases.map(\.key) == ["V", "L", "R", "O", "P", "H", "T", "B", "E"])
        let titles: [(String, String)] = [("Arrow", "Flecha"), ("Line", "Línea"), ("Rectangle", "Rectángulo"), ("Circle", "Círculo"),
                                          ("Pen", "Lápiz"), ("Highlighter", "Resaltador"), ("Text", "Texto"), ("Blur", "Desenfocar"),
                                          ("Eraser", "Borrador")]
        for (tool, title) in zip(CaptureTool.allCases, titles) { expectText(tool.title, english: title.0, es: title.1) }
        #expect(CaptureTool.allCases.filter { !$0.usesColor } == [.blur, .eraser])
    }

    // SS-24: eight colors, keys 1–8; yellow and white get a dark checkmark.
    @Test("SS-24 the eight colors")
    func palette() {
        #expect(CapturePalette.colors == [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple, .white, .black])
        let names: [(String, String)] = [("Red", "Rojo"), ("Orange", "Naranja"), ("Yellow", "Amarillo"), ("Green", "Verde"),
                                         ("Blue", "Azul"), ("Purple", "Morado"), ("White", "Blanco"), ("Black", "Negro")]
        for (index, name) in names.enumerated() { expectText(CapturePalette.name(index), english: name.0, es: name.1) }
        #expect((0..<8).filter(CapturePalette.isLight) == [2, 6])
    }

    // SS-25: four sizes for every tool.
    @Test("SS-25 the four sizes")
    func sizes() {
        #expect(CaptureSize.count == 4)
        #expect(CaptureSize.defaultIndex == 1)
        #expect(CaptureSize.lineWidths == [2, 3.5, 6, 10])
        #expect(CaptureSize.fontSizes == [15, 22, 32, 46])
        #expect((0..<4).map { Self.mark(.highlighter, [], size: $0).highlighterWidth } == [14, 20, 30, 46])
        #expect(MarkEditing.eraserSizes == [10, 18, 28, 40])
        let names: [(String, String)] = [("Thin", "Fino"), ("Medium", "Mediano"), ("Thick", "Grueso"), ("Extra thick", "Muy grueso")]
        for (index, name) in names.enumerated() { expectText(CaptureSize.name(index), english: name.0, es: name.1) }
        #expect(CaptureSize.font(3).pointSize == 46)
    }

    // SS-28: ⇧ snaps a line's angle to 45° steps, keeping its length.
    @Test("SS-28 ⇧ snaps to 45°")
    func snapping() {
        let flat = MarkEditing.snapped(Self.p(10, 3), from: .zero)
        #expect(abs(flat.x - hypot(10, 3)) < 0.001 && abs(flat.y) < 0.001)
        let diagonal = MarkEditing.snapped(Self.p(10, 9), from: .zero)
        #expect(abs(diagonal.x - diagonal.y) < 0.001 && abs(hypot(diagonal.x, diagonal.y) - hypot(10, 9)) < 0.001)
        let fromOrigin = MarkEditing.snapped(Self.p(105, 80), from: Self.p(100, 100))
        #expect(abs(fromOrigin.x - 100) < 0.001 && fromOrigin.y < 100)
    }

    // SS-29: rectangle and circle are drawn inside their box, line inset by half its width, and
    // never vanish (a null rect) when smaller than their line.
    @Test("SS-29 rectangle and circle inside their box, never vanish")
    func strokeRect() {
        let medium = Self.mark(.rectangle, [.zero, Self.p(100, 50)], size: 1).strokeRect
        #expect(medium == CGRect(x: 1.75, y: 1.75, width: 96.5, height: 46.5))
        let tiny = Self.mark(.ellipse, [.zero, Self.p(2, 2)], size: 3).strokeRect
        #expect(!tiny.isNull)
        #expect(tiny.midX == 1 && tiny.midY == 1)
    }

    // SS-30 / SS-33: marks too small to be meant are dropped.
    @Test("SS-30 SS-33 marks too small to be meant")
    func meaningful() {
        for tool in [CaptureTool.arrow, .line, .rectangle, .ellipse, .blur] {
            #expect(!Self.mark(tool, [.zero, Self.p(4, 0)]).isMeaningful, "\(tool) 4 pt")
            #expect(Self.mark(tool, [.zero, Self.p(4.1, 0)]).isMeaningful, "\(tool) 4.1 pt")
            #expect(Self.mark(tool, [.zero, Self.p(0, 4.1)]).isMeaningful, "\(tool) 4.1 pt tall")
        }
        let p = Self.p(10, 10)
        #expect(Self.mark(.pen, [p, p]).isMeaningful)
        #expect(!Self.mark(.pen, [p]).isMeaningful)
        #expect(Self.mark(.highlighter, [p, p]).isMeaningful)
        #expect(!Self.mark(.text, [p], text: "  \n").isMeaningful)
        #expect(Self.mark(.text, [p], text: " a ").isMeaningful)
        #expect(!Self.mark(.eraser, [.zero, Self.p(50, 50)]).isMeaningful)
    }

    // SS-31 (part): text is semibold with a 35 % black shadow, none for black text.
    @Test("SS-31 text shadow")
    func textShadow() throws {
        let red = Annotation.textAttributes(.systemRed, size: 1)
        let shadow = try #require(red[.shadow] as? NSShadow)
        #expect(shadow.shadowColor?.alphaComponent == 0.35)
        #expect(shadow.shadowBlurRadius == 2)
        #expect(shadow.shadowOffset == NSSize(width: 0, height: -1))
        #expect((red[.font] as? NSFont)?.pointSize == 22)
        #expect(red[.foregroundColor] as? NSColor == .systemRed)
        let black = try #require(Annotation.textAttributes(.black, size: 1)[.shadow] as? NSShadow)
        #expect(black.shadowColor?.alphaComponent == 0)
        var scaled = Self.mark(.text, [.zero], size: 2, text: "a")
        scaled.scale = 2
        #expect(scaled.font.pointSize == 64)
    }

    // SS-32: the blur flattens what it covers, keeps the size; a blur without pixels is solid
    // dark gray, never clear.
    @Test("SS-32 blur flattens; a blur without pixels is solid gray")
    func blur() throws {
        // 120 × 120 px of 2 px black and white stripes; the middle third is measured (the edges
        // are clamped, so they stay darker or lighter).
        let side = 120
        var stripes = [UInt8](repeating: 255, count: side * side * 4)
        for y in 0..<side { for x in 0..<side where (x / 2) % 2 == 0 { for c in 0..<3 { stripes[(y * side + x) * 4 + c] = 0 } } }
        let provider = try #require(CGDataProvider(data: Data(stripes) as CFData))
        let image = try #require(CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let blurred = try #require(Annotation.blur(image, scale: 1, context: CIContext(options: [.useSoftwareRenderer: true])))
        #expect(blurred.width == side && blurred.height == side)
        let before = Self.pixels(image), after = Self.pixels(blurred)
        let row = side / 2
        func spread(_ bytes: [UInt8]) -> Int {
            let reds = (side / 3..<side * 2 / 3).map { Int(bytes[(row * side + $0) * 4]) }
            return reds.max()! - reds.min()!
        }
        #expect(spread(before) == 255)
        #expect(spread(after) < 20, "blurred stripes still differ by \(spread(after))")

        // No pixels: drawn into a bitmap, its center is dark gray (25 % white).
        let blank = Self.mark(.blur, [.zero, Self.p(20, 20)])
        var canvas = [UInt8](repeating: 0, count: 20 * 20 * 4)
        canvas.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 80,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            blank.draw()
            NSGraphicsContext.restoreGraphicsState()
        }
        let center = (10 * 20 + 10) * 4
        #expect(canvas[center + 3] == 255, "not opaque")
        for c in 0..<3 { #expect((50...80).contains(canvas[center + c]), "channel \(c) = \(canvas[center + c])") }
    }

    // MARK: F. Editing marks

    // SS-35: a click within 6 pt plus half the line selects it; inside text; never on an erased
    // spot; the topmost wins; a long thin ellipse is hit on its line only.
    @Test("SS-35 what a click selects")
    func hits() {
        let line = Self.mark(.line, [.zero, Self.p(100, 0)], size: 1)  // reach 1.75
        #expect(line.hit(Self.p(50, 7.75)))
        #expect(!line.hit(Self.p(50, 8.75)))
        #expect(line.hit(Self.p(107.75, 0)))
        let arrow = Self.mark(.arrow, [.zero, Self.p(100, 0)], size: 1)
        #expect(arrow.hit(Self.p(50, 7.75)) && !arrow.hit(Self.p(50, 8.75)))
        let highlighter = Self.mark(.highlighter, [.zero, Self.p(100, 0)], size: 1)  // 20 pt wide
        #expect(highlighter.hit(Self.p(50, 16)) && !highlighter.hit(Self.p(50, 17)))

        let text = Self.mark(.text, [Self.p(10, 10)], text: "Hola")
        #expect(text.hit(Self.p(15, 15)))

        var erased = line
        erased.erasures = [Erasure(points: [Self.p(50, 0)], width: 10, stroke: 0)]
        #expect(!erased.hit(Self.p(50, 0)))
        #expect(erased.hit(Self.p(10, 0)))

        let marks = [line, Self.mark(.line, [Self.p(50, -20), Self.p(50, 20)])]
        #expect(MarkEditing.topmost(at: Self.p(50, 0), in: marks) == 1)
        #expect(MarkEditing.topmost(at: Self.p(10, 0), in: marks) == 0)
        #expect(MarkEditing.topmost(at: Self.p(10, 50), in: marks) == nil)

        let ellipse = Self.mark(.ellipse, [.zero, Self.p(200, 100)], size: 0)
        #expect(ellipse.hit(Self.p(1, 50)))
        #expect(!ellipse.hit(Self.p(8, 8)), "a corner of its box is not on its line")
        #expect(!ellipse.hit(Self.p(100, 50)), "its middle is not on its line")
        #expect(!Self.mark(.eraser, [.zero, Self.p(10, 10)]).hit(Self.p(5, 5)))
    }

    // SS-36: handles by kind, grabbed within 7 pt; the ✕ stays inside the screen.
    @Test("SS-36 handles and the ✕")
    func handles() {
        let rectangle = Self.mark(.rectangle, [Self.p(50, 50), Self.p(150, 150)], size: 1)
        #expect(MarkEditing.handles(rectangle).count == 8)
        for tool in [CaptureTool.ellipse, .blur] { #expect(MarkEditing.handles(Self.mark(tool, [.zero, Self.p(40, 40)])).count == 8) }
        #expect(MarkEditing.handles(Self.mark(.pen, [.zero, Self.p(40, 40)])).count == 8)
        #expect(MarkEditing.handles(Self.mark(.text, [.zero], text: "a")).map(\.index) == [0, 2, 4, 6])
        let line = Self.mark(.line, [.zero, Self.p(100, 0)])
        #expect(MarkEditing.handles(line).map(\.index) == [0, 1, 2])
        #expect(MarkEditing.handles(line).last?.point == Self.p(50, 0))

        let frame = MarkEditing.frame(rectangle)  // the shape and its line plus 4 pt
        #expect(frame == CGRect(x: 44.25, y: 44.25, width: 111.5, height: 111.5))
        #expect(MarkEditing.handle(at: Self.p(frame.minX + 7, frame.minY), of: rectangle) == 0)
        #expect(MarkEditing.handle(at: Self.p(frame.minX + 8, frame.minY), of: rectangle) == nil)
        #expect(MarkEditing.handle(at: Self.p(frame.maxX, frame.maxY - 7), of: rectangle) == 4)

        let screen = CGRect(x: 0, y: 0, width: 200, height: 200)
        #expect(MarkEditing.closeCenter(rectangle, within: screen) == Self.p(frame.maxX + 8, frame.minY - 8))
        let corner = Self.mark(.rectangle, [Self.p(150, 0), Self.p(200, 50)], size: 1)
        let inside = MarkEditing.closeCenter(corner, within: screen)
        #expect(inside == Self.p(MarkEditing.frame(corner).maxX - 10, MarkEditing.frame(corner).minY + 10))
        #expect(screen.contains(inside))
        #expect(MarkEditing.isOnClose(Self.p(inside.x + 10, inside.y), of: corner, within: screen))
        #expect(!MarkEditing.isOnClose(Self.p(inside.x + 10.5, inside.y), of: corner, within: screen))
    }

    // SS-37: resizing and bending.
    @Test("SS-37 resize keeps the fixed corner; text scales 0.3–8×; ⇧ keeps the ratio")
    func resizing() {
        let text = Self.mark(.text, [Self.p(100, 100)], text: "Hola")
        let big = MarkEditing.resized(text, handle: 4, to: Self.p(5000, 5000), keepRatio: false)
        #expect(big.scale == 8)
        #expect(big.points[0] == Self.p(100, 100))
        let small = MarkEditing.resized(text, handle: 4, to: .zero, keepRatio: false)
        #expect(abs(small.scale - 0.3) < 0.0001)
        let fromTopLeft = MarkEditing.resized(text, handle: 0, to: Self.p(60, 60), keepRatio: false)
        #expect(fromTopLeft.scale > 1)
        #expect(abs(fromTopLeft.box.maxX - text.box.maxX) < 0.01 && abs(fromTopLeft.box.maxY - text.box.maxY) < 0.01)

        let rectangle = Self.mark(.rectangle, [.zero, Self.p(100, 50)], size: 1)
        let kept = MarkEditing.resized(rectangle, handle: 4, to: Self.p(300, 60), keepRatio: true).box
        #expect(abs(kept.width / kept.height - 2) < 0.001)
        #expect(kept.origin == .zero)
        let free = MarkEditing.resized(rectangle, handle: 4, to: Self.p(300, 60), keepRatio: false).box
        #expect(abs(free.width / free.height - 2) > 0.5)
        let least = MarkEditing.resized(rectangle, handle: 4, to: Self.p(-100, -100), keepRatio: false).box
        #expect(abs(least.width - 4.5) < 0.001 && abs(least.height - 4.5) < 0.001)  // its line (3.5) + 1

        let line = Self.mark(.line, [.zero, Self.p(100, 0)])
        let end = MarkEditing.resized(line, handle: 1, to: Self.p(80, 30), keepRatio: false)
        #expect(end.points == [.zero, Self.p(80, 30)])
        let snappedEnd = MarkEditing.resized(line, handle: 1, to: Self.p(80, 10), keepRatio: true)
        #expect(abs(snappedEnd.points[1].y) < 0.001)
        let bent = MarkEditing.resized(line, handle: 2, to: Self.p(50, 20), keepRatio: false)
        #expect(bent.bend == Self.p(50, 40))
    }

    @Test("SS-37 bend through a point; straight again within 3 pt")
    func bending() {
        var line = Self.mark(.arrow, [.zero, Self.p(100, 0)])
        line.bend(through: Self.p(50, 2))
        #expect(line.bend == nil)
        line.bend(through: Self.p(50, 20))
        #expect(line.bend == Self.p(50, 40))
        #expect(line.curveMiddle == Self.p(50, 20))
        line.bend(through: Self.p(51, 2.5))
        #expect(line.bend == nil)
    }

    @Test("SS-37 move and map carry the erased strokes along")
    func movingErasures() throws {
        var mark = Self.mark(.line, [.zero, Self.p(100, 10)])
        mark.erasures = [Erasure(points: [Self.p(50, 5)], width: 10, stroke: 0)]
        mark.bend = Self.p(50, 30)
        mark.move(by: CGVector(dx: 10, dy: 20))
        #expect(mark.points == [Self.p(10, 20), Self.p(110, 30)])
        #expect(try #require(mark.erasures.first).points == [Self.p(60, 25)])
        #expect(mark.bend == Self.p(60, 50))
        mark.map(from: CGRect(x: 10, y: 20, width: 100, height: 10), to: CGRect(x: 10, y: 20, width: 200, height: 20))
        #expect(mark.points == [Self.p(10, 20), Self.p(210, 40)])
        #expect(try #require(mark.erasures.first).points == [Self.p(110, 30)])
        #expect(try #require(mark.erasures.first).width == 10)
        #expect(mark.lineWidth == 3.5)
    }

    // SS-38 (part): ⌥ arrows grow a mark from its bottom-right.
    @Test("SS-38 ⌥ arrows grow a mark")
    func growing() {
        let line = Self.mark(.arrow, [.zero, Self.p(100, 0)])
        #expect(MarkEditing.grown(line, by: CGVector(dx: 10, dy: 5)).points == [.zero, Self.p(110, 5)])
        let rectangle = Self.mark(.rectangle, [.zero, Self.p(10, 10)])
        #expect(MarkEditing.grown(rectangle, by: CGVector(dx: -20, dy: 0)).box.width == 4)
        #expect(MarkEditing.grown(rectangle, by: CGVector(dx: 10, dy: 0)).box == CGRect(x: 0, y: 0, width: 20, height: 10))
        let text = Self.mark(.text, [.zero], text: "Hola")
        #expect(MarkEditing.grown(text, by: CGVector(dx: 100_000, dy: 0)).scale == 8)
        #expect(abs(MarkEditing.grown(text, by: CGVector(dx: -100_000, dy: 0)).scale - 0.3) < 0.0001)
        #expect(MarkEditing.grown(text, by: CGVector(dx: 0, dy: 10)).scale > 1)
    }

    // SS-41: the eraser takes only where it passes, samples fast drags, and a mark it covered
    // completely counts as gone.
    @Test("SS-41 the eraser")
    func eraser() throws {
        var line = Self.mark(.line, [.zero, Self.p(100, 0)], size: 0)  // 2 pt, reach 1
        let touched1 = line.erase(from: nil, to: Self.p(50, 50), width: 10, stroke: 1)
        #expect(!touched1)
        #expect(line.erasures.isEmpty)
        let touched2 = line.erase(from: nil, to: Self.p(50, 6), width: 10, stroke: 1)
        #expect(touched2)
        let touched3 = line.erase(from: Self.p(50, 6), to: Self.p(60, 50), width: 10, stroke: 1)
        #expect(touched3)
        #expect(line.erasures.count == 1)
        #expect(try #require(line.erasures.first).points == [Self.p(50, 6), Self.p(60, 50)])

        var fast = Self.mark(.line, [.zero, Self.p(100, 0)], size: 0)
        let touched4 = fast.erase(from: Self.p(50, -100), to: Self.p(50, 100), width: 10, stroke: 2)
        #expect(touched4)
        #expect(try #require(fast.erasures.first).points == [Self.p(50, -100), Self.p(50, 100)])
        var eraserMark = Self.mark(.eraser, [.zero, Self.p(100, 0)])
        let touched5 = eraserMark.erase(from: nil, to: Self.p(50, 0), width: 10, stroke: 1)
        #expect(!touched5)

        var covered = Self.mark(.line, [.zero, Self.p(100, 0)], size: 0)
        #expect(!covered.isFullyErased)
        covered.erasures = [Erasure(points: [Self.p(-10, 0), Self.p(110, 0)], width: 10, stroke: 0)]
        #expect(covered.isFullyErased)
        covered.erasures = [Erasure(points: [Self.p(-10, 0), Self.p(50, 0)], width: 10, stroke: 0)]
        #expect(!covered.isFullyErased)

        let dot = Erasure(points: [.zero], width: 10, stroke: 0)
        #expect(dot.covers(Self.p(5, 0)) && !dot.covers(Self.p(5.01, 0)))
        let stroke = Erasure(points: [.zero, Self.p(100, 0)], width: 10, stroke: 0)
        #expect(stroke.covers(Self.p(50, 5)) && !stroke.covers(Self.p(50, 5.01)))
        #expect(!Erasure(points: [], width: 10, stroke: 0).covers(.zero))
    }

    // MARK: S2 overlay geometry

    static let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)

    @Test("SS-12 an area drag: clamped, under 4 pt dropped, rounded out and kept on the screen")
    func areaDrag() {
        let g = CaptureGeometry.self
        #expect(g.clamp(Self.p(-5, 900), to: Self.screen) == Self.p(0, 800))
        #expect(g.clamp(Self.p(1200, -1), to: Self.screen) == Self.p(1000, 0))
        #expect(g.dragRect(from: Self.p(50, 60), to: Self.p(10, 20)) == CGRect(x: 10, y: 20, width: 40, height: 40))
        #expect(!g.keepsDrag(CGRect(x: 0, y: 0, width: 3.9, height: 100)))
        #expect(!g.keepsDrag(CGRect(x: 0, y: 0, width: 100, height: 3)))
        #expect(g.keepsDrag(CGRect(x: 0, y: 0, width: 4, height: 4)))
        #expect(g.chosen(CGRect(x: 10.4, y: 20.6, width: 30.2, height: 40.1), bounds: Self.screen) == CGRect(x: 10, y: 20, width: 31, height: 41))
        #expect(g.chosen(CGRect(x: 990.5, y: -5, width: 50, height: 50), bounds: Self.screen) == CGRect(x: 990, y: 0, width: 10, height: 45))
    }

    @Test("SS-17 moving, resizing and nudging an area selection")
    func changingSelection() {
        let g = CaptureGeometry.self
        let rect = CGRect(x: 100, y: 100, width: 200, height: 100)
        // Handles: corners and edge midpoints, grabbed within 8 pt.
        #expect(g.handlePoints(rect) == [Self.p(100, 100), Self.p(200, 100), Self.p(300, 100), Self.p(300, 150),
                                         Self.p(300, 200), Self.p(200, 200), Self.p(100, 200), Self.p(100, 150)])
        #expect(g.handle(at: Self.p(308, 192), of: rect) == 4)
        #expect(g.handle(at: Self.p(308.5, 200), of: rect) == nil)
        #expect(g.handle(at: Self.p(200, 150), of: rect) == nil)
        // Dragging inside moves it, kept inside the screen.
        #expect(g.moved(rect, to: Self.p(-20, 750), bounds: Self.screen) == CGRect(x: 0, y: 700, width: 200, height: 100))
        #expect(g.moved(rect, to: Self.p(900, 10), bounds: Self.screen) == CGRect(x: 800, y: 10, width: 200, height: 100))
        // A handle: crossing over flips; at least 1 pt.
        #expect(g.resizeSelection(handle: 4, original: rect, to: Self.p(50, 80)) == CGRect(x: 50, y: 80, width: 50, height: 20))
        #expect(g.resizeSelection(handle: 3, original: rect, to: Self.p(100, 999)) == CGRect(x: 100, y: 100, width: 1, height: 100))
        #expect(g.resizeSelection(handle: 1, original: rect, to: Self.p(999, 130)) == CGRect(x: 100, y: 130, width: 200, height: 70))
        // Arrows move inside the screen; ⌥ arrows resize from the bottom-right, at least 8 pt, within the screen.
        #expect(g.nudge(selection: rect, dx: 10, dy: 0, resize: false, bounds: Self.screen) == CGRect(x: 110, y: 100, width: 200, height: 100))
        let atEdge = CGRect(x: 0, y: 700, width: 200, height: 100)
        #expect(g.nudge(selection: atEdge, dx: -1, dy: 1, resize: false, bounds: Self.screen) == atEdge)
        #expect(g.nudge(selection: CGRect(x: 0, y: 0, width: 9, height: 9), dx: -10, dy: -10, resize: true, bounds: Self.screen)
                == CGRect(x: 0, y: 0, width: 8, height: 8))
        #expect(g.nudge(selection: CGRect(x: 900, y: 750, width: 95, height: 45), dx: 10, dy: 10, resize: true, bounds: Self.screen)
                == CGRect(x: 900, y: 750, width: 100, height: 50))
    }

    @Test("SS-14 the windows window mode can choose, and the arrows through them")
    func windowTargets() {
        let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)
        func info(_ id: CGWindowID, _ rect: CGRect, layer: Int? = 0, pid: pid_t? = 7, alpha: Double? = 1) -> WindowInfo {
            WindowInfo(id: id, layer: layer, ownerPID: pid, alpha: alpha, bounds: rect)
        }
        let list = [
            info(1, CGRect(x: 100, y: 100, width: 500, height: 400)),
            info(2, CGRect(x: 100, y: 100, width: 500, height: 400), pid: 99),            // Penknife's own
            info(3, CGRect(x: 100, y: 100, width: 500, height: 400), layer: 25),          // a panel, not layer 0
            info(4, CGRect(x: 100, y: 100, width: 500, height: 400), layer: nil),
            info(5, CGRect(x: 100, y: 100, width: 500, height: 400), alpha: 0),
            info(6, CGRect(x: 100, y: 100, width: 500, height: 400), pid: nil, alpha: nil), // missing values: kept
            info(7, CGRect(x: 100, y: 100, width: 40, height: 400)),                       // 40 pt wide: too small
            info(8, CGRect(x: 1410, y: 100, width: 500, height: 400)),                     // 30 pt on this screen
            info(9, CGRect(x: 1400, y: 100, width: 500, height: 400)),                     // 40 pt on this screen
        ]
        let targets = CaptureGeometry.windowTargets(list: list, ownPID: 99, screenFrame: primary, primaryHeight: 900)
        #expect(targets == [.window(1, CGRect(x: 100, y: 100, width: 500, height: 400)),
                            .window(6, CGRect(x: 100, y: 100, width: 500, height: 400)),
                            .window(9, CGRect(x: 1400, y: 100, width: 500, height: 400))])
        // A second screen above the primary one: global y −1000 is 80 pt from its top.
        let above = CGRect(x: 0, y: 900, width: 1920, height: 1080)
        let upper = CaptureGeometry.windowTargets(list: [info(1, CGRect(x: 100, y: -1000, width: 500, height: 400)), list[0]],
                                                  ownPID: 99, screenFrame: above, primaryHeight: 900)
        #expect(upper == [.window(1, CGRect(x: 100, y: 80, width: 500, height: 400))])
        // Arrows: front to back, then the desktop, wrapping both ways; none highlighted = just before the first.
        #expect(CaptureGeometry.nextTarget(current: nil, count: 4, forward: true) == 0)
        #expect(CaptureGeometry.nextTarget(current: nil, count: 4, forward: false) == 2)
        #expect(CaptureGeometry.nextTarget(current: 3, count: 4, forward: true) == 0)
        #expect(CaptureGeometry.nextTarget(current: 0, count: 4, forward: false) == 3)
        #expect(CaptureGeometry.nextTarget(current: nil, count: 1, forward: true) == 0)
    }

    @Test("SS-18 the size label: output pixels, above the top-left corner or inside it")
    func sizeLabel() {
        let g = CaptureGeometry.self
        #expect(g.sizeText(selection: CGRect(x: 0, y: 0, width: 400, height: 300), scale: 2) == "800 × 600")
        #expect(g.sizeText(selection: CGRect(x: 0, y: 0, width: 100.3, height: 50.2), scale: 2) == "201 × 100")
        let text = CGSize(width: 60, height: 14)
        #expect(g.sizeLabelFrame(selection: CGRect(x: 100, y: 100, width: 200, height: 100), textSize: text, bounds: Self.screen)
                == CGRect(x: 100, y: 74, width: 74, height: 20))
        #expect(g.sizeLabelFrame(selection: CGRect(x: 100, y: 0, width: 200, height: 100), textSize: text, bounds: Self.screen)
                == CGRect(x: 106, y: 6, width: 74, height: 20))
        #expect(g.sizeLabelFrame(selection: CGRect(x: 980, y: 100, width: 20, height: 100), textSize: text, bounds: Self.screen).maxX == 996)
        #expect(g.sizeLabelFrame(selection: CGRect(x: 0, y: 100, width: 20, height: 100), textSize: text, bounds: Self.screen).minX == 4)
    }

    @Test("SS-21 the toolbar: below, above, or inside the selection; 8 pt from the edges")
    func toolbarPlacement() {
        let g = CaptureGeometry.self
        let bar = CGSize(width: 400, height: 44)
        #expect(g.toolbarFrame(selection: CGRect(x: 300, y: 100, width: 400, height: 200), size: bar, bounds: Self.screen)
                == CGRect(x: 300, y: 310, width: 400, height: 44))
        #expect(g.toolbarFrame(selection: CGRect(x: 300, y: 500, width: 400, height: 250), size: bar, bounds: Self.screen)
                == CGRect(x: 300, y: 446, width: 400, height: 44))
        #expect(g.toolbarFrame(selection: Self.screen, size: bar, bounds: Self.screen) == CGRect(x: 300, y: 746, width: 400, height: 44))
        #expect(g.toolbarFrame(selection: CGRect(x: 0, y: 100, width: 100, height: 100), size: bar, bounds: Self.screen).minX == 8)
        #expect(g.toolbarFrame(selection: CGRect(x: 950, y: 100, width: 50, height: 100), size: bar, bounds: Self.screen).maxX == 992)
        // Never higher than 8 pt from the top.
        #expect(g.toolbarFrame(selection: CGRect(x: 300, y: 0, width: 400, height: 40), size: CGSize(width: 400, height: 790),
                               bounds: Self.screen).minY == 8)
    }

    @Test("SS-26 the scroll wheel: one step per notch or per 24 pt, by the physical direction")
    func scrollSteps() {
        let g = CaptureGeometry.self
        #expect(g.scrollStep(delta: 1, inverted: false, precise: false, accumulated: 0, upThinner: false) == (1, 0))
        #expect(g.scrollStep(delta: -3, inverted: false, precise: false, accumulated: 5, upThinner: false) == (-1, 5))
        #expect(g.scrollStep(delta: 0, inverted: false, precise: false, accumulated: 0, upThinner: false) == (0, 0))
        #expect(g.scrollStep(delta: 1, inverted: true, precise: false, accumulated: 0, upThinner: false) == (-1, 0))
        #expect(g.scrollStep(delta: 1, inverted: false, precise: false, accumulated: 0, upThinner: true) == (-1, 0))
        #expect(g.scrollStep(delta: 1, inverted: true, precise: false, accumulated: 0, upThinner: true) == (1, 0))
        // Trackpad: 23 pt is not a step yet; 24 is, and the leftover starts again.
        #expect(g.scrollStep(delta: 23, inverted: false, precise: true, accumulated: 0, upThinner: false) == (0, 23))
        #expect(g.scrollStep(delta: 1, inverted: false, precise: true, accumulated: 23, upThinner: false) == (1, 0))
        #expect(g.scrollStep(delta: 10, inverted: true, precise: true, accumulated: -20, upThinner: false) == (-1, 0))
    }

    @Test("SS-48 the save name: date and time, then \" 2\", \" 3\" when taken")
    func saveName() throws {
        let folder = URL(filePath: "/nonexistent/Shots", directoryHint: .isDirectory)
        let date = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 10, minute: 0, second: 0)))
        let free = CaptureGeometry.saveURL(folder: folder, date: date) { _ in false }
        #expect(free.deletingLastPathComponent().path == folder.path)
        let base = free.lastPathComponent
        #expect(["Screenshot 2026-11-19 at 10.00.00.png", "Captura de pantalla 2026-11-19 a las 10.00.00.png"].contains(base))
        let stem = String(base.dropLast(4))
        var taken: Set<String> = [base]
        #expect(CaptureGeometry.saveURL(folder: folder, date: date) { taken.contains($0.lastPathComponent) }.lastPathComponent == stem + " 2.png")
        taken.insert(stem + " 2.png")
        #expect(CaptureGeometry.saveURL(folder: folder, date: date) { taken.contains($0.lastPathComponent) }.lastPathComponent == stem + " 3.png")
    }

    // MARK: S3 key dispatch

    /// One key through the overlay's key table (codes: Esc 53, Space 49, Return 36, keypad Enter 76,
    /// Tab 48, Delete 51, Forward Delete 117, arrows 123 ← 124 → 125 ↓ 126 ↑).
    private func key(_ code: UInt16, _ characters: String = "", _ flags: NSEvent.ModifierFlags = [], isRepeat: Bool = false,
                     _ context: CaptureKeyContext = CaptureKeyContext()) -> CaptureKeyAction? {
        CaptureKeys.action(keyCode: code, characters: characters, flags: flags, isRepeat: isRepeat, context: context)
    }

    private static let editing = CaptureKeyContext(hasSelection: true, markCount: 3)

    @Test("SS-13 Space switches area ⇄ window before a selection, not while grabbing, once when held")
    func spaceKey() {
        #expect(key(49, " ") == .toggleWindowMode)
        #expect(key(49, " ", [], CaptureKeyContext(windowMode: true)) == .toggleWindowMode)
        #expect(key(49, " ", [], CaptureKeyContext(capturing: true)) == .swallow)
        #expect(key(49, " ", isRepeat: true) == .swallow)
        #expect(key(49, " ", [], Self.editing) == nil)
        #expect(key(49, " ", [], CaptureKeyContext(recordMode: true)) == .toggleWindowMode)
    }

    @Test("SS-14 arrows before a selection go through the windows in window mode only")
    func arrowsBeforeSelection() {
        let window = CaptureKeyContext(windowMode: true)
        #expect(key(124, "", [], window) == .nextTarget(forward: true))
        #expect(key(125, "", [], window) == .nextTarget(forward: true))
        #expect(key(123, "", [], window) == .nextTarget(forward: false))
        #expect(key(126, "", [], window) == .nextTarget(forward: false))
        #expect(key(124) == .swallow)
        // A window's frozen image can't move.
        #expect(key(124, "", [], CaptureKeyContext(hasSelection: true, fixedSelection: true, windowMode: true)) == .swallow)
        #expect(key(124, "", [.shift], Self.editing) == .nudgeSelection(dx: 10, dy: 0, resize: false))
        #expect(key(126, "", [.option], Self.editing) == .nudgeSelection(dx: 0, dy: -1, resize: true))
    }

    @Test("SS-27 tool, color and size keys: with a selection, ⇧ allowed, not with ⌃ ⌥ ⌘")
    func toolKeys() {
        #expect(key(9, "v", [], Self.editing) == .tool(.arrow))
        #expect(key(9, "V", [.shift], Self.editing) == .tool(.arrow))
        for tool in CaptureTool.allCases {
            #expect(key(0, tool.key.lowercased(), [], Self.editing) == .tool(tool))
        }
        #expect(key(9, "v", [.option], Self.editing) == nil)
        #expect(key(9, "v", [.control], Self.editing) == nil)
        #expect(key(9, "v") == nil)
        #expect(key(18, "1", [], Self.editing) == .color(0))
        #expect(key(28, "8", [], Self.editing) == .color(7))
        #expect(key(25, "9", [], Self.editing) == nil)
        #expect(key(29, "0", [], Self.editing) == nil)
        var sized = Self.editing
        sized.sizeIndex = 0
        #expect(key(27, "-", [], sized) == .size(0))
        #expect(key(24, "=", [], sized) == .size(1))
        #expect(key(24, "+", [.shift], sized) == .size(1))
        sized.sizeIndex = CaptureSize.count - 1
        #expect(key(24, "=", [], sized) == .size(CaptureSize.count - 1))
        #expect(key(27, "-", [], sized) == .size(CaptureSize.count - 2))
    }

    @Test("SS-38 mark keys: Tab cycles and wraps, Delete removes, arrows move (⇧ 10) or resize (⌥)")
    func markKeys() {
        #expect(key(48, "\t", [], Self.editing) == .selectMark(0))
        #expect(key(48, "\t", [.shift], Self.editing) == .selectMark(2))
        var selected = Self.editing
        selected.selectedMark = 2
        #expect(key(48, "\t", [], selected) == .selectMark(0))
        #expect(key(48, "\t", [.shift], selected) == .selectMark(1))
        #expect(key(48, "\t", [.option], selected) == nil)
        #expect(key(48, "\t", [], CaptureKeyContext(hasSelection: true)) == nil)
        #expect(key(53, "", [], selected) == .deselectMark)
        #expect(key(51, "", [], selected) == .removeMark(2))
        #expect(key(117, "", [], selected) == .removeMark(2))
        #expect(key(123, "", [], selected) == .nudgeMark(2, CGVector(dx: -1, dy: 0), grow: false))
        #expect(key(125, "", [.shift], selected) == .nudgeMark(2, CGVector(dx: 0, dy: 10), grow: false))
        #expect(key(124, "", [.option], selected) == .nudgeMark(2, CGVector(dx: 1, dy: 0), grow: true))
        // Without a mark selected the arrows move the selection; Delete is not ours.
        #expect(key(51, "", [], Self.editing) == nil)
        // Not in record mode.
        var record = selected
        record.recordMode = true
        #expect(key(48, "\t", [], record) == nil)
        #expect(key(51, "", [], record) == nil)
    }

    @Test("SS-42 Return chooses, starts typing with Text on, else copies; held once")
    func returnKey() {
        #expect(key(36) == .choose)
        #expect(key(76) == .choose)
        #expect(key(36, "", [], Self.editing) == .copy)
        var text = Self.editing
        text.tool = .text
        #expect(key(36, "", [], text) == .beginText)
        text.typing = true
        #expect(key(36, "", [], text) == .copy)
        #expect(key(36, "", isRepeat: true, Self.editing) == .swallow)
        #expect(key(76, "", isRepeat: true) == .swallow)
    }

    @Test("SS-43 Esc lets the selected mark go, else closes the overlay; held once")
    func escKey() {
        var selected = Self.editing
        selected.selectedMark = 0
        #expect(key(53, "", [], selected) == .deselectMark)
        #expect(key(53, "", [], Self.editing) == .cancel)
        #expect(key(53) == .cancel)
        #expect(key(53, "", isRepeat: true, selected) == .swallow)
    }

    @Test("SS-44 ⌘ keys in the editor: C, S, Z, ⇧Z, ⇧R; any other stays in the overlay (B-9)")
    func commandKeys() {
        let c = Self.editing
        #expect(key(8, "c", [.command], c) == .copy)
        #expect(key(1, "s", [.command], c) == .save)
        #expect(key(6, "z", [.command], c) == .undo)
        #expect(key(6, "Z", [.command, .shift], c) == .redo)
        #expect(key(15, "R", [.command, .shift], c) == .record)
        #expect(key(15, "r", [.command], c) == .swallow)
        #expect(key(43, ",", [.command], c) == .swallow)   // Settings would open under the overlay
        #expect(key(12, "q", [.command], c) == .swallow)   // quitting would lose the screenshot
        #expect(key(13, "w", [.command], c) == .swallow)
        #expect(key(43, ",", [.command]) == .swallow)
        // Also before a selection.
        #expect(key(8, "c", [.command]) == .copy)
    }

    @Test("SS-52 record mode: no tools or ⌘ keys but ⌘Q; Return chooses or starts; Esc closes")
    func recordModeKeys() {
        let choosing = CaptureKeyContext(recordMode: true)
        let chosen = CaptureKeyContext(hasSelection: true, recordMode: true, markCount: 2)
        #expect(key(8, "c", [.command], chosen) == .swallow)
        #expect(key(6, "z", [.command], choosing) == .swallow)
        #expect(key(12, "q", [.command], chosen) == nil)
        #expect(key(9, "v", [], chosen) == nil)
        #expect(key(18, "1", [], chosen) == nil)
        #expect(key(53, "", [], choosing) == .cancel)
        #expect(key(36, "", [], choosing) == .choose)
        #expect(key(36, "", [], chosen) == .startRecording)
    }

    // MARK: Bugs fixed after S2 and S3

    @Test("B-9 while typing a text only the Edit menu's keys reach the app's menu")
    func typingMenuKeys() {
        for character in ["z", "Z", "x", "c", "v", "a"] {
            #expect(CaptureKeys.reachesMenuWhileTyping(characters: character, flags: [.command]))
        }
        #expect(CaptureKeys.reachesMenuWhileTyping(characters: "z", flags: [.command, .shift]))
        #expect(!CaptureKeys.reachesMenuWhileTyping(characters: ",", flags: [.command]))
        #expect(!CaptureKeys.reachesMenuWhileTyping(characters: "q", flags: [.command]))
        #expect(!CaptureKeys.reachesMenuWhileTyping(characters: "w", flags: [.command]))
        #expect(CaptureKeys.reachesMenuWhileTyping(characters: "a", flags: []))
    }

    @Test("B-8 the toolbar stays on the screen for a window past the screen's bottom")
    func toolbarForTallWindow() {
        let bar = CGSize(width: 400, height: 44)
        let window = CGRect(x: 200, y: 30, width: 600, height: 900)   // the screen is 800 pt tall
        let frame = CaptureGeometry.toolbarFrame(selection: window, size: bar, bounds: Self.screen)
        #expect(frame == CGRect(x: 300, y: 746, width: 400, height: 44))
        #expect(Self.screen.contains(frame))
    }

    @Test("B-10 a recording takes only the selection's part on the screen")
    func recordRegionOnScreen() {
        let g = CaptureGeometry.self
        #expect(g.recordRegion(CGRect(x: 600, y: 500, width: 800, height: 600), bounds: Self.screen)
                == CGRect(x: 600, y: 500, width: 400, height: 300))
        #expect(g.recordRegion(CGRect(x: -100, y: -50, width: 1200, height: 900), bounds: Self.screen) == Self.screen)
        #expect(g.recordRegion(CGRect(x: 10, y: 10, width: 100, height: 50), bounds: Self.screen)
                == CGRect(x: 10, y: 10, width: 100, height: 50))
    }

    @Test("B-11 writing or deleting these files tells Settings, which reads the space again")
    func pastableChangesAreAnnounced() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var posts = 0
        let token = NotificationCenter.default.addObserver(forName: PastableImage.changed, object: nil, queue: nil) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        #expect(PastableImage.used(in: folder) == 0)
        let url = try #require(PastableImage.write(Data(count: 1_000), named: "a", in: folder, limit: 10_000))
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(posts == 1)
        #expect(PastableImage.used(in: folder) == 1_000)
        PastableImage.makeRoom(0, limit: 10_000, in: folder)
        #expect(posts == 1)
        PastableImage.makeRoom(0, limit: 0, in: folder)
        #expect(posts == 2)
        #expect(PastableImage.used(in: folder) == 0)
    }

    /// A plain opaque image of `width` × `height` pixels in `space`.
    static func solid(_ width: Int, _ height: Int, white: CGFloat = 1,
                      space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: white, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    @Test("SS-34 SS-45 the output is the selection at full resolution, with the marks where they are on the screen")
    func renderOutput() throws {
        // The selection is 100 × 50 pt at (100, 50) on the screen, grabbed at 2× = 200 × 100 px.
        let selection = CGRect(x: 100, y: 50, width: 100, height: 50)
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        let background = Self.solid(200, 100, space: p3)
        let bare = try #require(CaptureRender.image(background: background, scale: 2, selection: selection, marks: []))
        #expect(bare.width == 200 && bare.height == 100)
        #expect(bare.colorSpace?.name == CGColorSpace.displayP3)
        #expect(Self.pixels(bare).allSatisfy { $0 > 250 })

        // A red rectangle from (110, 60) to (150, 80) on the screen = pixels 20…100 × 20…60 from
        // the top-left; a mark outside the selection leaves nothing.
        let marks = [Self.mark(.rectangle, [Self.p(110, 60), Self.p(150, 80)], color: .red),
                     Self.mark(.rectangle, [Self.p(0, 0), Self.p(40, 40)], color: .red)]
        let image = try #require(CaptureRender.image(background: background, scale: 2, selection: selection, marks: marks))
        let bytes = Self.pixels(image)
        func rgb(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
            let i = (y * image.width + x) * 4
            return (bytes[i], bytes[i + 1], bytes[i + 2])
        }
        let edge = rgb(20, 40)        // the rectangle's left side, halfway down
        #expect(edge.0 > 200 && edge.1 < 120 && edge.2 < 120, "\(edge)")
        let inside = rgb(60, 40)      // inside the rectangle: untouched
        #expect(inside.0 > 250 && inside.1 > 250 && inside.2 > 250, "\(inside)")
        let corner = rgb(2, 2)        // where the outside mark would be if it weren't clipped
        #expect(corner.0 > 250 && corner.1 > 250 && corner.2 > 250, "\(corner)")
    }
}

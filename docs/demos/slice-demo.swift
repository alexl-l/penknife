// Penknife R-23 design demo: a playable slicing game on the Touch Bar with 3 visual styles.
// Build: swiftc -O main.swift -o slice-demo    Run: ./slice-demo    Quit: tap the X.
import AppKit
import QuartzCore

// MARK: - Private Touch Bar calls (same as Penknife's TouchBarPrivate)

enum TB {
    typealias Presence = @convention(c) (NSString, Bool) -> Void
    typealias Present = @convention(c) (AnyClass, Selector, NSTouchBar, Int64, NSString) -> Void
    typealias BarFn = @convention(c) (AnyClass, Selector, NSTouchBar) -> Void
    typealias ItemFn = @convention(c) (AnyClass, Selector, NSTouchBarItem) -> Void
    static let dfr = dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_LAZY)
    static func fn<T>(_ n: String, _ t: T.Type) -> T? { dfr.flatMap { dlsym($0, n) }.map { unsafeBitCast($0, to: t) } }
    static func cm<T>(_ c: AnyClass, _ n: String, _ t: T.Type) -> (Selector, T)? {
        let s = NSSelectorFromString(n)
        guard let m = class_getClassMethod(c, s) else { return nil }
        return (s, unsafeBitCast(method_getImplementation(m), to: t))
    }
    static func present(_ bar: NSTouchBar, tray: NSCustomTouchBarItem) {
        if let (s, add) = cm(NSTouchBarItem.self, "addSystemTrayItem:", ItemFn.self) { add(NSTouchBarItem.self, s, tray) }
        fn("DFRElementSetControlStripPresenceForIdentifier", Presence.self)?(tray.identifier.rawValue as NSString, true)
        if let (s, p) = cm(NSTouchBar.self, "presentSystemModalTouchBar:placement:systemTrayItemIdentifier:", Present.self) {
            p(NSTouchBar.self, s, bar, 1, tray.identifier.rawValue as NSString)
        }
    }
    static func dismiss(_ bar: NSTouchBar, tray: NSCustomTouchBarItem) {
        if let (s, m) = cm(NSTouchBar.self, "minimizeSystemModalTouchBar:", BarFn.self) { m(NSTouchBar.self, s, bar) }
        fn("DFRElementSetControlStripPresenceForIdentifier", Presence.self)?(tray.identifier.rawValue as NSString, false)
    }
}

// MARK: - Model

struct FruitKind {
    let skin: NSColor, dark: NSColor, flesh: NSColor, leaf: Bool
}

let kinds: [FruitKind] = [
    FruitKind(skin: NSColor(srgbRed: 0.93, green: 0.20, blue: 0.22, alpha: 1), dark: NSColor(srgbRed: 0.55, green: 0.05, blue: 0.08, alpha: 1), flesh: NSColor(srgbRed: 1.0, green: 0.95, blue: 0.80, alpha: 1), leaf: true),   // apple
    FruitKind(skin: NSColor(srgbRed: 1.0, green: 0.58, blue: 0.10, alpha: 1), dark: NSColor(srgbRed: 0.75, green: 0.30, blue: 0.0, alpha: 1), flesh: NSColor(srgbRed: 1.0, green: 0.75, blue: 0.35, alpha: 1), leaf: true),   // orange
    FruitKind(skin: NSColor(srgbRed: 0.45, green: 0.80, blue: 0.20, alpha: 1), dark: NSColor(srgbRed: 0.15, green: 0.45, blue: 0.05, alpha: 1), flesh: NSColor(srgbRed: 0.80, green: 0.95, blue: 0.55, alpha: 1), leaf: false),  // lime
    FruitKind(skin: NSColor(srgbRed: 0.55, green: 0.30, blue: 0.75, alpha: 1), dark: NSColor(srgbRed: 0.28, green: 0.10, blue: 0.45, alpha: 1), flesh: NSColor(srgbRed: 0.98, green: 0.85, blue: 0.45, alpha: 1), leaf: true),   // plum
    FruitKind(skin: NSColor(srgbRed: 1.0, green: 0.85, blue: 0.15, alpha: 1), dark: NSColor(srgbRed: 0.80, green: 0.60, blue: 0.0, alpha: 1), flesh: NSColor(srgbRed: 1.0, green: 0.97, blue: 0.70, alpha: 1), leaf: false),   // lemon
]

struct Thing { var kind: Int; var bomb: Bool; var p: CGPoint; var v: CGVector; var r: CGFloat; var angle: CGFloat; var spin: CGFloat; var risen = false }
struct Half { var kind: Int; var p: CGPoint; var v: CGVector; var r: CGFloat; var angle: CGFloat; var spin: CGFloat; var side: CGFloat; var life: CGFloat }
struct Drop { var p: CGPoint; var v: CGVector; var color: NSColor; var life: CGFloat }
struct Floater { var text: String; var p: CGPoint; var life: CGFloat }

let clickSound = NSSound(contentsOfFile: CommandLine.arguments[0].replacingOccurrences(of: "slice-demo", with: "") + "TapClick.wav", byReference: true)

// MARK: - Game view

final class GameView: NSView {
    static let width: CGFloat = 1004
    let H: CGFloat = 30
    var style = 0
    let styleNames = ["Brillante", "Plano", "Neón"]

    var things: [Thing] = [], halves: [Half] = [], drops: [Drop] = [], floaters: [Floater] = []
    var trail: [(CGPoint, CFTimeInterval)] = []
    var score = 0, lives = 3
    var best = UserDefaults.standard.integer(forKey: "sliceDemoBest")
    var gameOverAt: CFTimeInterval?, flash: CGFloat = 0
    var startTime = CACurrentMediaTime(), last = CACurrentMediaTime(), nextSpawn: CFTimeInterval = 0
    var lastTouch: CGPoint?, swipeCuts = 0, swipeCutTime: CFTimeInterval = 0
    var timer: Timer?

    // Layout: [X][score][styles] .......play field....... [hearts]
    let closeRect = CGRect(x: 4, y: 3, width: 30, height: 24)
    var styleRects: [CGRect] { (0..<3).map { CGRect(x: 92 + CGFloat($0) * 62, y: 4, width: 58, height: 22) } }
    var fieldMinX: CGFloat { 286 }
    let fieldMaxX: CGFloat = GameView.width - 70

    override init(frame: NSRect) {
        super.init(frame: frame)
        allowedTouchTypes = [.direct]
        wantsLayer = true
        timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize { NSSize(width: GameView.width, height: 30) }

    func restart() {
        things = []; halves = []; drops = []; floaters = []; score = 0; lives = 3; gameOverAt = nil
        startTime = CACurrentMediaTime(); nextSpawn = startTime + 0.6
    }

    // MARK: Simulation
    let g: CGFloat = 95

    func spawn(now: CFTimeInterval) {
        let elapsed = now - startTime
        let bomb = elapsed > 4 && Double.random(in: 0..<1) < 0.13
        let x = CGFloat.random(in: (fieldMinX + 30)...(fieldMaxX - 30))
        let toCenter: CGFloat = x < (fieldMinX + fieldMaxX) / 2 ? 1 : -1
        let speed = CGFloat(1 + min(elapsed / 60, 1) * 0.6)
        let vx = toCenter * CGFloat.random(in: 30...140) * speed
        let r: CGFloat = bomb ? 10 : CGFloat.random(in: 10...12)
        // rise so the center peaks around 14–20 pt
        let peak = CGFloat.random(in: 14...20) + r
        let vy = sqrt(2 * g * peak) * sqrt(speed)
        things.append(Thing(kind: Int.random(in: 0..<kinds.count), bomb: bomb, p: CGPoint(x: x, y: -r), v: CGVector(dx: vx, dy: vy), r: r, angle: 0, spin: CGFloat.random(in: -3...3)))
        let interval = max(0.35, 0.95 - elapsed / 90)
        nextSpawn = now + interval * Double.random(in: 0.6...1.3)
        if elapsed > 15 && Double.random(in: 0..<1) < 0.25 { nextSpawn = now + 0.12 } // occasional pair
    }

    func tick() {
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(now - last, 1.0 / 20)); last = now
        if gameOverAt == nil {
            if nextSpawn == 0 { nextSpawn = now + 0.6 }
            if now >= nextSpawn { spawn(now: now) }
        }
        let gScaled = g * CGFloat(1 + min((now - startTime) / 60, 1) * 0.6)
        var kept: [Thing] = []
        for var t in things {
            t.v.dy -= gScaled * dt
            t.p.x += t.v.dx * dt; t.p.y += t.v.dy * dt; t.angle += t.spin * dt
            if t.p.y > 0 { t.risen = true }
            if t.p.x < fieldMinX - t.r { t.p.x = fieldMinX - t.r; t.v.dx = abs(t.v.dx) } // bounce off the UI area
            if t.p.x > fieldMaxX + t.r { t.p.x = fieldMaxX + t.r; t.v.dx = -abs(t.v.dx) }
            if t.risen && t.p.y < -t.r - 1 {
                if !t.bomb && gameOverAt == nil { loseLife() }
                continue
            }
            kept.append(t)
        }
        things = kept
        halves = halves.compactMap { var h = $0
            h.v.dy -= g * 1.2 * dt; h.p.x += h.v.dx * dt; h.p.y += h.v.dy * dt; h.angle += h.spin * dt; h.life -= dt * 0.8
            return h.life > 0 && h.p.y > -h.r * 2 ? h : nil }
        drops = drops.compactMap { var d = $0
            d.v.dy -= g * 1.5 * dt; d.p.x += d.v.dx * dt; d.p.y += d.v.dy * dt; d.life -= dt * 1.6
            return d.life > 0 ? d : nil }
        floaters = floaters.compactMap { var f = $0; f.life -= dt * 1.2; return f.life > 0 ? f : nil }
        trail.removeAll { now - $0.1 > 0.16 }
        flash = max(0, flash - dt * 2)
        needsDisplay = true
    }

    func loseLife() {
        lives -= 1
        flash = 0.5
        if lives <= 0 { endGame() }
    }

    func endGame() {
        gameOverAt = CACurrentMediaTime()
        if score > best { best = score; UserDefaults.standard.set(best, forKey: "sliceDemoBest") }
    }

    // MARK: Touches

    override func touchesBegan(with event: NSEvent) {
        guard let t = event.touches(matching: .began, in: self).first else { return }
        let p = t.location(in: self)
        if closeRect.insetBy(dx: -4, dy: -4).contains(p) { NSApp.terminate(nil); return }
        if let i = styleRects.firstIndex(where: { $0.contains(p) }) { style = i; return }
        if let over = gameOverAt, CACurrentMediaTime() - over > 0.8 { restart(); return }
        lastTouch = p; swipeCuts = 0
        trail.append((p, CACurrentMediaTime()))
    }

    override func touchesMoved(with event: NSEvent) {
        guard let t = event.touches(matching: .moved, in: self).first, let a = lastTouch else { return }
        let b = t.location(in: self)
        let now = CACurrentMediaTime()
        trail.append((b, now))
        if gameOverAt == nil && hypot(b.x - a.x, b.y - a.y) > 1.5 { cut(from: a, to: b, now: now) }
        lastTouch = b
    }

    override func touchesEnded(with event: NSEvent) { lastTouch = nil }
    override func touchesCancelled(with event: NSEvent) { lastTouch = nil }

    func cut(from a: CGPoint, to b: CGPoint, now: CFTimeInterval) {
        let dir = CGVector(dx: b.x - a.x, dy: b.y - a.y)
        let len = max(hypot(dir.dx, dir.dy), 0.001)
        var survivors: [Thing] = []
        for t in things {
            // distance from the center to segment ab; the bar is short, so be generous vertically
            let tt = max(0, min(1, ((t.p.x - a.x) * dir.dx + (t.p.y - a.y) * dir.dy) / (len * len)))
            let cx = a.x + dir.dx * tt
            if abs(t.p.x - cx) > t.r + 2 { survivors.append(t); continue }
            if t.bomb {
                flash = 1
                for _ in 0..<18 { drops.append(Drop(p: t.p, v: CGVector(dx: .random(in: -160...160), dy: .random(in: -40...120)), color: .systemOrange, life: 1)) }
                lives = 0; endGame(); return
            }
            let cutAngle = atan2(dir.dy, dir.dx)
            let nx = -sin(cutAngle), ny = cos(cutAngle)
            for side: CGFloat in [-1, 1] {
                halves.append(Half(kind: t.kind, p: t.p, v: CGVector(dx: t.v.dx * 0.5 + nx * side * 40, dy: max(t.v.dy, 20) * 0.5 + ny * side * 25), r: t.r, angle: cutAngle, spin: side * 4, side: side, life: 1))
            }
            for _ in 0..<7 { drops.append(Drop(p: t.p, v: CGVector(dx: dir.dx / len * 90 + .random(in: -50...50), dy: .random(in: 0...80)), color: kinds[t.kind].flesh, life: 1)) }
            score += 1
            if now - swipeCutTime < 0.35 { swipeCuts += 1 } else { swipeCuts = 1 }
            swipeCutTime = now
            if swipeCuts >= 2 { score += swipeCuts - 1; floaters.append(Floater(text: "+\(swipeCuts) combo", p: t.p, life: 1)) }
            clickSound?.stop(); clickSound?.play()
        }
        things = survivors
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let c = NSGraphicsContext.current?.cgContext else { return }
        NSColor.black.setFill(); bounds.fill()
        if flash > 0 { NSColor.systemRed.withAlphaComponent(flash * 0.35).setFill(); CGRect(x: fieldMinX - 10, y: 0, width: fieldMaxX - fieldMinX + 20, height: H).fill() }
        drawUI(c)
        c.saveGState(); c.clip(to: CGRect(x: fieldMinX - 14, y: 0, width: fieldMaxX - fieldMinX + 28, height: H))
        for h in halves { drawHalf(c, h) }
        for t in things { t.bomb ? drawBomb(c, t) : drawFruit(c, kinds[t.kind], at: t.p, r: t.r, angle: t.angle) }
        for d in drops {
            d.color.withAlphaComponent(max(0, d.life)).setFill()
            NSBezierPath(ovalIn: CGRect(x: d.p.x - 1.3, y: d.p.y - 1.3, width: 2.6, height: 2.6)).fill()
        }
        drawTrail(c)
        for f in floaters {
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .heavy), .foregroundColor: NSColor.systemYellow.withAlphaComponent(f.life)]
            NSAttributedString(string: f.text, attributes: a).draw(at: CGPoint(x: f.p.x - 20, y: 8 + (1 - f.life) * 8))
        }
        c.restoreGState()
        if let over = gameOverAt { drawGameOver(over) }
    }

    func drawUI(_ c: CGContext) {
        // close
        let x = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)!.withSymbolConfiguration(.init(pointSize: 18, weight: .regular).applying(.init(paletteColors: [.white, NSColor(white: 0.25, alpha: 1)])))!
        x.draw(in: CGRect(x: closeRect.midX - 10, y: closeRect.midY - 10, width: 20, height: 20))
        // score
        let sa: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 17, weight: .semibold), .foregroundColor: NSColor.white]
        NSAttributedString(string: "\(score)", attributes: sa).draw(at: CGPoint(x: 42, y: 5))
        // style picker (demo only)
        for (i, r) in styleRects.enumerated() {
            let p = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
            (i == style ? NSColor(white: 0.45, alpha: 1) : NSColor(white: 0.18, alpha: 1)).setFill(); p.fill()
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white]
            let s = NSAttributedString(string: styleNames[i], attributes: a)
            s.draw(at: CGPoint(x: r.midX - s.size().width / 2, y: r.midY - s.size().height / 2))
        }
        // lives
        for i in 0..<3 {
            let on = i < lives
            let img = NSImage(systemSymbolName: on ? "heart.fill" : "heart", accessibilityDescription: nil)!.withSymbolConfiguration(.init(pointSize: 13, weight: .semibold).applying(.init(paletteColors: [on ? .systemRed : NSColor(white: 0.4, alpha: 1)])))!
            img.draw(in: CGRect(x: GameView.width - 62 + CGFloat(i) * 20, y: 8, width: 16, height: 14))
        }
    }

    func drawFruit(_ c: CGContext, _ k: FruitKind, at p: CGPoint, r: CGFloat, angle: CGFloat) {
        c.saveGState(); c.translateBy(x: p.x, y: p.y); c.rotate(by: angle)
        let body = CGRect(x: -r, y: -r, width: r * 2, height: r * 2)
        switch style {
        case 0: // glossy
            let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [k.skin.highlight(withLevel: 0.35)!.cgColor, k.skin.cgColor, k.dark.cgColor] as CFArray, locations: [0, 0.55, 1])!
            c.saveGState(); c.addEllipse(in: body); c.clip()
            c.drawRadialGradient(grad, startCenter: CGPoint(x: -r * 0.35, y: r * 0.35), startRadius: 0, endCenter: .zero, endRadius: r * 1.1, options: [.drawsAfterEndLocation])
            c.restoreGState()
            c.setFillColor(NSColor.white.withAlphaComponent(0.55).cgColor)
            c.fillEllipse(in: CGRect(x: -r * 0.55, y: r * 0.25, width: r * 0.5, height: r * 0.32))
            if k.leaf { drawLeaf(c, r: r, color: NSColor(srgbRed: 0.3, green: 0.75, blue: 0.25, alpha: 1)) }
        case 1: // flat
            c.setFillColor(k.skin.cgColor); c.fillEllipse(in: body)
            c.setFillColor(k.dark.withAlphaComponent(0.35).cgColor)
            c.addEllipse(in: body); c.addEllipse(in: body.offsetBy(dx: -r * 0.18, dy: r * 0.18)); c.fillPath(using: .evenOdd)
            if k.leaf { drawLeaf(c, r: r, color: NSColor(srgbRed: 0.35, green: 0.70, blue: 0.30, alpha: 1)) }
        default: // neon outline
            c.setShadow(offset: .zero, blur: 6, color: k.skin.cgColor)
            c.setStrokeColor(k.skin.highlight(withLevel: 0.2)!.cgColor); c.setLineWidth(2)
            c.setFillColor(k.skin.withAlphaComponent(0.18).cgColor)
            c.addEllipse(in: body.insetBy(dx: 1, dy: 1)); c.drawPath(using: .fillStroke)
            if k.leaf { c.setLineWidth(1.5); c.move(to: CGPoint(x: 0, y: r - 1)); c.addLine(to: CGPoint(x: r * 0.35, y: r + 3)); c.strokePath() }
        }
        c.restoreGState()
    }

    func drawLeaf(_ c: CGContext, r: CGFloat, color: NSColor) {
        c.setStrokeColor(NSColor(srgbRed: 0.4, green: 0.25, blue: 0.1, alpha: 1).cgColor); c.setLineWidth(1.2)
        c.move(to: CGPoint(x: 0, y: r * 0.8)); c.addLine(to: CGPoint(x: 0.5, y: r + 2.5)); c.strokePath()
        c.saveGState(); c.translateBy(x: 2.5, y: r + 1.2); c.rotate(by: 0.5)
        c.setFillColor(color.cgColor); c.fillEllipse(in: CGRect(x: 0, y: -1.4, width: 6, height: 2.8))
        c.restoreGState()
    }

    func drawHalf(_ c: CGContext, _ h: Half) {
        let k = kinds[h.kind], r = h.r
        c.saveGState(); c.setAlpha(min(1, h.life * 1.5))
        c.translateBy(x: h.p.x, y: h.p.y); c.rotate(by: h.angle)
        c.clip(to: h.side > 0 ? CGRect(x: -r - 4, y: 0.6, width: r * 2 + 8, height: r + 6) : CGRect(x: -r - 4, y: -r - 6, width: r * 2 + 8, height: r + 5.4))
        let body = CGRect(x: -r, y: -r, width: r * 2, height: r * 2)
        switch style {
        case 0:
            c.setFillColor(k.skin.cgColor); c.fillEllipse(in: body)
            c.setFillColor(k.flesh.cgColor); c.fillEllipse(in: body.insetBy(dx: 1.8, dy: 1.8))
            c.setFillColor(k.skin.withAlphaComponent(0.25).cgColor); c.fillEllipse(in: body.insetBy(dx: r * 0.6, dy: r * 0.6))
        case 1:
            c.setFillColor(k.skin.cgColor); c.fillEllipse(in: body)
            c.setFillColor(k.flesh.cgColor); c.fillEllipse(in: body.insetBy(dx: 2, dy: 2))
            c.setFillColor(NSColor(srgbRed: 0.3, green: 0.2, blue: 0.1, alpha: 1).cgColor)
            for s in [-0.35, 0.0, 0.35] as [CGFloat] { c.fillEllipse(in: CGRect(x: s * r - 1, y: h.side * r * 0.3 - 1.2, width: 2, height: 2.4)) }
        default:
            c.setShadow(offset: .zero, blur: 6, color: k.skin.cgColor)
            c.setStrokeColor(k.skin.highlight(withLevel: 0.2)!.cgColor); c.setLineWidth(2)
            c.addEllipse(in: body.insetBy(dx: 1, dy: 1)); c.strokePath()
            c.setStrokeColor(k.flesh.cgColor); c.move(to: CGPoint(x: -r, y: h.side * 0.6)); c.addLine(to: CGPoint(x: r, y: h.side * 0.6)); c.strokePath()
        }
        c.restoreGState()
    }

    func drawBomb(_ c: CGContext, _ t: Thing) {
        c.saveGState(); c.translateBy(x: t.p.x, y: t.p.y)
        let r = t.r, body = CGRect(x: -r, y: -r, width: r * 2, height: r * 2)
        let sparkOn = Int(CACurrentMediaTime() * 12) % 2 == 0
        if style == 2 {
            c.setShadow(offset: .zero, blur: 6, color: NSColor.systemRed.cgColor)
            c.setStrokeColor(NSColor.systemRed.cgColor); c.setLineWidth(2); c.addEllipse(in: body.insetBy(dx: 1, dy: 1)); c.strokePath()
        } else {
            let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [NSColor(white: 0.45, alpha: 1).cgColor, NSColor(white: 0.12, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
            c.saveGState(); c.addEllipse(in: body); c.clip()
            c.drawRadialGradient(grad, startCenter: CGPoint(x: -r * 0.35, y: r * 0.35), startRadius: 0, endCenter: .zero, endRadius: r * 1.1, options: [.drawsAfterEndLocation])
            c.restoreGState()
            c.setStrokeColor(NSColor.systemRed.cgColor); c.setLineWidth(1.5)
            c.move(to: CGPoint(x: -r * 0.45, y: -r * 0.45)); c.addLine(to: CGPoint(x: r * 0.45, y: r * 0.45))
            c.move(to: CGPoint(x: -r * 0.45, y: r * 0.45)); c.addLine(to: CGPoint(x: r * 0.45, y: -r * 0.45)); c.strokePath()
        }
        c.setStrokeColor(NSColor(white: 0.7, alpha: 1).cgColor); c.setLineWidth(1.2)
        c.move(to: CGPoint(x: r * 0.5, y: r * 0.75)); c.addQuadCurve(to: CGPoint(x: r * 1.0, y: r * 1.3), control: CGPoint(x: r * 1.0, y: r * 0.8)); c.strokePath()
        c.setFillColor((sparkOn ? NSColor.systemYellow : NSColor.systemOrange).cgColor)
        c.fillEllipse(in: CGRect(x: r * 1.0 - 2, y: r * 1.3 - 2, width: 4, height: 4))
        c.restoreGState()
    }

    func drawTrail(_ c: CGContext) {
        guard trail.count >= 2 else { return }
        let now = CACurrentMediaTime()
        c.saveGState(); c.setLineCap(.round)
        for i in 1..<trail.count {
            let (a, ta) = trail[i - 1], (b, _) = trail[i]
            let k = CGFloat(1 - (now - ta) / 0.16)
            let w = max(0.5, k * 4)
            switch style {
            case 0:
                c.setShadow(offset: .zero, blur: 5, color: NSColor.white.cgColor)
                c.setStrokeColor(NSColor.white.withAlphaComponent(k).cgColor)
            case 1:
                c.setStrokeColor(NSColor(white: 0.85, alpha: k).cgColor)
            default:
                let hue = (CGFloat(i) / CGFloat(trail.count) + CGFloat(now * 0.5)).truncatingRemainder(dividingBy: 1)
                c.setShadow(offset: .zero, blur: 6, color: NSColor(hue: hue, saturation: 1, brightness: 1, alpha: 1).cgColor)
                c.setStrokeColor(NSColor(hue: hue, saturation: 0.8, brightness: 1, alpha: k).cgColor)
            }
            c.setLineWidth(style == 1 ? w * 0.6 : w)
            c.move(to: a); c.addLine(to: b); c.strokePath()
        }
        // blade tip (flat style): a small silver penknife blade at the finger
        if style == 1, let (tip, _) = trail.last, let (prev, _) = trail.dropLast().last {
            let ang = atan2(tip.y - prev.y, tip.x - prev.x)
            c.translateBy(x: tip.x, y: tip.y); c.rotate(by: ang)
            c.setFillColor(NSColor(white: 0.9, alpha: 1).cgColor)
            c.move(to: CGPoint(x: 6, y: 0)); c.addLine(to: CGPoint(x: -4, y: 2.5)); c.addLine(to: CGPoint(x: -4, y: -1)); c.closePath(); c.fillPath()
            c.setFillColor(NSColor.systemRed.cgColor); c.fill(CGRect(x: -10, y: -1.2, width: 6, height: 3.4))
        }
        c.restoreGState()
    }

    func drawGameOver(_ over: CFTimeInterval) {
        let f = CGRect(x: fieldMinX, y: 0, width: fieldMaxX - fieldMinX, height: H)
        NSColor.black.withAlphaComponent(0.75).setFill(); f.fill()
        let newBest = score >= best && score > 0
        let text = "Fin · \(score) puntos · Récord \(best)\(newBest ? " ★" : "")   —   toca para jugar otra vez"
        let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: NSColor.white]
        let s = NSAttributedString(string: text, attributes: a)
        s.draw(at: CGPoint(x: f.midX - s.size().width / 2, y: f.midY - s.size().height / 2))
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSTouchBarDelegate {
    let gameID = NSTouchBarItem.Identifier("demo.slice.game")
    let tray = NSCustomTouchBarItem(identifier: NSTouchBarItem.Identifier("demo.slice.tray"))
    let bar = NSTouchBar()
    let game = GameView(frame: NSRect(x: 0, y: 0, width: GameView.width, height: 30))

    func applicationDidFinishLaunching(_ n: Notification) {
        tray.view = NSButton(title: "🔪", target: self, action: #selector(show))
        bar.delegate = self
        bar.defaultItemIdentifiers = [gameID]
        game.restart()
        show()
    }
    @objc func show() { TB.present(bar, tray: tray) }
    func applicationWillTerminate(_ n: Notification) { TB.dismiss(bar, tray: tray) }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier id: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        guard id == gameID else { return nil }
        let item = NSCustomTouchBarItem(identifier: id)
        item.view = game
        game.widthAnchor.constraint(equalToConstant: GameView.width).isActive = true
        return item
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
signal(SIGINT) { _ in DispatchQueue.main.async { NSApp.terminate(nil) } }
app.run()

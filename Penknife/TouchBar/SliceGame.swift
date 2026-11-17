import AppKit
import QuartzCore

/// R-23: a slicing game on the whole Touch Bar. Fruits jump up from the bottom edge; a swipe
/// through one cuts it in two. 3 lives (an uncut fruit that falls back costs one), a cut bomb
/// ends the game, the best score is kept. Three looks the user picks inside the game.
/// It only costs anything while a game is open: one 60 Hz timer, stopped by `finish()`.
/// The play field is Core Animation layers showing pre-drawn sprites; each tick only moves
/// them, and `draw(_:)` paints just the controls when the score, lives or style change.
final class SliceGameView: NSView {
    enum Style: Int, CaseIterable {
        case glossy, flat, neon
        var name: String {
            switch self {
            case .glossy: String(localized: "Glossy")
            case .flat: String(localized: "Flat")
            case .neon: String(localized: "Neon")
            }
        }
    }

    static let styleKey = "touchBar.gameStyle"
    static let bestKey = "touchBar.gameBest"

    /// Called once when the game closes (X, or a while after game over).
    var onFinish: (() -> Void)?

    private struct Fruit { let skin: NSColor, dark: NSColor, flesh: NSColor, leaf: Bool }
    private static let fruits: [Fruit] = [
        Fruit(skin: NSColor(hex: 0xED3338), dark: NSColor(hex: 0x8C0D14), flesh: NSColor(hex: 0xFFF2CC), leaf: true),  // apple
        Fruit(skin: NSColor(hex: 0xFF941A), dark: NSColor(hex: 0xBF4D00), flesh: NSColor(hex: 0xFFBF59), leaf: true),  // orange
        Fruit(skin: NSColor(hex: 0x73CC33), dark: NSColor(hex: 0x26730D), flesh: NSColor(hex: 0xCCF28C), leaf: false), // lime
        Fruit(skin: NSColor(hex: 0x8C4DBF), dark: NSColor(hex: 0x471A73), flesh: NSColor(hex: 0xFAD973), leaf: true),  // plum
        Fruit(skin: NSColor(hex: 0xFFD926), dark: NSColor(hex: 0xCC9900), flesh: NSColor(hex: 0xFFF7B3), leaf: false), // lemon
    ]

    // Drawing caches: nothing is looked up or allocated per frame for these.
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)
    private static let fruitGradients: [CGGradient?] = fruits.map {
        CGGradient(colorsSpace: sRGB, colors: [($0.skin.highlight(withLevel: 0.35) ?? $0.skin).cgColor, $0.skin.cgColor, $0.dark.cgColor] as CFArray,
                   locations: [0, 0.55, 1])
    }
    private static let neonStrokes: [CGColor] = fruits.map { ($0.skin.highlight(withLevel: 0.2) ?? $0.skin).cgColor }
    private static let bombGradient = CGGradient(colorsSpace: sRGB, colors: [NSColor(white: 0.45, alpha: 1).cgColor, NSColor(white: 0.12, alpha: 1).cgColor] as CFArray,
                                                 locations: [0, 1])
    private static let stemColor = NSColor(hex: 0x66401A).cgColor
    private static let seedColor = NSColor(hex: 0x4D331A).cgColor
    private static let glossyLeaf = NSColor(hex: 0x4DBF40).cgColor
    private static let flatLeaf = NSColor(hex: 0x59B34D).cgColor
    private static let shine = NSColor.white.withAlphaComponent(0.55).cgColor
    private static let closeImage = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 18, weight: .regular).applying(.init(paletteColors: [.white, NSColor(white: 0.25, alpha: 1)])))
    private static let heartOn = NSImage(systemSymbolName: "heart.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold).applying(.init(paletteColors: [.systemRed])))
    private static let heartOff = NSImage(systemSymbolName: "heart", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold).applying(.init(paletteColors: [NSColor(white: 0.4, alpha: 1)])))
    private static let scoreAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 17, weight: .semibold), .foregroundColor: NSColor.white]
    private static let styleLabels: [NSAttributedString] = Style.allCases.map {
        NSAttributedString(string: $0.name, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white])
    }
    private static let pillOn = NSColor(white: 0.45, alpha: 1), pillOff = NSColor(white: 0.18, alpha: 1)
    private static let comboFont = NSFont.systemFont(ofSize: 11, weight: .heavy)
    private static let gameOverAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: NSColor.white]

    private struct Thing { var kind: Int; var bomb: Bool; var p: CGPoint; var v: CGVector; var r: CGFloat; var angle: CGFloat; var spin: CGFloat; var risen = false }
    private struct Half { var kind: Int; var p: CGPoint; var v: CGVector; var r: CGFloat; var angle: CGFloat; var spin: CGFloat; var side: CGFloat; var life: CGFloat }
    private struct Drop { var p: CGPoint; var v: CGVector; var color: CGColor; var life: CGFloat }
    private struct Floater { var text: String; var p: CGPoint; var life: CGFloat }

    private var style: Style
    private var things: [Thing] = [], halves: [Half] = [], drops: [Drop] = [], floaters: [Floater] = []
    private var trail: [(CGPoint, CFTimeInterval)] = []
    private var score = 0 { didSet { if score != oldValue { scoreText = nil; needsDisplay = true } } }
    private var lives = 3 { didSet { if lives != oldValue { needsDisplay = true } } }
    private var scoreText: NSAttributedString?
    private var best = UserDefaults.standard.integer(forKey: SliceGameView.bestKey)
    private var newRecord = false
    private var gameOverAt: CFTimeInterval?
    private var flash: CGFloat = 0
    private var startTime: CFTimeInterval = 0, last: CFTimeInterval = 0, nextSpawn: CFTimeInterval = 0
    private var lastTouch: CGPoint?, swipeCuts = 0, swipeCutTime: CFTimeInterval = 0
    private var timer: Timer?

    // Layers: the field clips to `fieldRect` and uses view coordinates (bounds origin = rect origin).
    private struct SpriteKey: Hashable { var kind: Int; var r: CGFloat; var part: Int } // part: 0 whole, ±1 half, 2/3 bomb, 4 knife
    private static let spritePad: CGFloat = 8
    private var sprites: [SpriteKey: CGImage] = [:] // current style only, built on first use
    private let field = CALayer(), flashLayer = CALayer(), knifeLayer = CALayer()
    private let halfGroup = CALayer(), thingGroup = CALayer(), dropGroup = CALayer(), trailGroup = CALayer(), floaterGroup = CALayer()
    private var halfLayers: [CALayer] = [], thingLayers: [CALayer] = [], dropLayers: [CALayer] = []
    private var trailLayers: [CAShapeLayer] = [], floaterLayers: [CATextLayer] = []
    private let overlay = CALayer(), overlayText = CATextLayer()
    private var overlayString: String?
    private var layersReady = false
    private var renderedEmpty = false // the field showed nothing last time: idle ticks skip the work
    private var scale: CGFloat { window?.backingScaleFactor ?? 2 }

    private let height: CGFloat = 30
    private let gravity: CGFloat = 95
    // Layout: [X][score][styles] ........ play field ........ [lives]
    private let closeRect = CGRect(x: 4, y: 3, width: 30, height: 24)
    private var styleRects: [CGRect] { (0..<3).map { CGRect(x: 92 + CGFloat($0) * 62, y: 4, width: 58, height: 22) } }
    private let fieldMinX: CGFloat = 286
    private var fieldMaxX: CGFloat { bounds.width - 70 }

    override init(frame: NSRect) {
        style = Style(rawValue: UserDefaults.standard.integer(forKey: Self.styleKey)) ?? .glossy
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        allowedTouchTypes = [.direct]
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "Slicing game"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func start() {
        restart()
    }

    private func startTicking() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// The bar went away some other way (system, another app): never tick unseen.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, timer != nil { finish() }
    }

    /// Stops the timer and hands control back (idempotent).
    func finish() {
        saveBest() // leaving mid-game (X, lock, sleep) keeps a new record too
        timer?.invalidate()
        timer = nil
        sprites = [:]
        field.removeFromSuperlayer()
        overlay.removeFromSuperlayer()
        halfLayers = []; thingLayers = []; dropLayers = []; trailLayers = []; floaterLayers = []
        layersReady = false
        let done = onFinish
        onFinish = nil
        done?()
    }

    private func restart() {
        things = []; halves = []; drops = []; floaters = []
        score = 0; lives = 3; gameOverAt = nil; flash = 0; newRecord = false
        startTime = CACurrentMediaTime(); last = startTime; nextSpawn = startTime + 0.6
        needsDisplay = true
        renderedEmpty = false
        render(now: startTime)
        startTicking()
    }

    // MARK: Simulation

    /// 0 at the start, 1 after a minute: speed and spawn rate grow with it.
    private func difficulty(_ now: CFTimeInterval) -> CGFloat { CGFloat(min((now - startTime) / 60, 1)) }

    private func spawn(now: CFTimeInterval) {
        let elapsed = now - startTime
        let bomb = elapsed > 4 && Double.random(in: 0..<1) < 0.13
        let x = CGFloat.random(in: (fieldMinX + 30)...(fieldMaxX - 30))
        let toCenter: CGFloat = x < (fieldMinX + fieldMaxX) / 2 ? 1 : -1
        let speed = 1 + difficulty(now) * 0.6
        let r: CGFloat = bomb ? 10 : CGFloat(Int.random(in: 20...24)) / 2 // half-point steps: few sprites
        // The center peaks 14–20 pt up the bar.
        let peak = CGFloat.random(in: 14...20) + r
        let vy = sqrt(2 * gravity * peak) * sqrt(speed)
        things.append(Thing(kind: Int.random(in: 0..<Self.fruits.count), bomb: bomb, p: CGPoint(x: x, y: -r),
                            v: CGVector(dx: toCenter * .random(in: 30...140) * speed, dy: vy),
                            r: r, angle: 0, spin: .random(in: -3...3)))
        let interval = max(0.35, 0.95 - elapsed / 90)
        nextSpawn = now + interval * Double.random(in: 0.6...1.3)
        if elapsed > 15 && Double.random(in: 0..<1) < 0.25 { nextSpawn = now + 0.12 } // a pair now and then
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(now - last, 1.0 / 20))
        last = now
        if let over = gameOverAt {
            // The result stays a while; then the normal buttons come back. Once nothing moves,
            // the 60 Hz timer gives way to a single wake-up.
            if now - over > 6 { finish(); return }
            if things.isEmpty && halves.isEmpty && drops.isEmpty && floaters.isEmpty && trail.isEmpty && flash == 0 {
                timer?.invalidate()
                timer = Timer.scheduledTimer(withTimeInterval: max(0, 6 - (now - over)), repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.finish() }
                }
                render(now: now)
                return
            }
        } else if now >= nextSpawn {
            spawn(now: now)
        }
        let g = gravity * (1 + difficulty(now) * 0.6)
        var kept: [Thing] = []
        kept.reserveCapacity(things.count)
        for var t in things {
            t.v.dy -= g * dt
            t.p.x += t.v.dx * dt
            t.p.y += t.v.dy * dt
            t.angle += t.spin * dt
            if t.p.y > 0 { t.risen = true }
            // Bounce off the controls on the left and the lives on the right.
            if t.p.x < fieldMinX - t.r { t.p.x = fieldMinX - t.r; t.v.dx = abs(t.v.dx) }
            if t.p.x > fieldMaxX + t.r { t.p.x = fieldMaxX + t.r; t.v.dx = -abs(t.v.dx) }
            if t.risen && t.p.y < -t.r - 1 {
                if !t.bomb && gameOverAt == nil { loseLife() }
                continue
            }
            kept.append(t)
        }
        things = kept
        halves = halves.compactMap {
            var h = $0
            h.v.dy -= gravity * 1.2 * dt
            h.p.x += h.v.dx * dt; h.p.y += h.v.dy * dt
            h.angle += h.spin * dt; h.life -= dt * 0.8
            return h.life > 0 && h.p.y > -h.r * 2 ? h : nil
        }
        drops = drops.compactMap {
            var d = $0
            d.v.dy -= gravity * 1.5 * dt
            d.p.x += d.v.dx * dt; d.p.y += d.v.dy * dt; d.life -= dt * 1.6
            return d.life > 0 ? d : nil
        }
        floaters = floaters.compactMap { var f = $0; f.life -= dt * 1.2; return f.life > 0 ? f : nil }
        trail.removeAll { now - $0.1 > 0.16 }
        flash = max(0, flash - dt * 2)
        render(now: now) // score, lives and style redraw only when they change
    }

    private var fieldRect: CGRect { CGRect(x: fieldMinX - 14, y: 0, width: fieldMaxX - fieldMinX + 28, height: height) }

    private func loseLife() {
        lives -= 1
        flash = 0.5
        if lives <= 0 { endGame() }
    }

    private func endGame() {
        gameOverAt = CACurrentMediaTime()
        saveBest()
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: gameOverText(withHint: false),
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    private func saveBest() {
        guard score > best else { return }
        best = score
        newRecord = true
        UserDefaults.standard.set(best, forKey: Self.bestKey)
    }

    // MARK: Touches

    override func touchesBegan(with event: NSEvent) {
        guard let touch = event.touches(matching: .began, in: self).first else { return }
        let p = touch.location(in: self)
        if closeRect.insetBy(dx: -4, dy: -4).contains(p) { GameSound.play(); finish(); return }
        if let index = styleRects.firstIndex(where: { $0.contains(p) }), let chosen = Style(rawValue: index) {
            GameSound.play()
            style = chosen
            UserDefaults.standard.set(index, forKey: Self.styleKey)
            sprites = [:]
            needsDisplay = true
            render(now: CACurrentMediaTime())
            return
        }
        if let over = gameOverAt {
            if CACurrentMediaTime() - over > 0.8 { GameSound.play(); restart() }
            return
        }
        lastTouch = p
        swipeCuts = 0
        trail.append((p, CACurrentMediaTime()))
    }

    override func touchesMoved(with event: NSEvent) {
        guard let touch = event.touches(matching: .moved, in: self).first, let a = lastTouch else { return }
        let b = touch.location(in: self)
        let now = CACurrentMediaTime()
        trail.append((b, now))
        if gameOverAt == nil && hypot(b.x - a.x, b.y - a.y) > 1.5 { cut(from: a, to: b, now: now) }
        lastTouch = b
    }

    override func touchesEnded(with event: NSEvent) { lastTouch = nil }
    override func touchesCancelled(with event: NSEvent) { lastTouch = nil }

    /// Everything the finger crossed between two samples is cut. The bar is only 30 pt tall,
    /// so only the horizontal distance counts.
    private func cut(from a: CGPoint, to b: CGPoint, now: CFTimeInterval) {
        let dir = CGVector(dx: b.x - a.x, dy: b.y - a.y)
        let len = max(hypot(dir.dx, dir.dy), 0.001)
        var survivors: [Thing] = []
        for (index, t) in things.enumerated() {
            let k = max(0, min(1, ((t.p.x - a.x) * dir.dx + (t.p.y - a.y) * dir.dy) / (len * len)))
            // Mostly below the bar edge (just launched or falling out): not visible, can't be cut.
            if t.p.y < -t.r * 0.4 || abs(t.p.x - (a.x + dir.dx * k)) > t.r + 2 { survivors.append(t); continue }
            if t.bomb {
                flash = 1
                for _ in 0..<18 {
                    drops.append(Drop(p: t.p, v: CGVector(dx: .random(in: -160...160), dy: .random(in: -40...120)), color: NSColor.systemOrange.cgColor, life: 1))
                }
                lives = 0
                things = survivors + things[(index + 1)...]
                endGame()
                return
            }
            let angle = atan2(dir.dy, dir.dx)
            let nx = -sin(angle), ny = cos(angle)
            for side: CGFloat in [-1, 1] {
                halves.append(Half(kind: t.kind, p: t.p,
                                   v: CGVector(dx: t.v.dx * 0.5 + nx * side * 40, dy: max(t.v.dy, 20) * 0.5 + ny * side * 25),
                                   r: t.r, angle: angle, spin: side * 4, side: side, life: 1))
            }
            for _ in 0..<7 {
                drops.append(Drop(p: t.p, v: CGVector(dx: dir.dx / len * 90 + .random(in: -50...50), dy: .random(in: 0...80)),
                                  color: Self.fruits[t.kind].flesh.cgColor, life: 1))
            }
            score += 1
            swipeCuts = now - swipeCutTime < 0.35 ? swipeCuts + 1 : 1
            swipeCutTime = now
            if swipeCuts >= 2 {
                score += swipeCuts - 1
                floaters.append(Floater(text: String(localized: "+\(swipeCuts) combo"), p: t.p, life: 1))
            }
            GameSound.play()
        }
        things = survivors
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        dirtyRect.fill()
        drawControls(in: dirtyRect)
    }

    private func drawControls(in dirty: CGRect) {
        let leftControls = CGRect(x: 0, y: 0, width: fieldMinX - 14, height: height)
        if dirty.intersects(leftControls) {
            Self.closeImage?.draw(in: CGRect(x: closeRect.midX - 10, y: closeRect.midY - 10, width: 20, height: 20))
            if scoreText == nil { scoreText = NSAttributedString(string: "\(score)", attributes: Self.scoreAttributes) }
            scoreText?.draw(at: CGPoint(x: 42, y: 5))
            for (index, rect) in styleRects.enumerated() {
                (index == style.rawValue ? Self.pillOn : Self.pillOff).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
                let name = Self.styleLabels[index]
                let size = name.size()
                name.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
            }
        }
        for i in 0..<3 {
            let rect = CGRect(x: bounds.width - 62 + CGFloat(i) * 20, y: 8, width: 16, height: 14)
            if dirty.intersects(rect) { (i < lives ? Self.heartOn : Self.heartOff)?.draw(in: rect) }
        }
    }

    private func drawFruit(_ c: CGContext, kind: Int, at p: CGPoint, r: CGFloat, angle: CGFloat) {
        let fruit = Self.fruits[kind]
        c.saveGState()
        c.translateBy(x: p.x, y: p.y)
        c.rotate(by: angle)
        let body = CGRect(x: -r, y: -r, width: r * 2, height: r * 2)
        switch style {
        case .glossy:
            if let gradient = Self.fruitGradients[kind] {
                c.saveGState()
                c.addEllipse(in: body)
                c.clip()
                c.drawRadialGradient(gradient, startCenter: CGPoint(x: -r * 0.35, y: r * 0.35), startRadius: 0,
                                     endCenter: .zero, endRadius: r * 1.1, options: [.drawsAfterEndLocation])
                c.restoreGState()
            }
            c.setFillColor(Self.shine)
            c.fillEllipse(in: CGRect(x: -r * 0.55, y: r * 0.25, width: r * 0.5, height: r * 0.32))
            if fruit.leaf { drawLeaf(c, r: r, color: Self.glossyLeaf) }
        case .flat:
            c.setFillColor(fruit.skin.cgColor)
            c.fillEllipse(in: body)
            c.setFillColor(fruit.dark.withAlphaComponent(0.35).cgColor)
            c.addEllipse(in: body)
            c.addEllipse(in: body.offsetBy(dx: -r * 0.18, dy: r * 0.18))
            c.fillPath(using: .evenOdd)
            if fruit.leaf { drawLeaf(c, r: r, color: Self.flatLeaf) }
        case .neon:
            c.setShadow(offset: .zero, blur: 6 * scale, color: fruit.skin.cgColor) // bitmap shadows are in pixels
            c.setStrokeColor(Self.neonStrokes[kind])
            c.setLineWidth(2)
            c.setFillColor(fruit.skin.withAlphaComponent(0.18).cgColor)
            c.addEllipse(in: body.insetBy(dx: 1, dy: 1))
            c.drawPath(using: .fillStroke)
            if fruit.leaf {
                c.setLineWidth(1.5)
                c.move(to: CGPoint(x: 0, y: r - 1))
                c.addLine(to: CGPoint(x: r * 0.35, y: r + 3))
                c.strokePath()
            }
        }
        c.restoreGState()
    }

    private func drawLeaf(_ c: CGContext, r: CGFloat, color: CGColor) {
        c.setStrokeColor(Self.stemColor)
        c.setLineWidth(1.2)
        c.move(to: CGPoint(x: 0, y: r * 0.8))
        c.addLine(to: CGPoint(x: 0.5, y: r + 2.5))
        c.strokePath()
        c.saveGState()
        c.translateBy(x: 2.5, y: r + 1.2)
        c.rotate(by: 0.5)
        c.setFillColor(color)
        c.fillEllipse(in: CGRect(x: 0, y: -1.4, width: 6, height: 2.8))
        c.restoreGState()
    }

    private func drawHalf(_ c: CGContext, _ h: Half) {
        let fruit = Self.fruits[h.kind], r = h.r
        c.saveGState()
        c.translateBy(x: h.p.x, y: h.p.y)
        c.rotate(by: h.angle)
        c.clip(to: h.side > 0 ? CGRect(x: -r - 4, y: 0.6, width: r * 2 + 8, height: r + 6)
                              : CGRect(x: -r - 4, y: -r - 6, width: r * 2 + 8, height: r + 5.4))
        let body = CGRect(x: -r, y: -r, width: r * 2, height: r * 2)
        switch style {
        case .glossy:
            c.setFillColor(fruit.skin.cgColor); c.fillEllipse(in: body)
            c.setFillColor(fruit.flesh.cgColor); c.fillEllipse(in: body.insetBy(dx: 1.8, dy: 1.8))
            c.setFillColor(fruit.skin.withAlphaComponent(0.25).cgColor); c.fillEllipse(in: body.insetBy(dx: r * 0.6, dy: r * 0.6))
        case .flat:
            c.setFillColor(fruit.skin.cgColor); c.fillEllipse(in: body)
            c.setFillColor(fruit.flesh.cgColor); c.fillEllipse(in: body.insetBy(dx: 2, dy: 2))
            c.setFillColor(Self.seedColor)
            for s: CGFloat in [-0.35, 0, 0.35] {
                c.fillEllipse(in: CGRect(x: s * r - 1, y: h.side * r * 0.3 - 1.2, width: 2, height: 2.4))
            }
        case .neon:
            c.setShadow(offset: .zero, blur: 6 * scale, color: fruit.skin.cgColor)
            c.setStrokeColor(Self.neonStrokes[h.kind])
            c.setLineWidth(2)
            c.addEllipse(in: body.insetBy(dx: 1, dy: 1)); c.strokePath()
            c.setStrokeColor(fruit.flesh.cgColor)
            c.move(to: CGPoint(x: -r, y: h.side * 0.6)); c.addLine(to: CGPoint(x: r, y: h.side * 0.6)); c.strokePath()
        }
        c.restoreGState()
    }

    private func drawBomb(_ c: CGContext, r: CGFloat, spark sparkOn: Bool) {
        c.saveGState()
        let body = CGRect(x: -r, y: -r, width: r * 2, height: r * 2)
        if style == .neon {
            c.setShadow(offset: .zero, blur: 6 * scale, color: NSColor.systemRed.cgColor)
            c.setStrokeColor(NSColor.systemRed.cgColor)
            c.setLineWidth(2)
            c.addEllipse(in: body.insetBy(dx: 1, dy: 1)); c.strokePath()
            c.setShadow(offset: .zero, blur: 0, color: nil)
        } else {
            if let gradient = Self.bombGradient {
                c.saveGState()
                c.addEllipse(in: body)
                c.clip()
                c.drawRadialGradient(gradient, startCenter: CGPoint(x: -r * 0.35, y: r * 0.35), startRadius: 0,
                                     endCenter: .zero, endRadius: r * 1.1, options: [.drawsAfterEndLocation])
                c.restoreGState()
            }
            c.setStrokeColor(NSColor.systemRed.cgColor)
            c.setLineWidth(1.5)
            c.move(to: CGPoint(x: -r * 0.45, y: -r * 0.45)); c.addLine(to: CGPoint(x: r * 0.45, y: r * 0.45))
            c.move(to: CGPoint(x: -r * 0.45, y: r * 0.45)); c.addLine(to: CGPoint(x: r * 0.45, y: -r * 0.45))
            c.strokePath()
        }
        c.setStrokeColor(NSColor(white: 0.7, alpha: 1).cgColor)
        c.setLineWidth(1.2)
        c.move(to: CGPoint(x: r * 0.5, y: r * 0.75))
        c.addQuadCurve(to: CGPoint(x: r, y: r * 1.3), control: CGPoint(x: r, y: r * 0.8))
        c.strokePath()
        c.setFillColor((sparkOn ? NSColor.systemYellow : NSColor.systemOrange).cgColor)
        c.fillEllipse(in: CGRect(x: r - 2, y: r * 1.3 - 2, width: 4, height: 4))
        c.restoreGState()
    }

    /// Flat look: a small penknife (silver blade, red handle), pointing right from the origin.
    private func drawKnife(_ c: CGContext) {
        c.setFillColor(NSColor(white: 0.9, alpha: 1).cgColor)
        c.move(to: CGPoint(x: 6, y: 0)); c.addLine(to: CGPoint(x: -4, y: 2.5)); c.addLine(to: CGPoint(x: -4, y: -1))
        c.closePath(); c.fillPath()
        c.setFillColor(NSColor.systemRed.cgColor)
        c.fill(CGRect(x: -10, y: -1.2, width: 6, height: 3.4))
    }

    // MARK: Layers

    /// A sprite for the current style, drawn once with the same CoreGraphics code as before,
    /// centered in a square of `r + spritePad` each side.
    private func sprite(_ key: SpriteKey, draw: (CGContext) -> Void) -> CGImage? {
        if let image = sprites[key] { return image }
        let half = key.r + Self.spritePad, px = Int((half * 2 * scale).rounded(.up))
        guard let c = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                space: Self.sRGB ?? CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        c.scaleBy(x: scale, y: scale)
        c.translateBy(x: half, y: half)
        draw(c)
        let image = c.makeImage()
        sprites[key] = image
        return image
    }

    private func ensureLayers() {
        guard !layersReady, let root = layer else { return }
        layersReady = true
        field.masksToBounds = true
        for sub in [flashLayer, halfGroup, thingGroup, dropGroup, trailGroup, knifeLayer, floaterGroup] { field.addSublayer(sub) }
        flashLayer.backgroundColor = NSColor.systemRed.cgColor
        flashLayer.opacity = 0
        knifeLayer.isHidden = true
        knifeLayer.contentsScale = scale
        overlay.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        overlay.isHidden = true
        overlayText.contentsScale = scale
        overlay.addSublayer(overlayText)
        root.addSublayer(field)
        root.addSublayer(overlay)
        layoutLayers()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard layersReady else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutLayers()
        CATransaction.commit()
    }

    private func layoutLayers() {
        let rect = fieldRect
        for sub in [field, flashLayer, halfGroup, thingGroup, dropGroup, trailGroup, floaterGroup] {
            sub.bounds = rect
            sub.position = CGPoint(x: rect.midX, y: rect.midY)
        }
        overlay.frame = CGRect(x: fieldMinX, y: 0, width: fieldMaxX - fieldMinX, height: height)
        overlayString = nil // re-center the text
    }

    /// Shows `count` layers of a pool, adding more as needed (they are never freed mid-game).
    private func pool<L: CALayer>(_ pool: inout [L], _ count: Int, in group: CALayer, make: () -> L) {
        while pool.count < count {
            let sub = make()
            group.addSublayer(sub)
            pool.append(sub)
        }
        for (index, sub) in pool.enumerated() where sub.isHidden != (index >= count) { sub.isHidden = index >= count }
    }

    private func spriteLayer() -> CALayer {
        let sub = CALayer()
        sub.contentsScale = scale
        return sub
    }

    private func place(_ sub: CALayer, _ image: CGImage?, at p: CGPoint, angle: CGFloat, r: CGFloat) {
        if (sub.contents as AnyObject?) !== image { sub.contents = image }
        let side = (r + Self.spritePad) * 2
        if sub.bounds.width != side { sub.bounds = CGRect(x: 0, y: 0, width: side, height: side) }
        sub.position = p
        sub.setAffineTransform(CGAffineTransform(rotationAngle: angle))
    }

    /// Moves the layers to the current state; no drawing happens here once the sprites exist.
    private func render(now: CFTimeInterval) {
        let empty = things.isEmpty && halves.isEmpty && drops.isEmpty && floaters.isEmpty && trail.isEmpty && flash == 0
        if empty && renderedEmpty && layersReady && overlay.isHidden == (gameOverAt == nil) { return }
        renderedEmpty = empty
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        ensureLayers()
        flashLayer.opacity = flash > 0 && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? Float(flash * 0.35) : 0

        pool(&halfLayers, halves.count, in: halfGroup, make: spriteLayer)
        for (h, sub) in zip(halves, halfLayers) {
            let image = sprite(SpriteKey(kind: h.kind, r: h.r, part: h.side > 0 ? 1 : -1)) { c in
                var still = h
                still.p = .zero
                still.angle = 0
                drawHalf(c, still)
            }
            place(sub, image, at: h.p, angle: h.angle, r: h.r)
            sub.opacity = Float(min(1, h.life * 1.5))
        }

        pool(&thingLayers, things.count, in: thingGroup, make: spriteLayer)
        let spark = Int(now * 12) % 2 == 0
        for (t, sub) in zip(things, thingLayers) {
            if t.bomb {
                let image = sprite(SpriteKey(kind: 0, r: t.r, part: spark ? 3 : 2)) { drawBomb($0, r: t.r, spark: spark) }
                place(sub, image, at: t.p, angle: 0, r: t.r)
            } else {
                let image = sprite(SpriteKey(kind: t.kind, r: t.r, part: 0)) { drawFruit($0, kind: t.kind, at: .zero, r: t.r, angle: 0) }
                place(sub, image, at: t.p, angle: t.angle, r: t.r)
            }
        }

        pool(&dropLayers, drops.count, in: dropGroup) {
            let sub = CALayer()
            sub.bounds = CGRect(x: 0, y: 0, width: 2.6, height: 2.6)
            sub.cornerRadius = 1.3
            return sub
        }
        for (d, sub) in zip(drops, dropLayers) {
            sub.position = d.p
            sub.backgroundColor = d.color
            sub.opacity = Float(max(0, d.life))
        }

        renderTrail(now: now)

        pool(&floaterLayers, floaters.count, in: floaterGroup) {
            let sub = CATextLayer()
            sub.contentsScale = scale
            sub.anchorPoint = .zero
            return sub
        }
        for (f, sub) in zip(floaters, floaterLayers) {
            if sub.name != f.text { // text is laid out only when a layer gets a new combo
                sub.name = f.text
                let text = NSAttributedString(string: f.text, attributes: [.font: Self.comboFont, .foregroundColor: NSColor.systemYellow])
                sub.string = text
                let size = text.size()
                sub.bounds = CGRect(x: 0, y: 0, width: ceil(size.width), height: ceil(size.height))
            }
            sub.position = CGPoint(x: f.p.x - 20, y: 8 + (1 - f.life) * 8)
            sub.opacity = Float(f.life)
        }

        renderOverlay()
    }

    /// One shape layer per segment, as the old per-segment strokes. The glow is a layer shadow
    /// with an explicit path, so it needs no offscreen pass.
    private func renderTrail(now: CFTimeInterval) {
        let segments = max(0, trail.count - 1)
        pool(&trailLayers, segments, in: trailGroup) {
            let sub = CAShapeLayer()
            sub.lineCap = .round
            sub.fillColor = nil
            sub.shadowOffset = .zero
            sub.contentsScale = scale
            return sub
        }
        for i in 0..<segments {
            let sub = trailLayers[i]
            let (a, ta) = trail[i], (b, _) = trail[i + 1]
            let k = max(0, CGFloat(1 - (now - ta) / 0.16))
            let width = max(0.5, k * 4)
            let path = CGMutablePath()
            path.move(to: a)
            path.addLine(to: b)
            sub.path = path
            switch style {
            case .glossy:
                sub.strokeColor = NSColor.white.withAlphaComponent(k).cgColor
                sub.lineWidth = width
                sub.shadowColor = NSColor.white.cgColor
                sub.shadowRadius = 2.5
                sub.shadowOpacity = Float(k)
            case .flat:
                sub.strokeColor = NSColor(white: 0.85, alpha: k).cgColor
                sub.lineWidth = width * 0.6
                sub.shadowOpacity = 0
            case .neon:
                let hue = (CGFloat(i + 1) / CGFloat(trail.count) + CGFloat(now * 0.5)).truncatingRemainder(dividingBy: 1)
                sub.strokeColor = NSColor(hue: hue, saturation: 0.8, brightness: 1, alpha: k).cgColor
                sub.lineWidth = width
                sub.shadowColor = NSColor(hue: hue, saturation: 1, brightness: 1, alpha: 1).cgColor
                sub.shadowRadius = 3
                sub.shadowOpacity = Float(k)
            }
            sub.shadowPath = sub.shadowOpacity > 0
                ? path.copy(strokingWithWidth: sub.lineWidth, lineCap: .round, lineJoin: .round, miterLimit: 10) : nil
        }
        if style == .flat, segments > 0, let tip = trail.last?.0 {
            let previous = trail[trail.count - 2].0
            let image = sprite(SpriteKey(kind: 0, r: 4, part: 4)) { drawKnife($0) }
            place(knifeLayer, image, at: tip, angle: atan2(tip.y - previous.y, tip.x - previous.x), r: 4)
            knifeLayer.isHidden = false
        } else if !knifeLayer.isHidden {
            knifeLayer.isHidden = true
        }
    }

    private func gameOverText(withHint: Bool) -> String {
        let star = newRecord ? " ★" : ""
        let result = String(localized: "Game over · \(score) points · Best \(best)") + star
        return withHint ? result + "   —   " + String(localized: "Tap to play again") : result
    }

    private func renderOverlay() {
        guard gameOverAt != nil else {
            if !overlay.isHidden { overlay.isHidden = true }
            overlayString = nil
            return
        }
        overlay.isHidden = false
        let string = gameOverText(withHint: true)
        guard string != overlayString else { return }
        overlayString = string
        let text = NSAttributedString(string: string, attributes: Self.gameOverAttributes)
        let size = text.size()
        overlayText.string = text
        overlayText.frame = CGRect(x: ((overlay.bounds.width - size.width) / 2).rounded(), y: ((overlay.bounds.height - size.height) / 2).rounded(),
                                   width: ceil(size.width), height: ceil(size.height))
    }
}

import AppKit

/// How the Touch Bar icons are colored; tapping the battery moves to the next one (R-1).
enum BarColorMode: Int, CaseIterable {
    case own, white, rainbow

    var next: BarColorMode { BarColorMode(rawValue: (rawValue + 1) % BarColorMode.allCases.count) ?? .own }
}

/// One Touch Bar button: an SF Symbol in the item's color and an optional text.
final class BarButton: NSButton {
    let itemID: String
    let ownColor: NSColor
    var onPress: ((BarButton) -> Void)?
    /// Color used right now (depends on the color mode); sliders take it for their track.
    private(set) var tint: NSColor
    private var textColor: NSColor = .white
    private var symbol: String?
    private var text = ""

    init(itemID: String, color: NSColor) {
        self.itemID = itemID
        ownColor = color
        tint = color
        super.init(frame: .zero)
        title = ""
        bezelStyle = .push
        imageHugsTitle = true
        target = self
        action = #selector(pressed)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func pressed() { onPress?(self) }

    /// Updates what the button shows. `label` is what VoiceOver reads (R-19).
    func show(symbol: String?, text: String = "", label: String) {
        guard symbol != self.symbol || text != self.text || label != accessibilityLabel() else { return }
        self.symbol = symbol
        self.text = text
        setAccessibilityLabel(label)
        render()
    }

    func setTint(_ color: NSColor, colorText: Bool) {
        tint = color
        textColor = colorText ? color : .white
        render()
    }

    private func render() {
        attributedTitle = NSAttributedString(string: text, attributes: [
            .foregroundColor: textColor,
            .font: NSFont.systemFont(ofSize: 15),
        ])
        if let symbol, let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
            image = base.withSymbolConfiguration(config)
            imagePosition = text.isEmpty ? .imageOnly : .imageLeading
        } else {
            image = nil
            imagePosition = .noImage
        }
    }
}

/// The whole bar: equal-width buttons and, on top, the slider panel when one is open.
final class BarView: NSView {
    private let stack = NSStackView()
    private(set) var buttons: [BarButton] = []
    private var panel: SliderPanel?

    var colorMode: BarColorMode = .own {
        didSet { applyColors() }
    }

    init(width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 30))
        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 6
        stack.detachesHiddenViews = false // hidden buttons keep their place
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setButtons(_ newButtons: [BarButton]) {
        closeSlider()
        buttons.forEach { $0.removeFromSuperview() }
        buttons = newButtons
        newButtons.forEach { stack.addArrangedSubview($0) }
        applyColors()
    }

    func button(_ id: String) -> BarButton? {
        buttons.first { $0.itemID == id }
    }

    private func applyColors() {
        let count = max(buttons.count - 1, 1)
        for (index, button) in buttons.enumerated() {
            switch colorMode {
            case .own: button.setTint(button.ownColor, colorText: false)
            case .white: button.setTint(.white, colorText: false)
            case .rainbow:
                // Red to violet, left to right, texts included.
                let hue = CGFloat(index) / CGFloat(count) * 0.83
                button.setTint(NSColor(hue: hue, saturation: 0.75, brightness: 1, alpha: 1), colorText: true)
            }
        }
    }

    // MARK: Slider

    /// Opens a slider from `button`: rightwards from the left half, leftwards from the right half.
    /// The close ✕ takes the button's place, so tapping the same spot again closes it.
    func openSlider(from button: BarButton, control: LevelControl, label: String, autoClose: Bool) {
        closeSlider()
        let opensRight = button.frame.midX < bounds.midX
        let panel = SliderPanel(control: control, tint: button.tint, label: label,
                                closeOnRight: !opensRight, autoClose: autoClose)
        panel.onClose = { [weak self] in self?.closeSlider() }
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)
        let width = min(button.frame.width + 300, bounds.width)
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: topAnchor),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor),
            panel.widthAnchor.constraint(equalToConstant: width),
            opensRight ? panel.leadingAnchor.constraint(equalTo: button.leadingAnchor)
                       : panel.trailingAnchor.constraint(equalTo: button.trailingAnchor),
        ])
        self.panel = panel
        // Only the slider stays on the bar while it is open.
        setButtonsHidden(true)
        NSAccessibility.post(element: panel.slider, notification: .layoutChanged)
    }

    func closeSlider() {
        guard let panel else { return }
        panel.invalidate()
        panel.removeFromSuperview()
        self.panel = nil
        setButtonsHidden(false)
    }

    private func setButtonsHidden(_ hidden: Bool) {
        buttons.forEach { $0.isHidden = hidden }
    }

    // MARK: Easter egg

    private var easterEgg: EasterEggView?

    /// Long press on the time: "Hello Penknife!" handwritten, then slashed by a penknife.
    func playEasterEgg() {
        guard easterEgg == nil else { return }
        closeSlider()
        let egg = EasterEggView(frame: bounds)
        egg.autoresizingMask = [.width, .height]
        egg.onFinish = { [weak self] in self?.endEasterEgg() }
        addSubview(egg)
        easterEgg = egg
        stack.isHidden = true
        egg.play()
    }

    /// The buttons come back with a short fade (none with Reduce Motion).
    private func endEasterEgg() {
        easterEgg?.removeFromSuperview()
        easterEgg = nil
        stack.isHidden = false
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        stack.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            stack.animator().alphaValue = 1
        }
    }
}

/// The easter egg: "Hello Penknife!" is handwritten in calligraphy, then a penknife slashes it
/// and the two halves fall apart. With Reduce Motion the text just shows for a moment.
/// A tap ends it at any time.
final class EasterEggView: NSView {
    var onFinish: (() -> Void)?
    private var timer: Timer?

    private static let writeTime: CFTimeInterval = 3.6
    private static let holdTime: CFTimeInterval = 0.5
    private static let slashTime: CFTimeInterval = 0.45
    private static let splitTime: CFTimeInterval = 0.7

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        allowedTouchTypes = .direct
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func touchesBegan(with event: NSEvent) { finish() }
    override func mouseDown(with event: NSEvent) { finish() }

    func play() {
        guard let root = layer else { return }
        let text = "Hello Penknife!"
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        let path = Self.textPath(text, fitting: bounds)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        if reduceMotion {
            root.addSublayer(Self.writing(path, animated: false))
            schedule(after: 2.5)
            return
        }

        let now = CACurrentMediaTime()
        let slashStart = now + Self.writeTime + Self.holdTime
        let splitStart = slashStart + Self.slashTime

        // The cut: a slightly tilted line across the text.
        let from = CGPoint(x: path.boundingBox.minX - 20, y: bounds.height * 0.72)
        let to = CGPoint(x: path.boundingBox.maxX + 20, y: bounds.height * 0.3)

        // Two copies of the text, each clipped to one side of the cut, drift apart after it.
        for upper in [true, false] {
            let half = CALayer()
            half.frame = bounds
            half.addSublayer(Self.writing(path, animated: true, start: now))
            let mask = CAShapeLayer()
            mask.path = Self.side(of: from, to, upper: upper, in: bounds)
            half.mask = mask
            root.addSublayer(half)

            let move = CABasicAnimation(keyPath: "transform")
            var transform = CATransform3DMakeTranslation(upper ? -6 : 6, upper ? 9 : -9, 0)
            transform = CATransform3DRotate(transform, upper ? 0.04 : -0.04, 0, 0, 1)
            move.toValue = transform
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.toValue = 0
            let group = CAAnimationGroup()
            group.animations = [move, fade]
            group.beginTime = splitStart
            group.duration = Self.splitTime
            group.timingFunction = CAMediaTimingFunction(name: .easeIn)
            group.fillMode = .forwards
            group.isRemovedOnCompletion = false
            half.add(group, forKey: "split")
        }

        // The slash mark the blade leaves.
        let cut = CAShapeLayer()
        let line = CGMutablePath()
        line.move(to: to) // cut right to left: the knife ends writing on the right
        line.addLine(to: from)
        cut.path = line
        cut.strokeColor = NSColor.white.cgColor
        cut.lineWidth = 1.5
        cut.lineCap = .round
        cut.shadowColor = NSColor.white.cgColor
        cut.shadowRadius = 3
        cut.shadowOpacity = 1
        cut.shadowOffset = .zero
        cut.strokeEnd = 0
        root.addSublayer(cut)
        let draw = CABasicAnimation(keyPath: "strokeEnd")
        draw.fromValue = 0
        draw.toValue = 1
        draw.beginTime = slashStart
        draw.duration = Self.slashTime
        draw.timingFunction = CAMediaTimingFunction(name: .easeIn)
        draw.fillMode = .forwards
        draw.isRemovedOnCompletion = false
        cut.add(draw, forKey: "draw")
        let vanish = CABasicAnimation(keyPath: "opacity")
        vanish.fromValue = 1
        vanish.toValue = 0
        vanish.beginTime = splitStart
        vanish.duration = Self.splitTime
        vanish.fillMode = .forwards
        vanish.isRemovedOnCompletion = false
        cut.add(vanish, forKey: "vanish")

        // The same penknife writes the text (its tip follows the ink) and then cuts it.
        let knife = Self.penknife()
        knife.anchorPoint = CGPoint(x: 1, y: 0.5) // the tip
        let pen = CATransform3DScale(CATransform3DMakeRotation(-.pi * 0.72, 0, 0, 1), 0.75, 0.75, 1)
        let cutAngle = atan2(from.y - to.y, from.x - to.x) // pointing left along the cut
        let blade = CATransform3DMakeRotation(cutAngle, 0, 0, 1)
        let along = { (x: CGFloat) in CGPoint(x: x, y: to.y + tan(cutAngle) * (x - to.x)) }
        knife.transform = blade
        knife.position = along(-80) // where it ends, off the bar
        root.addSublayer(knife)

        let writeEnd = now + Self.writeTime * 0.8
        let write = CAKeyframeAnimation(keyPath: "position")
        // The tip glides along a smoothed copy of the ink's path, sampled by length so it
        // stays with the ink (traced at a constant pace) without jerking around each outline.
        let points = Self.smoothed(Self.samples(of: path, count: 240), radius: 8)
        write.values = points.map { NSValue(point: $0) }
        write.calculationMode = .cubic
        write.beginTime = now
        write.duration = Self.writeTime * 0.8
        write.fillMode = .backwards
        knife.add(write, forKey: "write")
        let hold = CABasicAnimation(keyPath: "transform")
        hold.fromValue = pen
        hold.toValue = pen
        hold.beginTime = now
        hold.duration = Self.writeTime * 0.8
        hold.fillMode = .backwards
        knife.add(hold, forKey: "pen")

        // From the last stroke to the right end of the cut, turning the blade to the left.
        let endOfText = points.last ?? path.currentPoint
        let moveTime = slashStart - writeEnd
        let move = CABasicAnimation(keyPath: "position")
        move.fromValue = NSValue(point: endOfText)
        move.toValue = NSValue(point: along(to.x + 10))
        let turn = CABasicAnimation(keyPath: "transform")
        turn.fromValue = pen
        turn.toValue = blade
        for animation in [move, turn] {
            animation.beginTime = writeEnd
            animation.duration = moveTime
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animation.fillMode = .forwards
            animation.isRemovedOnCompletion = false
        }
        knife.add(move, forKey: "move")
        knife.add(turn, forKey: "turn")

        let slash = CABasicAnimation(keyPath: "position")
        slash.fromValue = NSValue(point: along(to.x + 10))
        slash.toValue = NSValue(point: along(-80))
        slash.beginTime = slashStart
        slash.duration = Self.slashTime + 0.3
        slash.timingFunction = CAMediaTimingFunction(name: .easeIn)
        slash.fillMode = .forwards
        slash.isRemovedOnCompletion = false
        knife.add(slash, forKey: "slash")

        schedule(after: Self.writeTime + Self.holdTime + Self.slashTime + Self.splitTime)
    }

    private func schedule(after seconds: TimeInterval) {
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish() }
        }
    }

    private func finish() {
        timer?.invalidate()
        timer = nil
        let done = onFinish
        onFinish = nil
        done?()
    }

    /// A small pocket knife pointing right: red handle with two rivets, silver blade.
    private static func penknife() -> CALayer {
        let knife = CALayer()
        knife.bounds = CGRect(x: 0, y: 0, width: 46, height: 10)

        let handle = CAShapeLayer()
        handle.path = CGPath(roundedRect: CGRect(x: 0, y: 1, width: 20, height: 8), cornerWidth: 4, cornerHeight: 4, transform: nil)
        handle.fillColor = NSColor(srgbRed: 0.84, green: 0.16, blue: 0.16, alpha: 1).cgColor
        knife.addSublayer(handle)
        for x in [6.0, 14.0] {
            let rivet = CAShapeLayer()
            rivet.path = CGPath(ellipseIn: CGRect(x: x - 1.2, y: 3.8, width: 2.4, height: 2.4), transform: nil)
            rivet.fillColor = NSColor(white: 0.85, alpha: 1).cgColor
            knife.addSublayer(rivet)
        }

        let blade = CAShapeLayer()
        let shape = CGMutablePath()
        shape.move(to: CGPoint(x: 19, y: 8.5))                          // spine
        shape.addLine(to: CGPoint(x: 38, y: 8.5))
        shape.addQuadCurve(to: CGPoint(x: 46, y: 5), control: CGPoint(x: 43, y: 8.5)) // tip
        shape.addQuadCurve(to: CGPoint(x: 19, y: 2), control: CGPoint(x: 36, y: 1))   // edge
        shape.closeSubpath()
        blade.path = shape
        blade.fillColor = NSColor(white: 0.82, alpha: 1).cgColor
        blade.strokeColor = NSColor.white.cgColor
        blade.lineWidth = 0.6
        knife.insertSublayer(blade, at: 0)
        return knife
    }

    /// The text written by hand: the outline is traced first, then the ink fills in.
    private static func writing(_ path: CGPath, animated: Bool, start: CFTimeInterval = 0) -> CAShapeLayer {
        let ink = CAShapeLayer()
        ink.path = path
        ink.strokeColor = NSColor.white.cgColor
        ink.fillColor = NSColor.white.cgColor
        ink.lineWidth = 0.6
        ink.lineJoin = .round
        guard animated else { return ink }

        let trace = CABasicAnimation(keyPath: "strokeEnd")
        trace.fromValue = 0
        trace.toValue = 1
        trace.beginTime = start
        trace.duration = writeTime * 0.8
        trace.timingFunction = CAMediaTimingFunction(name: .linear) // the knife follows at this pace
        trace.fillMode = .backwards
        ink.add(trace, forKey: "trace")

        let fill = CABasicAnimation(keyPath: "fillColor")
        fill.fromValue = NSColor.clear.cgColor
        fill.toValue = NSColor.white.cgColor
        fill.beginTime = start + writeTime * 0.55
        fill.duration = writeTime * 0.45
        fill.fillMode = .backwards
        ink.add(fill, forKey: "fill")
        return ink
    }

    /// `count` points evenly spaced by length along `path` (jumps between letters count as zero
    /// length, like the ink's stroke).
    private static func samples(of path: CGPath, count: Int) -> [CGPoint] {
        var segments: [(CGPoint, CGPoint)] = []
        var current = CGPoint.zero
        var start = CGPoint.zero
        func line(to point: CGPoint) {
            segments.append((current, point))
            current = point
        }
        path.applyWithBlock { pointer in
            let element = pointer.pointee
            let p = element.points
            switch element.type {
            case .moveToPoint:
                current = p[0]
                start = p[0]
            case .addLineToPoint:
                line(to: p[0])
            case .addQuadCurveToPoint:
                let from = current
                for step in 1...8 {
                    let t = CGFloat(step) / 8, u = 1 - t
                    line(to: CGPoint(x: u * u * from.x + 2 * u * t * p[0].x + t * t * p[1].x,
                                     y: u * u * from.y + 2 * u * t * p[0].y + t * t * p[1].y))
                }
            case .addCurveToPoint:
                let from = current
                for step in 1...8 {
                    let t = CGFloat(step) / 8, u = 1 - t
                    let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
                    line(to: CGPoint(x: a * from.x + b * p[0].x + c * p[1].x + d * p[2].x,
                                     y: a * from.y + b * p[0].y + c * p[1].y + d * p[2].y))
                }
            case .closeSubpath:
                line(to: start)
            @unknown default:
                break
            }
        }
        let lengths = segments.map { hypot($0.1.x - $0.0.x, $0.1.y - $0.0.y) }
        let total = lengths.reduce(0, +)
        guard total > 0, let first = segments.first else { return [path.currentPoint] }
        var result: [CGPoint] = []
        var index = 0
        var walked: CGFloat = 0
        for sample in 0..<count {
            let target = total * CGFloat(sample) / CGFloat(count - 1)
            while index < segments.count - 1, walked + lengths[index] < target {
                walked += lengths[index]
                index += 1
            }
            let (a, b) = index < segments.count ? segments[index] : (first.0, first.0)
            let t = lengths[index] > 0 ? min(max((target - walked) / lengths[index], 0), 1) : 0
            result.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
        }
        return result
    }

    /// Moving average over `radius` neighbors on each side: a calm hand instead of a jittery one.
    private static func smoothed(_ points: [CGPoint], radius: Int) -> [CGPoint] {
        points.indices.map { index in
            let range = max(index - radius, 0)...min(index + radius, points.count - 1)
            let sum = range.reduce(CGPoint.zero) { CGPoint(x: $0.x + points[$1].x, y: $0.y + points[$1].y) }
            let n = CGFloat(range.count)
            return CGPoint(x: sum.x / n, y: sum.y / n)
        }
    }

    /// Glyph outlines of `text` in a calligraphic script, centered in `rect`.
    private static func textPath(_ text: String, fitting rect: CGRect) -> CGPath {
        let font = NSFont(name: "SnellRoundhand-Black", size: 26)
            ?? NSFont(name: "SnellRoundhand-Bold", size: 26)
            ?? NSFont(name: "Apple Chancery", size: 24)
            ?? NSFont.systemFont(ofSize: 22)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        let path = CGMutablePath()
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let count = CTRunGetGlyphCount(run)
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let runFont = attributes[kCTFontAttributeName] as! CTFont
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            for index in 0..<count {
                guard let glyph = CTFontCreatePathForGlyph(runFont, glyphs[index], nil) else { continue }
                path.addPath(glyph, transform: CGAffineTransform(translationX: positions[index].x, y: positions[index].y))
            }
        }
        let box = path.boundingBoxOfPath
        var center = CGAffineTransform(translationX: rect.midX - box.midX, y: rect.midY - box.midY)
        return path.copy(using: &center) ?? path
    }

    /// The part of `rect` above (or below) the line through `a` and `b`.
    private static func side(of a: CGPoint, _ b: CGPoint, upper: Bool, in rect: CGRect) -> CGPath {
        let slope = (b.y - a.y) / (b.x - a.x)
        let left = CGPoint(x: rect.minX - 50, y: a.y + slope * (rect.minX - 50 - a.x))
        let right = CGPoint(x: rect.maxX + 50, y: a.y + slope * (rect.maxX + 50 - a.x))
        let edge = upper ? rect.maxY + 50 : rect.minY - 50
        let path = CGMutablePath()
        path.addLines(between: [left, right, CGPoint(x: right.x, y: edge), CGPoint(x: left.x, y: edge)])
        path.closeSubpath()
        return path
    }
}


/// Slider and ✕ as one gray element, full bar height (R-1).
final class SliderPanel: NSView {
    let slider: NSSlider
    var onClose: (() -> Void)?
    private let control: LevelControl
    private let autoClose: Bool
    private var closeTimer: Timer?

    init(control: LevelControl, tint: NSColor, label: String, closeOnRight: Bool, autoClose: Bool) {
        self.control = control
        self.autoClose = autoClose
        slider = NSSlider(value: Double(control.level ?? 0), minValue: 0, maxValue: 1, target: nil, action: nil)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.28, alpha: 1).cgColor
        layer?.cornerRadius = 6

        let cell = TintedSliderCell()
        cell.tint = tint
        cell.onTrackingEnded = { [weak self] in self?.scheduleClose(after: 0.4) }
        slider.cell = cell
        slider.minValue = 0
        slider.maxValue = 1
        slider.doubleValue = Double(control.level ?? 0)
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(changed)
        slider.setAccessibilityLabel(label)

        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: String(localized: "Close"))!,
                             target: self, action: #selector(closePressed))
        close.isBordered = false
        close.contentTintColor = .white
        close.setAccessibilityLabel(String(localized: "Close"))

        for view in [slider, close] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            slider.centerYAnchor.constraint(equalTo: centerYAnchor),
            close.centerYAnchor.constraint(equalTo: centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 44),
            close.heightAnchor.constraint(equalTo: heightAnchor),
        ])
        if closeOnRight {
            NSLayoutConstraint.activate([
                slider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
                close.leadingAnchor.constraint(equalTo: slider.trailingAnchor, constant: 8),
                close.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
        } else {
            NSLayoutConstraint.activate([
                close.leadingAnchor.constraint(equalTo: leadingAnchor),
                slider.leadingAnchor.constraint(equalTo: close.trailingAnchor, constant: 8),
                slider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            ])
        }
        scheduleClose(after: 4)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func changed() {
        control.setLevel(Float(slider.doubleValue))
        // Touches don't always report the end of tracking, so after the last change it closes
        // soon anyway; untouched, it waits the full idle time.
        scheduleClose(after: 1)
    }

    @objc private func closePressed() { onClose?() }

    /// Without auto-close (R-19 setting) only the ✕ closes the slider.
    private func scheduleClose(after seconds: TimeInterval) {
        closeTimer?.invalidate()
        guard autoClose else { return }
        closeTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.onClose?() }
        }
    }

    func invalidate() {
        closeTimer?.invalidate()
        closeTimer = nil
    }
}

/// Track tinted with the item's color and a round white knob.
final class TintedSliderCell: NSSliderCell {
    var tint: NSColor = .white
    var onTrackingEnded: (() -> Void)?

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let track = NSRect(x: rect.minX, y: rect.midY - 2, width: rect.width, height: 4)
        NSColor(white: 0.5, alpha: 1).setFill()
        NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
        let fraction = CGFloat((doubleValue - minValue) / max(maxValue - minValue, 0.0001))
        var filled = track
        filled.size.width = track.width * fraction
        tint.setFill()
        NSBezierPath(roundedRect: filled, xRadius: 2, yRadius: 2).fill()
    }

    override func drawKnob(_ knobRect: NSRect) {
        let size = min(knobRect.height, 24)
        let rect = NSRect(x: knobRect.midX - size / 2, y: knobRect.midY - size / 2, width: size, height: size)
        NSColor.white.setFill()
        NSBezierPath(ovalIn: rect).fill()
    }

    override func stopTracking(last lastPoint: NSPoint, current stopPoint: NSPoint, in controlView: NSView, mouseIsUp flag: Bool) {
        super.stopTracking(last: lastPoint, current: stopPoint, in: controlView, mouseIsUp: flag)
        onTrackingEnded?()
    }
}

import AppKit
import AudioToolbox

/// How the Touch Bar icons are colored; a long press on the battery moves to the next one
/// (R-1, R-25). Raw values are stored: 0 was "own", 1 "white".
enum BarColorMode: Int, CaseIterable {
    case multicolor, monochrome, rainbow

    var next: BarColorMode { BarColorMode(rawValue: (rawValue + 1) % BarColorMode.allCases.count) ?? .multicolor }

    var title: String {
        switch self {
        case .multicolor: String(localized: "Multicolor")
        case .monochrome: String(localized: "Monochrome")
        case .rainbow: String(localized: "Rainbow")
        }
    }
}

/// The slicing game's short dry click (`TapClick.wav`, synthesized: a 240 Hz sine decaying in
/// 4 ms plus a 3 kHz transient, 45 ms). Silent when macOS "Play user interface sound effects" is
/// off. Touch Bar buttons no longer click: with "Hey Siri" on, any sound makes Siri unmute the
/// microphone for ~1 s and then restore it, undoing a mute change made meanwhile (2026-11-16).
enum GameSound {
    /// A system sound: decoded once, played by the system with minimal latency (NSSound took
    /// a noticeable moment to start).
    private static let sound: SystemSoundID? = {
        guard let url = Bundle.main.url(forResource: "TapClick", withExtension: "wav") else { return nil }
        var id: SystemSoundID = 0
        return AudioServicesCreateSystemSoundID(url as CFURL, &id) == noErr ? id : nil
    }()

    /// Loads the sound ahead of the first tap (the first play could be lost while it loads).
    static func prepare() { _ = sound }

    static func play() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "com.apple.sound.uiaudio.enabled") as? Bool ?? true,
              let sound else { return }
        AudioServicesPlaySystemSound(sound)
    }
}

/// Battery drawn like the menu bar's: dimmed outline, a fill as long as the charge, and a bolt
/// cut out of it while charging (SF Symbols only has fixed quarter steps).
enum BatteryIcon {
    static func image(fraction: CGFloat, charging: Bool, color: NSColor) -> NSImage {
        let size = NSSize(width: 27, height: 13)
        let image = NSImage(size: size, flipped: false) { _ in
            let body = NSRect(x: 0.6, y: 0.6, width: 23.4, height: 11.8)
            let outline = NSBezierPath(roundedRect: body, xRadius: 3.6, yRadius: 3.6)
            outline.lineWidth = 1.2
            color.withAlphaComponent(0.5).setStroke()
            outline.stroke()
            color.withAlphaComponent(0.5).setFill()
            NSBezierPath(roundedRect: NSRect(x: 25, y: 4.2, width: 1.6, height: 4.6), xRadius: 0.8, yRadius: 0.8).fill()

            let inner = body.insetBy(dx: 2, dy: 2)
            var fill = inner
            fill.size.width = max(inner.width * min(max(fraction, 0), 1), 2)
            color.setFill()
            NSBezierPath(roundedRect: fill, xRadius: 1.8, yRadius: 1.8).fill()

            if charging, let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .bold)) {
                let boltRect = NSRect(x: body.midX - bolt.size.width / 2, y: body.midY - bolt.size.height / 2,
                                      width: bolt.size.width, height: bolt.size.height)
                // A clear edge around the bolt, then the bolt in the icon's color.
                bolt.draw(in: boltRect.insetBy(dx: -1.5, dy: -1.5), from: .zero, operation: .destinationOut, fraction: 1)
                let tinted = NSImage(size: boltRect.size, flipped: false) { rect in
                    bolt.draw(in: rect)
                    color.setFill()
                    rect.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: boltRect)
            }
            return true
        }
        return image
    }
}

/// One Touch Bar button: an SF Symbol in the item's color and an optional text.
final class BarButton: NSButton {
    let itemID: String
    let ownColor: NSColor
    /// Replaces `ownColor` in multicolor mode when the state has a color (battery level).
    var stateColor: NSColor?
    var onPress: ((BarButton) -> Void)?
    /// Color used right now (depends on the color mode); sliders take it for their track.
    private(set) var tint: NSColor
    private var textColor: NSColor = .white
    private var symbol: String?
    private var text = ""
    private var unit = ""
    /// Unavailable (no microphone, O-1): the symbol at 35 % of its color.
    private var dimmed = false
    /// A drawn icon instead of a symbol (the battery), made in the current tint.
    private var drawing: ((NSColor) -> NSImage)?
    private var drawingKey = ""

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

    /// O-34: shows a hold's progress; `holdFired()` when the hold action runs.
    private var holdFill: HoldFill?
    func showsHold(_ seconds: CFTimeInterval?) {
        holdFill?.remove()
        holdFill = seconds.map { HoldFill(on: self, duration: $0) }
    }
    func holdFired() { holdFill?.fire() }

    /// O-34 b: the speed test's estimated progress.
    private lazy var testFill = TestFill(on: self)
    func showTest(running: Bool, succeeded: Bool = true) {
        running ? testFill.start() : testFill.finish(succeeded: succeeded)
    }

    /// Updates what the button shows. `label` is what VoiceOver reads (R-19). With `unit`, the text
    /// is a number with its unit in small type underneath (speed test, user's pick C, 2026-11-16).
    func show(symbol: String?, text: String = "", unit: String = "", dimmed: Bool = false, label: String) {
        // A label-only change (e.g. a new percentage under the same symbol) needs no redraw.
        if label != accessibilityLabel() { setAccessibilityLabel(label) }
        guard symbol != self.symbol || text != self.text || unit != self.unit || dimmed != self.dimmed
                || drawing != nil else { return }
        self.symbol = symbol
        self.text = text
        self.unit = unit
        self.dimmed = dimmed
        setAccessibilityEnabled(!dimmed)
        drawing = nil
        drawingKey = ""
        setAccessibilityLabel(label)
        render()
    }

    /// Shows a drawn icon. `key` identifies what it shows, so an unchanged state isn't redrawn.
    func show(drawing: @escaping (NSColor) -> NSImage, key: String, label: String) {
        if label != accessibilityLabel() { setAccessibilityLabel(label) }
        guard key != drawingKey else { return }
        symbol = nil
        text = ""
        self.drawing = drawing
        drawingKey = key
        setAccessibilityLabel(label)
        render()
    }

    func setTint(_ color: NSColor, colorText: Bool) {
        let newText = colorText ? color : .white
        guard color != tint || newText != textColor else { return }
        tint = color
        textColor = newText
        render()
    }

    /// Symbol, then the number (14 pt) over its unit (9 pt, 55 % opacity), centered as one image.
    private static func stacked(symbol: String?, number: String, unit: String, tint: NSColor, textColor: NSColor) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
        let icon = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil)?.withSymbolConfiguration(config) }
        let top = NSAttributedString(string: number, attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: textColor])
        let bottom = NSAttributedString(string: unit, attributes: [
            .font: NSFont.systemFont(ofSize: 9, weight: .medium), .foregroundColor: textColor.withAlphaComponent(0.55)])
        let textWidth = max(top.size().width, bottom.size().width)
        let gap: CGFloat = icon == nil ? 0 : 4
        let height: CGFloat = 26
        let size = NSSize(width: (icon?.size.width ?? 0) + gap + textWidth, height: height)
        return NSImage(size: size, flipped: true) { _ in
            var x: CGFloat = 0
            if let icon {
                icon.draw(in: NSRect(x: 0, y: (height - icon.size.height) / 2, width: icon.size.width, height: icon.size.height))
                x = icon.size.width + gap
            }
            top.draw(at: NSPoint(x: x + (textWidth - top.size().width) / 2, y: 0))
            bottom.draw(at: NSPoint(x: x + (textWidth - bottom.size().width) / 2, y: 16))
            return true
        }
    }

    private func render() {
        attributedTitle = NSAttributedString(string: text, attributes: [
            .foregroundColor: textColor,
            .font: NSFont.systemFont(ofSize: 15),
        ])
        if let drawing {
            image = drawing(tint)
            imagePosition = .imageOnly
        } else if !unit.isEmpty {
            attributedTitle = NSAttributedString(string: "")
            image = Self.stacked(symbol: symbol, number: text, unit: unit, tint: tint, textColor: textColor)
            imagePosition = .imageOnly
        } else if let symbol, let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [dimmed ? tint.withAlphaComponent(0.35) : tint]))
            image = base.withSymbolConfiguration(config)
            imagePosition = text.isEmpty ? .imageOnly : .imageLeading
        } else {
            image = nil
            imagePosition = .noImage
        }
    }
}

/// O-34: a hold's progress drawn on its button. A flat fill grows while the finger is down and is
/// full exactly when the hold action fires; lifting early empties it. Nothing runs at idle: one
/// Core Animation per hold, no timer (TB-61). Taps shorter than `delay` show nothing.
/// O-34: a flat fill drawn on a button, clipped to its rounded shape. `bar` grows inside the
/// clip with a straight leading edge (scaling a rounded layer squashed its corners: user,
/// 2026-11-22). One Core Animation at a time, no timer (TB-61).
final class ButtonFill {
    /// The button's own corner radius, measured on the Touch Bar (12 px at 2×, circular).
    private static let radius: CGFloat = 6
    private let clip = CALayer()
    private let bar = CALayer()
    private weak var host: NSView?
    private let alpha: CGFloat
    var isShown: Bool { !clip.isHidden }
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    init(on host: NSView, alpha: CGFloat) {
        self.host = host
        self.alpha = alpha
        host.wantsLayer = true
        let still: [String: CAAction] = ["bounds": NSNull(), "position": NSNull(), "opacity": NSNull(), "hidden": NSNull(),
                                         "backgroundColor": NSNull(), "cornerRadius": NSNull(), "frame": NSNull()]
        clip.actions = still
        bar.actions = still
        clip.masksToBounds = true
        clip.isHidden = true
        bar.anchorPoint = .zero
        clip.addSublayer(bar)
    }

    func remove() { clip.removeFromSuperlayer() }

    private var fullWidth: CGFloat { clip.bounds.width }
    var width: CGFloat { bar.presentation()?.bounds.width ?? bar.bounds.width }

    /// Shows an empty fill (or, with Reduce Motion, a still full tint) after `delay`.
    func show(delay: CFTimeInterval) {
        guard let host, let root = host.layer else { return }
        clip.removeAllAnimations()
        bar.removeAllAnimations()
        // The button draws its gray background in its own bezel subview, whose layer sits above
        // any sublayer added to the button: the fill goes right above that background and below
        // the icon (measured 2026-11-22: as the first sublayer it was hidden under the bezel).
        let bezel = host.subviews.first { String(describing: type(of: $0)).contains("Bezel") }?.layer
        if let bezel, bezel.superlayer === root {
            root.insertSublayer(clip, above: bezel)
        } else if clip.superlayer !== root {
            clip.zPosition = 1   // no bezel view found: above everything, still a light tint
            root.addSublayer(clip)
        }
        clip.frame = host.bounds
        clip.cornerRadius = Self.radius
        bar.backgroundColor = NSColor(white: 1, alpha: alpha).cgColor
        bar.position = .zero
        bar.bounds = CGRect(x: 0, y: 0, width: Self.reduceMotion ? fullWidth : 0, height: clip.bounds.height)
        clip.opacity = 1
        clip.isHidden = false
        guard delay > 0 else { return }
        let wait = CABasicAnimation(keyPath: "opacity")
        wait.fromValue = 0; wait.toValue = 0
        wait.beginTime = clip.convertTime(CACurrentMediaTime(), from: nil); wait.duration = delay
        clip.add(wait, forKey: "wait")
    }

    /// Grows to full: linear over `duration` after `delay`, or along `keyTimes`/`values` (0…1).
    func grow(after delay: CFTimeInterval, duration: CFTimeInterval, values: [CGFloat]? = nil) {
        guard !Self.reduceMotion else { return }
        let animation: CAPropertyAnimation
        if let values {
            let curve = CAKeyframeAnimation(keyPath: "bounds.size.width")
            curve.values = values.map { $0 * fullWidth }
            curve.calculationMode = .linear
            animation = curve
        } else {
            let line = CABasicAnimation(keyPath: "bounds.size.width")
            line.fromValue = 0
            line.toValue = fullWidth
            animation = line
        }
        animation.beginTime = bar.convertTime(CACurrentMediaTime(), from: nil) + delay
        animation.duration = max(duration, 0.05)
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        bar.add(animation, forKey: "grow")
    }

    /// Done: full at once, then fades in 0.15 s.
    func complete() {
        guard isShown else { return }
        let width = fullWidth
        bar.removeAllAnimations()
        bar.bounds.size.width = width
        clip.opacity = 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1; fade.toValue = 0; fade.duration = 0.15
        clip.add(fade, forKey: "fade")
    }

    /// Stopped early: empties in 0.15 s.
    func empty() {
        let current = width
        bar.removeAllAnimations()
        bar.bounds.size.width = 0
        guard current > 0, !Self.reduceMotion, isShown else { clip.isHidden = true; return }
        let back = CABasicAnimation(keyPath: "bounds.size.width")
        back.fromValue = current; back.toValue = 0; back.duration = 0.15
        bar.add(back, forKey: "back")
    }
}

/// A hold's progress (O-34 a): starts 0.15 s after the touch (taps show nothing) and is full
/// exactly when the hold fires; lifting early empties it.
final class HoldFill {
    static let delay: CFTimeInterval = 0.15
    private let fill: ButtonFill
    private weak var host: NSView?
    private let duration: CFTimeInterval
    private var fired = false
    private var watcher: NSGestureRecognizer?

    init(on host: NSView, duration: CFTimeInterval) {
        self.host = host
        self.duration = duration
        fill = ButtonFill(on: host, alpha: 0.22)
        let watcher = TouchWatcher(target: nil, action: nil)
        watcher.allowedTouchTypes = .direct
        watcher.onBegan = { [weak self] in self?.begin() }
        watcher.onEnded = { [weak self] in self?.end() }
        host.addGestureRecognizer(watcher)
        self.watcher = watcher
    }

    /// Takes the fill and its watcher off the button (the hold changed or went away).
    func remove() {
        fill.remove()
        if let watcher { host?.removeGestureRecognizer(watcher) }
    }

    private func begin() {
        fired = false
        fill.show(delay: Self.delay)
        fill.grow(after: Self.delay, duration: duration - Self.delay)
    }

    func fire() {
        guard !fired else { return }
        fired = true
        fill.complete()
    }

    private func end() {
        guard !fired else { return }
        fill.empty()
    }
}

/// The speed test's progress (O-34 b). networkQuality takes 16–56 s (measured 2026-11-22), so
/// the fill is an estimate: fast at first, slower and slower, never past 92 % until the test
/// really ends. Lighter (14 %) than a hold, so the two aren't confused.
final class TestFill {
    private let fill: ButtonFill
    /// 0.92 × (1 − e^(−t/20 s)), sampled every 5 s over 60 s: ~51 % at 16 s, ~83 % at 46 s.
    static let span: CFTimeInterval = 60
    static let values: [CGFloat] = stride(from: 0.0, through: span, by: 5).map { 0.92 * (1 - exp(-$0 / 20)) }

    init(on host: NSView) { fill = ButtonFill(on: host, alpha: 0.14) }

    func start() {
        guard !fill.isShown else { return }
        fill.show(delay: 0)
        fill.grow(after: 0, duration: Self.span, values: Self.values)
    }

    func finish(succeeded: Bool) {
        guard fill.isShown else { return }
        succeeded ? fill.complete() : fill.empty()
    }

    func remove() { fill.remove() }
}

/// Sees a finger go down and up on a view without ever recognizing, so the button's own tap and
/// the hold recognizers work as before.
private final class TouchWatcher: NSGestureRecognizer {
    var onBegan: (() -> Void)?
    var onEnded: (() -> Void)?
    override func touchesBegan(with event: NSEvent) { onBegan?() }
    override func touchesEnded(with event: NSEvent) { onEnded?(); state = .failed }
    override func touchesCancelled(with event: NSEvent) { onEnded?(); state = .failed }
    // Fails at the end of every touch so it never blocks the button; AppKit then resets it to
    // .possible for the next touch (an empty `reset()` override kept it failed: 2nd hold showed nothing).
    override func canPrevent(_ other: NSGestureRecognizer) -> Bool { false }
}

/// The whole bar: equal-width buttons and, on top, the slider panel when one is open.
final class BarView: NSView {
    private let stack = NSStackView()
    private(set) var buttons: [BarButton] = []
    private var panel: SliderPanel?
    var isSliderOpen: Bool { panel != nil }
    /// Called after a slider closes (the module re-reads the levels once).
    var onSliderClose: (() -> Void)?

    var colorMode: BarColorMode = .multicolor {
        didSet { applyColors() }
    }

    /// The single color of monochrome mode (Settings, R-25).
    var monochromeColor: NSColor = .white {
        didSet { if colorMode == .monochrome { applyColors() } }
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

    func applyColors() {
        for (index, button) in buttons.enumerated() {
            let tint = Self.tint(mode: colorMode, index: index, count: buttons.count,
                                 own: button.ownColor, state: button.stateColor, mono: monochromeColor)
            button.setTint(tint.color, colorText: tint.colorsText)
        }
    }

    /// The color of the button at `index` of `count` (TB-11): multicolor = the state's color
    /// (battery level) or the button's own, texts white; monochrome = one color, texts too;
    /// rainbow = red to violet from left to right, texts too.
    static func tint(mode: BarColorMode, index: Int, count: Int, own: NSColor, state: NSColor?,
                     mono: NSColor) -> (color: NSColor, colorsText: Bool) {
        switch mode {
        case .multicolor: return (state ?? own, false)
        case .monochrome: return (mono, true)
        case .rainbow:
            let hue = CGFloat(index) / CGFloat(max(count - 1, 1)) * 0.83
            return (NSColor(hue: hue, saturation: 0.75, brightness: 1, alpha: 1), true)
        }
    }

    // MARK: Slider

    /// Opens a slider from `button`: rightwards from the left half, leftwards from the right half.
    /// The close ✕ takes the button's place, so tapping the same spot again closes it.
    func openSlider(from button: BarButton, control: LevelControl, label: String, autoClose: Bool) {
        closeSlider()
        KeyboardBrightness.autoTurnedOff = false
        let placement = Self.sliderPlacement(buttonFrame: button.frame, barWidth: bounds.width)
        let opensRight = placement.opensRight
        let panel = SliderPanel(control: control, tint: button.tint, label: label,
                                closeOnRight: !opensRight, autoClose: autoClose)
        panel.onClose = { [weak self] in self?.closeSlider() }
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: topAnchor),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor),
            panel.widthAnchor.constraint(equalToConstant: placement.width),
            opensRight ? panel.leadingAnchor.constraint(equalTo: button.leadingAnchor)
                       : panel.trailingAnchor.constraint(equalTo: button.trailingAnchor),
        ])
        self.panel = panel
        // Only the slider stays on the bar while it is open.
        setButtonsHidden(true)
        NSAccessibility.post(element: panel.slider, notification: .layoutChanged)
    }

    /// TB-29: rightwards when the button's center is in the bar's left half, else leftwards; as
    /// wide as the button plus 300 pt, at most the bar.
    static func sliderPlacement(buttonFrame: CGRect, barWidth: CGFloat) -> (opensRight: Bool, width: CGFloat) {
        (buttonFrame.midX < barWidth / 2, min(buttonFrame.width + 300, barWidth))
    }

    func closeSlider() {
        guard let panel else { return }
        panel.invalidate()
        panel.removeFromSuperview()
        self.panel = nil
        setButtonsHidden(false)
        onSliderClose?()
    }

    private func setButtonsHidden(_ hidden: Bool) {
        buttons.forEach { $0.isHidden = hidden }
    }

    // MARK: Game (R-23)

    private var game: SliceGameView?
    var isGameOpen: Bool { game != nil }
    /// Called after the game closes.
    var onGameEnd: (() -> Void)?

    /// Hold on the jiggler button: the slicing game takes the whole bar.
    func playGame() {
        guard game == nil, easterEgg == nil else { return }
        closeSlider()
        let view = SliceGameView(frame: bounds)
        view.autoresizingMask = [.width, .height]
        view.onFinish = { [weak self] in self?.endGame() }
        addSubview(view)
        game = view
        stack.isHidden = true
        view.start()
        NSAccessibility.post(element: view, notification: .layoutChanged)
    }

    /// Closes the game if open (also when the bar hides, the screens sleep or the Mac locks).
    func closeGame() { game?.finish() }

    private func endGame() {
        game?.removeFromSuperview()
        game = nil
        stack.isHidden = false
        onGameEnd?()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        stack.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            stack.animator().alphaValue = 1
        }
    }

    // MARK: Easter egg

    private var easterEgg: EasterEggView?

    /// Long press on the time: "Hello Penknife!" handwritten, then slashed by a penknife.
    func playEasterEgg() {
        guard easterEgg == nil, game == nil else { return }
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
    let slider: LevelSlider
    var onClose: (() -> Void)?
    private let control: LevelControl
    private let autoClose: Bool
    private var closeTimer: Timer?

    init(control: LevelControl, tint: NSColor, label: String, closeOnRight: Bool, autoClose: Bool) {
        self.control = control
        self.autoClose = autoClose
        slider = LevelSlider(value: Double(control.level ?? 0), minValue: 0, maxValue: 1, target: nil, action: nil)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.28, alpha: 1).cgColor
        layer?.cornerRadius = 6

        let cell = TintedSliderCell()
        cell.tint = tint
        slider.cell = cell
        slider.onRelease = { [weak self] in self?.scheduleClose(after: .release) }
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
        scheduleClose(after: .open)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func changed() {
        control.setLevel(Float(slider.doubleValue))
        // Touches don't always report the end of tracking, so after the last change it closes
        // soon anyway; untouched, it waits the full idle time.
        scheduleClose(after: .change)
    }

    @objc private func closePressed() { onClose?() }

    enum CloseReason { case open, change, release }

    /// TB-31: 4 s after opening if untouched, 1 s after the last change, 0.4 s after the finger
    /// lifts. Without auto-close (R-19 setting) only the ✕ closes the slider.
    static func closeDelay(after reason: CloseReason, autoClose: Bool) -> TimeInterval? {
        guard autoClose else { return nil }
        return switch reason {
        case .open: 4
        case .change: 1
        case .release: 0.4
        }
    }

    private func scheduleClose(after reason: CloseReason) {
        closeTimer?.invalidate()
        guard let seconds = Self.closeDelay(after: reason, autoClose: autoClose) else { return }
        closeTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.onClose?() }
        }
    }

    func invalidate() {
        closeTimer?.invalidate()
        closeTimer = nil
    }
}

/// A level slider that follows the finger itself (B-12). AppKit's own tracking puts back the
/// starting value when the touch ends outside the slider, and stops following once the finger
/// passes its end; here the value is the finger's x clamped to the track and stays where the
/// finger lifts. Still an NSSlider, so VoiceOver and the accessibility actions are unchanged.
final class LevelSlider: NSSlider {
    var onRelease: (() -> Void)?

    /// TB-29/TB-32: the knob's center spans the width minus one knob; beyond either end clamps.
    nonisolated static func value(x: CGFloat, width: CGFloat, knob: CGFloat) -> Double {
        let span = width - knob
        guard span > 0 else { return 0 }
        return Double(min(max((x - knob / 2) / span, 0), 1))
    }

    private func follow(_ event: NSEvent) {
        guard let touch = event.touches(matching: .any, in: self).first else { return }
        let knob = (cell as? NSSliderCell)?.knobThickness ?? 0
        let value = Self.value(x: touch.location(in: self).x, width: bounds.width, knob: knob)
        guard value != doubleValue else { return }
        doubleValue = value
        sendAction(action, to: target)
    }

    override func touchesBegan(with event: NSEvent) { follow(event) }
    override func touchesMoved(with event: NSEvent) { follow(event) }
    override func touchesEnded(with event: NSEvent) { follow(event); onRelease?() }
    override func touchesCancelled(with event: NSEvent) { onRelease?() }
}

/// Track tinted with the item's color and a round white knob.
final class TintedSliderCell: NSSliderCell {
    var tint: NSColor = .white

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
}

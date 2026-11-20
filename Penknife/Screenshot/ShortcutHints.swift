import AppKit
import Observation
import SwiftUI

/// The key of every toolbar button, shown only when asked (user's pick A1 + A2, 2026-11-19,
/// SS-62): the pointer over a button shows its name and key at once, above it; holding ⌘ alone
/// shows the key above every button. Nothing is ever added under the toolbar, so it never grows.
/// Shared by the screenshot editor and the recording toolbar (one component, user: "el
/// componente debería ser el mismo").
@MainActor
@Observable
final class ShortcutHintModel {
    struct Item: Equatable {
        var name: String
        var key: String
        /// In the toolbar's own coordinates (top-left origin).
        var frame: CGRect
    }

    /// The coordinate space the buttons report their frames in: the toolbar's root view.
    nonisolated static let space = "shortcutHints"
    /// Room above the toolbar for the label and the key caps.
    static let headroom: CGFloat = 34
    /// The hints view is this much wider than the toolbar on each side (a label over the first
    /// or last button can stick out).
    static let overhang: CGFloat = 70
    /// ⌘ held alone this long shows the keys (a quick ⌘Z never flashes them).
    static let commandDelay: TimeInterval = 0.3

    var items: [String: Item] = [:]
    private(set) var hovered: String?
    private(set) var commandHeld = false
    @ObservationIgnored private var commandWork: DispatchWorkItem?

    /// The pointer in the toolbar (its coordinates, top-left origin), nil when it left.
    func hover(at point: CGPoint?) {
        let id = point.flatMap { Self.item(at: $0, in: items) }
        if id != hovered { hovered = id }
    }

    static func item(at point: CGPoint, in items: [String: Item]) -> String? {
        items.first { $0.value.frame.contains(point) }?.key
    }

    /// ⌘ alone and nothing else: the only modifier state that shows every key.
    static func isCommandAlone(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.intersection([.command, .shift, .option, .control]) == .command
    }

    func modifiersChanged(_ flags: NSEvent.ModifierFlags) {
        commandWork?.cancel()
        commandWork = nil
        guard Self.isCommandAlone(flags) else {
            if commandHeld { commandHeld = false }
            return
        }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.commandHeld = true }
        }
        commandWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.commandDelay, execute: work)
    }

    /// A key went down with ⌘ (⌘Z…): don't show the keys for this press.
    func keyPressed() {
        commandWork?.cancel()
        commandWork = nil
    }

    func reset() {
        keyPressed()
        hovered = nil
        commandHeld = false
    }
}

extension View {
    /// Registers a toolbar button with its name and key (SS-62). Without a model (the countdown
    /// capsule) the system tooltip "Name (key)" stays.
    func shortcut(_ id: String, name: String, key: String, in model: ShortcutHintModel?) -> some View {
        modifier(ShortcutItem(id: id, name: name, key: key, model: model))
    }
}

private struct ShortcutItem: ViewModifier {
    let id: String
    let name: String
    let key: String
    let model: ShortcutHintModel?

    func body(content: Content) -> some View {
        if let model {
            content
                .accessibilityCustomContent(Text("Shortcut"), Text(key))
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(ShortcutHintModel.space)) } action: { frame in
                    model.items[id] = .init(name: name, key: key, frame: frame)
                }
                .onChange(of: name) { model.items[id]?.name = name }
                .onChange(of: key) { model.items[id]?.key = key }
                .onDisappear { model.items[id] = nil }
        } else {
            content.help(key.isEmpty ? name : "\(name) (\(key))")
        }
    }
}

/// Drawn in its own view above the toolbar (it never takes the pointer): the hovered button's
/// label, or every key while ⌘ is held. Hidden from VoiceOver, which reads the buttons'
/// names and their "Shortcut" content.
struct ShortcutHints: View {
    let model: ShortcutHintModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topLeading) {
            if model.commandHeld {
                ForEach(model.items.sorted { $0.value.frame.minX < $1.value.frame.minX }, id: \.key) { _, item in
                    KeyCap(key: item.key)
                        .position(x: item.frame.midX + ShortcutHintModel.overhang, y: ShortcutHintModel.headroom - 14)
                }
                .transition(.opacity)
            } else if let id = model.hovered, let item = model.items[id] {
                HStack(spacing: 5) {
                    Text(item.name).font(.system(size: 12, weight: .medium))
                    KeyCap(key: item.key)
                }
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background {
                    if opaque {
                        Capsule().fill(Color(nsColor: .windowBackgroundColor))
                            .overlay(Capsule().strokeBorder(Color.primary.opacity(contrast == .increased ? 1 : 0.15)))
                    }
                }
                .glassEffect(opaque ? .identity : .regular, in: .capsule)
                .fixedSize()
                .position(x: item.frame.midX + ShortcutHintModel.overhang, y: ShortcutHintModel.headroom - 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: model.commandHeld)
        .accessibilityHidden(true)
    }

    private var opaque: Bool { reduceTransparency || contrast == .increased }
}

/// A key cap: "V", "⌘Z", "⇧⌫".
struct KeyCap: View {
    let key: String
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Text(key)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(contrast == .increased ? Color.primary : Color.secondary)
            .frame(minWidth: 16, minHeight: 16)
            .padding(.horizontal, 3)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(contrast == .increased ? 0.8 : 0.12)))
            .fixedSize()
    }
}

/// A toolbar's hosting view that follows the pointer itself (Penknife is never the active app
/// over a screenshot or a recording, so SwiftUI's hover can't be trusted) and tells the hints.
final class HintTrackingHostingView<Content: View>: NSHostingView<Content> {
    weak var hints: ShortcutHintModel?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if !trackingAreas.contains(where: { $0.owner === self && $0.userInfo?["hints"] != nil }) {
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                           owner: self, userInfo: ["hints": true]))
        }
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        hints?.hover(at: CGPoint(x: point.x, y: isFlipped ? point.y : bounds.height - point.y))
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hints?.hover(at: nil)
    }
}

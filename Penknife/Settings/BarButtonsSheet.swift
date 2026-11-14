import SwiftUI

/// "Buttons: Customize…" in the Touch Bar section (R-26).
struct BarButtonsRow: View {
    let manager: ModuleManager
    @State private var showing = false

    var body: some View {
        LabeledContent("Buttons") {
            Button("Customize…") { showing = true }
        }
        .sheet(isPresented: $showing) {
            BarButtonsSheet(manager: manager)
        }
    }
}

/// Which Touch Bar buttons show and in what order. Every change is saved at once, so the bar
/// updates while the sheet is open.
private struct BarButtonsSheet: View {
    let manager: ModuleManager
    @Environment(\.dismiss) private var dismiss
    @State private var order = BarLayout.order
    @State private var hidden = BarLayout.hidden

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Customize Touch Bar")
                .font(.headline)
            BarPreview(items: visible)
            BarButtonsList(order: $order, hidden: $hidden, isOn: isOn)
            Text("Drag to reorder. At least one button stays visible. Hiding a button doesn't turn its function off: it still works from the menu and its shortcut.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Restore Defaults") {
                    BarLayout.restoreDefaults()
                    withAnimation(.snappy(duration: 0.2)) {
                        order = BarLayout.order
                        hidden = BarLayout.hidden
                    }
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onChange(of: order) { BarLayout.save(order: order, hidden: hidden) }
        .onChange(of: hidden) { BarLayout.save(order: order, hidden: hidden) }
    }

    private func isOn(_ item: BarItem) -> Bool {
        item.module.map(manager.isEnabled) ?? true
    }

    private var visible: [BarItem] {
        order.filter { !hidden.contains($0) && isOn($0) }
    }
}

/// A small drawing of the bar with the buttons that will show.
private struct BarPreview: View {
    let items: [BarItem]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(items) { item in
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(white: 0.22))
                    .overlay {
                        Image(systemName: item.symbol)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color(nsColor: NSColor(hex: item.hex)))
                    }
                    .frame(height: 26)
            }
        }
        .padding(5)
        .background(RoundedRectangle(cornerRadius: 8).fill(.black))
        .frame(maxWidth: .infinity)
        .animation(.snappy(duration: 0.2), value: items)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Touch Bar preview: \(items.map(\.title).formatted(.list(type: .and)))"))
    }
}

/// The list of buttons. The system List drag didn't work for the user, so rows move with a
/// drag gesture of their own: the row lifts and the others make room.
private struct BarButtonsList: View {
    @Binding var order: [BarItem]
    @Binding var hidden: Set<BarItem>
    let isOn: (BarItem) -> Bool
    @State private var dragging: BarItem?
    @State private var startIndex = 0
    @State private var offset: CGFloat = 0
    private let rowHeight: CGFloat = 28
    /// Drags are measured in the list's space: in the row's own space the reference moves with
    /// the row, so a slow drag around half a row made it jump back and forth.
    private static let space = "barButtonsList"

    private var visibleCount: Int {
        order.filter { !hidden.contains($0) && isOn($0) }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(order.enumerated()), id: \.element) { index, item in
                row(item, index: index)
            }
        }
        .coordinateSpace(.named(Self.space))
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
    }

    private func row(_ item: BarItem, index: Int) -> some View {
        let moduleOn = isOn(item)
        let shown = !hidden.contains(item)
        let isLast = shown && moduleOn && visibleCount == 1
        let isDragged = dragging == item
        let color = item.hex == 0xFFFFFF ? Color.primary : Color(nsColor: NSColor(hex: item.hex))
        return HStack(spacing: 8) {
            Toggle(item.title, isOn: Binding(
                get: { shown },
                set: { show in
                    if show { hidden.remove(item) } else { hidden.insert(item) }
                }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(!moduleOn || isLast)
            .help(isLast ? String(localized: "At least one button must stay visible") : "")
            Image(systemName: item.symbol)
                .foregroundStyle(color)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(item.title)
            Spacer()
            if !moduleOn {
                Text("Module off")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .opacity(moduleOn ? 1 : 0.4)
        .padding(.horizontal, 10)
        .frame(height: rowHeight)
        .background {
            if isDragged {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.background)
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
            } else if !index.isMultiple(of: 2) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.04))
            }
        }
        .contentShape(Rectangle())
        .offset(y: isDragged ? offset : 0)
        .zIndex(isDragged ? 1 : 0)
        .gesture(dragGesture(item))
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Drag to reorder"))
        .accessibilityAction(named: Text("Move up")) { move(item, by: -1) }
        .accessibilityAction(named: Text("Move down")) { move(item, by: 1) }
    }

    private func dragGesture(_ item: BarItem) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.space))
            .onChanged { drag in
                if dragging == nil {
                    dragging = item
                    startIndex = order.firstIndex(of: item) ?? 0
                }
                guard let dragging, let current = order.firstIndex(of: dragging) else { return }
                let steps = Int((drag.translation.height / rowHeight).rounded())
                let target = min(max(startIndex + steps, 0), order.count - 1)
                if target != current {
                    withAnimation(.snappy(duration: 0.2)) {
                        order.move(fromOffsets: [current], toOffset: target > current ? target + 1 : target)
                    }
                }
                offset = drag.translation.height - CGFloat(target - startIndex) * rowHeight
            }
            .onEnded { _ in
                withAnimation(.snappy(duration: 0.2)) { offset = 0 }
                dragging = nil
            }
    }

    private func move(_ item: BarItem, by delta: Int) {
        guard let index = order.firstIndex(of: item) else { return }
        let target = min(max(index + delta, 0), order.count - 1)
        guard target != index else { return }
        withAnimation(.snappy(duration: 0.2)) {
            order.move(fromOffsets: [index], toOffset: target > index ? target + 1 : target)
        }
    }
}

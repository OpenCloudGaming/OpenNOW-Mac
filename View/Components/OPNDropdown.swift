import AppKit
import SwiftUI

struct OPNDropdownItem: Identifiable {
    let id: String
    let title: String
    var isSelected = false
    var isDestructive = false
    /// Draws a 1px Stroke Subtle rule above this row, separating it from the group before it.
    var startsGroup = false
    let action: () -> Void
}

/// One row of a pad-drivable dropdown, owned by the model rather than the view.
///
/// A controller handler has to walk and commit rows before anything is drawn — the pad's confirm is
/// what opens the panel in the first place — so the rows have to exist outside the view tree. The
/// HUD's dropdowns build their `OPNDropdownItem`s from these, which keeps one definition of "which
/// rows, in which order, doing what" for the pointer and the pad.
struct OPNDropdownPadItem {
    let id: String
    let title: String
    var isSelected = false
    var isDestructive = false
    var startsGroup = false
    let action: () -> Void

    /// The same row as the panel draws it. `action` is carried across unchanged: the panel wraps it
    /// in a dismissal only for the pointer path.
    var dropdownItem: OPNDropdownItem {
        OPNDropdownItem(id: id,
                        title: title,
                        isSelected: isSelected,
                        isDestructive: isDestructive,
                        startsGroup: startsGroup,
                        action: action)
    }
}

/// Lets a pad-driven host own a dropdown's open state and highlighted row.
///
/// The host changes these values and the menu renders them, which is what lets the panel be opened,
/// walked and committed without a pointer. A menu with no driver behaves exactly as it did before:
/// pointer-only, with its own internal open state.
struct OPNDropdownPadDriver {
    /// Whether the panel is drawn.
    let isPresented: Bool
    /// The row the pad stands on, or nil when the panel just opened on nothing selectable.
    let highlightedItemID: String?
    /// Opens or closes the panel — a click on the trigger, and the pad's confirm on the trigger.
    let toggle: () -> Void
    /// Closes without selecting — an outside click, Escape, or the pad's cancel.
    let close: () -> Void
}

struct OPNDropdownRow: View {
    let title: String
    var isSelected = false
    var isDestructive = false
    /// True while the pad stands on this row. `false` for every pointer-only dropdown, where the
    /// hover fill is the only affordance there has ever been.
    var isHighlighted = false
    let action: () -> Void

    @Environment(\.opnUIScale) private var uiScale
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: OPNDesign.Spacing.xSmall(scale: uiScale)) {
                Text(title)
                    .catalogFont(size: 12, weight: .bold)
                    .foregroundStyle(foreground)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .catalogFont(size: 11, weight: .bold)
                        .foregroundStyle(OPNDesign.accent)
                }
            }
            .padding(.horizontal, OPNDesign.Spacing.controlRow(scale: uiScale))
            .frame(maxWidth: .infinity, minHeight: 30 * uiScale, alignment: .leading)
            .background(background)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var background: Color {
        if isHighlighted { return OPNDesign.accent.opacity(0.20) }
        return isHovering ? Color.white.opacity(0.08) : .clear
    }

    private var foreground: Color {
        if isDestructive { return OPNDesign.Semantic.destructive }
        return (isHovering || isHighlighted) ? OPNDesign.Text.primary : OPNDesign.Text.secondary
    }
}

struct OPNDropdownPanel: View {
    let items: [OPNDropdownItem]
    var width: CGFloat?
    var visibleItemCount: Int?
    /// The row the pad stands on, so the panel can mark it and keep it inside the capped height.
    var highlightedItemID: String?

    @Environment(\.opnUIScale) private var uiScale

    static func minimumWidth(scale: CGFloat) -> CGFloat {
        208 * scale
    }

    static func rowHeight(scale: CGFloat) -> CGFloat {
        30 * scale
    }

    var body: some View {
        Group {
            if let visibleItemCount, visibleItemCount > 0 {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        rows
                    }
                    .contentMargins(.trailing, 12, for: .scrollContent)
                    .frame(height: CGFloat(min(items.count, visibleItemCount)) * Self.rowHeight(scale: uiScale))
                    // A pad walks rows the panel may have scrolled past; without this it would move
                    // focus out of sight and the list would read as frozen.
                    .onAppear { scroll(proxy) }
                    .onChange(of: highlightedItemID) { _, _ in scroll(proxy) }
                }
            } else {
                rows
            }
        }
        .padding(.vertical, OPNDesign.Spacing.menuPanelVertical(scale: uiScale))
        .frame(minWidth: width == nil ? Self.minimumWidth(scale: uiScale) : nil)
        .frame(maxWidth: width == nil ? .infinity : nil)
        .frame(width: width)
        .background(OPNDesign.Surface.panelRaised)
        .overlay {
            Rectangle()
                .stroke(OPNDesign.Stroke.regular, lineWidth: 1)
        }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard highlightedItemID != nil else { return }
        // No animation: the pad's row must be in place before the next press, not easing toward it.
        if let id = highlightedItemID { proxy.scrollTo(id, anchor: .center) }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items) { item in
                if item.startsGroup {
                    Rectangle()
                        .fill(OPNDesign.Stroke.subtle)
                        .frame(height: 1)
                        .padding(.vertical, OPNDesign.Spacing.xxSmall(scale: uiScale))
                }
                OPNDropdownRow(
                    title: item.title,
                    isSelected: item.isSelected,
                    isDestructive: item.isDestructive,
                    isHighlighted: item.id == highlightedItemID,
                    action: item.action
                )
                .id(item.id)
            }
        }
    }
}

struct OPNDropdownMenu<Label: View>: View {
    let items: [OPNDropdownItem]
    var isDisabled = false
    var visibleItemCount: Int?
    /// Opens leftward by default, for a menu whose trigger sits at the right edge of a narrow column
    /// (the HUD sidebar) where opening right would cover the video. An edge check still wins if there
    /// is not enough room to the left.
    var opensLeftByDefault = false
    /// True while the pad stands on this menu. Strokes the trigger with the accent, the same
    /// treatment every other focusable HUD control uses.
    var isFocused = false
    /// Pad-driven presentation. Nil for the pointer-only call sites, which keep their own open state
    /// and behave exactly as before.
    var padDriver: OPNDropdownPadDriver?
    @ViewBuilder let label: () -> Label

    @Environment(\.opnUIScale) private var uiScale
    @State private var isPresented = false
    @State private var triggerSize: CGSize = .zero
    @State private var panelHeight: CGFloat = 0
    @State private var spaceProbe = DropdownSpaceProbe()

    /// The panel is open when the pad's host says so, when a host is driving, and from this view's
    /// own state otherwise — never both, or a click and the pad would fight over the same panel.
    private var isOpen: Bool { padDriver?.isPresented ?? isPresented }

    private func close() {
        isPresented = false
    }

    var body: some View {
        Button {
            if let padDriver {
                padDriver.toggle()
            } else {
                spaceProbe.refresh()
                isPresented.toggle()
            }
        } label: { label() }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .overlay {
            if isFocused {
                Rectangle().stroke(OPNDesign.accent, lineWidth: 2)
            }
        }
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { triggerSize = proxy.size }
                    .onChange(of: proxy.size) { _, newSize in triggerSize = newSize }
            }
        )
        .background(DropdownSpaceProbeView(probe: spaceProbe))
        .overlay {
            if isOpen {
                Color.black.opacity(0.001)
                    .frame(width: 6000, height: 6000)
                    .contentShape(Rectangle())
                    .onTapGesture { dismiss() }
            }
        }
        .overlay(alignment: panelAlignment) {
            if isOpen {
                panel
            }
        }
        .onExitCommand { dismiss() }
        .onChange(of: items.map(\.id)) { _, _ in dismiss() }
        .onChange(of: isDisabled) { _, disabled in
            if disabled { dismiss() }
        }
        // The panel is an overlay, so it still obeys sibling paint order: without this an open
        // menu draws underneath any control laid out after it.
        .zIndex(isOpen ? 1 : 0)
    }

    /// Closes without selecting, through whichever owner holds the open state.
    private func dismiss() {
        if let padDriver { padDriver.close() } else { close() }
    }

    private var anchorSpacing: CGFloat {
        OPNDesign.Spacing.xxSmall(scale: uiScale)
    }

    private var panelWidth: CGFloat {
        max(OPNDropdownPanel.minimumWidth(scale: uiScale), triggerSize.width)
    }

    /// Opens away from the window edge the panel would otherwise run past.
    ///
    /// A menu near the right of a narrow sidebar used to open rightward, off the sidebar and over the
    /// video, where it read as a translucent, garbled list. The same applies vertically.
    private var opensLeft: Bool {
        guard spaceProbe.isConstrained else { return opensLeftByDefault }
        if opensLeftByDefault {
            // Stay inside the narrow column, but never off the window's left edge.
            return spaceProbe.spaceLeft >= panelWidth || spaceProbe.spaceLeft > spaceProbe.spaceRight
        }
        return spaceProbe.spaceRight < panelWidth && spaceProbe.spaceLeft > spaceProbe.spaceRight
    }

    private var opensUp: Bool {
        guard spaceProbe.isConstrained, panelHeight > 0 else { return false }
        return spaceProbe.spaceBelow < panelHeight && spaceProbe.spaceAbove > spaceProbe.spaceBelow
    }

    private var panelAlignment: Alignment {
        switch (opensLeft, opensUp) {
        case (false, false): return .topLeading
        case (true, false): return .topTrailing
        case (false, true): return .bottomLeading
        case (true, true): return .bottomTrailing
        }
    }

    private var panelVerticalOffset: CGFloat {
        let magnitude = triggerSize.height + anchorSpacing
        return opensUp ? -magnitude : magnitude
    }

    @ViewBuilder
    private var panel: some View {
        let available = (opensUp ? spaceProbe.spaceAbove : spaceProbe.spaceBelow) - anchorSpacing

        if spaceProbe.isConstrained, available > 0, panelHeight > available {
            ScrollView(.vertical) {
                measuredPanel
            }
            .frame(width: panelWidth, height: available)
            .offset(y: panelVerticalOffset)
        } else {
            measuredPanel
                .offset(y: panelVerticalOffset)
        }
    }

    private var measuredPanel: some View {
        OPNDropdownPanel(items: dismissingItems,
                         width: panelWidth,
                         visibleItemCount: visibleItemCount,
                         highlightedItemID: padDriver?.highlightedItemID)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                panelHeight = height
            }
    }

    private var dismissingItems: [OPNDropdownItem] {
        items.map { item in
            OPNDropdownItem(
                id: item.id,
                title: item.title,
                isSelected: item.isSelected,
                isDestructive: item.isDestructive,
                startsGroup: item.startsGroup
            ) {
                dismiss()
                item.action()
            }
        }
    }
}

@MainActor
private final class DropdownSpaceProbe {
    weak var probeView: NSView?
    private(set) var spaceBelow: CGFloat = 0
    private(set) var spaceAbove: CGFloat = 0
    private(set) var spaceLeft: CGFloat = 0
    private(set) var spaceRight: CGFloat = 0
    private(set) var isConstrained = false

    func refresh() {
        guard let probeView, let content = probeView.window?.contentView else {
            isConstrained = false
            return
        }
        // AppKit window coordinates are bottom-left origin, so `minY` is the room below the trigger and
        // `maxY` the room above it. All four are needed: the panel is opened away from whichever edge
        // it would otherwise run off.
        let frameInWindow = probeView.convert(probeView.bounds, to: nil)
        let bounds = content.bounds
        spaceBelow = max(frameInWindow.minY - bounds.minY, 0)
        spaceAbove = max(bounds.maxY - frameInWindow.maxY, 0)
        spaceLeft = max(frameInWindow.minX - bounds.minX, 0)
        spaceRight = max(bounds.maxX - frameInWindow.maxX, 0)
        isConstrained = true
    }
}

private struct DropdownSpaceProbeView: NSViewRepresentable {
    let probe: DropdownSpaceProbe

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        probe.probeView = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        probe.probeView = nsView
    }
}

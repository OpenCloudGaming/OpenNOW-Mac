import Foundation
import SwiftUI

/// One collapsible panel in the unified HUD dock. The header is a button and a pad focus row; the
/// caller owns `isCollapsed`, and a folded section still draws its header so a pad can reopen it.
struct StreamHUDSection<Content: View>: View {
    let label: String
    let spacing: CGFloat
    /// Marks a section as still settling. Sits beside the label rather than in the content so it
    /// reads as a property of the feature, not of one control inside it.
    let showsBetaTag: Bool
    /// What the focused control in this section does, for a pad user reading icon-only tiles.
    /// Drawn in the accent colour under the content; nil hides the line.
    let caption: String?
    let isCollapsed: Bool
    let isFocused: Bool
    /// When set, the header shows a grab handle that drags this payload to reorder the section.
    let reorderPayload: String?
    let onToggle: () -> Void
    let content: Content

    @State private var hasExpandedPanel = false
    /// The hovered tile's caption, which takes over from the pad-focus caption while the pointer is
    /// over a tile so a mouse user gets the same label a pad user gets.
    @State private var hoveredCaption: String?

    init(
        label: String,
        spacing: CGFloat = 10,
        showsBetaTag: Bool = false,
        caption: String? = nil,
        isCollapsed: Bool = false,
        isFocused: Bool = false,
        reorderPayload: String? = nil,
        onToggle: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.label = label
        self.spacing = spacing
        self.showsBetaTag = showsBetaTag
        self.caption = caption
        self.isCollapsed = isCollapsed
        self.isFocused = isFocused
        self.reorderPayload = reorderPayload
        self.onToggle = onToggle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            header
            if !isCollapsed {
                sectionContent
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            Rectangle().fill(Color.white.opacity(0.055))
            Rectangle().stroke(StreamHUDTheme.divider, lineWidth: 1)
        }
        // Animates the fold from any source, including the pad's activate, which does not pass
        // through this view's toggle action.
        .opnMotion(OPNDesign.Motion.panel, value: isCollapsed)
        .onPreferenceChange(StreamHUDExpandedPanelKey.self) { hasExpandedPanel = $0 }
        .onPreferenceChange(StreamHUDHoveredCaptionKey.self) { hoveredCaption = $0 }
        // Above every sibling while one of this section's dropdowns is open, so the panel is not
        // tinted by the next section's background painting over it.
        .zIndex(hasExpandedPanel ? 50 : 0)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button(action: onToggle) {
                headerLabel
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isCollapsed ? "Expand \(label) section" : "Collapse \(label) section")
            .help(isCollapsed ? "Expand \(label)" : "Collapse \(label)")
            if let reorderPayload {
                Image(systemName: "line.3.horizontal")
                    .font(.streamFont(size: 10, weight: .bold))
                    .foregroundStyle(StreamHUDTheme.textTertiary)
                    .contentShape(Rectangle())
                    .draggable(reorderPayload)
                    .accessibilityLabel("Reorder \(label) section")
                    .help("Drag to reorder")
            }
        }
        .overlay {
            if isFocused {
                Rectangle().stroke(StreamHUDTheme.accent, lineWidth: 2).padding(-4)
            }
        }
    }

    private var headerLabel: some View {
        HStack(spacing: 6) {
            // The disclosure chevron leads, away from the trailing grab handle, so the two trailing
            // affordances cannot be mistaken for each other.
            Image(systemName: "chevron.right")
                .font(.streamFont(size: 9, weight: .bold))
                .foregroundStyle(isFocused ? StreamHUDTheme.accent : StreamHUDTheme.textTertiary)
                .rotationEffect(.degrees(isCollapsed ? 0 : 90))
            Text(label)
                .font(.streamFont(size: 10, weight: .bold))
                .tracking(1.1)
                .foregroundStyle(isFocused ? StreamHUDTheme.textSecondary : StreamHUDTheme.textTertiary)
            if showsBetaTag { OPNBetaTag(uiScale: 1, prominent: true) }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var sectionContent: some View {
        Group {
            content
            if let visibleCaption = hoveredCaption ?? caption, !visibleCaption.isEmpty {
                Text(visibleCaption)
                    .font(.streamFont(size: 10, weight: .bold))
                    .foregroundStyle(StreamHUDTheme.accentSoft)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityHidden(true)
            }
        }
        .opnTransition(.opacity)
    }
}

import SwiftUI

/// The inline notice a title shows when the vendor has taken it down — the amber "Offline" strip
/// above the play row. Flat: a warning-tinted fill and a 1px stroke, a headline over one line.
///
/// A maintenance notice also carries the **Watch** control: the one place the reader opts in to
/// being told when the title is playable again. The same notice is drawn by the mouse detail panel
/// and the pad overlay, so the control lands on both at once.
struct CatalogAvailabilityNotice: View {
    let title: String
    let message: String
    /// Whether this title is being watched right now, which the control reports and the copy
    /// already speaks to.
    var isWatching = false
    /// Offered for `.maintenance` only; absent for `.unavailable`, `.patching` and `.available`.
    var showsWatchControl = false
    var onToggleWatch: (() -> Void)?

    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        HStack(alignment: .top, spacing: 10 * uiScale) {
            Image(systemName: "exclamationmark.circle.fill")
                .catalogFont(size: 15, weight: .bold)
                .foregroundStyle(OPNDesign.Semantic.warning)
                .padding(.top, 1 * uiScale)
            VStack(alignment: .leading, spacing: 3 * uiScale) {
                Text(title)
                    .catalogFont(size: 13, weight: .bold)
                    .foregroundStyle(OPNDesign.Semantic.warning)
                Text(message)
                    .catalogFont(size: 13, weight: .medium)
                    .foregroundStyle(OPNDesign.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if showsWatchControl, let onToggleWatch {
                watchButton(onToggleWatch)
            }
        }
        .padding(.horizontal, 14 * uiScale)
        .padding(.vertical, 11 * uiScale)
        .frame(maxWidth: 520 * uiScale, alignment: .leading)
        .background(OPNCornerShape(role: .control, scale: uiScale).fill(OPNDesign.Semantic.warning.opacity(0.14)))
        .overlay { OPNCornerShape(role: .control, scale: uiScale).strokeBorder(OPNDesign.Semantic.warning.opacity(0.45), lineWidth: 1) }
    }

    /// A square chip like the detail panel's other secondary controls, filled with the accent while
    /// watching so the state reads without a separate indicator.
    private func watchButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6 * uiScale) {
                Image(systemName: isWatching ? "eye.fill" : "eye")
                    .catalogFont(size: 12, weight: .bold)
                Text(GameDetailPresentation.watchActionTitle(isWatching: isWatching))
                    .catalogFont(size: 11, weight: .bold)
                    .tracking(0.8)
            }
            .foregroundStyle(isWatching ? OPNDesign.onAccent : OPNDesign.Text.primary)
            .padding(.horizontal, 12 * uiScale)
            .frame(height: 28 * uiScale)
            .background(OPNCornerShape(role: .control, scale: uiScale).fill(isWatching ? OPNDesign.accent : OPNDesign.Fill.neutral(0.12)))
            .overlay { OPNCornerShape(role: .control, scale: uiScale).strokeBorder(isWatching ? OPNDesign.accent : OPNDesign.Stroke.regular, lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(GameDetailPresentation.watchActionAccessibilityLabel(isWatching: isWatching))
        .accessibilityAddTraits(isWatching ? .isSelected : [])
    }
}

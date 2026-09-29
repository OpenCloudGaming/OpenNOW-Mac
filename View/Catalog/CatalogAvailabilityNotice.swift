import SwiftUI

/// The inline notice a title shows when the vendor has taken it down — the amber "Offline" strip
/// above the play row. Flat: a warning-tinted fill and a 1px stroke, a headline over one line.
struct CatalogAvailabilityNotice: View {
    let title: String
    let message: String

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
        }
        .padding(.horizontal, 14 * uiScale)
        .padding(.vertical, 11 * uiScale)
        .frame(maxWidth: 520 * uiScale, alignment: .leading)
        .background(OPNDesign.Semantic.warning.opacity(0.14))
        .overlay { Rectangle().stroke(OPNDesign.Semantic.warning.opacity(0.45), lineWidth: 1) }
    }
}

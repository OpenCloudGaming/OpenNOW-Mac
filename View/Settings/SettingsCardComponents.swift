import SwiftUI

/// The containers a settings page is built from: the plain card, and the one that keeps its body
/// folded away until asked for.

enum SettingsCardBadge {
    /// Shipped, still settling. Scope is the card, not the whole tab.
    case beta
    /// Off by default, on trial. Promoted to `beta` or removed.
    case experimental

    var text: String {
        switch self {
        case .beta: "BETA"
        case .experimental: "EXPERIMENTAL"
        }
    }
}

struct SettingsCard<Content: View>: View {
    let title: String
    let badge: SettingsCardBadge?
    /// The card qualifies a setting added in the current release, so its header wears the NEW tag.
    /// Expires by version and by use exactly as a row's does.
    let isNew: Bool
    let uiScale: CGFloat
    private let content: Content

    init(title: String, badge: SettingsCardBadge? = nil, isNew: Bool = false, uiScale: CGFloat, @ViewBuilder content: () -> Content) {
        self.title = title
        self.badge = badge
        self.isNew = isNew
        self.uiScale = uiScale
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10 * uiScale) {
                Rectangle()
                    .fill(OPNDesign.accent)
                    .frame(width: 4 * uiScale, height: 18 * uiScale)
                Text(title.uppercased())
                    .font(.settingsFont(size: 12 * uiScale, weight: .bold))
                    .foregroundStyle(OPNDesign.Text.secondary)
                    .tracking(1.1)
                if let badge {
                    SettingsCardTag(text: badge.text, uiScale: uiScale)
                }
                if isNew {
                    OPNNewTag(uiScale: uiScale)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18 * uiScale)
            .padding(.top, 17 * uiScale)
            .padding(.bottom, 12 * uiScale)
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(.horizontal, 20 * uiScale)
            .padding(.bottom, 20 * uiScale)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack(alignment: .topLeading) {
                SettingsVendorLayout.card
                LinearGradient(colors: [OPNDesign.Fill.neutral(0.035), .clear], startPoint: .top, endPoint: .center)
                Rectangle()
                    .fill(OPNDesign.accent.opacity(0.10))
                    .frame(width: 1)
            }
        )
        .overlay { Rectangle().stroke(OPNDesign.Stroke.subtle, lineWidth: 1) }
        .shadow(color: .black.opacity(0.26), radius: 16 * uiScale, y: 8 * uiScale)
    }
}

/// A card for a setting most hosts never touch: collapsed by default, so its status is visible without
/// its full field set reading as something everyone has to configure. Callers should seed `isExpanded`
/// from whether the setting is already configured, so a host who set it up in a previous session still
/// sees it open.
struct SettingsCollapsibleCard<Content: View>: View {
    let title: String
    let statusSummary: String
    let isConfigured: Bool
    let uiScale: CGFloat
    @Binding var isExpanded: Bool
    private let content: Content

    init(title: String, statusSummary: String, isConfigured: Bool, uiScale: CGFloat, isExpanded: Binding<Bool>, @ViewBuilder content: () -> Content) {
        self.title = title
        self.statusSummary = statusSummary
        self.isConfigured = isConfigured
        self.uiScale = uiScale
        self._isExpanded = isExpanded
        self.content = content()
    }

    /// The header is a focusable row in its own right. Without it a pad walks straight past a
    /// collapsed card, and every setting folded inside it is reachable only with a pointer.
    @State private var focusIdentity = ControllerFocusIdentity()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { isExpanded.toggle() } label: {
                HStack(spacing: 10 * uiScale) {
                    Rectangle()
                        .fill(OPNDesign.accent)
                        .frame(width: 4 * uiScale, height: 18 * uiScale)
                    Text(title.uppercased())
                        .font(.settingsFont(size: 12 * uiScale, weight: .bold))
                        .foregroundStyle(OPNDesign.Text.secondary)
                        .tracking(1.1)
                    Spacer(minLength: 0)
                    Text(statusSummary)
                        .font(.settingsFont(size: 11 * uiScale, weight: .bold))
                        .foregroundStyle(isConfigured ? OPNDesign.accentInk : OPNDesign.Text.muted)
                        .fixedSize()
                    Text(isExpanded ? "\u{25BE}" : "\u{25B8}")
                        .font(.settingsFont(size: 11 * uiScale, weight: .bold))
                        .foregroundStyle(OPNDesign.Text.muted)
                }
                .padding(.horizontal, 18 * uiScale)
                .padding(.top, 17 * uiScale)
                .padding(.bottom, isExpanded ? 12 * uiScale : 17 * uiScale)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .controllerFocusable(
                focusIdentity,
                activate: { isExpanded.toggle() },
                adjust: { delta in isExpanded = delta > 0 }
            )
            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    content
                }
                .padding(.horizontal, 20 * uiScale)
                .padding(.bottom, 20 * uiScale)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack(alignment: .topLeading) {
                SettingsVendorLayout.card
                LinearGradient(colors: [OPNDesign.Fill.neutral(0.035), .clear], startPoint: .top, endPoint: .center)
                Rectangle()
                    .fill(OPNDesign.accent.opacity(0.10))
                    .frame(width: 1)
            }
        )
        .overlay { Rectangle().stroke(OPNDesign.Stroke.subtle, lineWidth: 1) }
        .shadow(color: .black.opacity(0.26), radius: 16 * uiScale, y: 8 * uiScale)
    }
}

import SwiftUI

/// The annotations a settings row or card can wear: how new the setting is, and how finished the
/// feature behind it is. Small enough to read as a footnote on the control they qualify, never as a
/// second title competing with it.

/// Letter-spacing is applied after every glyph including the last, so a tracked label sits left of
/// centre inside a padded box unless the trailing padding gives that space back. Tracking scales
/// with the interface like the padding it is subtracted from; mixing the two only looks right at
/// 1.0.
enum SettingsTagMetrics {
    static let tracking: CGFloat = 0.7
    static let horizontalPadding: CGFloat = 4
    static var trailingPadding: CGFloat { horizontalPadding - tracking }
}

/// A row title with its optional NEW tag riding alongside, so every row kind renders the tag the
/// same way.
struct SettingsRowTitle: View {
    let title: String
    let isNew: Bool
    let uiScale: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8 * uiScale) {
            Text(title)
                .font(.settingsNvidia(size: 15 * uiScale, weight: .bold))
                .foregroundStyle(.white)
            if isNew { OpenNOWNewTag(uiScale: uiScale) }
        }
    }
}

/// A card-header annotation: BETA or EXPERIMENTAL. Quieter than the row-level NEW tag, since it
/// qualifies a whole card rather than pointing at one control.
struct SettingsCardTag: View {
    let text: String
    let uiScale: CGFloat

    var body: some View {
        Text(text)
            .font(.settingsNvidia(size: 8 * uiScale, weight: .bold))
            .tracking(SettingsTagMetrics.tracking * uiScale)
            .foregroundStyle(OpenNOWDesign.accent.opacity(0.78))
            .padding(.leading, SettingsTagMetrics.horizontalPadding * uiScale)
            .padding(.trailing, SettingsTagMetrics.trailingPadding * uiScale)
            .padding(.vertical, 2 * uiScale)
            .background(OpenNOWDesign.accent.opacity(0.12))
            .accessibilityLabel(text.capitalized)
    }
}

/// Marks a setting added in the current release. Solid accent so it reads at a glance next to
/// the quieter tinted BETA tag; it disappears once the setting is used or the next release ships.
struct OpenNOWNewTag: View {
    let uiScale: CGFloat

    var body: some View {
        Text("NEW")
            .font(.settingsNvidia(size: 8 * uiScale, weight: .bold))
            .tracking(SettingsTagMetrics.tracking * uiScale)
            .foregroundStyle(.black)
            .padding(.leading, SettingsTagMetrics.horizontalPadding * uiScale)
            .padding(.trailing, SettingsTagMetrics.trailingPadding * uiScale)
            .padding(.vertical, 2 * uiScale)
            .background(OpenNOWDesign.accent)
            .accessibilityLabel("New setting")
    }
}

/// A small "BETA" tag, for surfaces that are shipped but still settling. One component rather than
/// three inline `Text`s: it appears on the Settings rail, in the stream HUD and on the Home entry
/// point, and three copies would drift in colour and casing the way the relay rows already did.
struct OpenNOWBetaTag: View {
    let uiScale: CGFloat
    /// The HUD and the top bar sit on a dark stream surface where the accent reads as interactive;
    /// Settings wants the quieter treatment.
    var prominent = false
    /// Rides along inside another control - a tab, a row title - where the tag is an annotation on
    /// something else and must not outweigh it.
    var compact = false

    var body: some View {
        Text("BETA")
            .font(.settingsNvidia(size: (compact ? 8 : 9) * uiScale, weight: .bold))
            .tracking(SettingsTagMetrics.tracking * uiScale)
            .foregroundStyle(foreground)
            .padding(.leading, leadingPadding * uiScale)
            .padding(.trailing, (leadingPadding - SettingsTagMetrics.tracking) * uiScale)
            .padding(.vertical, 2 * uiScale)
            .background(background)
            .accessibilityLabel("Beta")
    }

    private var leadingPadding: CGFloat { compact ? 4 : 5 }

    private var foreground: Color {
        if prominent { return .black }
        return compact ? OpenNOWDesign.accent.opacity(0.72) : OpenNOWDesign.accent
    }

    private var background: Color {
        if prominent { return OpenNOWDesign.accent }
        return OpenNOWDesign.accent.opacity(compact ? 0.12 : 0.16)
    }
}

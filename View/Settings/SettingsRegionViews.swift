import SwiftUI

struct SettingsRegionRow: View {
    let option: OPNStreamRegionOption
    let isSelected: Bool
    let uiScale: CGFloat
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8 * uiScale) {
                HStack(alignment: .top, spacing: 8 * uiScale) {
                    Text(SettingsRegionName.shortName(for: option))
                        .font(.settingsFont(size: 13 * uiScale, weight: .bold))
                        .foregroundStyle(OPNDesign.Text.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Spacer(minLength: 6 * uiScale)
                    Circle()
                        .fill(isSelected ? OPNDesign.accent : (isHovering ? OPNDesign.Fill.neutral(0.34) : OPNDesign.Stroke.strong))
                        .frame(width: 8 * uiScale, height: 8 * uiScale)
                        .padding(.top, 4 * uiScale)
                }
                RegionLatencyBadge(latencyMs: option.latencyMs, isSelected: isSelected, uiScale: uiScale)
            }
            .frame(maxWidth: .infinity, minHeight: 56 * uiScale, alignment: .leading)
            .padding(.horizontal, 11 * uiScale)
            .padding(.vertical, 9 * uiScale)
            .background(isSelected ? OPNDesign.accent.opacity(0.13) : OPNDesign.Fill.neutral(isHovering ? 0.065 : 0.045))
            .overlay { Rectangle().stroke(isSelected ? OPNDesign.accent.opacity(0.74) : (isHovering ? OPNDesign.Stroke.regular : OPNDesign.Stroke.subtle), lineWidth: 1) }
        }
        .buttonStyle(.opnPressable)
        .onHover { isHovering = $0 }
        .opnMotion(OPNDesign.Motion.hover, value: isHovering)
    }
}

enum SettingsRegionName {
    static func shortName(for option: OPNStreamRegionOption) -> String {
        guard !option.automatic else { return "Auto" }
        let withoutParenthetical = option.name.replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression)
        let withoutPrefixes = withoutParenthetical
            .replacingOccurrences(of: "GeForce NOW", with: "")
            .replacingOccurrences(of: "NVIDIA", with: "")
            .replacingOccurrences(of: "Cloudmatch", with: "")
        let cleaned = withoutPrefixes.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? option.name : cleaned
    }
}

struct RegionLatencyBadge: View {
    let latencyMs: Int
    let isSelected: Bool
    let uiScale: CGFloat

    var body: some View {
        HStack(spacing: 7 * uiScale) {
            Circle()
                .fill(indicatorColor)
                .frame(width: 6 * uiScale, height: 6 * uiScale)
            Text(latencyText)
                .font(.settingsFont(size: 11 * uiScale, weight: .bold))
                .foregroundStyle(isSelected ? OPNDesign.accentInk : OPNDesign.Text.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8 * uiScale)
        .frame(height: 24 * uiScale)
        .background(isSelected ? OPNDesign.Fill.neutral(0.20) : OPNDesign.Fill.neutral(0.045))
        .overlay { Rectangle().stroke(isSelected ? OPNDesign.accent.opacity(0.30) : OPNDesign.Stroke.subtle, lineWidth: 1) }
    }

    private var latencyText: String {
        latencyMs >= 0 ? "\(latencyMs) ms" : "Measuring"
    }

    private var indicatorColor: Color {
        guard latencyMs >= 0 else { return OPNDesign.Fill.neutral(0.36) }
        if latencyMs <= 40 { return OPNDesign.accent }
        if latencyMs <= 65 { return OPNDesign.Semantic.warning }
        return OPNDesign.Semantic.destructive
    }
}

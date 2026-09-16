import SwiftUI

struct ControllerTestBatteryBadge: View {
    let percentage: Int?
    let isCharging: Bool

    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        SteamControllerBadge(uiScale: uiScale) {
            HStack(spacing: 4 * uiScale) {
                Image(systemName: icon)
                    .font(.settingsFont(size: 11 * uiScale, weight: .medium))
                    .foregroundStyle(color)
                Text(label)
                    .font(.settingsFont(size: 10 * uiScale, weight: .medium))
                    .foregroundStyle(OPNDesign.Text.tertiary)
                    .monospacedDigit()
            }
        }
        .fixedSize()
        .help(percentage == nil ? "macOS has not reported a battery percentage for this connection." : "Controller battery level")
    }

    private var label: String {
        if let percentage { return "\(percentage)%" }
        return isCharging ? "Charging" : "Battery unavailable"
    }

    private var icon: String {
        if isCharging { return "bolt.fill" }
        guard let percentage else { return "questionmark.circle" }
        switch percentage {
        case 90...: return "battery.100percent"
        case 60..<90: return "battery.75percent"
        case 30..<60: return "battery.50percent"
        case 15..<30: return "battery.25percent"
        default: return "battery.0percent"
        }
    }

    private var color: Color {
        if isCharging { return OPNDesign.accentInk }
        guard let percentage else { return OPNDesign.Text.muted }
        switch percentage {
        case 20...: return OPNDesign.accent
        case 10..<20: return OPNDesign.Semantic.warning
        default: return OPNDesign.Semantic.destructive
        }
    }
}

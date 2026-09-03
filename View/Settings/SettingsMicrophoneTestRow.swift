//
//  SettingsMicrophoneTestRow.swift
//  OpenNOW
//

import SwiftUI

/// Live microphone check that needs no stream: opens the selected input device and shows its
/// level on the same scale the in-session meter uses. The run is bounded by the view model (it
/// auto-stops after half a minute), so the row only reports state and toggles it. Lives in its
/// own file because `SettingsRowComponents.swift` sits at its length budget.
struct SettingsMicrophoneTestRow: View {
    let active: Bool
    let level: Double
    let message: String?
    let uiScale: CGFloat
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 18 * uiScale) {
            VStack(alignment: .leading, spacing: 5 * uiScale) {
                Text("Microphone Test")
                    .font(.settingsNvidia(size: 15 * uiScale, weight: .bold))
                    .foregroundStyle(.white)
                Text(message ?? "Opens the selected input device without starting a stream, so the microphone can be checked before playing.")
                    .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                    .foregroundStyle(.white.opacity(0.58))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 250 * uiScale, alignment: .leading)
            levelMeter
                .frame(maxWidth: .infinity)
            SettingsActionButton(
                title: active ? "STOP TEST" : "TEST MICROPHONE",
                tone: active ? .secondary : .primary,
                minimumWidth: 150 * uiScale,
                uiScale: uiScale,
                action: action)
        }
        .accessibilityElement(children: .combine)
    }

    /// A flat bar rather than a capsule, per DESIGN.md: state reads through the accent fill.
    private var levelMeter: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.white.opacity(0.07))
                Rectangle()
                    .fill(OpenNOWDesign.accent.opacity(active ? 0.9 : 0.25))
                    .frame(width: min(max(level, 0), 1) * proxy.size.width)
            }
        }
        .frame(height: 10 * uiScale)
        .overlay { Rectangle().stroke(OpenNOWDesign.Stroke.subtle, lineWidth: 1) }
        .animation(.linear(duration: 0.06), value: level)
    }
}

import SwiftUI

/// The destination for features on trial. Always present, so people know where to look and can see
/// that nothing is brewing rather than having to remember whether the tab exists this week.
struct LabsSettingsPage: View {
    let uiScale: CGFloat

    static let sections: [SettingsSection] = [SettingsSection("labs", "Labs")]

    var body: some View {
        if OpenNOWLabs.hasFlags {
            flagList
        } else {
            LabsEmptyState(uiScale: uiScale)
        }
    }

    private var flagList: some View {
        SettingsStack(spacing: 16 * uiScale) {
            SettingsCard(title: "In Flight", badge: .experimental, uiScale: uiScale) {
                Text("Each of these is off by default and may change, misbehave or disappear. Turning one on is a request to be surprised.")
                    .font(.settingsFont(size: 12 * uiScale, weight: .medium))
                    .foregroundStyle(.white.opacity(0.58))
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(OpenNOWLabs.flags) { flag in
                    SettingsDivider(uiScale: uiScale)
                    LabsFlagRow(flag: flag, uiScale: uiScale)
                }
            }
            .settingsSection("labs")
        }
    }
}

struct LabsFlagRow: View {
    let flag: OpenNOWLabsFlag
    let uiScale: CGFloat

    @State private var isEnabled = false

    var body: some View {
        SettingsToggleRow(
            title: flag.title,
            subtitle: "\(flag.summary) On trial since \(flag.since).",
            isOn: isEnabled,
            uiScale: uiScale
        ) { enabled in
            isEnabled = enabled
            OpenNOWLabs.setEnabled(flag, enabled)
        }
        .onAppear { isEnabled = OpenNOWLabs.isEnabled(flag) }
    }
}

/// What the page says when nothing is on trial. It names itself, which is why the page frame drops
/// its header for this state: two titles would compete.
struct LabsEmptyState: View {
    let uiScale: CGFloat

    var body: some View {
        VStack(spacing: 20 * uiScale) {
            illustration
            VStack(spacing: 10 * uiScale) {
                Text("Nothing in flight")
                    .font(.settingsFont(size: 22 * uiScale, weight: .bold))
                    .foregroundStyle(.white.opacity(0.94))
                Text("New experimental features land here first, behind a switch, before they ship to everyone. Look in now and then to try one early.")
                    .font(.settingsFont(size: 14 * uiScale, weight: .medium))
                    .foregroundStyle(.white.opacity(0.60))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420 * uiScale)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    /// The destination's own flask, resting in the accent, with the bubbles that would be there if
    /// something were brewing.
    private var illustration: some View {
        ZStack {
            Circle()
                .fill(OpenNOWDesign.accent.opacity(0.10))
                .frame(width: 132 * uiScale, height: 132 * uiScale)
            Circle()
                .stroke(OpenNOWDesign.accent.opacity(0.22), lineWidth: 1)
                .frame(width: 132 * uiScale, height: 132 * uiScale)
            Image(systemName: "flask.fill")
                .font(.settingsFont(size: 48 * uiScale, weight: .bold))
                .foregroundStyle(OpenNOWDesign.accent.opacity(0.85))
            bubbles
        }
        .accessibilityHidden(true)
    }

    private var bubbles: some View {
        ForEach(Array(Self.bubbleLayout.enumerated()), id: \.offset) { _, bubble in
            Circle()
                .fill(OpenNOWDesign.accent.opacity(bubble.opacity))
                .frame(width: bubble.size * uiScale, height: bubble.size * uiScale)
                .offset(x: bubble.x * uiScale, y: bubble.y * uiScale)
        }
    }

    /// Hugging the neck. The glyph is 48pt, so its top edge is about 24 points above centre;
    /// anything much beyond that reads as three dots near a flask rather than as bubbles leaving it.
    private static let bubbleLayout: [(x: CGFloat, y: CGFloat, size: CGFloat, opacity: Double)] = [
        (10, -24, 7, 0.55),
        (17, -32, 5, 0.38),
        (7, -38, 3.5, 0.26),
    ]
}

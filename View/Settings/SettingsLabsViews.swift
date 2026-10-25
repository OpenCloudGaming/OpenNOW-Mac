import SwiftUI

/// The destination for features on trial. Always present, so people know where to look and can see
/// that nothing is brewing rather than having to remember whether the tab exists this week.
struct LabsSettingsPage: View {
    let uiScale: CGFloat

    static let sections: [SettingsSection] = [SettingsSection("labs", "Labs")]

    var body: some View {
        if OPNLabs.hasFlags {
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
                    .foregroundStyle(OPNDesign.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(OPNLabs.flags) { flag in
                    SettingsDivider(uiScale: uiScale)
                    LabsFlagRow(flag: flag, uiScale: uiScale)
                }
            }
            .settingsSection("labs")
            if isCouchCoopEnabled {
                CouchCoopTilingCard(uiScale: uiScale)
            }
        }
    }

    @AppStorage(OPNLabs.couchCoop.storageKey) private var isCouchCoopEnabled = false
}

/// How two or more stream windows share the screens. Shown only while Couch Co-op is on, since
/// nothing else reads it. A change places the windows that are already open at once.
struct CouchCoopTilingCard: View {
    let uiScale: CGFloat

    @State private var orientation = OPNStreamTileOrientation.auto
    @State private var coverage = OPNStreamTileCoverage.visibleArea

    var body: some View {
        SettingsCard(title: "Couch Co-op Layout", badge: .experimental, uiScale: uiScale) {
            Text("With two accounts on two screens each stream fills its own screen. When streams share a screen they split it, and this decides how.")
                .font(.settingsFont(size: 12 * uiScale, weight: .medium))
                .foregroundStyle(OPNDesign.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            SettingsDivider(uiScale: uiScale)
            dropdownRow("Split shared screens", selection: orientation.title, items: OPNStreamTileOrientation.allCases.map { option in
                OPNDropdownItem(id: option.id, title: option.title, isSelected: option == orientation) {
                    orientation = option
                    OPNStreamTileOrientation.store(option)
                    OPNStreamWindowPresenter.shared.retileWindows()
                }
            })
            SettingsDivider(uiScale: uiScale)
            dropdownRow("Stream windows sit", selection: coverage.title, items: OPNStreamTileCoverage.allCases.map { option in
                OPNDropdownItem(id: option.id, title: option.title, isSelected: option == coverage) {
                    coverage = option
                    OPNStreamWindowPresenter.shared.setTileCoverage(option)
                }
            })
        }
        .onAppear {
            orientation = OPNStreamTileOrientation.stored
            coverage = OPNStreamTileCoverage.stored
        }
    }

    private func dropdownRow(_ title: String, selection: String, items: [OPNDropdownItem]) -> some View {
        HStack {
            Text(title)
                .font(.settingsFont(size: 13 * uiScale, weight: .bold))
                .foregroundStyle(OPNDesign.Text.primary)
            Spacer(minLength: 0)
            OPNDropdownMenu(items: items) {
                HStack(spacing: OPNDesign.Spacing.xSmall(scale: uiScale)) {
                    Text(selection)
                        .font(.settingsFont(size: 12 * uiScale, weight: .bold))
                        .foregroundStyle(OPNDesign.Text.primary)
                    Image(systemName: "chevron.down")
                        .font(.settingsFont(size: 9 * uiScale, weight: .bold))
                }
                .padding(.horizontal, OPNDesign.Spacing.controlRow(scale: uiScale))
                .frame(height: 30 * uiScale)
                .background(OPNCornerShape(role: .control, scale: uiScale).fill(OPNDesign.Fill.neutral(0.075)))
                .overlay { OPNCornerShape(role: .control, scale: uiScale).strokeBorder(OPNDesign.Stroke.regular, lineWidth: 1) }
            }
        }
    }
}

struct LabsFlagRow: View {
    let flag: OPNLabsFlag
    let uiScale: CGFloat

    @State private var isEnabled = false
    @State private var isRestartPromptPresented = false

    var body: some View {
        SettingsToggleRow(
            title: flag.title,
            subtitle: "\(flag.summary) On trial since \(flag.since).",
            isOn: isEnabled,
            uiScale: uiScale
        ) { enabled in
            isEnabled = enabled
            OPNLabs.setEnabled(flag, enabled)
            if flag.requiresRestart { isRestartPromptPresented = true }
        }
        .onAppear { isEnabled = OPNLabs.isEnabled(flag) }
        .opnConfirmation(
            isPresented: $isRestartPromptPresented,
            eyebrow: "LABS",
            title: "Restart to apply \(flag.title)?",
            message: "\(flag.title) takes full effect when OpenNOW starts. Restarting ends any stream that is running.",
            actions: [
                OPNConfirmationAction("LATER", role: .cancel) { isRestartPromptPresented = false },
                OPNConfirmationAction("RESTART NOW") {
                    isRestartPromptPresented = false
                    OPNAppRelaunch.relaunch()
                }
            ]
        )
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
                    .foregroundStyle(OPNDesign.Text.primary)
                Text("New experimental features land here first, behind a switch, before they ship to everyone. Look in now and then to try one early.")
                    .font(.settingsFont(size: 14 * uiScale, weight: .medium))
                    .foregroundStyle(OPNDesign.Text.tertiary)
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
                .fill(OPNDesign.accent.opacity(0.10))
                .frame(width: 132 * uiScale, height: 132 * uiScale)
            Circle()
                .stroke(OPNDesign.accent.opacity(0.22), lineWidth: 1)
                .frame(width: 132 * uiScale, height: 132 * uiScale)
            Image(systemName: "flask.fill")
                .font(.settingsFont(size: 48 * uiScale, weight: .bold))
                .foregroundStyle(OPNDesign.accentInk.opacity(0.85))
            bubbles
        }
        .accessibilityHidden(true)
    }

    private var bubbles: some View {
        ForEach(Array(Self.bubbleLayout.enumerated()), id: \.offset) { _, bubble in
            Circle()
                .fill(OPNDesign.accent.opacity(bubble.opacity))
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

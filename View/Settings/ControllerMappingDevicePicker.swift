import SwiftUI

extension ControllerMappingView {
    /// The type picker. Profiles are family-bound, so the sheet edits one controller type at a
    /// time and a per-game override is set for that type without touching the other two.
    var familyPicker: some View {
        VStack(alignment: .leading, spacing: OPNDesign.Spacing.xSmall(scale: uiScale)) {
            OPNDropdownMenu(items: familyPickerItems) {
                HStack(spacing: OPNDesign.Spacing.xSmall(scale: uiScale)) {
                    Text(family.label)
                        .font(.settingsFont(size: 12 * uiScale, weight: .bold))
                    Image(systemName: "chevron.down")
                        .font(.settingsFont(size: 9 * uiScale, weight: .bold))
                }
                .padding(.horizontal, OPNDesign.Spacing.controlRow(scale: uiScale))
                .frame(height: 30 * uiScale)
                .background(OPNDesign.Fill.neutral(0.075))
                .overlay { Rectangle().strokeBorder(OPNDesign.Stroke.regular, lineWidth: 1) }
            }
            Text("Each controller type keeps its own default profile, so a Steam Controller, a DualShock 4 and a generic pad never share one mapping.")
                .font(.settingsFont(size: 11 * uiScale, weight: .medium))
                .foregroundStyle(OPNDesign.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Text(store.isCurrentGameKnown
                 ? "The running game can override \(family.label) on its own, leaving every other game on the type default."
                 : "Start a stream to apply the profile being edited to that game alone.")
                .font(.settingsFont(size: 11 * uiScale, weight: .medium))
                .foregroundStyle(OPNDesign.Text.muted)
                .fixedSize(horizontal: false, vertical: true)
            if isRemoteCoOpActive {
                Text("Remote Co-Op guests keep the global Steam Controller profile in this version, so an override here applies to your own controller only.")
                    .font(.settingsFont(size: 11 * uiScale, weight: .medium))
                    .foregroundStyle(OPNDesign.Text.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var familyPickerItems: [OPNDropdownItem] {
        ControllerFamily.allCases.map { candidateFamily in
            OPNDropdownItem(
                id: candidateFamily.rawValue,
                title: candidateFamily.label,
                isSelected: family == candidateFamily,
                action: { selection = .family(candidateFamily) }
            )
        }
    }

    /// Writes the profile picker's selection onto the selected type's default. For steam this is the
    /// value the sheet already wrote; for the other two it turns an inert profile into their default.
    func selectProfile(_ id: UUID?) {
        store.setDefaultProfile(id, for: family)
        draft = savedProfile
    }

    /// What the running game resolves for the selected type now, so an override and a type default
    /// are distinguishable before anything changes. Shown only while a session game is known.
    var gameOverrideBar: some View {
        let storedGameOverride = store.storedOverride(for: family)
        return HStack(alignment: .center, spacing: OPNDesign.Spacing.small(scale: uiScale)) {
            VStack(alignment: .leading, spacing: 2 * uiScale) {
                Text("THIS GAME")
                    .font(.settingsFont(size: 10 * uiScale, weight: .bold))
                    .tracking(1.1)
                    .foregroundStyle(OPNDesign.Text.muted)
                Text(gameOverrideDescription)
                    .font(.settingsFont(size: 12 * uiScale, weight: .medium))
                    .foregroundStyle(OPNDesign.Text.secondary)
            }
            Spacer(minLength: 8 * uiScale)
            Button("Apply to this game") {
                guard let profileID = savedProfile?.id else { return }
                store.setGameOverride(profileID: profileID, for: family)
            }
            .buttonStyle(OPNCompactButtonStyle(uiScale: uiScale))
            .disabled(savedProfile == nil)
            .opacity(savedProfile == nil ? 0.46 : 1)
            .help(savedProfile == nil ? "Select or create a profile for this controller type first." : "The running game uses this profile for \(family.label).")
            Button("Remove for this game") { store.removeGameOverride(for: family) }
                .buttonStyle(OPNCompactButtonStyle(uiScale: uiScale))
                .disabled(storedGameOverride == nil)
                .opacity(storedGameOverride == nil ? 0.46 : 1)
                .help("Back to the \(family.label) type default. Overrides for the other controller types are untouched.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var gameOverrideDescription: String {
        if store.activeOverride(for: family) != nil, let resolvedProfile = store.profile(for: family) {
            return "\(family.label) uses \"\(resolvedProfile.name)\" in this game only."
        }
        if let defaultProfileID = store.defaultProfileID(for: family),
           let fallbackProfile = store.profiles.first(where: { $0.id == defaultProfileID }) {
            return "No override. \(family.label) uses its type default \"\(fallbackProfile.name)\"."
        }
        return "No override and no \(family.label) default, so this type passes through unchanged."
    }
}

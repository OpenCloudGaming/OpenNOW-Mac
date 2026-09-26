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
            .controllerFocusable(id: "mapping-family", adjust: { cycleFamily(delta: $0) })
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
                action: { requestFamilySelection(candidateFamily) }
            )
        }
    }

    /// Every row of the editor, in paint order: the type picker on top, then the rows stacked below.
    @ViewBuilder
    var profileEditorContent: some View {
        familyPicker
            .padding(.horizontal, OPNDesign.Spacing.card(scale: uiScale))
            .padding(.vertical, OPNDesign.Spacing.small(scale: uiScale))
            .zIndex(Self.typePickerRowZIndex)
        if store.isCurrentGameKnown {
            SteamControllerModalRule()
            gameOverrideBar
                .padding(.horizontal, OPNDesign.Spacing.card(scale: uiScale))
                .padding(.vertical, OPNDesign.Spacing.small(scale: uiScale))
                .zIndex(Self.stackedRowZIndex)
        }
        SteamControllerModalRule()
        profileBar
            .padding(.horizontal, OPNDesign.Spacing.card(scale: uiScale))
            .padding(.vertical, OPNDesign.Spacing.contentVertical(scale: uiScale))
            .zIndex(Self.stackedRowZIndex)
        SteamControllerModalRule()
        if draft != nil {
            configuratorLayout
        }
        if draft == nil {
            noProfileMessage
        }
    }

    /// Writes the profile picker's selection onto the selected type's default. For steam this is the
    /// value the sheet already wrote; for the other two it turns an inert profile into their default.
    func selectProfile(_ id: UUID?) {
        store.setDefaultProfile(id, for: family)
        draft = savedProfile
    }

    // MARK: - Actions

    /// Switching type or profile replaces the draft, so both ask before discarding unsaved edits.
    func requestFamilySelection(_ candidateFamily: ControllerFamily) {
        requestDiscardableAction { selection = .family(candidateFamily) }
    }

    func requestProfileSelection(_ profileID: UUID?) {
        requestDiscardableAction { selectProfile(profileID) }
    }

    func createProfile() {
        let createdProfile = store.createProfile(named: "", family: family)
        selectProfile(createdProfile.id)
    }

    func requestProfileDelete() {
        guard savedProfile != nil else { return }
        isDeleteConfirmationPresented = true
    }

    var deleteConfirmationTitle: String { "Delete \"\(savedProfile?.name ?? "this profile")\"?" }

    /// Names what the delete takes with it: `deleteProfile` drops every override binding it.
    var deleteConfirmationMessage: String {
        let overrideCount = savedProfile.map { store.overrideCount(referencingProfile: $0.id) } ?? 0
        guard overrideCount > 0 else { return "This cannot be undone." }
        let overrides = overrideCount == 1 ? "1 per-game override" : "\(overrideCount) per-game overrides"
        return "\(overrides) that use this profile will be removed too. This cannot be undone."
    }

    func performProfileDelete() {
        guard let profileID = savedProfile?.id else { return }
        store.deleteProfile(profileID)
    }

    func saveEdits() {
        guard let draft else { return }
        store.updateProfile(draft)
        SteamControllerHIDMonitor.shared.refreshCaptureConfiguration()
        dismiss()
    }

    func requestDismiss() {
        requestDiscardableAction { dismiss() }
    }

    /// Runs `action` now unless the draft has unsaved edits, in which case it asks first.
    func requestDiscardableAction(_ action: @escaping () -> Void) {
        guard hasUnsavedChanges else {
            action()
            return
        }
        pendingDiscardAction = action
        isDiscardConfirmationPresented = true
    }

    func confirmDiscard() {
        let action = pendingDiscardAction
        pendingDiscardAction = nil
        action?()
    }

    func applyOverrideToGame() {
        guard let profileID = savedProfile?.id else { return }
        store.setGameOverride(profileID: profileID, for: family)
        onAnnounce?("\(family.label) mapping applied to this game")
    }

    func removeOverrideForGame() {
        store.removeGameOverride(for: family)
        onAnnounce?("\(family.label) back to its default in this game")
    }

    // MARK: - Pad focus

    func cycleFamily(delta: Int) {
        let families = ControllerFamily.allCases
        guard let index = families.firstIndex(of: family) else { return }
        requestFamilySelection(families[min(max(index + delta, 0), families.count - 1)])
    }

    func cycleProfile(delta: Int) {
        let candidates: [UUID?] = [nil] + store.profiles.filter { $0.family == family }.map(\.id)
        let current = candidates.firstIndex { $0 == savedProfile?.id } ?? 0
        requestProfileSelection(candidates[min(max(current + delta, 0), candidates.count - 1)])
    }

    /// Mirrors the Settings page's pad handling: the first press only takes focus, and `back`
    /// dismisses through the unsaved-changes guard.
    func applyPadCommand(_ command: ControllerInputCommand) {
        padFocus.setActive(true)
        guard command != .back else {
            requestDismiss()
            return
        }
        if padFocus.focusFirstIfNeeded() { return }
        switch command {
        case .move(.up): padFocus.move(delta: -1)
        case .move(.down): padFocus.move(delta: 1)
        case .move(.left), .move(.right), .confirm: padFocus.send(command)
        default: break
        }
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
            Button("Apply \(family.label) to this game") { applyOverrideToGame() }
                .buttonStyle(OPNCompactButtonStyle(uiScale: uiScale))
                .disabled(savedProfile == nil)
                .opacity(savedProfile == nil ? 0.46 : 1)
                .help(savedProfile == nil ? "Select or create a profile for this controller type first." : "The running game uses this profile for \(family.label).")
                .controllerFocusable(id: "mapping-apply", activate: { applyOverrideToGame() })
            Button("Remove for this game") { removeOverrideForGame() }
                .buttonStyle(OPNCompactButtonStyle(uiScale: uiScale))
                .disabled(storedGameOverride == nil)
                .opacity(storedGameOverride == nil ? 0.46 : 1)
                .help("Back to the \(family.label) type default. Overrides for the other controller types are untouched.")
                .controllerFocusable(id: "mapping-remove", activate: { removeOverrideForGame() })
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

    var footer: some View {
        HStack(spacing: OPNDesign.Spacing.small(scale: uiScale)) {
            if hasUnsavedChanges {
                Text("UNSAVED CHANGES")
                    .font(.settingsFont(size: 10 * uiScale, weight: .bold))
                    .tracking(1.1)
                    .foregroundStyle(OPNDesign.Semantic.warning)
            }
            Spacer()
            Button(resolvedSelection == .none ? "CLOSE" : "CANCEL") { requestDismiss() }
                .buttonStyle(OPNModalSecondaryButtonStyle(uiScale: uiScale))
                .keyboardShortcut(.cancelAction)
                .controllerFocusable(id: "mapping-cancel", activate: { requestDismiss() })

            if resolvedSelection != .none {
                Button("SAVE") { saveEdits() }
                .buttonStyle(VendorGetInButtonStyle(uiScale: uiScale))
                .keyboardShortcut(.defaultAction)
                .disabled(!hasUnsavedChanges)
                .opacity(hasUnsavedChanges ? 1 : 0.46)
                .controllerFocusable(id: "mapping-save", activate: { saveEdits() })
            }
        }
        .padding(.horizontal, OPNDesign.Spacing.card(scale: uiScale))
        .padding(.vertical, OPNDesign.Spacing.small(scale: uiScale))
    }

    var disconnectedMessage: some View {
        VStack(spacing: OPNDesign.Spacing.small(scale: uiScale)) {
            Image(systemName: "gamecontroller")
                .font(.settingsFont(size: 40 * uiScale))
                .foregroundStyle(OPNDesign.Text.muted)
            Text("No controller connected")
                .font(.settingsFont(size: 20 * uiScale, weight: .bold))
            Text("Connect a controller to configure mappings. Your saved profiles are kept.")
                .font(.settingsFont(size: 14 * uiScale))
                .foregroundStyle(OPNDesign.Text.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(OPNDesign.Spacing.xLarge(scale: uiScale))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

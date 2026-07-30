import SwiftUI

struct SteamControllerGripMappingView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = SteamControllerGripMappingStore.shared
    @StateObject private var liveModel = SteamControllerTestModel()
    @State private var draft: SteamControllerGripProfile?

    private static let backgroundColor = Color(red: 18 / 255, green: 19 / 255, blue: 18 / 255)

    private var savedProfile: SteamControllerGripProfile? {
        store.activeProfile
    }

    private var hasUnsavedChanges: Bool {
        guard let draft, let savedProfile else { return false }
        return draft != savedProfile
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.12))
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    profileBar
                    if draft != nil {
                        gripEditor
                    } else {
                        noProfileMessage
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
            }
            Divider().overlay(Color.white.opacity(0.12))
            footer
        }
        .frame(minWidth: 760, minHeight: 560)
        .background(Self.backgroundColor)
        .foregroundStyle(.white)
        .onAppear {
            liveModel.start()
            draft = savedProfile
        }
        .onDisappear { liveModel.stop() }
        .onChange(of: store.activeProfileID) {
            draft = savedProfile
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "square.grid.2x2.fill")
                .font(.system(size: 18))
                .foregroundStyle(Color.openNowGreen)
            Text("BACK GRIP MAPPING")
                .font(MacForceNowNVIDIAFont.font(size: 15, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(.white.opacity(0.78))
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 28, height: 28)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private var profileBar: some View {
        HStack(spacing: 12) {
            Menu {
                Button("Mapping Off") { store.setActiveProfile(nil) }
                if !store.profiles.isEmpty {
                    Divider()
                    ForEach(store.profiles) { profile in
                        Button(profile.name) { store.setActiveProfile(profile.id) }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(savedProfile?.name ?? "Mapping Off")
                        .font(MacForceNowNVIDIAFont.font(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.88))
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Selecting another profile discards unsaved changes.")

            if draft != nil {
                TextField("Profile name", text: draftNameBinding)
                    .textFieldStyle(.plain)
                    .font(MacForceNowNVIDIAFont.font(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.88))
                    .padding(.horizontal, 10)
                    .frame(width: 200, height: 30)
                    .background(Color.white.opacity(0.04))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.1), lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                Button {
                    if let id = savedProfile?.id {
                        store.deleteProfile(id)
                    }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: 30, height: 30)
                        .background(Color.white.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help("Delete this profile")
            }

            Spacer()

            Button("New Profile") {
                store.createProfile(named: "")
            }
            .font(MacForceNowNVIDIAFont.font(size: 12, weight: .bold))
            .foregroundStyle(.black)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(Color.openNowGreen)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .buttonStyle(.plain)
        }
    }

    private var draftNameBinding: Binding<String> {
        Binding(
            get: { draft?.name ?? "" },
            set: { draft?.name = $0 }
        )
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if hasUnsavedChanges {
                Text("Unsaved changes")
                    .font(MacForceNowNVIDIAFont.font(size: 11, weight: .medium))
                    .foregroundStyle(.orange.opacity(0.85))
            }
            Spacer()
            Button("Cancel") {
                dismiss()
            }
            .font(MacForceNowNVIDIAFont.font(size: 12, weight: .bold))
            .foregroundStyle(.white.opacity(0.75))
            .padding(.horizontal, 18)
            .frame(height: 32)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .buttonStyle(.plain)

            Button("Save") {
                if let draft {
                    store.updateProfile(draft)
                }
                dismiss()
            }
            .font(MacForceNowNVIDIAFont.font(size: 12, weight: .bold))
            .foregroundStyle(hasUnsavedChanges ? .black : .black.opacity(0.4))
            .padding(.horizontal, 22)
            .frame(height: 32)
            .background(Color.openNowGreen.opacity(hasUnsavedChanges ? 1 : 0.35))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .buttonStyle(.plain)
            .disabled(!hasUnsavedChanges)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    private var noProfileMessage: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 44))
                .foregroundStyle(.white.opacity(0.15))
            Text("No mapping profile active")
                .font(MacForceNowNVIDIAFont.font(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
            Text("Create a profile to map L4, L5, R4, and R5 to button combos sent to the stream.")
                .font(MacForceNowNVIDIAFont.font(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.25))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 70)
    }

    private var gripEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(SteamControllerGripButton.allCases) { grip in
                gripRow(grip)
            }
            Text("While a grip is held, its combo is pressed in the stream like a human chord: L1, R1, L2, and R2 land first, and the remaining buttons follow a moment later so games register them as modifier + press. Press a grip on the controller to highlight its row.")
                .font(MacForceNowNVIDIAFont.font(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.25))
        }
    }

    private func gripRow(_ grip: SteamControllerGripButton) -> some View {
        let combo = draft?.combo(for: grip) ?? SteamControllerGripCombo()
        let held = liveModel.snapshot.buttons.contains(grip.gamepadButton)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(grip.label)
                    .font(MacForceNowNVIDIAFont.font(size: 12, weight: .bold))
                    .foregroundStyle(held ? .black : .white.opacity(0.78))
                    .frame(width: 44, height: 24)
                    .background(held ? Color.openNowGreen : Color.white.opacity(0.07))
                    .clipShape(Capsule())
                Text(SteamControllerGripComboTarget.comboLabel(for: combo))
                    .font(MacForceNowNVIDIAFont.font(size: 11, weight: .medium))
                    .foregroundStyle(combo.isEmpty ? .white.opacity(0.3) : Color.openNowGreen.opacity(0.9))
                Spacer()
                if !combo.isEmpty {
                    Button("Clear") {
                        draft?.combos.removeValue(forKey: grip)
                    }
                    .font(MacForceNowNVIDIAFont.font(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.45))
                    .buttonStyle(.plain)
                }
            }
            targetChips(grip: grip, combo: combo)
        }
        .padding(14)
        .background(Color.white.opacity(0.03))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(held ? Color.openNowGreen.opacity(0.5) : Color.white.opacity(0.08), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func targetChips(grip: SteamControllerGripButton, combo: SteamControllerGripCombo) -> some View {
        let columns = [GridItem(.adaptive(minimum: 64), spacing: 6)]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(SteamControllerGripComboTarget.all) { target in
                let selected = combo.contains(target.element)
                Button {
                    var updated = combo
                    updated.toggle(target.element)
                    if updated.isEmpty {
                        draft?.combos.removeValue(forKey: grip)
                    } else {
                        draft?.combos[grip] = updated
                    }
                } label: {
                    Text(target.label)
                        .font(MacForceNowNVIDIAFont.font(size: 10, weight: .bold))
                        .foregroundStyle(selected ? .black : .white.opacity(0.55))
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                        .background(selected ? Color.openNowGreen : Color.white.opacity(0.05))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(selected ? Color.openNowGreen.opacity(0.8) : Color.white.opacity(0.1), lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

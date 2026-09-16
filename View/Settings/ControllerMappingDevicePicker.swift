import SwiftUI

extension ControllerMappingView {
    var devicePicker: some View {
        VStack(alignment: .leading, spacing: OPNDesign.Spacing.xSmall(scale: uiScale)) {
            OPNDropdownMenu(items: devicePickerItems) {
                HStack(spacing: OPNDesign.Spacing.xSmall(scale: uiScale)) {
                    Text(resolvedSelection == .steamDefaults ? "Steam Controller defaults" : selectedDevice?.name ?? "Choose controller")
                        .font(.settingsFont(size: 12 * uiScale, weight: .bold))
                    Image(systemName: "chevron.down")
                        .font(.settingsFont(size: 9 * uiScale, weight: .bold))
                }
                .padding(.horizontal, OPNDesign.Spacing.controlRow(scale: uiScale))
                .frame(height: 30 * uiScale)
                .background(OPNDesign.Fill.neutral(0.075))
                .overlay { Rectangle().strokeBorder(OPNDesign.Stroke.regular, lineWidth: 1) }
            }
            Text(resolvedSelection == .steamDefaults
                 ? "Default profile for Steam Controllers. Select a connected controller to configure its own assignment."
                 : "Only this controller is assigned. Profiles are saved; connection assignments reset when disconnected or OpenNOW restarts.")
                .font(.settingsFont(size: 11 * uiScale, weight: .medium))
                .foregroundStyle(OPNDesign.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var devicePickerItems: [OPNDropdownItem] {
        let connected = devices.devices.map { device in
            OPNDropdownItem(id: device.id.rawValue, title: device.name, isSelected: selectedDeviceID == device.id,
                            action: { selection = .device(device.id) })
        }
        guard devices.devices.contains(where: { $0.family == .steam }) else { return connected }
        return connected + [
            OPNDropdownItem(id: "steam-default", title: "Steam Controller defaults", isSelected: resolvedSelection == .steamDefaults,
                            action: { selection = .steamDefaults }),
        ]
    }

    func selectProfile(_ id: UUID?) {
        if let selectedDevice {
            store.assignProfile(id, to: selectedDevice.id, family: selectedDevice.family)
        } else if resolvedSelection == .steamDefaults {
            store.setActiveProfile(id)
        }
        draft = savedProfile
    }
}

import SwiftUI

struct ControllerTestDevicePicker: View {
    let devices: [ControllerMappingDevice]
    let selectedDeviceID: InputDeviceID?
    let onSelect: (InputDeviceID) -> Void
    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        VStack(alignment: .leading, spacing: OPNDesign.Spacing.xSmall(scale: uiScale)) {
            OPNDropdownMenu(items: devices.map { device in
                OPNDropdownItem(id: device.id.rawValue, title: device.name,
                                isSelected: device.id == selectedDeviceID, action: { onSelect(device.id) })
            }) {
                HStack(spacing: OPNDesign.Spacing.xSmall(scale: uiScale)) {
                    Text(devices.first(where: { $0.id == selectedDeviceID })?.name ?? "No controller connected")
                        .font(.settingsFont(size: 12 * uiScale, weight: .bold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.settingsFont(size: 9 * uiScale, weight: .bold))
                }
                .padding(.horizontal, OPNDesign.Spacing.controlRow(scale: uiScale))
                .frame(height: 30 * uiScale)
                .background(OPNDesign.Fill.neutral(0.075))
                .overlay { Rectangle().strokeBorder(OPNDesign.Stroke.regular, lineWidth: 1) }
            }
            .disabled(devices.count < 2)
            .accessibilityLabel("Controller to test")
            Text("Only the selected controller’s input and battery are shown. Player order and mappings are unchanged.")
                .font(.settingsFont(size: 11 * uiScale, weight: .medium))
                .foregroundStyle(OPNDesign.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, OPNDesign.Spacing.railHorizontal(scale: uiScale))
        .padding(.vertical, OPNDesign.Spacing.small(scale: uiScale))
    }
}

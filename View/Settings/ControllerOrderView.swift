import GameController
import SwiftUI

struct ControllerOrderView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.opnUIScale) private var uiScale
    @ObservedObject private var devices = ControllerMappingDevices.shared
    @StateObject private var navigation = ControllerOrderNavigationModel()
    @State private var inputWindow = ControllerOrderWindowReference()

    var body: some View {
        let size = ControllerOrderPanel.sheetSize(deviceCount: devices.devices.count, uiScale: uiScale)
        ControllerOrderPanel(devices: devices.orderedDevices, isCustom: devices.playerOrder.isCustom, focusedControl: navigation.focus,
                             onMove: devices.move, onReset: devices.resetOrder, onClose: { dismiss() })
            .frame(minWidth: size.width, idealWidth: size.width, minHeight: size.height, idealHeight: size.height)
            .background(ControllerOrderWindowReader(reference: inputWindow))
            .onExitCommand { dismiss() }
            .task {
                devices.refresh()
                SteamControllerHIDMonitor.shared.beginInputCapture(inputWindow)
                defer { SteamControllerHIDMonitor.shared.endInputCapture(inputWindow) }
                while !Task.isCancelled {
                    navigation.reconcile(devices.playerOrder.deviceIDs)
                    if inputWindow.acceptsInput {
                        if pollNavigation() { break }
                    } else {
                        navigation.reset()
                    }
                    try? await Task.sleep(for: .milliseconds(33))
                }
            }
    }

    private func pollNavigation() -> Bool {
        for device in devices.devices {
            let snapshot: ControllerInputSnapshot?
            if let gamepad = devices.controller(for: device.id)?.extendedGamepad {
                snapshot = ControllerInputSnapshot(gamepad: gamepad)
            } else {
                snapshot = SteamControllerHIDMonitor.shared.snapshot(for: device.id)
            }
            guard let snapshot else { continue }
            let state = snapshot.gamepadState(deviceID: device.id, playerIndex: 0, timestamp: MediaTimestamp(nanoseconds: 0))
            switch navigation.process(state, deviceIDs: devices.playerOrder.deviceIDs) {
            case .move(let id, let direction): devices.move(id, direction: direction)
            case .close: dismiss(); return true
            case nil: break
            }
        }
        return false
    }
}

struct ControllerOrderPanel: View {
    static func sheetSize(deviceCount: Int, uiScale: CGFloat) -> CGSize {
        let height: CGFloat = deviceCount == 0 ? 320 : min(680, 360 + CGFloat(deviceCount) * 64)
        return SteamControllerSheetMetrics.size(width: 680, height: height, uiScale: uiScale)
    }

    let devices: [ControllerMappingDevice]
    let isCustom: Bool
    let focusedControl: ControllerOrderNavigationModel.Focus?
    let onMove: (InputDeviceID, ControllerPlayerOrder.Direction) -> Void
    let onReset: () -> Void
    let onClose: () -> Void
    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        VStack(spacing: 0) {
            SteamControllerModalTopBar()
            SteamControllerModalHeader(eyebrow: "CONTROLLERS", title: "Controller Order", uiScale: uiScale, onClose: onClose)
            SteamControllerModalRule()
            if devices.isEmpty {
                Text("No controllers connected")
                    .font(.settingsFont(size: 16 * uiScale, weight: .medium))
                    .foregroundStyle(OPNDesign.Text.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("Move controllers to choose Player 1–4. Changes apply immediately; mapping profiles stay with each controller. Remote Co-Op guests are not reordered.")
                    .font(.settingsFont(size: 12 * uiScale))
                    .foregroundStyle(OPNDesign.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(OPNDesign.Spacing.card(scale: uiScale))
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: OPNDesign.Spacing.xSmall(scale: uiScale)) {
                            ForEach(Array(devices.enumerated()), id: \.element.id) { index, device in
                                row(device: device, index: index).id(device.id)
                            }
                        }
                        .padding(.horizontal, OPNDesign.Spacing.card(scale: uiScale))
                        .padding(.bottom, OPNDesign.Spacing.card(scale: uiScale))
                    }
                    .task(id: scrollTarget) {
                        await Task.yield()
                        if !Task.isCancelled, let id = scrollTarget.deviceID { proxy.scrollTo(id, anchor: .center) }
                    }
                }
                Text("D-pad: navigate · Confirm: move · Back: close")
                    .font(.settingsFont(size: 11 * uiScale))
                    .foregroundStyle(OPNDesign.Text.secondary)
                Text("Order lasts for this connection session. New controllers join the end of a custom order. Some games may require reconnecting to recognize new player slots.")
                    .font(.settingsFont(size: 11 * uiScale))
                    .foregroundStyle(OPNDesign.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(OPNDesign.Spacing.card(scale: uiScale))
            }
            SteamControllerModalRule()
            HStack {
                Button("Default Order", action: onReset)
                    .buttonStyle(OPNModalSecondaryButtonStyle(uiScale: uiScale))
                    .disabled(!isCustom)
                    .opacity(isCustom ? 1 : 0.46)
                    .help("Restore Steam Controllers first, followed by other controllers.")
                Spacer()
                Button("CLOSE", action: onClose)
                    .buttonStyle(VendorGetInButtonStyle(uiScale: uiScale))
                    .keyboardShortcut(.cancelAction)
            }
            .padding(OPNDesign.Spacing.card(scale: uiScale))
        }
        .foregroundStyle(OPNDesign.Text.primary)
        .background(OPNDesign.Surface.deep)
    }

    private struct ScrollTarget: Equatable {
        let deviceID: InputDeviceID?
        let index: Int?
    }

    private var scrollTarget: ScrollTarget {
        ScrollTarget(deviceID: focusedControl?.deviceID, index: devices.firstIndex { $0.id == focusedControl?.deviceID })
    }

    private func row(device: ControllerMappingDevice, index: Int) -> some View {
        HStack(spacing: OPNDesign.Spacing.small(scale: uiScale)) {
            Text(index < ControllerPlayerOrder.maximumPlayers ? "PLAYER \(index + 1)" : "WAITING")
                .font(.settingsFont(size: 11 * uiScale, weight: .bold))
                .foregroundStyle(index < ControllerPlayerOrder.maximumPlayers ? OPNDesign.accentInk : OPNDesign.Text.muted)
                .frame(width: 76 * uiScale, alignment: .leading)
            VStack(alignment: .leading, spacing: OPNDesign.Spacing.xxSmall(scale: uiScale)) {
                Text(device.name)
                    .font(.settingsFont(size: 14 * uiScale, weight: .bold))
                    .lineLimit(1)
                    .help(device.name)
                Text(index < ControllerPlayerOrder.maximumPlayers ? device.family.label : "Move into the first four to use in the stream")
                    .font(.settingsFont(size: 11 * uiScale))
                    .foregroundStyle(OPNDesign.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            moveButton(device: device, direction: .earlier, disabled: index == 0)
            moveButton(device: device, direction: .later, disabled: index == devices.count - 1)
        }
        .padding(OPNDesign.Spacing.small(scale: uiScale))
        .background(OPNDesign.Surface.panel)
        .overlay { Rectangle().strokeBorder(OPNDesign.Stroke.subtle, lineWidth: 1) }
    }

    private func moveButton(device: ControllerMappingDevice, direction: ControllerPlayerOrder.Direction, disabled: Bool) -> some View {
        let label = direction == .earlier ? "Move \(device.name) earlier" : "Move \(device.name) later"
        return Button { onMove(device.id, direction) } label: {
            Image(systemName: direction == .earlier ? "arrow.up" : "arrow.down")
        }
        .buttonStyle(OPNModalSecondaryButtonStyle(uiScale: uiScale))
        .disabled(disabled)
        .overlay {
            if focusedControl?.deviceID == device.id, focusedControl?.direction == direction {
                Rectangle().strokeBorder(OPNDesign.accent, lineWidth: 2)
            }
        }
        .opacity(disabled ? 0.46 : 1)
        .accessibilityLabel(label)
        .help(label)
    }
}

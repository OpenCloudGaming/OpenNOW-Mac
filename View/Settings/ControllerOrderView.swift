import GameController
import SwiftUI

struct ControllerOrderView: View {
    /// The stream whose selection this panel edits, or nil on the Settings surface, where the panel
    /// only reorders the app-wide controller order.
    var stream: StreamControllerSelectionContext? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.opnUIScale) private var uiScale
    @ObservedObject private var devices = ControllerMappingDevices.shared
    @StateObject private var navigation = ControllerOrderNavigationModel()
    @State private var inputWindow = ControllerOrderWindowReference()
    @State private var streamRows: [ControllerStreamSelection.Row] = []

    var body: some View {
        let rows = self.rows
        let size = ControllerOrderPanel.sheetSize(deviceCount: rows.count, uiScale: uiScale)
        ControllerOrderPanel(rows: rows, isCustom: devices.playerOrder.isCustom, streamScoped: stream != nil,
                             focusedControl: navigation.focus,
                             onSetEnabled: { stream?.setEnabled($0, for: $1) },
                             onMove: devices.move, onReset: devices.resetOrder, onClose: { dismiss() })
            .frame(minWidth: size.width, idealWidth: size.width, minHeight: size.height, idealHeight: size.height)
            .background(ControllerOrderWindowReader(reference: inputWindow))
            .onExitCommand { dismiss() }
            .task {
                devices.refresh()
                navigation.activateToggles = stream != nil
                streamRows = stream?.rows ?? []
                SteamControllerHIDMonitor.shared.beginInputCapture(inputWindow)
                defer { SteamControllerHIDMonitor.shared.endInputCapture(inputWindow) }
                while !Task.isCancelled {
                    refreshStreamRows()
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

    /// Rows come from the stream's own selection when there is one, so the panel shows the effective
    /// player each enabled controller actually occupies rather than its place in the global order.
    private var rows: [ControllerOrderRow] {
        guard stream != nil else { return ControllerOrderRows.order(devices.orderedDevices) }
        let families = Dictionary(uniqueKeysWithValues: devices.devices.map { ($0.id, $0.family) })
        return ControllerOrderRows.stream(streamRows, families: families)
    }

    private func refreshStreamRows() {
        guard let stream else { return }
        let next = stream.rows
        guard next != streamRows else { return }
        streamRows = next
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
            case .toggle(let id): toggleStreamDevice(id)
            case .close: dismiss(); return true
            case nil: break
            }
        }
        return false
    }

    private func toggleStreamDevice(_ id: InputDeviceID) {
        guard let stream, let row = streamRows.first(where: { $0.id == id }), row.state != .disconnected else { return }
        stream.setEnabled(!row.isEnabled, for: id)
        refreshStreamRows()
    }
}

struct ControllerOrderPanel: View {
    static func sheetSize(deviceCount: Int, uiScale: CGFloat) -> CGSize {
        let height: CGFloat = deviceCount == 0 ? 320 : min(680, 360 + CGFloat(deviceCount) * 64)
        return SteamControllerSheetMetrics.size(width: 680, height: height, uiScale: uiScale)
    }

    let rows: [ControllerOrderRow]
    let isCustom: Bool
    /// Whether the panel is editing one stream's selection rather than the app-wide order alone.
    let streamScoped: Bool
    let focusedControl: ControllerOrderNavigationModel.Focus?
    let onSetEnabled: (Bool, InputDeviceID) -> Void
    let onMove: (InputDeviceID, ControllerPlayerOrder.Direction) -> Void
    let onReset: () -> Void
    let onClose: () -> Void
    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        VStack(spacing: 0) {
            SteamControllerModalTopBar()
            SteamControllerModalHeader(eyebrow: "CONTROLLERS", title: "Controller Order", uiScale: uiScale, onClose: onClose)
            SteamControllerModalRule()
            if rows.isEmpty {
                Text("No controllers connected")
                    .font(.settingsFont(size: 16 * uiScale, weight: .medium))
                    .foregroundStyle(OPNDesign.Text.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text(explanation)
                    .font(.settingsFont(size: 12 * uiScale))
                    .foregroundStyle(OPNDesign.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(OPNDesign.Spacing.card(scale: uiScale))
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: OPNDesign.Spacing.xSmall(scale: uiScale)) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                                self.row(row, index: index).id(row.id)
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
                Text(footerHint)
                    .font(.settingsFont(size: 11 * uiScale))
                    .foregroundStyle(OPNDesign.Text.secondary)
                Text(footerNote)
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

    private var explanation: String {
        guard streamScoped else {
            return "Move controllers to choose Player 1–4. Changes apply immediately; mapping profiles stay with each controller. Remote Co-Op guests are not reordered."
        }
        return "Enable controllers in this stream and move them in the shared order. Ordering is global and every stream uses it; the enable toggles affect this stream only. Mapping profiles stay with each controller, and Remote Co-Op guests are not reordered."
    }

    private var footerHint: String {
        streamScoped
            ? "D-pad: navigate · Left/Right: reorder · Confirm: enable or disable · Back: close"
            : "D-pad: navigate · Confirm: move · Back: close"
    }

    private var footerNote: String {
        streamScoped
            ? "Enablement and remembered rows last for this stream session. Controllers connected after the stream starts stay disabled until you enable them. Some games may require reconnecting to recognize new player slots."
            : "Order lasts for this connection session. New controllers join the end of a custom order. Some games may require reconnecting to recognize new player slots."
    }

    private struct ScrollTarget: Equatable {
        let deviceID: InputDeviceID?
        let index: Int?
    }

    private var scrollTarget: ScrollTarget {
        ScrollTarget(deviceID: focusedControl?.deviceID, index: rows.firstIndex { $0.id == focusedControl?.deviceID })
    }

    private func row(_ row: ControllerOrderRow, index: Int) -> some View {
        HStack(spacing: OPNDesign.Spacing.small(scale: uiScale)) {
            Text(row.slotLabel)
                .font(.settingsFont(size: 11 * uiScale, weight: .bold))
                .foregroundStyle(slotColor(for: row))
                .frame(width: 76 * uiScale, alignment: .leading)
            VStack(alignment: .leading, spacing: OPNDesign.Spacing.xxSmall(scale: uiScale)) {
                Text(row.name)
                    .font(.settingsFont(size: 14 * uiScale, weight: .bold))
                    .lineLimit(1)
                    .help(row.name)
                Text(row.detail)
                    .font(.settingsFont(size: 11 * uiScale))
                    .foregroundStyle(OPNDesign.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if row.showsEnableToggle {
                enableToggle(for: row)
            }
            moveButton(row: row, direction: .earlier, disabled: index == 0)
            moveButton(row: row, direction: .later, disabled: index == rows.count - 1)
        }
        .padding(OPNDesign.Spacing.small(scale: uiScale))
        .background(OPNCornerShape(role: .card, scale: uiScale).fill(OPNDesign.Surface.panel))
        .overlay { OPNCornerShape(role: .card, scale: uiScale).strokeBorder(OPNDesign.Stroke.subtle, lineWidth: 1) }
        .opacity(row.isDimmed ? 0.55 : 1)
    }

    /// The stream-scoped control. A disconnected row keeps showing the remembered choice but takes
    /// no action, so history cannot be edited after the hardware is gone.
    private func enableToggle(for row: ControllerOrderRow) -> some View {
        Toggle(isOn: Binding(get: { row.isEnabled }, set: { onSetEnabled($0, row.id) }), uiScale: uiScale)
            .accessibilityLabel("Enabled in this stream")
            .accessibilityValue(row.isEnabled ? "On" : "Off")
            .help(row.isEnabled ? "Enabled in this stream — disable it here" : "Disabled in this stream — enable it here")
    }

    private func slotColor(for row: ControllerOrderRow) -> Color {
        guard !row.isDimmed else { return OPNDesign.Text.muted }
        return row.isEnabled ? OPNDesign.accentInk : OPNDesign.Text.muted
    }

    private func moveButton(row: ControllerOrderRow, direction: ControllerPlayerOrder.Direction, disabled: Bool) -> some View {
        let label = direction == .earlier ? "Move \(row.name) earlier" : "Move \(row.name) later"
        return Button { onMove(row.id, direction) } label: {
            Image(systemName: direction == .earlier ? "arrow.up" : "arrow.down")
        }
        .buttonStyle(OPNModalSecondaryButtonStyle(uiScale: uiScale))
        .disabled(disabled)
        .overlay {
            if focusedControl?.deviceID == row.id, focusedControl?.direction == direction {
                OPNCornerShape(role: .control, scale: uiScale).strokeBorder(OPNDesign.accent, lineWidth: 2)
            }
        }
        .opacity(disabled ? 0.46 : 1)
        .accessibilityLabel(label)
        .help(label)
    }
}

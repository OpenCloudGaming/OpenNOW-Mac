import Combine
import SwiftUI

/// Live input tester: connection state, the matching controller diagram - Valve's shell for a
/// Steam Controller, a generic gamepad shell for anything GameController exposes - and every raw
/// axis and button value. Chrome follows the modal spec in DESIGN.md - accent top bar, App Bar
/// header, square surfaces, tokenised colours - and scales with the interface scale setting.
struct SteamControllerTestView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.opnUIScale) private var uiScale
    @StateObject private var steamModel = SteamControllerTestModel()
    @StateObject private var genericModel = GenericControllerTestModel()

    /// Which pad the tester is showing. Steam wins when both are attached: its HID path is the only
    /// one with rumble and a full shell to draw, and the generic branch covers everything else.
    private enum InputSource { case steam, generic, none }

    private var inputSource: InputSource {
        if steamModel.isConnected { return .steam }
        if genericModel.isConnected { return .generic }
        return .none
    }

    private var sheetSize: CGSize {
        SteamControllerSheetMetrics.size(width: 860, height: 700, uiScale: uiScale)
    }

    var body: some View {
        VStack(spacing: 0) {
            SteamControllerModalTopBar()
            SteamControllerModalHeader(
                eyebrow: "CONTROLLER",
                title: "Controller Test",
                uiScale: uiScale,
                onClose: { dismiss() }
            )
            SteamControllerModalRule()
            ScrollView {
                VStack(spacing: OPNDesign.Spacing.xLarge(scale: uiScale)) {
                    connectionStatusBar
                    testerContent
                }
                .padding(.horizontal, OPNDesign.Spacing.railHorizontal(scale: uiScale))
                .padding(.vertical, OPNDesign.Spacing.xLarge(scale: uiScale))
            }
        }
        .frame(minWidth: sheetSize.width, minHeight: sheetSize.height)
        .background(OPNDesign.Surface.deep)
        .foregroundStyle(OPNDesign.Text.primary)
        .onExitCommand { dismiss() }
        .onAppear {
            steamModel.start()
            genericModel.start()
        }
        .onDisappear {
            steamModel.stop()
            genericModel.stop()
        }
    }

    @ViewBuilder
    private var testerContent: some View {
        switch inputSource {
        case .steam:
            controllerDiagram
            rumblePanel
            rawValuesPanel
        case .generic:
            GenericControllerDiagramView(snapshot: genericModel.snapshot)
            rawValuesPanel
        case .none:
            noControllerMessage
        }
    }

    // MARK: - Connection

    private var connectedDeviceName: String {
        switch inputSource {
        case .steam: steamModel.deviceID
        case .generic: genericModel.deviceName
        case .none: ""
        }
    }

    private var batteryPercent: Int? {
        switch inputSource {
        case .steam: steamModel.batteryLevel.map { Int($0) }
        case .generic: genericModel.batteryPercent
        case .none: nil
        }
    }

    private var isCharging: Bool {
        switch inputSource {
        case .steam: steamModel.isCharging
        case .generic: genericModel.isCharging
        case .none: false
        }
    }

    private var connectionStatusBar: some View {
        HStack(spacing: OPNDesign.Spacing.section(scale: uiScale)) {
            SteamControllerStatusMarker(
                color: inputSource == .none ? OPNDesign.Semantic.destructive : OPNDesign.accent,
                uiScale: uiScale
            )
            Text(inputSource == .none ? "No controller detected" : "Connected")
                .font(.settingsFont(size: 12 * uiScale, weight: .bold))
                .foregroundStyle(OPNDesign.Text.secondary)
            if inputSource != .none {
                Spacer()
                if let battery = batteryPercent {
                    SteamControllerBadge(uiScale: uiScale) {
                        HStack(spacing: 4 * uiScale) {
                            Image(systemName: isCharging ? "bolt.fill" : batteryIconName(for: battery))
                                .font(.settingsFont(size: 11 * uiScale, weight: .medium))
                                .foregroundStyle(isCharging ? OPNDesign.accentInk : batteryColor(for: battery))
                            Text("\(battery)%")
                                .font(.settingsFont(size: 10 * uiScale, weight: .medium))
                                .foregroundStyle(OPNDesign.Text.tertiary)
                                .monospacedDigit()
                        }
                    }
                }
                Text(connectedDeviceName)
                    .font(.settingsFont(size: 10 * uiScale, weight: .medium))
                    .foregroundStyle(OPNDesign.Text.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private func batteryIconName(for level: Int) -> String {
        switch level {
        case 90...: return "battery.100percent"
        case 60..<90: return "battery.75percent"
        case 30..<60: return "battery.50percent"
        case 15..<30: return "battery.25percent"
        default: return "battery.0percent"
        }
    }

    private func batteryColor(for level: Int) -> Color {
        switch level {
        case 20...: return OPNDesign.accent
        case 10..<20: return OPNDesign.Semantic.warning
        default: return OPNDesign.Semantic.destructive
        }
    }

    private var noControllerMessage: some View {
        VStack(spacing: OPNDesign.Spacing.small(scale: uiScale)) {
            Image(systemName: "gamecontroller")
                .font(.settingsFont(size: 40 * uiScale))
                .foregroundStyle(OPNDesign.Text.muted.opacity(0.5))
            Text("Connect a controller to begin testing")
                .font(.settingsFont(size: 14 * uiScale, weight: .medium))
                .foregroundStyle(OPNDesign.Text.tertiary)
            Text("Steam Controllers need Steam Controller Support enabled in Settings → Input.")
                .font(.settingsFont(size: 11 * uiScale, weight: .medium))
                .foregroundStyle(OPNDesign.Text.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80 * uiScale)
    }

    // MARK: - Controller diagram

    private var controllerDiagram: some View {
        VStack(spacing: 6 * uiScale) {
            SteamControllerDiagramView(snapshot: steamModel.snapshot)
            Text("L4 · L5 · R4 · R5 sit on the underside of the grips")
                .font(.settingsFont(size: 10 * uiScale, weight: .medium))
                .foregroundStyle(OPNDesign.Text.muted)
        }
    }

    // MARK: - Rumble

    /// The same feature report a seat's rumble command drives, one motor at a time, so a game
    /// that stays silent can be told apart from a pad whose motors never fire.
    private var rumblePanel: some View {
        SteamControllerSection(title: "RUMBLE", uiScale: uiScale) {
            VStack(alignment: .leading, spacing: OPNDesign.Spacing.small(scale: uiScale)) {
                HStack(spacing: OPNDesign.Spacing.small(scale: uiScale)) {
                    rumbleButton("Left Motor", target: .left)
                    rumbleButton("Both", target: .both)
                    rumbleButton("Right Motor", target: .right)
                    Spacer()
                    Text(steamModel.rumbleInFlight == nil ? "Pulses for \(ControllerRumbleTester.pulseMilliseconds) ms" : "Rumbling…")
                        .font(.settingsFont(size: 10 * uiScale, weight: .medium))
                        .foregroundStyle(OPNDesign.Text.muted)
                        .monospacedDigit()
                }
                HStack(spacing: OPNDesign.Spacing.xSmall(scale: uiScale)) {
                    Text("Intensity")
                        .font(.settingsFont(size: 10 * uiScale, weight: .bold))
                        .foregroundStyle(OPNDesign.Text.tertiary)
                        .frame(width: 60 * uiScale, alignment: .leading)
                    Slider(value: Binding(get: { Double(steamModel.rumbleIntensityPercent) }, set: { steamModel.rumbleIntensityPercent = Int($0.rounded()) }), in: 0...100, step: 5)
                        .tint(OPNDesign.accent)
                    Text("\(steamModel.rumbleIntensityPercent)%")
                        .font(.settingsFont(size: 10 * uiScale, weight: .medium))
                        .foregroundStyle(OPNDesign.Text.secondary)
                        .monospacedDigit()
                        .frame(width: 40 * uiScale, alignment: .trailing)
                }
            }
        }
    }

    private func rumbleButton(_ title: String, target: SteamControllerTestModel.RumbleTarget) -> some View {
        Button(title) { steamModel.testRumble(target) }
            .buttonStyle(OPNCompactButtonStyle(uiScale: uiScale))
            .disabled(steamModel.rumbleInFlight != nil)
            .opacity(steamModel.rumbleInFlight == target ? 0.6 : 1)
    }

    // MARK: - Raw values

    @ViewBuilder
    private var rawValuesPanel: some View {
        switch inputSource {
        case .steam: steamRawValuesPanel
        case .generic: genericRawValuesPanel
        case .none: EmptyView()
        }
    }

    private var steamRawValuesPanel: some View {
        SteamControllerSection(title: "RAW INPUT VALUES", uiScale: uiScale) {
            HStack(alignment: .top, spacing: OPNDesign.Spacing.xLarge(scale: uiScale)) {
                steamAxesColumn
                steamButtonStatesGrid
            }
        }
    }

    private var steamAxesColumn: some View {
        VStack(spacing: OPNDesign.Spacing.xSmall(scale: uiScale)) {
            axisBar("LX", value: steamModel.snapshot.leftStickX)
            axisBar("LY", value: steamModel.snapshot.leftStickY)
            axisBar("RX", value: steamModel.snapshot.rightStickX)
            axisBar("RY", value: steamModel.snapshot.rightStickY)
            axisBar("LT", value: steamModel.snapshot.leftTrigger, unsigned: true)
            axisBar("RT", value: steamModel.snapshot.rightTrigger, unsigned: true)
            axisBar("LPX", value: steamModel.snapshot.leftPad.x)
            axisBar("LPY", value: steamModel.snapshot.leftPad.y)
            axisBar("RPX", value: steamModel.snapshot.rightPad.x)
            axisBar("RPY", value: steamModel.snapshot.rightPad.y)
        }
        .frame(maxWidth: .infinity)
    }

    private var steamButtonStatesGrid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 6 * uiScale), count: 2),
            spacing: 4 * uiScale
        ) {
            buttonStateRow("A", active: steamModel.snapshot.buttons.contains(.south))
            buttonStateRow("B", active: steamModel.snapshot.buttons.contains(.east))
            buttonStateRow("X", active: steamModel.snapshot.buttons.contains(.west))
            buttonStateRow("Y", active: steamModel.snapshot.buttons.contains(.north))
            buttonStateRow("LB", active: steamModel.snapshot.buttons.contains(.leftShoulder))
            buttonStateRow("RB", active: steamModel.snapshot.buttons.contains(.rightShoulder))
            buttonStateRow("SEL", active: steamModel.snapshot.buttons.contains(.select))
            buttonStateRow("STA", active: steamModel.snapshot.buttons.contains(.start))
            buttonStateRow("STM", active: steamModel.snapshot.buttons.contains(.mode))
            buttonStateRow("QAM", active: steamModel.snapshot.buttons.contains(.quickAccess))
            buttonStateRow("LS", active: steamModel.snapshot.buttons.contains(.leftStick))
            buttonStateRow("RS", active: steamModel.snapshot.buttons.contains(.rightStick))
            buttonStateRow("DU", active: steamModel.snapshot.buttons.contains(.dpadUp))
            buttonStateRow("DD", active: steamModel.snapshot.buttons.contains(.dpadDown))
            buttonStateRow("DL", active: steamModel.snapshot.buttons.contains(.dpadLeft))
            buttonStateRow("DR", active: steamModel.snapshot.buttons.contains(.dpadRight))
            buttonStateRow("L4", active: steamModel.snapshot.buttons.contains(.leftGrip))
            buttonStateRow("R4", active: steamModel.snapshot.buttons.contains(.rightGrip))
            buttonStateRow("L5", active: steamModel.snapshot.buttons.contains(.leftGrip2))
            buttonStateRow("R5", active: steamModel.snapshot.buttons.contains(.rightGrip2))
            buttonStateRow("LPT", active: steamModel.snapshot.leftPad.touched)
            buttonStateRow("RPT", active: steamModel.snapshot.rightPad.touched)
            buttonStateRow("LPC", active: steamModel.snapshot.leftPad.pressed)
            buttonStateRow("RPC", active: steamModel.snapshot.rightPad.pressed)
        }
        .frame(maxWidth: .infinity)
    }

    private var genericRawValuesPanel: some View {
        SteamControllerSection(title: "RAW INPUT VALUES", uiScale: uiScale) {
            HStack(alignment: .top, spacing: OPNDesign.Spacing.xLarge(scale: uiScale)) {
                genericAxesColumn
                genericButtonStatesGrid
            }
        }
    }

    private var genericAxesColumn: some View {
        VStack(spacing: OPNDesign.Spacing.xSmall(scale: uiScale)) {
            axisBar("LX", value: genericModel.snapshot.leftStickX)
            axisBar("LY", value: genericModel.snapshot.leftStickY)
            axisBar("RX", value: genericModel.snapshot.rightStickX)
            axisBar("RY", value: genericModel.snapshot.rightStickY)
            axisBar("LT", value: genericModel.snapshot.leftTrigger, unsigned: true)
            axisBar("RT", value: genericModel.snapshot.rightTrigger, unsigned: true)
        }
        .frame(maxWidth: .infinity)
    }

    private var genericButtonStatesGrid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 6 * uiScale), count: 2),
            spacing: 4 * uiScale
        ) {
            buttonStateRow("A", active: genericModel.snapshot.buttons.contains(.south))
            buttonStateRow("B", active: genericModel.snapshot.buttons.contains(.east))
            buttonStateRow("X", active: genericModel.snapshot.buttons.contains(.west))
            buttonStateRow("Y", active: genericModel.snapshot.buttons.contains(.north))
            buttonStateRow("LB", active: genericModel.snapshot.buttons.contains(.leftShoulder))
            buttonStateRow("RB", active: genericModel.snapshot.buttons.contains(.rightShoulder))
            buttonStateRow("VIEW", active: genericModel.snapshot.buttons.contains(.select))
            buttonStateRow("MENU", active: genericModel.snapshot.buttons.contains(.start))
            buttonStateRow("HOME", active: genericModel.snapshot.buttons.contains(.mode))
            buttonStateRow("LS", active: genericModel.snapshot.buttons.contains(.leftStick))
            buttonStateRow("RS", active: genericModel.snapshot.buttons.contains(.rightStick))
            buttonStateRow("DU", active: genericModel.snapshot.buttons.contains(.dpadUp))
            buttonStateRow("DD", active: genericModel.snapshot.buttons.contains(.dpadDown))
            buttonStateRow("DL", active: genericModel.snapshot.buttons.contains(.dpadLeft))
            buttonStateRow("DR", active: genericModel.snapshot.buttons.contains(.dpadRight))
        }
        .frame(maxWidth: .infinity)
    }

    private func axisBar(_ label: String, value: Float, unsigned: Bool = false) -> some View {
        HStack(spacing: OPNDesign.Spacing.xSmall(scale: uiScale)) {
            Text(label)
                .font(.settingsFont(size: 10 * uiScale, weight: .bold))
                .foregroundStyle(OPNDesign.Text.tertiary)
                .frame(width: 30 * uiScale, alignment: .leading)
            SteamControllerValueBar(value: value, signed: !unsigned, uiScale: uiScale)
            Text(String(format: unsigned ? "%.2f" : "%+.3f", value))
                .font(.settingsFont(size: 10 * uiScale, weight: .medium))
                .foregroundStyle(OPNDesign.Text.secondary)
                .monospacedDigit()
                .frame(width: 52 * uiScale, alignment: .trailing)
        }
    }

    private func buttonStateRow(_ label: String, active: Bool) -> some View {
        HStack(spacing: 6 * uiScale) {
            Text(label)
                .font(.settingsFont(size: 10 * uiScale, weight: .bold))
                .foregroundStyle(active ? OPNDesign.accentInk : OPNDesign.Text.tertiary)
                .frame(width: 36 * uiScale, alignment: .leading)
            // Fixed column: "ON" and "OFF" are different widths, and the UI sans isn't monospaced,
            // so an unconstrained label makes the whole grid twitch as buttons are pressed.
            Text(active ? "ON" : "OFF")
                .font(.settingsFont(size: 10 * uiScale, weight: .medium))
                .foregroundStyle(active ? OPNDesign.accentInk : OPNDesign.Text.muted)
                .frame(width: 26 * uiScale, alignment: .leading)
        }
    }
}

import Combine
import SwiftUI

/// Live input tester: connection state, the shared controller diagram, and every raw axis and
/// button value. Chrome follows the modal spec in DESIGN.md — accent top bar, App Bar header,
/// square surfaces, tokenised colours — and scales with the interface scale setting.
struct SteamControllerTestView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.opnUIScale) private var uiScale
    @StateObject private var model = SteamControllerTestModel()

    private var sheetSize: CGSize {
        SteamControllerSheetMetrics.size(width: 860, height: 700, uiScale: uiScale)
    }

    var body: some View {
        VStack(spacing: 0) {
            SteamControllerModalTopBar()
            SteamControllerModalHeader(
                eyebrow: "STEAM CONTROLLER",
                title: "Controller Test",
                uiScale: uiScale,
                onClose: { dismiss() }
            )
            SteamControllerModalRule()
            ScrollView {
                VStack(spacing: OpenNOWDesign.Spacing.xLarge(scale: uiScale)) {
                    connectionStatusBar
                    if model.isConnected {
                        controllerDiagram
                        rumblePanel
                        rawValuesPanel
                    } else {
                        noControllerMessage
                    }
                }
                .padding(.horizontal, OpenNOWDesign.Spacing.railHorizontal(scale: uiScale))
                .padding(.vertical, OpenNOWDesign.Spacing.xLarge(scale: uiScale))
            }
        }
        .frame(minWidth: sheetSize.width, minHeight: sheetSize.height)
        .background(OpenNOWDesign.Surface.deep)
        .foregroundStyle(OpenNOWDesign.Text.primary)
        .onExitCommand { dismiss() }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    private var connectionStatusBar: some View {
        HStack(spacing: OpenNOWDesign.Spacing.section(scale: uiScale)) {
            SteamControllerStatusMarker(
                color: model.isConnected ? OpenNOWDesign.accent : OpenNOWDesign.Semantic.destructive,
                uiScale: uiScale
            )
            Text(model.isConnected ? "Connected" : "No controller detected")
                .font(.settingsFont(size: 12 * uiScale, weight: .bold))
                .foregroundStyle(OpenNOWDesign.Text.secondary)
            if model.isConnected {
                Spacer()
                if let battery = model.batteryLevel {
                    SteamControllerBadge(uiScale: uiScale) {
                        HStack(spacing: 4 * uiScale) {
                            Image(systemName: model.isCharging ? "bolt.fill" : batteryIconName(for: battery))
                                .font(.settingsFont(size: 11 * uiScale, weight: .medium))
                                .foregroundStyle(model.isCharging ? OpenNOWDesign.accent : batteryColor(for: battery))
                            Text("\(Int(battery))%")
                                .font(.settingsFont(size: 10 * uiScale, weight: .medium))
                                .foregroundStyle(OpenNOWDesign.Text.tertiary)
                                .monospacedDigit()
                        }
                    }
                }
                Text(model.deviceID)
                    .font(.settingsFont(size: 10 * uiScale, weight: .medium))
                    .foregroundStyle(OpenNOWDesign.Text.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private func batteryIconName(for level: UInt8) -> String {
        switch level {
        case 90...: return "battery.100percent"
        case 60..<90: return "battery.75percent"
        case 30..<60: return "battery.50percent"
        case 15..<30: return "battery.25percent"
        default: return "battery.0percent"
        }
    }

    private func batteryColor(for level: UInt8) -> Color {
        switch level {
        case 20...: return OpenNOWDesign.accent
        case 10..<20: return OpenNOWDesign.Semantic.warning
        default: return OpenNOWDesign.Semantic.destructive
        }
    }

    private var noControllerMessage: some View {
        VStack(spacing: OpenNOWDesign.Spacing.small(scale: uiScale)) {
            Image(systemName: "gamecontroller")
                .font(.settingsFont(size: 40 * uiScale))
                .foregroundStyle(OpenNOWDesign.Text.muted.opacity(0.5))
            Text("Connect a Steam Controller to begin testing")
                .font(.settingsFont(size: 14 * uiScale, weight: .medium))
                .foregroundStyle(OpenNOWDesign.Text.tertiary)
            Text("Make sure Steam Controller Support is enabled in Experimental Features")
                .font(.settingsFont(size: 11 * uiScale, weight: .medium))
                .foregroundStyle(OpenNOWDesign.Text.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80 * uiScale)
    }

    // MARK: - Controller diagram

    private var controllerDiagram: some View {
        VStack(spacing: 6 * uiScale) {
            SteamControllerDiagramView(snapshot: model.snapshot, backgroundColor: OpenNOWDesign.Surface.deep)
            Text("L4 · L5 · R4 · R5 sit on the underside of the grips")
                .font(.settingsFont(size: 10 * uiScale, weight: .medium))
                .foregroundStyle(OpenNOWDesign.Text.muted)
        }
    }

    // MARK: - Rumble

    /// The same feature report a seat's rumble command drives, one motor at a time, so a game
    /// that stays silent can be told apart from a pad whose motors never fire.
    private var rumblePanel: some View {
        SteamControllerSection(title: "RUMBLE", uiScale: uiScale) {
            VStack(alignment: .leading, spacing: OpenNOWDesign.Spacing.small(scale: uiScale)) {
                HStack(spacing: OpenNOWDesign.Spacing.small(scale: uiScale)) {
                    rumbleButton("Left Motor", target: .left)
                    rumbleButton("Both", target: .both)
                    rumbleButton("Right Motor", target: .right)
                    Spacer()
                    Text(model.rumbleInFlight == nil ? "Pulses for \(ControllerRumbleTester.pulseMilliseconds) ms" : "Rumbling…")
                        .font(.settingsFont(size: 10 * uiScale, weight: .medium))
                        .foregroundStyle(OpenNOWDesign.Text.muted)
                        .monospacedDigit()
                }
                HStack(spacing: OpenNOWDesign.Spacing.xSmall(scale: uiScale)) {
                    Text("Intensity")
                        .font(.settingsFont(size: 10 * uiScale, weight: .bold))
                        .foregroundStyle(OpenNOWDesign.Text.tertiary)
                        .frame(width: 60 * uiScale, alignment: .leading)
                    Slider(value: Binding(get: { Double(model.rumbleIntensityPercent) }, set: { model.rumbleIntensityPercent = Int($0.rounded()) }), in: 0...100, step: 5)
                        .tint(OpenNOWDesign.accent)
                    Text("\(model.rumbleIntensityPercent)%")
                        .font(.settingsFont(size: 10 * uiScale, weight: .medium))
                        .foregroundStyle(OpenNOWDesign.Text.secondary)
                        .monospacedDigit()
                        .frame(width: 40 * uiScale, alignment: .trailing)
                }
            }
        }
    }

    private func rumbleButton(_ title: String, target: SteamControllerTestModel.RumbleTarget) -> some View {
        Button(title) { model.testRumble(target) }
            .buttonStyle(OpenNOWCompactButtonStyle(uiScale: uiScale))
            .disabled(model.rumbleInFlight != nil)
            .opacity(model.rumbleInFlight == target ? 0.6 : 1)
    }

    // MARK: - Raw values

    private var rawValuesPanel: some View {
        SteamControllerSection(title: "RAW INPUT VALUES", uiScale: uiScale) {
            HStack(alignment: .top, spacing: OpenNOWDesign.Spacing.xLarge(scale: uiScale)) {
                axesColumn
                buttonStatesGrid
            }
        }
    }

    private var axesColumn: some View {
        VStack(spacing: OpenNOWDesign.Spacing.xSmall(scale: uiScale)) {
            axisBar("LX", value: model.snapshot.leftStickX)
            axisBar("LY", value: model.snapshot.leftStickY)
            axisBar("RX", value: model.snapshot.rightStickX)
            axisBar("RY", value: model.snapshot.rightStickY)
            axisBar("LT", value: model.snapshot.leftTrigger, unsigned: true)
            axisBar("RT", value: model.snapshot.rightTrigger, unsigned: true)
            axisBar("LPX", value: model.snapshot.leftPad.x)
            axisBar("LPY", value: model.snapshot.leftPad.y)
            axisBar("RPX", value: model.snapshot.rightPad.x)
            axisBar("RPY", value: model.snapshot.rightPad.y)
        }
        .frame(maxWidth: .infinity)
    }

    private func axisBar(_ label: String, value: Float, unsigned: Bool = false) -> some View {
        HStack(spacing: OpenNOWDesign.Spacing.xSmall(scale: uiScale)) {
            Text(label)
                .font(.settingsFont(size: 10 * uiScale, weight: .bold))
                .foregroundStyle(OpenNOWDesign.Text.tertiary)
                .frame(width: 30 * uiScale, alignment: .leading)
            SteamControllerValueBar(value: value, signed: !unsigned, uiScale: uiScale)
            Text(String(format: unsigned ? "%.2f" : "%+.3f", value))
                .font(.settingsFont(size: 10 * uiScale, weight: .medium))
                .foregroundStyle(OpenNOWDesign.Text.secondary)
                .monospacedDigit()
                .frame(width: 52 * uiScale, alignment: .trailing)
        }
    }

    private var buttonStatesGrid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 6 * uiScale), count: 2),
            spacing: 4 * uiScale
        ) {
            buttonStateRow("A", active: model.snapshot.buttons.contains(.south))
            buttonStateRow("B", active: model.snapshot.buttons.contains(.east))
            buttonStateRow("X", active: model.snapshot.buttons.contains(.west))
            buttonStateRow("Y", active: model.snapshot.buttons.contains(.north))
            buttonStateRow("LB", active: model.snapshot.buttons.contains(.leftShoulder))
            buttonStateRow("RB", active: model.snapshot.buttons.contains(.rightShoulder))
            buttonStateRow("SEL", active: model.snapshot.buttons.contains(.select))
            buttonStateRow("STA", active: model.snapshot.buttons.contains(.start))
            buttonStateRow("STM", active: model.snapshot.buttons.contains(.mode))
            buttonStateRow("QAM", active: model.snapshot.buttons.contains(.quickAccess))
            buttonStateRow("LS", active: model.snapshot.buttons.contains(.leftStick))
            buttonStateRow("RS", active: model.snapshot.buttons.contains(.rightStick))
            buttonStateRow("DU", active: model.snapshot.buttons.contains(.dpadUp))
            buttonStateRow("DD", active: model.snapshot.buttons.contains(.dpadDown))
            buttonStateRow("DL", active: model.snapshot.buttons.contains(.dpadLeft))
            buttonStateRow("DR", active: model.snapshot.buttons.contains(.dpadRight))
            buttonStateRow("L4", active: model.snapshot.buttons.contains(.leftGrip))
            buttonStateRow("R4", active: model.snapshot.buttons.contains(.rightGrip))
            buttonStateRow("L5", active: model.snapshot.buttons.contains(.leftGrip2))
            buttonStateRow("R5", active: model.snapshot.buttons.contains(.rightGrip2))
            buttonStateRow("LPT", active: model.snapshot.leftPad.touched)
            buttonStateRow("RPT", active: model.snapshot.rightPad.touched)
            buttonStateRow("LPC", active: model.snapshot.leftPad.pressed)
            buttonStateRow("RPC", active: model.snapshot.rightPad.pressed)
        }
        .frame(maxWidth: .infinity)
    }

    private func buttonStateRow(_ label: String, active: Bool) -> some View {
        HStack(spacing: 6 * uiScale) {
            Text(label)
                .font(.settingsFont(size: 10 * uiScale, weight: .bold))
                .foregroundStyle(active ? OpenNOWDesign.accent : OpenNOWDesign.Text.tertiary)
                .frame(width: 30 * uiScale, alignment: .leading)
            // Fixed column: "ON" and "OFF" are different widths, and the UI sans isn't monospaced,
            // so an unconstrained label makes the whole grid twitch as buttons are pressed.
            Text(active ? "ON" : "OFF")
                .font(.settingsFont(size: 10 * uiScale, weight: .medium))
                .foregroundStyle(active ? OpenNOWDesign.accent : OpenNOWDesign.Text.muted)
                .frame(width: 26 * uiScale, alignment: .leading)
        }
    }
}

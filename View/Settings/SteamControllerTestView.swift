import Combine
import SwiftUI

struct SteamControllerTestView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = SteamControllerTestModel()

    private static let backgroundColor = MacForceNowDesign.Surface.deep

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.12))
            ScrollView {
                VStack(spacing: 28) {
                    connectionStatusBar
                    if model.isConnected {
                        controllerDiagram
                        rawValuesPanel
                    } else {
                        noControllerMessage
                    }
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 24)
            }
        }
        .frame(minWidth: 860, minHeight: 700)
        .background(Self.backgroundColor)
        .foregroundStyle(.white)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    private var header: some View {
        HStack {
            Image(systemName: "gamecontroller.fill")
                .font(.nvidiaSans(size: 18))
                .foregroundStyle(MacForceNowDesign.accent)
            Text("STEAM CONTROLLER TEST")
                .font(MacForceNowNVIDIAFont.font(size: 15, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(.white.opacity(0.78))
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.nvidiaSans(size: 13, weight: .bold))
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

    private var connectionStatusBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(model.isConnected ? MacForceNowDesign.accent : Color.red.opacity(0.7))
                .frame(width: 8, height: 8)
                .shadow(color: (model.isConnected ? MacForceNowDesign.accent : Color.red).opacity(0.5), radius: 3)
            Text(model.isConnected ? "Connected" : "No controller detected")
                .font(MacForceNowNVIDIAFont.font(size: 12, weight: .bold))
                .foregroundStyle(.white.opacity(0.7))
            if model.isConnected {
                Spacer()
                if let battery = model.batteryLevel {
                    HStack(spacing: 4) {
                        Image(systemName: model.isCharging ? "bolt.fill" : batteryIconName(for: battery))
                            .font(.nvidiaSans(size: 11, weight: .medium))
                            .foregroundStyle(model.isCharging ? .yellow : batteryColor(for: battery))
                        Text("\(Int(battery))%")
                            .font(MacForceNowNVIDIAFont.font(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.04))
                    .clipShape(Capsule())
                }
                Text(model.deviceID)
                    .font(MacForceNowNVIDIAFont.font(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.3))
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
        case 20...: return MacForceNowDesign.accent
        case 10..<20: return .orange
        default: return .red
        }
    }

    private var noControllerMessage: some View {
        VStack(spacing: 12) {
            Image(systemName: "gamecontroller")
                .font(.nvidiaSans(size: 48))
                .foregroundStyle(.white.opacity(0.15))
            Text("Connect a Steam Controller to begin testing")
                .font(MacForceNowNVIDIAFont.font(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
            Text("Make sure Steam Controller Support is enabled in Experimental Features")
                .font(MacForceNowNVIDIAFont.font(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.25))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }

    // MARK: - Controller diagram

    private var controllerDiagram: some View {
        VStack(spacing: 6) {
            SteamControllerDiagramView(snapshot: model.snapshot, backgroundColor: Self.backgroundColor)
            Text("L4 · L5 · R4 · R5 sit on the underside of the grips")
                .font(MacForceNowNVIDIAFont.font(size: 9, weight: .medium))
                .tracking(0.5)
                .foregroundStyle(.white.opacity(0.2))
        }
    }

    // MARK: - Raw values

    private var rawValuesPanel: some View {
        VStack(spacing: 16) {
            Text("RAW INPUT VALUES")
                .font(MacForceNowNVIDIAFont.font(size: 11, weight: .bold))
                .tracking(1.0)
                .foregroundStyle(.white.opacity(0.35))
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(alignment: .top, spacing: 24) {
                axesColumn
                buttonStatesGrid
            }
        }
        .padding(20)
        .background(Color.white.opacity(0.02))
        .overlay(Rectangle().stroke(Color.white.opacity(0.06), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var axesColumn: some View {
        VStack(spacing: 8) {
            axisBar("LX", value: model.snapshot.leftStickX)
            axisBar("LY", value: model.snapshot.leftStickY)
            axisBar("RX", value: model.snapshot.rightStickX)
            axisBar("RY", value: model.snapshot.rightStickY)
            axisBar("LT", value: model.snapshot.leftTrigger * 2 - 1, raw: model.snapshot.leftTrigger, unsigned: true)
            axisBar("RT", value: model.snapshot.rightTrigger * 2 - 1, raw: model.snapshot.rightTrigger, unsigned: true)
            axisBar("LPX", value: model.snapshot.leftPad.x)
            axisBar("LPY", value: model.snapshot.leftPad.y)
            axisBar("RPX", value: model.snapshot.rightPad.x)
            axisBar("RPY", value: model.snapshot.rightPad.y)
        }
        .frame(maxWidth: .infinity)
    }

    private func axisBar(_ label: String, value: Float, raw: Float? = nil, unsigned: Bool = false) -> some View {
        let displayValue = raw ?? value
        return HStack(spacing: 8) {
            Text(label)
                .font(MacForceNowNVIDIAFont.font(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.4))
                .frame(width: 28, alignment: .leading)
            GeometryReader { geo in
                let barWidth = geo.size.width
                if unsigned {
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.white.opacity(0.06))
                        RoundedRectangle(cornerRadius: 2)
                            .fill(MacForceNowDesign.accent.opacity(0.6))
                            .frame(width: barWidth * CGFloat(max(0, min(1, displayValue))))
                    }
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.white.opacity(0.06))
                        Rectangle()
                            .fill(Color.white.opacity(0.08))
                            .frame(width: 1)
                            .position(x: barWidth / 2, y: geo.size.height / 2)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(MacForceNowDesign.accent.opacity(0.6))
                            .frame(width: barWidth * CGFloat(abs(value) / 2))
                            .offset(x: value >= 0 ? barWidth * CGFloat(value) / 4 : -barWidth * CGFloat(abs(value)) / 4)
                    }
                }
            }
            .frame(height: 8)
            Text(String(format: unsigned ? "%.2f" : "%+.3f", unsigned ? displayValue : value))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 52, alignment: .trailing)
        }
    }

    private var buttonStatesGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 2), spacing: 4) {
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
        HStack(spacing: 6) {
            Text(label)
                .font(MacForceNowNVIDIAFont.font(size: 10, weight: .bold))
                .foregroundStyle(active ? MacForceNowDesign.accent : .white.opacity(0.35))
                .frame(width: 28, alignment: .leading)
            Text(active ? "ON" : "OFF")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(active ? MacForceNowDesign.accent.opacity(0.8) : .white.opacity(0.2))
        }
    }
}

@MainActor
final class SteamControllerTestModel: ObservableObject {
    @Published var snapshot = SteamControllerInputSnapshot()
    @Published var deviceID: String = ""
    @Published var isConnected = false
    @Published var batteryLevel: UInt8?
    @Published var isCharging: Bool = false

    private var consumerKey: ObjectIdentifier?
    private var monitorWasEnabled = false

    func start() {
        monitorWasEnabled = SteamControllerPreference.isEnabled
        if !monitorWasEnabled {
            SteamControllerHIDMonitor.shared.setEnabled(true)
        }

        consumerKey = ObjectIdentifier(self)
        SteamControllerHIDMonitor.shared.beginInputCapture(self)
        SteamControllerHIDMonitor.shared.register(
            self,
            onControllersChanged: { [weak self] in self?.refreshConnection() },
            onInputState: { [weak self] deviceID, snapshot in
                guard let self else { return }
                self.deviceID = deviceID.rawValue
                self.snapshot = snapshot
                if !self.isConnected { self.isConnected = true }
            },
            onBatteryLevel: { [weak self] _, level in
                guard let self else { return }
                self.batteryLevel = level
            }
        )
        refreshConnection()
    }

    func stop() {
        if let consumerKey {
            SteamControllerHIDMonitor.shared.unregister(key: consumerKey)
            SteamControllerHIDMonitor.shared.endInputCapture(key: consumerKey)
        }
        consumerKey = nil

        if !monitorWasEnabled {
            SteamControllerHIDMonitor.shared.setEnabled(false)
        }
    }

    private func refreshConnection() {
        let ids = SteamControllerHIDMonitor.shared.activeDeviceIDs
        if let first = ids.first {
            isConnected = true
            deviceID = first.rawValue
            batteryLevel = SteamControllerHIDMonitor.shared.batteryLevels[first]
            isCharging = SteamControllerHIDMonitor.shared.batteryCharging[first] ?? false
            if let snap = SteamControllerHIDMonitor.shared.snapshot(for: first) {
                snapshot = snap
            }
        } else {
            isConnected = false
            deviceID = ""
            batteryLevel = nil
            isCharging = false
            snapshot = SteamControllerInputSnapshot()
        }
    }
}

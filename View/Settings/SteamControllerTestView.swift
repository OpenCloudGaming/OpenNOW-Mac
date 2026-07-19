import Combine
import SwiftUI

struct SteamControllerTestView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = SteamControllerTestModel()

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
        .background(Color(red: 18 / 255, green: 19 / 255, blue: 18 / 255))
        .foregroundStyle(.white)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    private var header: some View {
        HStack {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 18))
                .foregroundStyle(Color.openNowGreen)
            Text("STEAM CONTROLLER TEST")
                .font(OpenNOWNVIDIAFont.font(size: 15, weight: .bold))
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

    private var connectionStatusBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(model.isConnected ? Color.openNowGreen : Color.red.opacity(0.7))
                .frame(width: 8, height: 8)
                .shadow(color: (model.isConnected ? Color.openNowGreen : Color.red).opacity(0.5), radius: 3)
            Text(model.isConnected ? "Connected" : "No controller detected")
                .font(OpenNOWNVIDIAFont.font(size: 12, weight: .bold))
                .foregroundStyle(.white.opacity(0.7))
            if model.isConnected {
                Spacer()
                Text(model.deviceID)
                    .font(OpenNOWNVIDIAFont.font(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.3))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var noControllerMessage: some View {
        VStack(spacing: 12) {
            Image(systemName: "gamecontroller")
                .font(.system(size: 48))
                .foregroundStyle(.white.opacity(0.15))
            Text("Connect a Steam Controller to begin testing")
                .font(OpenNOWNVIDIAFont.font(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
            Text("Make sure Steam Controller Support is enabled in Experimental Features")
                .font(OpenNOWNVIDIAFont.font(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.25))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }

    private var controllerDiagram: some View {
        VStack(spacing: 0) {
            controllerBody
            shoulderButtons
            backGripButtons
        }
    }

    private var backGripButtons: some View {
        HStack(spacing: 12) {
            VStack(spacing: 4) {
                gripButton("L4", pressed: model.snapshot.buttons.contains(.leftGrip))
                    .frame(width: 70, height: 28)
                gripButton("L5", pressed: model.snapshot.buttons.contains(.leftGrip2))
                    .frame(width: 70, height: 28)
            }
            Text("BACK GRIPS")
                .font(OpenNOWNVIDIAFont.font(size: 8, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.2))
            VStack(spacing: 4) {
                gripButton("R4", pressed: model.snapshot.buttons.contains(.rightGrip))
                    .frame(width: 70, height: 28)
                gripButton("R5", pressed: model.snapshot.buttons.contains(.rightGrip2))
                    .frame(width: 70, height: 28)
            }
        }
        .padding(.top, 16)
    }

    private func gripButton(_ label: String, pressed: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(pressed ? Color.openNowGreen.opacity(0.25) : Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(pressed ? Color.openNowGreen.opacity(0.6) : Color.white.opacity(0.12), lineWidth: 1)
                )
            Text(label)
                .font(OpenNOWNVIDIAFont.font(size: 11, weight: .bold))
                .foregroundStyle(pressed ? Color.openNowGreen : .white.opacity(0.5))
        }
    }

    private var controllerBody: some View {
        ZStack {
            controllerOutline

            VStack {
                HStack(spacing: 0) {
                    leftStickView
                        .frame(width: 120, height: 120)
                    Spacer()
                    faceButtonsView
                        .frame(width: 120, height: 120)
                }
                .padding(.horizontal, 60)
                .padding(.top, 20)

                Spacer()

                HStack(spacing: 0) {
                    dpadView
                        .frame(width: 100, height: 100)
                    Spacer()
                    rightStickView
                        .frame(width: 120, height: 120)
                }
                .padding(.horizontal, 70)
                .padding(.bottom, 20)
            }
            .frame(width: 440, height: 280)

            centerButtonsView
        }
        .frame(width: 500, height: 320)
    }

    private var controllerOutline: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height

            let bodyRect = CGRect(x: w * 0.08, y: h * 0.05, width: w * 0.84, height: h * 0.9)
            let bodyPath = Path(roundedRect: bodyRect, cornerRadius: 60)

            let leftGrip = Path { p in
                p.move(to: CGPoint(x: w * 0.12, y: h * 0.55))
                p.addQuadCurve(to: CGPoint(x: w * 0.02, y: h * 0.95),
                               control: CGPoint(x: w * 0.0, y: h * 0.75))
                p.addQuadCurve(to: CGPoint(x: w * 0.18, y: h * 0.95),
                               control: CGPoint(x: w * 0.08, y: h * 1.02))
                p.addLine(to: CGPoint(x: w * 0.22, y: h * 0.7))
            }

            let rightGrip = Path { p in
                p.move(to: CGPoint(x: w * 0.88, y: h * 0.55))
                p.addQuadCurve(to: CGPoint(x: w * 0.98, y: h * 0.95),
                               control: CGPoint(x: w * 1.0, y: h * 0.75))
                p.addQuadCurve(to: CGPoint(x: w * 0.82, y: h * 0.95),
                               control: CGPoint(x: w * 0.92, y: h * 1.02))
                p.addLine(to: CGPoint(x: w * 0.78, y: h * 0.7))
            }

            let strokeColor = Color.white.opacity(0.12)
            let fillColor = Color.white.opacity(0.03)

            context.fill(bodyPath, with: .color(fillColor))
            context.stroke(bodyPath, with: .color(strokeColor), lineWidth: 1.5)
            context.stroke(leftGrip, with: .color(strokeColor), lineWidth: 1.5)
            context.stroke(rightGrip, with: .color(strokeColor), lineWidth: 1.5)
        }
    }

    private var shoulderButtons: some View {
        HStack(spacing: 0) {
            triggerButton("L2", value: model.snapshot.leftTrigger, pressed: model.snapshot.leftTrigger > 0.05)
                .frame(width: 100, height: 36)
            bumperButton("L1", pressed: model.snapshot.buttons.contains(.leftShoulder))
                .frame(width: 80, height: 28)
            Spacer()
            bumperButton("R1", pressed: model.snapshot.buttons.contains(.rightShoulder))
                .frame(width: 80, height: 28)
            triggerButton("R2", value: model.snapshot.rightTrigger, pressed: model.snapshot.rightTrigger > 0.05)
                .frame(width: 100, height: 36)
        }
        .frame(width: 500)
    }

    private func triggerButton(_ label: String, value: Float, pressed: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(pressed ? Color.openNowGreen.opacity(0.25) : Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(pressed ? Color.openNowGreen.opacity(0.6) : Color.white.opacity(0.12), lineWidth: 1)
                )
            HStack(spacing: 4) {
                Text(label)
                    .font(OpenNOWNVIDIAFont.font(size: 11, weight: .bold))
                    .foregroundStyle(pressed ? Color.openNowGreen : .white.opacity(0.5))
                Text("\(Int(value * 100))%")
                    .font(OpenNOWNVIDIAFont.font(size: 10, weight: .medium))
                    .foregroundStyle(pressed ? Color.openNowGreen.opacity(0.8) : .white.opacity(0.3))
                    .monospacedDigit()
            }
        }
    }

    private func bumperButton(_ label: String, pressed: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(pressed ? Color.openNowGreen.opacity(0.25) : Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(pressed ? Color.openNowGreen.opacity(0.6) : Color.white.opacity(0.12), lineWidth: 1)
                )
            Text(label)
                .font(OpenNOWNVIDIAFont.font(size: 11, weight: .bold))
                .foregroundStyle(pressed ? Color.openNowGreen : .white.opacity(0.5))
        }
    }

    private var leftStickView: some View {
        stickView(
            label: "LS",
            x: model.snapshot.leftStickX,
            y: model.snapshot.leftStickY,
            pressed: model.snapshot.buttons.contains(.leftStick)
        )
    }

    private var rightStickView: some View {
        stickView(
            label: "RS",
            x: model.snapshot.rightStickX,
            y: model.snapshot.rightStickY,
            pressed: model.snapshot.buttons.contains(.rightStick)
        )
    }

    private func stickView(label: String, x: Float, y: Float, pressed: Bool) -> some View {
        let active = pressed || abs(x) > 0.05 || abs(y) > 0.05
        return ZStack {
            Circle()
                .stroke(Color.white.opacity(active ? 0.2 : 0.08), lineWidth: 1)
                .background(Circle().fill(Color.white.opacity(0.02)))

            Circle()
                .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
                .frame(width: 8, height: 8)

            Path { p in
                p.move(to: CGPoint(x: 0, y: -45))
                p.addLine(to: CGPoint(x: 0, y: 45))
                p.move(to: CGPoint(x: -45, y: 0))
                p.addLine(to: CGPoint(x: 45, y: 0))
            }
            .stroke(Color.white.opacity(0.04), lineWidth: 0.5)

            Circle()
                .fill(active ? Color.openNowGreen : Color.white.opacity(0.3))
                .frame(width: 18, height: 18)
                .shadow(color: active ? Color.openNowGreen.opacity(0.5) : .clear, radius: 6)
                .offset(x: CGFloat(x) * 35, y: CGFloat(-y) * 35)

            Text(label)
                .font(OpenNOWNVIDIAFont.font(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(0.2))
                .offset(y: 50)
        }
    }

    private var faceButtonsView: some View {
        ZStack {
            faceButtonNode("Y", x: 0, y: -38, pressed: model.snapshot.buttons.contains(.north))
            faceButtonNode("B", x: 38, y: 0, pressed: model.snapshot.buttons.contains(.east))
            faceButtonNode("A", x: 0, y: 38, pressed: model.snapshot.buttons.contains(.south))
            faceButtonNode("X", x: -38, y: 0, pressed: model.snapshot.buttons.contains(.west))
        }
    }

    private func faceButtonNode(_ label: String, x: CGFloat, y: CGFloat, pressed: Bool) -> some View {
        ZStack {
            Circle()
                .fill(pressed ? Color.openNowGreen : Color.white.opacity(0.05))
                .overlay(Circle().stroke(pressed ? Color.openNowGreen.opacity(0.8) : Color.white.opacity(0.12), lineWidth: 1))
                .frame(width: 34, height: 34)
                .shadow(color: pressed ? Color.openNowGreen.opacity(0.4) : .clear, radius: 6)
                .offset(x: x, y: y)
            Text(label)
                .font(OpenNOWNVIDIAFont.font(size: 12, weight: .bold))
                .foregroundStyle(pressed ? .black : .white.opacity(0.35))
                .offset(x: x, y: y)
        }
    }

    private var dpadView: some View {
        ZStack {
            dpadSegment("U", rotation: 0, pressed: model.snapshot.buttons.contains(.dpadUp))
            dpadSegment("R", rotation: 90, pressed: model.snapshot.buttons.contains(.dpadRight))
            dpadSegment("D", rotation: 180, pressed: model.snapshot.buttons.contains(.dpadDown))
            dpadSegment("L", rotation: 270, pressed: model.snapshot.buttons.contains(.dpadLeft))
            Rectangle()
                .fill(Color.white.opacity(0.04))
                .frame(width: 14, height: 14)
        }
    }

    private func dpadSegment(_ label: String, rotation: Double, pressed: Bool) -> some View {
        let isActive = pressed
        return ZStack {
            RoundedRectangle(cornerRadius: 3)
                .fill(isActive ? Color.openNowGreen : Color.white.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(isActive ? Color.openNowGreen.opacity(0.7) : Color.white.opacity(0.08), lineWidth: 0.5))
                .frame(width: 26, height: 30)
                .offset(y: -16)
                .rotationEffect(.degrees(rotation))
            Text(label)
                .font(OpenNOWNVIDIAFont.font(size: 9, weight: .bold))
                .foregroundStyle(isActive ? .black : .white.opacity(0.25))
                .offset(y: -16)
                .rotationEffect(.degrees(rotation))
        }
    }

    private var centerButtonsView: some View {
        HStack(spacing: 20) {
            centerButton("SELECT", pressed: model.snapshot.buttons.contains(.select))
            centerButton("START", pressed: model.snapshot.buttons.contains(.start))
        }
        .offset(y: -60)
    }

    private func centerButton(_ label: String, pressed: Bool) -> some View {
        Text(label)
            .font(OpenNOWNVIDIAFont.font(size: 8, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(pressed ? Color.openNowGreen : .white.opacity(0.25))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(pressed ? Color.openNowGreen.opacity(0.15) : Color.white.opacity(0.03))
            )
            .overlay(Capsule().stroke(pressed ? Color.openNowGreen.opacity(0.5) : Color.white.opacity(0.08), lineWidth: 0.5))
    }

    private var rawValuesPanel: some View {
        VStack(spacing: 16) {
            Text("RAW INPUT VALUES")
                .font(OpenNOWNVIDIAFont.font(size: 11, weight: .bold))
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
        }
        .frame(maxWidth: .infinity)
    }

    private func axisBar(_ label: String, value: Float, raw: Float? = nil, unsigned: Bool = false) -> some View {
        let displayValue = raw ?? value
        return HStack(spacing: 8) {
            Text(label)
                .font(OpenNOWNVIDIAFont.font(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.4))
                .frame(width: 22, alignment: .leading)
            GeometryReader { geo in
                let barWidth = geo.size.width
                if unsigned {
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.white.opacity(0.06))
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.openNowGreen.opacity(0.6))
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
                            .fill(Color.openNowGreen.opacity(0.6))
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
        }
        .frame(maxWidth: .infinity)
    }

    private func buttonStateRow(_ label: String, active: Bool) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(OpenNOWNVIDIAFont.font(size: 10, weight: .bold))
                .foregroundStyle(active ? Color.openNowGreen : .white.opacity(0.35))
                .frame(width: 28, alignment: .leading)
            Text(active ? "ON" : "OFF")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(active ? Color.openNowGreen.opacity(0.8) : .white.opacity(0.2))
        }
    }
}

@MainActor
final class SteamControllerTestModel: ObservableObject {
    @Published var snapshot = SteamControllerInputSnapshot()
    @Published var deviceID: String = ""
    @Published var isConnected = false

    private var consumerKey: ObjectIdentifier?
    private var monitorWasEnabled = false

    func start() {
        monitorWasEnabled = SteamControllerPreference.isEnabled
        if !monitorWasEnabled {
            SteamControllerHIDMonitor.shared.setEnabled(true)
        }

        consumerKey = ObjectIdentifier(self)
        SteamControllerHIDMonitor.shared.register(
            self,
            onControllersChanged: { [weak self] in self?.refreshConnection() },
            onInputState: { [weak self] deviceID, snapshot in
                guard let self else { return }
                self.deviceID = deviceID.rawValue
                self.snapshot = snapshot
                if !self.isConnected { self.isConnected = true }
            }
        )
        refreshConnection()
    }

    func stop() {
        if let consumerKey {
            SteamControllerHIDMonitor.shared.unregister(key: consumerKey)
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
            if let snap = SteamControllerHIDMonitor.shared.snapshot(for: first) {
                snapshot = snap
            }
        } else {
            isConnected = false
            deviceID = ""
            snapshot = SteamControllerInputSnapshot()
        }
    }
}

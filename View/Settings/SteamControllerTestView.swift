import Combine
import SwiftUI

struct SteamControllerTestView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = SteamControllerTestModel()

    private static let backgroundColor = Color(red: 18 / 255, green: 19 / 255, blue: 18 / 255)

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
                .font(.system(size: 18))
                .foregroundStyle(Color.openNowGreen)
            Text("STEAM CONTROLLER TEST")
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

    private var connectionStatusBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(model.isConnected ? Color.openNowGreen : Color.red.opacity(0.7))
                .frame(width: 8, height: 8)
                .shadow(color: (model.isConnected ? Color.openNowGreen : Color.red).opacity(0.5), radius: 3)
            Text(model.isConnected ? "Connected" : "No controller detected")
                .font(MacForceNowNVIDIAFont.font(size: 12, weight: .bold))
                .foregroundStyle(.white.opacity(0.7))
            if model.isConnected {
                Spacer()
                if let battery = model.batteryLevel {
                    HStack(spacing: 4) {
                        Image(systemName: model.isCharging ? "bolt.fill" : batteryIconName(for: battery))
                            .font(.system(size: 11, weight: .medium))
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
        case 20...: return .openNowGreen
        case 10..<20: return .orange
        default: return .red
        }
    }

    private var noControllerMessage: some View {
        VStack(spacing: 12) {
            Image(systemName: "gamecontroller")
                .font(.system(size: 48))
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

    // The shell art is Valve's own Steam Controller (Triton) layout drawing, which is
    // authored in a 456x320 space. Every live overlay below is positioned in those same
    // coordinates and scaled to the rendered diagram width, so the two always line up.
    private static let artSize = CGSize(width: 456, height: 320)
    private static let diagramWidth: CGFloat = 560
    private static let artScale = diagramWidth / artSize.width
    private static let diagramHeight = artSize.height * artScale

    private func art(_ value: CGFloat) -> CGFloat { value * Self.artScale }

    private var controllerDiagram: some View {
        VStack(spacing: 6) {
            shoulderRow
            controllerBody
            Text("L4 · L5 · R4 · R5 sit on the underside of the grips")
                .font(MacForceNowNVIDIAFont.font(size: 9, weight: .medium))
                .tracking(0.5)
                .foregroundStyle(.white.opacity(0.2))
        }
    }

    private var shoulderRow: some View {
        ZStack {
            shoulderGroup(
                trigger: "L2",
                value: model.snapshot.leftTrigger,
                bumper: "L1",
                pressed: model.snapshot.buttons.contains(.leftShoulder)
            )
            .position(x: art(92), y: 27)

            shoulderGroup(
                trigger: "R2",
                value: model.snapshot.rightTrigger,
                bumper: "R1",
                pressed: model.snapshot.buttons.contains(.rightShoulder)
            )
            .position(x: art(362), y: 27)
        }
        .frame(width: Self.diagramWidth, height: 54)
    }

    private func shoulderGroup(trigger: String, value: Float, bumper: String, pressed: Bool) -> some View {
        VStack(spacing: 4) {
            triggerButton(trigger, value: value)
                .frame(width: 104, height: 26)
            bumperButton(bumper, pressed: pressed)
                .frame(width: 118, height: 20)
        }
    }

    private var controllerBody: some View {
        ZStack {
            Image("SteamControllerShellFill")
                .renderingMode(.template)
                .resizable()
                .frame(width: Self.diagramWidth, height: Self.diagramHeight)
                .foregroundStyle(Color.white.opacity(0.035))
            Image("SteamControllerShell")
                .renderingMode(.template)
                .resizable()
                .frame(width: Self.diagramWidth, height: Self.diagramHeight)
                .foregroundStyle(Color.white.opacity(0.18))

            dpadView
                .frame(width: art(68), height: art(68))
                .position(x: art(88), y: art(75))

            faceButtonsView
                .frame(width: art(78), height: art(78))
                .position(x: art(366.5), y: art(75.5))

            centerButton(icon: "rectangle.on.rectangle", pressed: model.snapshot.buttons.contains(.select))
                .position(x: art(147), y: art(43))
            centerButton(icon: "line.3.horizontal", pressed: model.snapshot.buttons.contains(.start))
                .position(x: art(307), y: art(43))

            steamButtonView(pressed: model.snapshot.buttons.contains(.mode))
                .position(x: art(227.5), y: art(76))

            stickView(
                x: model.snapshot.leftStickX,
                y: model.snapshot.leftStickY,
                pressed: model.snapshot.buttons.contains(.leftStick)
            )
            .position(x: art(161.5), y: art(108.5))

            stickView(
                x: model.snapshot.rightStickX,
                y: model.snapshot.rightStickY,
                pressed: model.snapshot.buttons.contains(.rightStick)
            )
            .position(x: art(292.5), y: art(108.5))

            trackpadView(model.snapshot.leftPad)
                .rotationEffect(.degrees(9.87))
                .position(x: art(140.5), y: art(193))
            trackpadView(model.snapshot.rightPad)
                .rotationEffect(.degrees(-9.87))
                .position(x: art(313.5), y: art(193))

            quickAccessButtonView(pressed: model.snapshot.buttons.contains(.quickAccess))
                .position(x: art(227), y: art(194.5))

            backGripPill("L4", pressed: model.snapshot.buttons.contains(.leftGrip))
                .rotationEffect(.degrees(-6))
                .position(x: art(84), y: art(246))
            backGripPill("L5", pressed: model.snapshot.buttons.contains(.leftGrip2))
                .rotationEffect(.degrees(-10))
                .position(x: art(76), y: art(268))
            backGripPill("R4", pressed: model.snapshot.buttons.contains(.rightGrip))
                .rotationEffect(.degrees(6))
                .position(x: art(370), y: art(246))
            backGripPill("R5", pressed: model.snapshot.buttons.contains(.rightGrip2))
                .rotationEffect(.degrees(10))
                .position(x: art(378), y: art(268))
        }
        .frame(width: Self.diagramWidth, height: Self.diagramHeight)
    }

    private func triggerButton(_ label: String, value: Float) -> some View {
        let pressed = value > 0.05
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: 14,
            bottomLeadingRadius: 6,
            bottomTrailingRadius: 6,
            topTrailingRadius: 14
        )
        return ZStack {
            shape.fill(Color.white.opacity(0.04))
            GeometryReader { geo in
                shape
                    .fill(Color.openNowGreen.opacity(0.3))
                    .frame(width: geo.size.width * CGFloat(max(0, min(1, value))))
            }
            .clipShape(shape)
            shape.stroke(pressed ? Color.openNowGreen.opacity(0.6) : Color.white.opacity(0.12), lineWidth: 1)
            HStack(spacing: 4) {
                Text(label)
                    .font(MacForceNowNVIDIAFont.font(size: 11, weight: .bold))
                    .foregroundStyle(pressed ? Color.openNowGreen : .white.opacity(0.5))
                Text("\(Int(value * 100))%")
                    .font(MacForceNowNVIDIAFont.font(size: 10, weight: .medium))
                    .foregroundStyle(pressed ? Color.openNowGreen.opacity(0.8) : .white.opacity(0.3))
                    .monospacedDigit()
            }
        }
    }

    private func bumperButton(_ label: String, pressed: Bool) -> some View {
        ZStack {
            Capsule()
                .fill(pressed ? Color.openNowGreen.opacity(0.25) : Color.white.opacity(0.04))
                .overlay(
                    Capsule()
                        .stroke(pressed ? Color.openNowGreen.opacity(0.6) : Color.white.opacity(0.12), lineWidth: 1)
                )
            Text(label)
                .font(MacForceNowNVIDIAFont.font(size: 11, weight: .bold))
                .foregroundStyle(pressed ? Color.openNowGreen : .white.opacity(0.5))
        }
    }

    private func stickView(x: Float, y: Float, pressed: Bool) -> some View {
        let active = pressed || abs(x) > 0.05 || abs(y) > 0.05
        // Valve draws the well at r=34.5 and the thumb cap at r=20.75.
        let well = art(69)
        let cap = art(41.5)
        let travel = art(13.75)
        return ZStack {
            Circle()
                .fill(Color.white.opacity(0.02))
                .overlay(
                    Circle().stroke(
                        pressed ? Color.openNowGreen.opacity(0.7) : Color.white.opacity(active ? 0.28 : 0.16),
                        lineWidth: pressed ? 1.5 : 1
                    )
                )
                .frame(width: well, height: well)

            Circle()
                .fill(active ? Color.openNowGreen.opacity(0.9) : Color.white.opacity(0.12))
                .overlay(
                    Circle().stroke(
                        active ? Color.openNowGreen : Color.white.opacity(0.28),
                        lineWidth: 1
                    )
                )
                .frame(width: cap, height: cap)
                .shadow(color: active ? Color.openNowGreen.opacity(0.5) : .clear, radius: 6)
                .offset(x: CGFloat(x) * travel, y: CGFloat(-y) * travel)
        }
        .frame(width: well, height: well)
    }

    private var faceButtonsView: some View {
        ZStack {
            // Valve spaces the diamond 26pt from its centre in art units.
            faceButtonNode("Y", x: 0, y: -art(26), pressed: model.snapshot.buttons.contains(.north))
            faceButtonNode("B", x: art(26), y: 0, pressed: model.snapshot.buttons.contains(.east))
            faceButtonNode("A", x: 0, y: art(26), pressed: model.snapshot.buttons.contains(.south))
            faceButtonNode("X", x: -art(26), y: 0, pressed: model.snapshot.buttons.contains(.west))
        }
    }

    private func faceButtonNode(_ label: String, x: CGFloat, y: CGFloat, pressed: Bool) -> some View {
        ZStack {
            Circle()
                .fill(pressed ? Color.openNowGreen : Color.white.opacity(0.05))
                .overlay(Circle().stroke(pressed ? Color.openNowGreen.opacity(0.8) : Color.white.opacity(0.18), lineWidth: 1))
                .frame(width: art(27), height: art(27))
                .shadow(color: pressed ? Color.openNowGreen.opacity(0.4) : .clear, radius: 6)
                .offset(x: x, y: y)
            Text(label)
                .font(MacForceNowNVIDIAFont.font(size: 12, weight: .bold))
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
            RoundedRectangle(cornerRadius: art(2))
                .fill(Color.white.opacity(0.06))
                .frame(width: art(21), height: art(21))
        }
    }

    private func dpadSegment(_ label: String, rotation: Double, pressed: Bool) -> some View {
        // Valve's cross spans 68 art units, so each arm reaches 34 from centre.
        let armWidth = art(21)
        let armLength = art(23)
        let armOffset = art(22.5)
        return ZStack {
            RoundedRectangle(cornerRadius: art(4))
                .fill(pressed ? Color.openNowGreen : Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: art(4))
                        .stroke(pressed ? Color.openNowGreen.opacity(0.7) : Color.white.opacity(0.16), lineWidth: 1)
                )
                .frame(width: armWidth, height: armLength)
                .offset(y: -armOffset)
                .rotationEffect(.degrees(rotation))
            Text(label)
                .font(MacForceNowNVIDIAFont.font(size: 8, weight: .bold))
                .foregroundStyle(pressed ? .black : .white.opacity(0.3))
                .offset(y: -armOffset)
                .rotationEffect(.degrees(rotation))
        }
    }

    private func centerButton(icon: String, pressed: Bool) -> some View {
        ZStack {
            Capsule()
                .fill(pressed ? Color.openNowGreen.opacity(0.25) : Color.white.opacity(0.04))
            Capsule()
                .stroke(pressed ? Color.openNowGreen.opacity(0.7) : Color.white.opacity(0.12), lineWidth: 1)
            Image(systemName: icon)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(pressed ? Color.openNowGreen : .white.opacity(0.35))
        }
        .frame(width: art(30), height: art(14))
    }

    private func steamButtonView(pressed: Bool) -> some View {
        ZStack {
            Circle()
                .fill(pressed ? Color.openNowGreen.opacity(0.25) : Color.white.opacity(0.05))
                .overlay(Circle().stroke(pressed ? Color.openNowGreen.opacity(0.8) : Color.white.opacity(0.16), lineWidth: 1))
                .shadow(color: pressed ? Color.openNowGreen.opacity(0.4) : .clear, radius: 6)
            Canvas { context, size in
                let ink = pressed ? Color.openNowGreen : Color.white.opacity(0.4)
                let bigCenter = CGPoint(x: size.width * 0.40, y: size.height * 0.62)
                let smallCenter = CGPoint(x: size.width * 0.66, y: size.height * 0.36)
                var rod = Path()
                rod.move(to: bigCenter)
                rod.addLine(to: smallCenter)
                context.stroke(rod, with: .color(ink), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                let bigRadius = size.width * 0.17
                let smallRadius = size.width * 0.11
                context.fill(Path(ellipseIn: CGRect(x: bigCenter.x - bigRadius, y: bigCenter.y - bigRadius, width: bigRadius * 2, height: bigRadius * 2)), with: .color(ink))
                context.fill(Path(ellipseIn: CGRect(x: smallCenter.x - smallRadius, y: smallCenter.y - smallRadius, width: smallRadius * 2, height: smallRadius * 2)), with: .color(ink))
                let bigHole = bigRadius * 0.45
                let smallHole = smallRadius * 0.45
                context.fill(Path(ellipseIn: CGRect(x: bigCenter.x - bigHole, y: bigCenter.y - bigHole, width: bigHole * 2, height: bigHole * 2)), with: .color(Self.backgroundColor))
                context.fill(Path(ellipseIn: CGRect(x: smallCenter.x - smallHole, y: smallCenter.y - smallHole, width: smallHole * 2, height: smallHole * 2)), with: .color(Self.backgroundColor))
            }
            .frame(width: art(26), height: art(26))
            .clipShape(Circle())
        }
        .frame(width: art(28), height: art(28))
    }

    private func quickAccessButtonView(pressed: Bool) -> some View {
        ZStack {
            Capsule()
                .fill(pressed ? Color.openNowGreen.opacity(0.25) : Color.white.opacity(0.04))
            Capsule()
                .stroke(pressed ? Color.openNowGreen.opacity(0.8) : Color.white.opacity(0.12), lineWidth: 1)
            Image(systemName: "ellipsis")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(pressed ? Color.openNowGreen : .white.opacity(0.35))
        }
        .frame(width: art(38), height: art(15))
        .shadow(color: pressed ? Color.openNowGreen.opacity(0.4) : .clear, radius: 5)
    }

    private func trackpadView(_ pad: SteamControllerTrackpadState) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: art(16))
                .fill(pad.pressed ? Color.openNowGreen.opacity(0.12) : Color.white.opacity(0.045))
                .overlay(
                    RoundedRectangle(cornerRadius: art(16)).stroke(
                        pad.pressed ? Color.openNowGreen.opacity(0.8) : (pad.touched ? Color.openNowGreen.opacity(0.45) : Color.white.opacity(0.14)),
                        lineWidth: pad.pressed ? 1.5 : 1
                    )
                )
                .shadow(color: pad.pressed ? Color.openNowGreen.opacity(0.4) : .clear, radius: 6)
            Canvas { context, size in
                let count = 5
                for row in 0..<count {
                    for column in 0..<count {
                        let x = size.width * CGFloat(column + 1) / CGFloat(count + 1)
                        let y = size.height * CGFloat(row + 1) / CGFloat(count + 1)
                        context.fill(
                            Path(ellipseIn: CGRect(x: x - 1, y: y - 1, width: 2, height: 2)),
                            with: .color(.white.opacity(0.1))
                        )
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))

            if pad.touched {
                Circle()
                    .fill(pad.pressed ? Color.openNowGreen : Color.openNowGreen.opacity(0.6))
                    .frame(width: art(14), height: art(14))
                    .shadow(color: Color.openNowGreen.opacity(0.5), radius: 4)
                    .offset(x: CGFloat(pad.x) * art(38), y: CGFloat(-pad.y) * art(38))
            }
        }
        .frame(width: art(93), height: art(93))
    }

    private func backGripPill(_ label: String, pressed: Bool) -> some View {
        ZStack {
            Capsule()
                .fill(pressed ? Color.openNowGreen.opacity(0.25) : Color.white.opacity(0.02))
            Capsule()
                .stroke(
                    pressed ? Color.openNowGreen.opacity(0.7) : Color.white.opacity(0.18),
                    style: StrokeStyle(lineWidth: 1, dash: [3, 2.5])
                )
            Text(label)
                .font(MacForceNowNVIDIAFont.font(size: 9, weight: .bold))
                .foregroundStyle(pressed ? Color.openNowGreen : .white.opacity(0.4))
        }
        .frame(width: art(30), height: art(15))
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

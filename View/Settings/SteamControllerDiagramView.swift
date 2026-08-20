import SwiftUI

/// Valve's own Steam Controller (Triton) shell art, live-highlighted from an input
/// snapshot. Shared by the controller tester and the mapping editor so both stay visually
/// identical to Steam Input / Steam Deck's own controller diagrams. Every control can be
/// tapped to select it (used by the mapping editor's binding panel); pass `onSelectControl`
/// as `nil` (the default) to render a read-only diagram, as the tester does.
struct SteamControllerDiagramView: View {
    let snapshot: SteamControllerInputSnapshot
    var selectedControl: SteamControllerControl?
    var onSelectControl: ((SteamControllerControl) -> Void)?
    var backgroundColor: Color = MacForceNowDesign.Surface.deep

    // The shell art is authored in a 456x320 space. Every live overlay below is
    // positioned in those same coordinates and scaled to the rendered diagram width,
    // so the two always line up.
    private static let artSize = CGSize(width: 456, height: 320)
    static let diagramWidth: CGFloat = 560
    private static let artScale = diagramWidth / artSize.width
    static let diagramHeight = artSize.height * artScale

    private func art(_ value: CGFloat) -> CGFloat { value * Self.artScale }

    var body: some View {
        VStack(spacing: 6) {
            shoulderRow
            controllerBody
        }
    }

    @ViewBuilder
    private func selectable<Content: View>(_ control: SteamControllerControl, @ViewBuilder content: () -> Content) -> some View {
        let isSelected = selectedControl == control
        content()
            .contentShape(Rectangle())
            .onTapGesture { onSelectControl?(control) }
            .scaleEffect(isSelected ? 1.12 : 1)
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 999).stroke(MacForceNowDesign.accent, lineWidth: 2)
                }
            }
            .animation(.easeOut(duration: 0.12), value: isSelected)
    }

    private var shoulderRow: some View {
        ZStack {
            shoulderGroup(
                triggerControl: .leftTrigger, triggerLabel: "L2", value: snapshot.leftTrigger,
                bumperControl: .leftShoulder, bumperLabel: "L1", pressed: snapshot.buttons.contains(.leftShoulder)
            )
            .position(x: art(92), y: 27)

            shoulderGroup(
                triggerControl: .rightTrigger, triggerLabel: "R2", value: snapshot.rightTrigger,
                bumperControl: .rightShoulder, bumperLabel: "R1", pressed: snapshot.buttons.contains(.rightShoulder)
            )
            .position(x: art(362), y: 27)
        }
        .frame(width: Self.diagramWidth, height: 54)
    }

    private func shoulderGroup(triggerControl: SteamControllerControl, triggerLabel: String, value: Float,
                                bumperControl: SteamControllerControl, bumperLabel: String, pressed: Bool) -> some View {
        VStack(spacing: 4) {
            selectable(triggerControl) { triggerButton(triggerLabel, value: value) }
                .frame(width: 104, height: 26)
            selectable(bumperControl) { bumperButton(bumperLabel, pressed: pressed) }
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

            // Each arm/button is its own independent selectable + position() call — not
            // grouped inside a shared parent with internal offsets — because a tap target
            // built from .contentShape() on top of an *internally offset* child doesn't
            // reliably follow that offset; .position() applied from the outside does.
            selectable(.dpadUp) { dpadSegment("U", rotation: 0, pressed: snapshot.buttons.contains(.dpadUp)) }
                .rotationEffect(.degrees(0))
                .position(x: art(88), y: art(52.5))
            selectable(.dpadRight) { dpadSegment("R", rotation: 90, pressed: snapshot.buttons.contains(.dpadRight)) }
                .rotationEffect(.degrees(90))
                .position(x: art(110.5), y: art(75))
            selectable(.dpadDown) { dpadSegment("D", rotation: 180, pressed: snapshot.buttons.contains(.dpadDown)) }
                .rotationEffect(.degrees(180))
                .position(x: art(88), y: art(97.5))
            selectable(.dpadLeft) { dpadSegment("L", rotation: 270, pressed: snapshot.buttons.contains(.dpadLeft)) }
                .rotationEffect(.degrees(270))
                .position(x: art(65.5), y: art(75))
            RoundedRectangle(cornerRadius: art(2))
                .fill(Color.white.opacity(0.06))
                .frame(width: art(21), height: art(21))
                .position(x: art(88), y: art(75))

            selectable(.faceY) { faceButtonNode("Y", pressed: snapshot.buttons.contains(.north)) }
                .position(x: art(366.5), y: art(49.5))
            selectable(.faceB) { faceButtonNode("B", pressed: snapshot.buttons.contains(.east)) }
                .position(x: art(392.5), y: art(75.5))
            selectable(.faceA) { faceButtonNode("A", pressed: snapshot.buttons.contains(.south)) }
                .position(x: art(366.5), y: art(101.5))
            selectable(.faceX) { faceButtonNode("X", pressed: snapshot.buttons.contains(.west)) }
                .position(x: art(340.5), y: art(75.5))

            selectable(.select) { centerButton(icon: "rectangle.on.rectangle", pressed: snapshot.buttons.contains(.select)) }
                .position(x: art(147), y: art(43))
            selectable(.start) { centerButton(icon: "line.3.horizontal", pressed: snapshot.buttons.contains(.start)) }
                .position(x: art(307), y: art(43))

            steamButtonView(pressed: snapshot.buttons.contains(.mode))
                .position(x: art(227.5), y: art(76))

            selectable(.leftStickClick) {
                stickView(x: snapshot.leftStickX, y: snapshot.leftStickY, pressed: snapshot.buttons.contains(.leftStick))
            }
            .position(x: art(161.5), y: art(108.5))

            selectable(.rightStickClick) {
                stickView(x: snapshot.rightStickX, y: snapshot.rightStickY, pressed: snapshot.buttons.contains(.rightStick))
            }
            .position(x: art(292.5), y: art(108.5))

            selectable(.leftPadClick) { trackpadView(snapshot.leftPad) }
                .rotationEffect(.degrees(9.87))
                .position(x: art(140.5), y: art(193))
            selectable(.rightPadClick) { trackpadView(snapshot.rightPad) }
                .rotationEffect(.degrees(-9.87))
                .position(x: art(313.5), y: art(193))

            quickAccessButtonView(pressed: snapshot.buttons.contains(.quickAccess))
                .position(x: art(227), y: art(194.5))

            selectable(.leftGrip) { gripPill(.leftGrip) }
                .rotationEffect(.degrees(-6))
                .position(x: art(84), y: art(246))
            selectable(.leftGrip2) { gripPill(.leftGrip2) }
                .rotationEffect(.degrees(-10))
                .position(x: art(76), y: art(268))
            selectable(.rightGrip) { gripPill(.rightGrip) }
                .rotationEffect(.degrees(6))
                .position(x: art(370), y: art(246))
            selectable(.rightGrip2) { gripPill(.rightGrip2) }
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
                    .fill(MacForceNowDesign.accent.opacity(0.3))
                    .frame(width: geo.size.width * CGFloat(max(0, min(1, value))))
            }
            .clipShape(shape)
            shape.stroke(pressed ? MacForceNowDesign.accent.opacity(0.6) : Color.white.opacity(0.12), lineWidth: 1)
            HStack(spacing: 4) {
                Text(label)
                    .font(MacForceNowNVIDIAFont.font(size: 11, weight: .bold))
                    .foregroundStyle(pressed ? MacForceNowDesign.accent : .white.opacity(0.5))
                Text("\(Int(value * 100))%")
                    .font(MacForceNowNVIDIAFont.font(size: 10, weight: .medium))
                    .foregroundStyle(pressed ? MacForceNowDesign.accent.opacity(0.8) : .white.opacity(0.3))
                    .monospacedDigit()
            }
        }
    }

    private func bumperButton(_ label: String, pressed: Bool) -> some View {
        ZStack {
            Capsule()
                .fill(pressed ? MacForceNowDesign.accent.opacity(0.25) : Color.white.opacity(0.04))
                .overlay(
                    Capsule()
                        .stroke(pressed ? MacForceNowDesign.accent.opacity(0.6) : Color.white.opacity(0.12), lineWidth: 1)
                )
            Text(label)
                .font(MacForceNowNVIDIAFont.font(size: 11, weight: .bold))
                .foregroundStyle(pressed ? MacForceNowDesign.accent : .white.opacity(0.5))
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
                        pressed ? MacForceNowDesign.accent.opacity(0.7) : Color.white.opacity(active ? 0.28 : 0.16),
                        lineWidth: pressed ? 1.5 : 1
                    )
                )
                .frame(width: well, height: well)

            Circle()
                .fill(active ? MacForceNowDesign.accent.opacity(0.9) : Color.white.opacity(0.12))
                .overlay(
                    Circle().stroke(
                        active ? MacForceNowDesign.accent : Color.white.opacity(0.28),
                        lineWidth: 1
                    )
                )
                .frame(width: cap, height: cap)
                .shadow(color: active ? MacForceNowDesign.accent.opacity(0.5) : .clear, radius: 6)
                .offset(x: CGFloat(x) * travel, y: CGFloat(-y) * travel)
        }
        .frame(width: well, height: well)
    }

    private func faceButtonNode(_ label: String, pressed: Bool) -> some View {
        ZStack {
            Circle()
                .fill(pressed ? MacForceNowDesign.accent : Color.white.opacity(0.05))
                .overlay(Circle().stroke(pressed ? MacForceNowDesign.accent.opacity(0.8) : Color.white.opacity(0.18), lineWidth: 1))
                .shadow(color: pressed ? MacForceNowDesign.accent.opacity(0.4) : .clear, radius: 6)
            Text(label)
                .font(MacForceNowNVIDIAFont.font(size: 12, weight: .bold))
                .foregroundStyle(pressed ? .black : .white.opacity(0.35))
        }
        .frame(width: art(27), height: art(27))
    }

    private func dpadSegment(_ label: String, rotation: Double, pressed: Bool) -> some View {
        let armWidth = art(21)
        let armLength = art(23)
        // The label counter-rotates so "U/R/D/L" stay upright at every arm's rotation.
        return ZStack {
            RoundedRectangle(cornerRadius: art(4))
                .fill(pressed ? MacForceNowDesign.accent : Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: art(4))
                        .stroke(pressed ? MacForceNowDesign.accent.opacity(0.7) : Color.white.opacity(0.16), lineWidth: 1)
                )
            Text(label)
                .font(MacForceNowNVIDIAFont.font(size: 8, weight: .bold))
                .foregroundStyle(pressed ? .black : .white.opacity(0.3))
                .rotationEffect(.degrees(-rotation))
        }
        .frame(width: armWidth, height: armLength)
    }

    private func centerButton(icon: String, pressed: Bool) -> some View {
        ZStack {
            Capsule()
                .fill(pressed ? MacForceNowDesign.accent.opacity(0.25) : Color.white.opacity(0.04))
            Capsule()
                .stroke(pressed ? MacForceNowDesign.accent.opacity(0.7) : Color.white.opacity(0.12), lineWidth: 1)
            Image(systemName: icon)
                .font(.nvidiaSans(size: 8, weight: .bold))
                .foregroundStyle(pressed ? MacForceNowDesign.accent : .white.opacity(0.35))
        }
        .frame(width: art(30), height: art(14))
    }

    private func steamButtonView(pressed: Bool) -> some View {
        ZStack {
            Circle()
                .fill(pressed ? MacForceNowDesign.accent.opacity(0.25) : Color.white.opacity(0.05))
                .overlay(Circle().stroke(pressed ? MacForceNowDesign.accent.opacity(0.8) : Color.white.opacity(0.16), lineWidth: 1))
                .shadow(color: pressed ? MacForceNowDesign.accent.opacity(0.4) : .clear, radius: 6)
            Canvas { context, size in
                let ink = pressed ? MacForceNowDesign.accent : Color.white.opacity(0.4)
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
                context.fill(Path(ellipseIn: CGRect(x: bigCenter.x - bigHole, y: bigCenter.y - bigHole, width: bigHole * 2, height: bigHole * 2)), with: .color(backgroundColor))
                context.fill(Path(ellipseIn: CGRect(x: smallCenter.x - smallHole, y: smallCenter.y - smallHole, width: smallHole * 2, height: smallHole * 2)), with: .color(backgroundColor))
            }
            .frame(width: art(26), height: art(26))
            .clipShape(Circle())
        }
        .frame(width: art(28), height: art(28))
    }

    private func quickAccessButtonView(pressed: Bool) -> some View {
        ZStack {
            Capsule()
                .fill(pressed ? MacForceNowDesign.accent.opacity(0.25) : Color.white.opacity(0.04))
            Capsule()
                .stroke(pressed ? MacForceNowDesign.accent.opacity(0.8) : Color.white.opacity(0.12), lineWidth: 1)
            Image(systemName: "ellipsis")
                .font(.nvidiaSans(size: 9, weight: .bold))
                .foregroundStyle(pressed ? MacForceNowDesign.accent : .white.opacity(0.35))
        }
        .frame(width: art(38), height: art(15))
        .shadow(color: pressed ? MacForceNowDesign.accent.opacity(0.4) : .clear, radius: 5)
    }

    private func trackpadView(_ pad: SteamControllerTrackpadState) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: art(16))
                .fill(pad.pressed ? MacForceNowDesign.accent.opacity(0.12) : Color.white.opacity(0.045))
                .overlay(
                    RoundedRectangle(cornerRadius: art(16)).stroke(
                        pad.pressed ? MacForceNowDesign.accent.opacity(0.8) : (pad.touched ? MacForceNowDesign.accent.opacity(0.45) : Color.white.opacity(0.14)),
                        lineWidth: pad.pressed ? 1.5 : 1
                    )
                )
                .shadow(color: pad.pressed ? MacForceNowDesign.accent.opacity(0.4) : .clear, radius: 6)
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
                    .fill(pad.pressed ? MacForceNowDesign.accent : MacForceNowDesign.accent.opacity(0.6))
                    .frame(width: art(14), height: art(14))
                    .shadow(color: MacForceNowDesign.accent.opacity(0.5), radius: 4)
                    .offset(x: CGFloat(pad.x) * art(38), y: CGFloat(-pad.y) * art(38))
            }
        }
        .frame(width: art(93), height: art(93))
    }

    private func gripPill(_ control: SteamControllerControl) -> some View {
        let pressed = control.gamepadButton.map { snapshot.buttons.contains($0) } ?? false
        return ZStack {
            Capsule()
                .fill(pressed ? MacForceNowDesign.accent.opacity(0.25) : Color.white.opacity(0.02))
            Capsule()
                .stroke(
                    pressed ? MacForceNowDesign.accent.opacity(0.7) : Color.white.opacity(0.18),
                    style: StrokeStyle(lineWidth: 1, dash: [3, 2.5])
                )
            Text(control.label)
                .font(MacForceNowNVIDIAFont.font(size: 9, weight: .bold))
                .foregroundStyle(pressed ? MacForceNowDesign.accent : .white.opacity(0.4))
        }
        .frame(width: art(30), height: art(15))
    }
}

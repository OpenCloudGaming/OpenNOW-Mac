import SwiftUI

/// A DualShock 4's shell, live-highlighted from a `GenericControllerInputSnapshot`. The third
/// shell in the tester's set: Valve's Triton art for a Steam Controller, this PS4 shell for a pad
/// GameController reports as `GCDualShockGamepad`, and `GenericControllerDiagramView` for
/// everything else. Drawn in the same authored space with the same overlay vocabulary, so the
/// three line up wherever they are swapped for one another. Read-only: mapping profiles are
/// Steam-only, so there is nothing here to tap.
///
/// Two GameController details shape the drawing:
///
/// - The face buttons are the PlayStation glyphs (△ ○ × □), not the A/B/X/Y the other shells show,
///   so the diagram matches what is printed on the hardware.
/// - GameController names these per pad, and the names are cross-brand: `buttonOptions` is the
///   left-hand button on every pad (SHARE on a DualShock 4, View on an Xbox) and `buttonMenu` the
///   right-hand one (OPTIONS here, Menu on an Xbox). So `.select` draws on the left and `.start`
///   on the right.
///
/// The rounded shapes below are the documented artwork exception in DESIGN.md: they trace physical
/// hardware (round face buttons, the touchpad, circular stick wells), not chrome. Everything the
/// user interacts with *around* the drawing stays square.
// Artwork, not chrome: DESIGN.md lists controller diagrams as a radius exception because every
// rounded shape below traces the physical controller. The rule stays on for the rest of View/.
// swiftlint:disable design_no_corner_radius
struct DualShock4DiagramView: View {
    let snapshot: GenericControllerInputSnapshot

    @Environment(\.opnUIScale) private var uiScale

    private var diagramWidth: CGFloat { ControllerDiagramArtwork.diagramWidth * uiScale }
    private var artScale: CGFloat { diagramWidth / ControllerDiagramArtwork.artSize.width }
    private var diagramHeight: CGFloat { ControllerDiagramArtwork.artSize.height * artScale }

    private func art(_ value: CGFloat) -> CGFloat { value * artScale }

    /// A pad with no touchpad still renders the rest of the shell; the touchpad is drawn from
    /// this, so an absent one is simply an unpressed pad.
    private var touchpad: ControllerTouchpadState { snapshot.touchpad ?? ControllerTouchpadState() }

    var body: some View {
        VStack(spacing: 6 * uiScale) {
            shoulderRow
            controllerBody
        }
    }

    // MARK: - Shoulders

    private var shoulderRow: some View {
        ZStack {
            shoulderGroup(
                triggerLabel: "L2", value: snapshot.leftTrigger,
                bumperLabel: "L1", pressed: snapshot.buttons.contains(.leftShoulder)
            )
            .position(x: art(88), y: 27 * uiScale)

            shoulderGroup(
                triggerLabel: "R2", value: snapshot.rightTrigger,
                bumperLabel: "R1", pressed: snapshot.buttons.contains(.rightShoulder)
            )
            .position(x: art(368), y: 27 * uiScale)
        }
        .frame(width: diagramWidth, height: 54 * uiScale)
    }

    private func shoulderGroup(triggerLabel: String, value: Float, bumperLabel: String, pressed: Bool) -> some View {
        VStack(spacing: 4 * uiScale) {
            triggerButton(triggerLabel, value: value)
                .frame(width: 96 * uiScale, height: 24 * uiScale)
            bumperButton(bumperLabel, pressed: pressed)
                .frame(width: 108 * uiScale, height: 18 * uiScale)
        }
    }

    private func triggerButton(_ label: String, value: Float) -> some View {
        let pressed = value > 0.05
        let shape = RoundedRectangle(cornerRadius: 6 * uiScale)
        return ZStack {
            shape.fill(ControllerDiagramArtwork.Overlay.fill(0.04))
            GeometryReader { geo in
                shape
                    .fill(OPNDesign.accent.opacity(0.3))
                    .frame(width: geo.size.width * CGFloat(max(0, min(1, value))))
            }
            .clipShape(shape)
            shape.stroke(pressed ? OPNDesign.accent.opacity(0.6) : OPNDesign.Stroke.regular, lineWidth: 1)
            HStack(spacing: 4 * uiScale) {
                Text(label)
                    .font(.settingsFont(size: 11 * uiScale, weight: .bold))
                    .foregroundStyle(pressed ? OPNDesign.accentInk : OPNDesign.Text.tertiary)
                Text("\(Int(value * 100))%")
                    .font(.settingsFont(size: 10 * uiScale, weight: .medium))
                    .foregroundStyle(pressed ? OPNDesign.accentInk.opacity(0.8) : OPNDesign.Text.muted)
                    .monospacedDigit()
            }
        }
    }

    private func bumperButton(_ label: String, pressed: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6 * uiScale)
        return ZStack {
            shape
                .fill(pressed ? OPNDesign.accent.opacity(0.25) : ControllerDiagramArtwork.Overlay.fill(0.04))
            shape
                .stroke(pressed ? OPNDesign.accent.opacity(0.6) : OPNDesign.Stroke.regular, lineWidth: 1)
            Text(label)
                .font(.settingsFont(size: 11 * uiScale, weight: .bold))
                .foregroundStyle(pressed ? OPNDesign.accentInk : OPNDesign.Text.tertiary)
        }
    }

    // MARK: - Body

    private var controllerBody: some View {
        ZStack {
            Image("DualShockControllerShellFill")
                .renderingMode(.template)
                .resizable()
                .frame(width: diagramWidth, height: diagramHeight)
                .foregroundStyle(ControllerDiagramArtwork.shellFill)
            Image("DualShockControllerShell")
                .renderingMode(.template)
                .resizable()
                .frame(width: diagramWidth, height: diagramHeight)
                .foregroundStyle(ControllerDiagramArtwork.shellStroke)

            touchpadView
                .position(x: art(228), y: art(74.5))
            centerButton("SHARE", pressed: snapshot.buttons.contains(.select))
                .position(x: art(137), y: art(58))
            centerButton("OPTIONS", pressed: snapshot.buttons.contains(.start))
                .position(x: art(319), y: art(58))
            psButton(pressed: snapshot.buttons.contains(.mode))
                .position(x: art(228), y: art(165))

            dpad
            faceButtons

            leftStick
            rightStick
        }
        .frame(width: diagramWidth, height: diagramHeight)
    }

    private var leftStick: some View {
        stickView(x: snapshot.leftStickX, y: snapshot.leftStickY, pressed: snapshot.buttons.contains(.leftStick))
            .position(x: art(156), y: art(165))
    }

    private var rightStick: some View {
        stickView(x: snapshot.rightStickX, y: snapshot.rightStickY, pressed: snapshot.buttons.contains(.rightStick))
            .position(x: art(300), y: art(165))
    }

    private var dpad: some View {
        ZStack {
            dpadArm(pressed: snapshot.buttons.contains(.dpadUp))
                .position(x: art(88), y: art(80))
            dpadArm(pressed: snapshot.buttons.contains(.dpadRight))
                .rotationEffect(.degrees(90))
                .position(x: art(108), y: art(100))
            dpadArm(pressed: snapshot.buttons.contains(.dpadDown))
                .rotationEffect(.degrees(180))
                .position(x: art(88), y: art(120))
            dpadArm(pressed: snapshot.buttons.contains(.dpadLeft))
                .rotationEffect(.degrees(270))
                .position(x: art(68), y: art(100))
        }
    }

    private var faceButtons: some View {
        ZStack {
            faceButtonNode(.triangle, pressed: snapshot.buttons.contains(.north))
                .position(x: art(368), y: art(67))
            faceButtonNode(.circle, pressed: snapshot.buttons.contains(.east))
                .position(x: art(401), y: art(100))
            faceButtonNode(.cross, pressed: snapshot.buttons.contains(.south))
                .position(x: art(368), y: art(133))
            faceButtonNode(.square, pressed: snapshot.buttons.contains(.west))
                .position(x: art(335), y: art(100))
        }
    }

    // MARK: - Hardware pieces

    /// The touchpad tracks the primary finger and clicks on press, the same two states the HID
    /// passthrough sends to a seat.
    private var touchpadView: some View {
        let pad = touchpad
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: art(3), bottomLeadingRadius: art(11),
            bottomTrailingRadius: art(11), topTrailingRadius: art(3)
        )
        return ZStack {
            shape
                .fill(pad.pressed ? OPNDesign.accent.opacity(0.12) : ControllerDiagramArtwork.Overlay.fill(0.045))
                .overlay(
                    shape.stroke(
                        pad.pressed ? OPNDesign.accent.opacity(0.8) : (pad.touched ? OPNDesign.accent.opacity(0.45) : ControllerDiagramArtwork.Overlay.strokeRegular),
                        lineWidth: pad.pressed ? 1.5 : 1
                    )
                )
            Canvas { context, size in
                let diameter = size.width / 160
                for row in 0..<12 {
                    for column in 0..<24 {
                        let x = size.width * CGFloat(column + 1) / 25
                        let y = size.height * CGFloat(row + 1) / 13
                        context.fill(
                            Path(ellipseIn: CGRect(x: x - diameter / 2, y: y - diameter / 2, width: diameter, height: diameter)),
                            with: .color(ControllerDiagramArtwork.Overlay.strokeSubtle)
                        )
                    }
                }
            }
            .clipShape(shape)

            if pad.touched {
                Circle()
                    .fill(pad.pressed ? OPNDesign.accent : OPNDesign.accent.opacity(0.6))
                    .frame(width: art(14), height: art(14))
                    .offset(x: CGFloat(pad.x) * art(61), y: CGFloat(-pad.y) * art(27))
            }
        }
        .frame(width: art(142), height: art(75))
        .clipShape(shape)
    }

    private func stickView(x: Float, y: Float, pressed: Bool) -> some View {
        let active = pressed || abs(x) > 0.05 || abs(y) > 0.05
        let well = art(76)
        let cap = art(56)
        let travel = art(6)
        return ZStack {
            Circle()
                .fill(ControllerDiagramArtwork.Overlay.fill(0.02))
                .overlay(
                    Circle().stroke(
                        pressed ? OPNDesign.accent.opacity(0.7) : (active ? ControllerDiagramArtwork.Overlay.fill(0.28) : ControllerDiagramArtwork.Overlay.strokeRegular),
                        lineWidth: pressed ? 1.5 : 1
                    )
                )
                .frame(width: well, height: well)

            Circle()
                .fill(active ? OPNDesign.accent.opacity(0.9) : ControllerDiagramArtwork.Overlay.strokeRegular)
                .overlay(
                    Circle().stroke(
                        active ? OPNDesign.accent : ControllerDiagramArtwork.Overlay.fill(0.28),
                        lineWidth: 1
                    )
                )
                .frame(width: cap, height: cap)
                .overlay {
                    Circle()
                        .stroke(active ? OPNDesign.onAccent.opacity(0.45) : ControllerDiagramArtwork.Overlay.strokeStrong, lineWidth: 1)
                        .frame(width: art(44), height: art(44))
                }
                .offset(x: CGFloat(x) * travel, y: CGFloat(-y) * travel)
        }
        .frame(width: well, height: well)
    }

    private func dpadArm(pressed: Bool) -> some View {
        DualShock4DPadSegment()
            .fill(pressed ? OPNDesign.accent : ControllerDiagramArtwork.Overlay.fill(0.06))
            .overlay(
                DualShock4DPadSegment()
                    .stroke(pressed ? OPNDesign.accent.opacity(0.7) : ControllerDiagramArtwork.Overlay.strokeRegular, lineWidth: 1)
            )
            .frame(width: art(24), height: art(29))
    }

    private func faceButtonNode(_ glyph: DualShock4FaceGlyph.Symbol, pressed: Bool) -> some View {
        ZStack {
            Circle()
                .fill(pressed ? OPNDesign.accent : ControllerDiagramArtwork.Overlay.fill(0.05))
                .overlay(Circle().stroke(pressed ? OPNDesign.accent.opacity(0.8) : ControllerDiagramArtwork.Overlay.strokeStrong, lineWidth: 1))
            DualShock4FaceGlyph(symbol: glyph)
                .stroke(pressed ? OPNDesign.onAccent : ControllerDiagramArtwork.Overlay.textTertiary,
                        style: StrokeStyle(lineWidth: art(1.3), lineCap: .round, lineJoin: .round))
                .frame(width: art(16), height: art(16))
        }
        .frame(width: art(27), height: art(27))
    }

    private func centerButton(_ label: String, pressed: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: art(5))
                .fill(pressed ? OPNDesign.accent.opacity(0.25) : ControllerDiagramArtwork.Overlay.fill(0.04))
            RoundedRectangle(cornerRadius: art(5))
                .stroke(pressed ? OPNDesign.accent.opacity(0.7) : ControllerDiagramArtwork.Overlay.strokeRegular, lineWidth: 1)
        }
        .frame(width: art(14), height: art(26))
        .overlay(alignment: .top) {
            Text(label)
                .font(.settingsFont(size: art(5.5), weight: .bold))
                .foregroundStyle(ControllerDiagramArtwork.Overlay.textTertiary)
                .fixedSize()
                .offset(y: art(-6))
        }
    }

    private func psButton(pressed: Bool) -> some View {
        ZStack {
            Circle()
                .fill(pressed ? OPNDesign.accent.opacity(0.25) : ControllerDiagramArtwork.Overlay.fill(0.05))
                .overlay(Circle().stroke(pressed ? OPNDesign.accent.opacity(0.8) : ControllerDiagramArtwork.Overlay.strokeRegular, lineWidth: 1))
            Image(systemName: "playstation.logo")
                .resizable()
                .scaledToFit()
                .frame(width: art(16), height: art(14))
                .foregroundStyle(pressed ? OPNDesign.accent : ControllerDiagramArtwork.Overlay.textTertiary)
        }
        .frame(width: art(23), height: art(23))
    }
}

private struct DualShock4FaceGlyph: Shape {
    enum Symbol { case triangle, circle, cross, square }

    let symbol: Symbol

    func path(in rect: CGRect) -> Path {
        switch symbol {
        case .triangle:
            return Path { path in
                path.move(to: CGPoint(x: rect.midX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
                path.closeSubpath()
            }
        case .circle:
            return Path(ellipseIn: rect)
        case .cross:
            return Path { path in
                path.move(to: CGPoint(x: rect.minX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            }
        case .square:
            return Path(rect)
        }
    }
}

private struct DualShock4DPadSegment: Shape {
    func path(in rect: CGRect) -> Path {
        let width = rect.width
        let height = rect.height
        return Path { path in
            path.move(to: CGPoint(x: width * 0.24, y: 0))
            path.addQuadCurve(to: CGPoint(x: 0, y: height * 0.18), control: .zero)
            path.addLine(to: CGPoint(x: width * 0.06, y: height * 0.65))
            path.addQuadCurve(to: CGPoint(x: width * 0.42, y: height * 0.97), control: CGPoint(x: width * 0.2, y: height * 0.86))
            path.addQuadCurve(to: CGPoint(x: width * 0.58, y: height * 0.97), control: CGPoint(x: width * 0.5, y: height * 1.03))
            path.addQuadCurve(to: CGPoint(x: width * 0.94, y: height * 0.65), control: CGPoint(x: width * 0.8, y: height * 0.86))
            path.addLine(to: CGPoint(x: width, y: height * 0.18))
            path.addQuadCurve(to: CGPoint(x: width * 0.76, y: 0), control: CGPoint(x: width, y: 0))
            path.closeSubpath()
        }
    }
}

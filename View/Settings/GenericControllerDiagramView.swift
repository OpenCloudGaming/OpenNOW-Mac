import SwiftUI

/// A generic gamepad's shell, live-highlighted from a `GenericControllerInputSnapshot`. The
/// counterpart to `SteamControllerDiagramView` for the pads GameController exposes - Xbox,
/// PlayStation, and anything else that is not a Steam Controller - drawn in the same authored
/// space with the same overlay vocabulary. Read-only: mapping profiles are Steam-only, so there is
/// nothing here to tap.
///
/// The rounded shapes below are the documented artwork exception in DESIGN.md: they trace physical
/// hardware (round face buttons, circular stick wells, a cross d-pad), not chrome. Everything the
/// user interacts with *around* the drawing stays square.
// Artwork, not chrome: DESIGN.md lists controller diagrams as a radius exception because every
// rounded shape below traces the physical controller. The rule stays on for the rest of View/.
// swiftlint:disable design_no_corner_radius
struct GenericControllerDiagramView: View {
    let snapshot: GenericControllerInputSnapshot

    @Environment(\.opnUIScale) private var uiScale

    private var diagramWidth: CGFloat { ControllerDiagramArtwork.diagramWidth * uiScale }
    private var artScale: CGFloat { diagramWidth / ControllerDiagramArtwork.artSize.width }
    private var diagramHeight: CGFloat { ControllerDiagramArtwork.artSize.height * artScale }

    private func art(_ value: CGFloat) -> CGFloat { value * artScale }

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
                triggerLabel: "LT", value: snapshot.leftTrigger,
                bumperLabel: "LB", pressed: snapshot.buttons.contains(.leftShoulder)
            )
            .position(x: art(100), y: 27 * uiScale)

            shoulderGroup(
                triggerLabel: "RT", value: snapshot.rightTrigger,
                bumperLabel: "RB", pressed: snapshot.buttons.contains(.rightShoulder)
            )
            .position(x: art(356), y: 27 * uiScale)
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
            Image("GenericControllerShellFill")
                .renderingMode(.template)
                .resizable()
                .frame(width: diagramWidth, height: diagramHeight)
                .foregroundStyle(ControllerDiagramArtwork.shellFill)
            Image("GenericControllerShell")
                .renderingMode(.template)
                .resizable()
                .frame(width: diagramWidth, height: diagramHeight)
                .foregroundStyle(ControllerDiagramArtwork.shellStroke)

            leftStick
            rightStick
            dpad
            faceButtons
            centerButtons
        }
        .frame(width: diagramWidth, height: diagramHeight)
    }

    private var leftStick: some View {
        stickView(x: snapshot.leftStickX, y: snapshot.leftStickY, pressed: snapshot.buttons.contains(.leftStick))
            .position(x: art(165), y: art(187))
    }

    private var rightStick: some View {
        stickView(x: snapshot.rightStickX, y: snapshot.rightStickY, pressed: snapshot.buttons.contains(.rightStick))
            .position(x: art(291), y: art(187))
    }

    private var dpad: some View {
        ZStack {
            dpadArm(pressed: snapshot.buttons.contains(.dpadUp))
                .rotationEffect(.degrees(0))
                .position(x: art(108), y: art(93))
            dpadArm(pressed: snapshot.buttons.contains(.dpadRight))
                .rotationEffect(.degrees(90))
                .position(x: art(126), y: art(111))
            dpadArm(pressed: snapshot.buttons.contains(.dpadDown))
                .rotationEffect(.degrees(180))
                .position(x: art(108), y: art(129))
            dpadArm(pressed: snapshot.buttons.contains(.dpadLeft))
                .rotationEffect(.degrees(270))
                .position(x: art(90), y: art(111))
            RoundedRectangle(cornerRadius: art(5))
                .fill(ControllerDiagramArtwork.Overlay.fill(0.06))
                .frame(width: art(20), height: art(20))
                .position(x: art(108), y: art(111))
        }
    }

    private var faceButtons: some View {
        ZStack {
            faceButtonNode("Y", pressed: snapshot.buttons.contains(.north))
                .position(x: art(346), y: art(86))
            faceButtonNode("B", pressed: snapshot.buttons.contains(.east))
                .position(x: art(376), y: art(111))
            faceButtonNode("A", pressed: snapshot.buttons.contains(.south))
                .position(x: art(346), y: art(136))
            faceButtonNode("X", pressed: snapshot.buttons.contains(.west))
                .position(x: art(316), y: art(111))
        }
    }

    private var centerButtons: some View {
        ZStack {
            centerButton(icon: "rectangle.on.rectangle", pressed: snapshot.buttons.contains(.select))
                .position(x: art(188), y: art(83))
            centerButton(icon: "line.3.horizontal", pressed: snapshot.buttons.contains(.start))
                .position(x: art(268), y: art(83))
            homeButton(pressed: snapshot.buttons.contains(.mode))
                .position(x: art(228), y: art(88))
        }
    }

    // MARK: - Hardware pieces

    private func stickView(x: Float, y: Float, pressed: Bool) -> some View {
        let active = pressed || abs(x) > 0.05 || abs(y) > 0.05
        let well = art(64)
        let cap = art(44)
        let travel = art(9)
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
                .offset(x: CGFloat(x) * travel, y: CGFloat(-y) * travel)
        }
        .frame(width: well, height: well)
    }

    private func dpadArm(pressed: Bool) -> some View {
        RoundedRectangle(cornerRadius: art(5))
            .fill(pressed ? OPNDesign.accent : ControllerDiagramArtwork.Overlay.fill(0.06))
            .overlay(
                RoundedRectangle(cornerRadius: art(5))
                    .stroke(pressed ? OPNDesign.accent.opacity(0.7) : ControllerDiagramArtwork.Overlay.strokeRegular, lineWidth: 1)
            )
            .frame(width: art(20), height: art(20))
    }

    private func faceButtonNode(_ label: String, pressed: Bool) -> some View {
        ZStack {
            Circle()
                .fill(pressed ? OPNDesign.accent : ControllerDiagramArtwork.Overlay.fill(0.05))
                .overlay(Circle().stroke(pressed ? OPNDesign.accent.opacity(0.8) : ControllerDiagramArtwork.Overlay.strokeStrong, lineWidth: 1))
            Text(label)
                .font(.settingsFont(size: 12 * uiScale, weight: .bold))
                .foregroundStyle(pressed ? OPNDesign.onAccent : ControllerDiagramArtwork.Overlay.textMuted)
        }
        .frame(width: art(30), height: art(26))
    }

    private func centerButton(icon: String, pressed: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: art(6))
                .fill(pressed ? OPNDesign.accent.opacity(0.25) : ControllerDiagramArtwork.Overlay.fill(0.04))
            RoundedRectangle(cornerRadius: art(6))
                .stroke(pressed ? OPNDesign.accent.opacity(0.7) : ControllerDiagramArtwork.Overlay.strokeRegular, lineWidth: 1)
            Image(systemName: icon)
                .font(.settingsFont(size: 9 * uiScale, weight: .bold))
                .foregroundStyle(pressed ? OPNDesign.accentInk : ControllerDiagramArtwork.Overlay.textMuted)
        }
        .frame(width: art(30), height: art(14))
    }

    private func homeButton(pressed: Bool) -> some View {
        ZStack {
            Circle()
                .fill(pressed ? OPNDesign.accent.opacity(0.25) : ControllerDiagramArtwork.Overlay.fill(0.05))
                .overlay(Circle().stroke(pressed ? OPNDesign.accent.opacity(0.8) : ControllerDiagramArtwork.Overlay.strokeRegular, lineWidth: 1))
            Circle()
                .stroke(pressed ? OPNDesign.accentInk : ControllerDiagramArtwork.Overlay.textMuted, lineWidth: 1.5)
                .frame(width: art(10), height: art(10))
        }
        .frame(width: art(26), height: art(26))
    }
}

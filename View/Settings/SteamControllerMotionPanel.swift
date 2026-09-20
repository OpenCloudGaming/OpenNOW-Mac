import SwiftUI

/// Live inertial data for the controller tester, plus the capacitive contacts that gate it.
///
/// This panel is also the hardware check the gyro feature depends on: the 2026 controller's IMU
/// ships disabled and reports twelve bytes of nothing until the host switches it on, so "no motion
/// data" here means the reporting command never landed — not that the pad is being held still.
///
/// Lives outside `SteamControllerTestView` to keep that type's body inside the linter's limit.
struct SteamControllerMotionPanel: View {
    let snapshot: ControllerInputSnapshot
    let uiScale: CGFloat

    var body: some View {
        SteamControllerSection(title: "MOTION", uiScale: uiScale) {
            VStack(alignment: .leading, spacing: OPNDesign.Spacing.small(scale: uiScale)) {
                if let motion = snapshot.motion {
                    vectorRow("GYRO", x: motion.gyroX, y: motion.gyroY, z: motion.gyroZ, unit: "°/s")
                    vectorRow("ACCEL", x: motion.accelX, y: motion.accelY, z: motion.accelZ, unit: "")
                    HStack(spacing: OPNDesign.Spacing.medium(scale: uiScale)) {
                        contactRow("Grip L", active: snapshot.leftGripSense)
                        contactRow("Grip R", active: snapshot.rightGripSense)
                        contactRow("Stick L", active: snapshot.leftStickTouched)
                        contactRow("Stick R", active: snapshot.rightStickTouched)
                    }
                } else {
                    Text("No motion data. The IMU is off in the controller's firmware until OpenNOW switches it on, which it does only while a profile asks for gyro — set Gyro → Output to anything other than Off.")
                        .font(.settingsFont(size: 11 * uiScale, weight: .medium))
                        .foregroundStyle(OPNDesign.Text.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func vectorRow(_ label: String, x: Float, y: Float, z: Float, unit: String) -> some View {
        HStack(spacing: OPNDesign.Spacing.small(scale: uiScale)) {
            Text(label)
                .font(.settingsFont(size: 10 * uiScale, weight: .bold))
                .foregroundStyle(OPNDesign.Text.tertiary)
                .frame(width: 44 * uiScale, alignment: .leading)
            axisCell("X", value: x)
            axisCell("Y", value: y)
            axisCell("Z", value: z)
            if !unit.isEmpty {
                Text(unit)
                    .font(.settingsFont(size: 10 * uiScale, weight: .medium))
                    .foregroundStyle(OPNDesign.Text.muted)
            }
        }
    }

    private func axisCell(_ axis: String, value: Float) -> some View {
        HStack(spacing: 3 * uiScale) {
            Text(axis)
                .font(.settingsFont(size: 10 * uiScale, weight: .bold))
                .foregroundStyle(OPNDesign.Text.muted)
            Text(String(format: "%.0f", value))
                .font(.settingsFont(size: 11 * uiScale, weight: .medium))
                .foregroundStyle(OPNDesign.Text.primary)
                .monospacedDigit()
                .frame(width: 48 * uiScale, alignment: .trailing)
        }
    }

    private func contactRow(_ label: String, active: Bool) -> some View {
        HStack(spacing: 6 * uiScale) {
            Text(label)
                .font(.settingsFont(size: 10 * uiScale, weight: .bold))
                .foregroundStyle(active ? OPNDesign.accentInk : OPNDesign.Text.tertiary)
                .frame(width: 46 * uiScale, alignment: .leading)
            Text(active ? "ON" : "OFF")
                .font(.settingsFont(size: 10 * uiScale, weight: .medium))
                .foregroundStyle(active ? OPNDesign.accentInk : OPNDesign.Text.muted)
                .frame(width: 26 * uiScale, alignment: .leading)
        }
    }
}

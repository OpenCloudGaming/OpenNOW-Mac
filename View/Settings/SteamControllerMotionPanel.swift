import SwiftUI

/// Live inertial data for the controller tester, plus the capacitive contacts that gate it.
///
/// The gyro rows only move while the configured mapping's activation source is engaged; otherwise
/// the panel says what it is waiting for. The mapping decides everything here, including whether
/// the IMU is switched on at all (`ControllerGyroSettings.needsMotionReporting`).
///
/// Lives outside `SteamControllerTestView` to keep that type's body inside the linter's limit.
struct SteamControllerMotionPanel: View {
    let snapshot: ControllerInputSnapshot
    let gyroReadout: SteamControllerGyroReadout
    let activationHint: String
    let uiScale: CGFloat

    var body: some View {
        SteamControllerSection(title: "MOTION", uiScale: uiScale) {
            VStack(alignment: .leading, spacing: OPNDesign.Spacing.small(scale: uiScale)) {
                switch gyroReadout {
                case .notConfigured:
                    notice("No gyro mapping is configured for this controller. Enable Gyro in a mapping profile to activate it here.")
                case .waiting:
                    notice("Waiting for activation. Engage \(activationHint) to start the gyroscope.")
                    contactRows
                case .active:
                    if let motion = snapshot.motion {
                        vectorRow("GYRO", x: motion.gyroX, y: motion.gyroY, z: motion.gyroZ, unit: "°/s")
                        vectorRow("ACCEL", x: motion.accelX, y: motion.accelY, z: motion.accelZ, unit: "")
                    } else {
                        notice("Gyro is active, but no inertial data is arriving from the controller.")
                    }
                    contactRows
                }
            }
        }
    }

    private var contactRows: some View {
        HStack(spacing: OPNDesign.Spacing.medium(scale: uiScale)) {
            contactRow("Grip L", active: snapshot.leftGripSense)
            contactRow("Grip R", active: snapshot.rightGripSense)
            contactRow("Stick L", active: snapshot.leftStickTouched)
            contactRow("Stick R", active: snapshot.rightStickTouched)
        }
    }

    private func notice(_ text: String) -> some View {
        Text(text)
            .font(.settingsFont(size: 11 * uiScale, weight: .medium))
            .foregroundStyle(OPNDesign.Text.muted)
            .fixedSize(horizontal: false, vertical: true)
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

//  The gyroscope editor: output mode, activation, tuning, and calibration.
//
//  Layout and chrome follow `ControllerBindingEditors`' behaviour section — eyebrow, square
//  option picker, slider rows — so the gyro panel reads as one more control's settings rather
//  than a foreign screen. The vocabulary is Steam Input's, because that is the vocabulary the
//  people who will use this already know.

import SwiftUI

extension ControllerMappingView {
    var gyroSettingsBinding: Binding<ControllerGyroSettings> {
        Binding(
            get: { draft?.gyro ?? ControllerGyroSettings() },
            set: { draft?.gyro = $0 }
        )
    }

    /// The whole gyro panel. Shown instead of a binding editor: gyro is a continuous source with
    /// behaviour, like a trackpad, not a control that gets pressed and bound.
    func gyroSection() -> some View {
        let binding = gyroSettingsBinding
        let settings = binding.wrappedValue
        return VStack(alignment: .leading, spacing: OPNDesign.Spacing.section(scale: uiScale)) {
            gyroOutputSection(binding)
            if settings.isEnabled {
                SteamControllerModalRule()
                gyroActivationSection(binding)
                SteamControllerModalRule()
                gyroSensitivitySection(binding)
                SteamControllerModalRule()
                gyroResponseSection(binding)
                if settings.mode == .joystickCamera || settings.mode == .joystickDeflection {
                    SteamControllerModalRule()
                    gyroJoystickSection(binding)
                }
                if settings.mode == .joystickDeflection {
                    SteamControllerModalRule()
                    gyroDeflectionSection(binding)
                }
                SteamControllerModalRule()
                gyroCalibrationSection(binding)
            }
        }
    }

    // MARK: - Output

    private func gyroOutputSection(_ binding: Binding<ControllerGyroSettings>) -> some View {
        VStack(alignment: .leading, spacing: OPNDesign.Spacing.small(scale: uiScale)) {
            SteamControllerEyebrow(text: "OUTPUT", uiScale: uiScale)
            SteamControllerOptionPicker(
                options: GyroOutputMode.allCases.map { (value: $0, label: $0.label) },
                selection: binding.wrappedValue.mode,
                uiScale: uiScale
            ) { mode in
                binding.mode.wrappedValue = mode
            }
            if let detail = binding.wrappedValue.mode.detail {
                gyroNote(detail)
            }
            gyroNote("GeForce NOW normalizes every controller to an XInput pad, so it never carries motion. The gyroscope is translated locally into whichever output you pick.")
        }
    }

    // MARK: - Activation

    private func gyroActivationSection(_ binding: Binding<ControllerGyroSettings>) -> some View {
        let sources: [GyroActivationSource] = GyroActivationSource.nonControlSources
            + GyroActivationSource.controlSources.map { .control($0) }
        return VStack(alignment: .leading, spacing: OPNDesign.Spacing.small(scale: uiScale)) {
            SteamControllerEyebrow(text: "ACTIVATION", uiScale: uiScale)
            SteamControllerOptionPicker(
                options: GyroActivationStyle.allCases.map { (value: $0, label: $0.label) },
                selection: binding.wrappedValue.activationStyle,
                uiScale: uiScale
            ) { style in
                binding.activationStyle.wrappedValue = style
            }
            SteamControllerOptionPicker(
                options: sources.map { (value: $0, label: $0.label) },
                selection: binding.wrappedValue.activationSource,
                uiScale: uiScale
            ) { source in
                binding.activationSource.wrappedValue = source
            }
            gyroNote(binding.wrappedValue.activationStyle == .always
                ? "Always-on gyro drifts unless Speed Deadzone is raised."
                : "Hold the source and move the controller to aim; release to re-centre your hands.")
        }
    }

    // MARK: - Sensitivity

    private func gyroSensitivitySection(_ binding: Binding<ControllerGyroSettings>) -> some View {
        VStack(alignment: .leading, spacing: OPNDesign.Spacing.small(scale: uiScale)) {
            SteamControllerEyebrow(text: "SENSITIVITY", uiScale: uiScale)
            SteamControllerOptionPicker(
                options: GyroConversion.allCases.map { (value: $0, label: $0.label) },
                selection: binding.wrappedValue.conversion,
                uiScale: uiScale
            ) { conversion in
                binding.conversion.wrappedValue = conversion
            }
            if let detail = binding.wrappedValue.conversion.detail {
                gyroNote(detail)
            }
            HStack {
                Text("Natural Sensitivity")
                    .font(.settingsFont(size: 11 * uiScale, weight: .medium))
                    .foregroundStyle(OPNDesign.Text.tertiary)
                Spacer()
                Toggle(isOn: binding.useNaturalSensitivity, uiScale: uiScale)
            }
            if binding.wrappedValue.useNaturalSensitivity {
                gyroSlider(title: "Pixels per 360°",
                           value: binding.pixelsPer360,
                           range: ControllerGyroSettings.minimumPixelsPer360...ControllerGyroSettings.maximumPixelsPer360,
                           display: String(format: "%.0f", binding.wrappedValue.pixelsPer360))
                gyroNote("Screen pixels for one physical 360° turn. One value reproduces the same turn in every game.")
            } else {
                gyroSlider(title: "Sensitivity",
                           value: binding.sensitivity,
                           range: 0.1...10,
                           display: String(format: "%.2f×", binding.wrappedValue.sensitivity))
            }
            gyroSlider(title: "Horizontal Scale",
                       value: binding.horizontalScale,
                       range: 0.1...3,
                       display: String(format: "%.0f%%", binding.wrappedValue.horizontalScale * 100))
            gyroSlider(title: "Vertical Scale",
                       value: binding.verticalScale,
                       range: 0.1...3,
                       display: String(format: "%.0f%%", binding.wrappedValue.verticalScale * 100))
            HStack {
                Text("Invert Horizontal")
                    .font(.settingsFont(size: 11 * uiScale, weight: .medium))
                    .foregroundStyle(OPNDesign.Text.tertiary)
                Spacer()
                Toggle(isOn: binding.invertX, uiScale: uiScale)
            }
            HStack {
                Text("Invert Vertical")
                    .font(.settingsFont(size: 11 * uiScale, weight: .medium))
                    .foregroundStyle(OPNDesign.Text.tertiary)
                Spacer()
                Toggle(isOn: binding.invertY, uiScale: uiScale)
            }
        }
    }

    // MARK: - Response

    private func gyroResponseSection(_ binding: Binding<ControllerGyroSettings>) -> some View {
        VStack(alignment: .leading, spacing: OPNDesign.Spacing.small(scale: uiScale)) {
            SteamControllerEyebrow(text: "RESPONSE", uiScale: uiScale)
            gyroSlider(title: "Smoothing",
                       value: binding.smoothing,
                       range: 0...1,
                       display: String(format: "%.0f%%", binding.wrappedValue.smoothing * 100))
            gyroSlider(title: "Speed Deadzone",
                       value: binding.speedDeadzoneDegreesPerSecond,
                       range: 0...30,
                       display: String(format: "%.1f°/s", binding.wrappedValue.speedDeadzoneDegreesPerSecond))
            gyroSlider(title: "Precision Zone",
                       value: binding.precisionZoneDegreesPerSecond,
                       range: 0...60,
                       display: String(format: "%.1f°/s", binding.wrappedValue.precisionZoneDegreesPerSecond))
            gyroSlider(title: "Momentum H",
                       value: binding.momentumHorizontal,
                       range: 0...1,
                       display: String(format: "%.0f%%", binding.wrappedValue.momentumHorizontal * 100))
            gyroSlider(title: "Momentum V",
                       value: binding.momentumVertical,
                       range: 0...1,
                       display: String(format: "%.0f%%", binding.wrappedValue.momentumVertical * 100))
            gyroNote("Speed Deadzone silences hand tremor; Precision Zone ramps output back in so fine aim does not stutter. Momentum lets a flick coast after release.")
        }
    }

    // MARK: - Joystick shaping

    private func gyroJoystickSection(_ binding: Binding<ControllerGyroSettings>) -> some View {
        VStack(alignment: .leading, spacing: OPNDesign.Spacing.small(scale: uiScale)) {
            SteamControllerEyebrow(text: "JOYSTICK", uiScale: uiScale)
            gyroSlider(title: "Power Curve",
                       value: binding.joystickPowerCurve,
                       range: 0.5...3,
                       display: String(format: "%.2f", binding.wrappedValue.joystickPowerCurve))
            gyroSlider(title: "Anti-Deadzone",
                       value: binding.antiDeadzone,
                       range: 0...0.5,
                       display: String(format: "%.0f%%", binding.wrappedValue.antiDeadzone * 100))
            gyroSlider(title: "Max Turn Rate",
                       value: binding.maxTurnRateDegreesPerSecond,
                       range: 40...600,
                       display: String(format: "%.0f°/s", binding.wrappedValue.maxTurnRateDegreesPerSecond))
            HStack {
                Text("Catch Up")
                    .font(.settingsFont(size: 11 * uiScale, weight: .medium))
                    .foregroundStyle(OPNDesign.Text.tertiary)
                Spacer()
                Toggle(isOn: binding.catchUp, uiScale: uiScale)
            }
            gyroNote("Anti-Deadzone jumps just past the game's own stick deadzone, and Power Curve cancels part of its response curve — the two things that make naive gyro-to-stick feel mushy.")
        }
    }

    private func gyroDeflectionSection(_ binding: Binding<ControllerGyroSettings>) -> some View {
        VStack(alignment: .leading, spacing: OPNDesign.Spacing.small(scale: uiScale)) {
            SteamControllerEyebrow(text: "DEFLECTION", uiScale: uiScale)
            gyroSlider(title: "Full Deflection Angle",
                       value: binding.deflectionAngleDegrees,
                       range: 10...180,
                       display: String(format: "%.0f°", binding.wrappedValue.deflectionAngleDegrees))
            HStack {
                Text("Lock Extents")
                    .font(.settingsFont(size: 11 * uiScale, weight: .medium))
                    .foregroundStyle(OPNDesign.Text.tertiary)
                Spacer()
                Toggle(isOn: binding.lockExtents, uiScale: uiScale)
            }
        }
    }

    // MARK: - Calibration

    private func gyroCalibrationSection(_ binding: Binding<ControllerGyroSettings>) -> some View {
        let settings = binding.wrappedValue
        return VStack(alignment: .leading, spacing: OPNDesign.Spacing.small(scale: uiScale)) {
            SteamControllerEyebrow(text: "CALIBRATION", uiScale: uiScale)
            SteamControllerOptionPicker(
                options: GyroCalibrationMode.allCases.map { (value: $0, label: $0.label) },
                selection: settings.calibrationMode,
                uiScale: uiScale
            ) { mode in
                binding.calibrationMode.wrappedValue = mode
            }
            HStack(spacing: OPNDesign.Spacing.xSmall(scale: uiScale)) {
                gyroValueChip("X", String(format: "%.2f", settings.biasX))
                gyroValueChip("Y", String(format: "%.2f", settings.biasY))
                gyroValueChip("Z", String(format: "%.2f", settings.biasZ))
            }
            gyroNote("Automatic calibration only adapts while gyro is inactive. That is deliberate: the controller's own firmware auto-calibrates constantly and cancels slow deliberate movement, which no setting in Steam Input can switch off. Hold the pad still with gyro released and the estimator re-learns the offset in a second or two.")
            zeroRateOffsetPass(binding)
            if settings.mode == .joystickCamera {
                turnRatePass(binding)
            }
        }
    }

    /// The zero-rate offset pass: hold still, measure, store what the estimator itself measured.
    private func zeroRateOffsetPass(_ binding: Binding<ControllerGyroSettings>) -> some View {
        let isRunning = calibration.isRunning && calibration.kind == .zeroRateOffset
        let isBusy = calibration.isRunning
        return VStack(alignment: .leading, spacing: OPNDesign.Spacing.xSmall(scale: uiScale)) {
            gyroNote("Zero-rate offset: hold the controller as still as you can and measure. The stored value seeds every session, so a pad on a table gives the cleanest reading; moving during the measurement cancels it.")
            if isRunning {
                SteamControllerValueBar(value: calibration.progress, signed: false, uiScale: uiScale)
            }
            HStack(spacing: OPNDesign.Spacing.xSmall(scale: uiScale)) {
                SteamControllerChip(label: isRunning ? "Measuring…" : "Measure Offset", isSelected: isRunning, uiScale: uiScale) {
                    if isRunning {
                        calibration.cancel()
                    } else {
                        calibration.start(.zeroRateOffset)
                    }
                }
                .disabled(isBusy && !isRunning)
                if case .measuredOffset(let x, let y, let z) = calibration.result, !isBusy {
                    SteamControllerChip(label: "Use \(offsetText(x, y, z))", isSelected: false, uiScale: uiScale) {
                        binding.wrappedValue = calibration.applyingMeasuredOffset(to: binding.wrappedValue)
                        calibration.cancel()
                    }
                }
            }
            if let text = offsetOutcomeText {
                gyroNote(text)
            }
        }
    }

    private func offsetText(_ x: Float, _ y: Float, _ z: Float) -> String {
        String(format: "%.2f / %.2f / %.2f", x, y, z)
    }

    private var offsetOutcomeText: String? {
        guard !calibration.isRunning else { return nil }
        switch calibration.result {
        case .measuredOffset:
            return "Measured. Store it, or measure again if the pad was not resting."
        case .movedDuringCapture:
            return "The controller moved while measuring, so nothing was stored. Rest your hands and measure again."
        case .noMotionData:
            return "This controller reports no motion data, so there is no zero-rate offset to measure."
        default:
            return nil
        }
    }

    /// The turn-rate pass. Offered only for joystick-camera output: that deflection divides the
    /// shaped rotation rate by `maxTurnRateDegreesPerSecond`, so it is the one mode where the number
    /// this measures is a number something reads.
    private func turnRatePass(_ binding: Binding<ControllerGyroSettings>) -> some View {
        let isRunning = calibration.isRunning && calibration.kind == .turnRate
        let isBusy = calibration.isRunning
        return VStack(alignment: .leading, spacing: OPNDesign.Spacing.xSmall(scale: uiScale)) {
            gyroNote("Maximum Turn Rate is how fast you rotate before the right stick pins at full — \(Int(binding.wrappedValue.maxTurnRateDegreesPerSecond))°/s now. Measure it by turning the controller the way you swing the camera in game.")
            if isRunning {
                SteamControllerValueBar(value: calibration.progress, signed: false, uiScale: uiScale)
            }
            HStack(spacing: OPNDesign.Spacing.xSmall(scale: uiScale)) {
                SteamControllerChip(label: isRunning ? "Measuring…" : "Measure Turn Rate", isSelected: isRunning, uiScale: uiScale) {
                    if isRunning {
                        calibration.cancel()
                    } else {
                        calibration.start(.turnRate)
                    }
                }
                .disabled(isBusy && !isRunning)
                if case .turnRateRecommended(let rate) = calibration.result, !isBusy {
                    SteamControllerChip(label: "Use \(Int(rate))°/s", isSelected: false, uiScale: uiScale) {
                        binding.wrappedValue = calibration.applyingMeasuredTurnRate(to: binding.wrappedValue)
                        calibration.cancel()
                    }
                }
            }
            if let text = turnRateOutcomeText {
                gyroNote(text)
            }
        }
    }

    private var turnRateOutcomeText: String? {
        if case .noTurnDetected = calibration.result {
            return "Only a slow drift was measured, so nothing was stored. Turn faster than you ever would in game."
        }
        guard calibration.isRunning, calibration.kind == .turnRate else { return nil }
        switch calibration.liveTurnRateVerdict {
        case .keepRotating:
            return "Keep turning — about a third of a full turn is needed before the reading means anything."
        case .noTurnDetected:
            return "Turn faster: only a slow drift has reached the gyro so far."
        case .recommend, nil:
            return nil
        }
    }

    // MARK: - Flick stick

    /// Flick stick settings live with the gyro data because the two calibrate against the same
    /// pixels-per-360 value, exactly as Steam's flick stick and gyro do.
    func flickStickSection() -> some View {
        let binding = gyroSettingsBinding
        return VStack(alignment: .leading, spacing: OPNDesign.Spacing.small(scale: uiScale)) {
            SteamControllerEyebrow(text: "FLICK STICK", uiScale: uiScale)
            gyroSlider(title: "Turn Sensitivity",
                       value: binding.flickStickSensitivity,
                       range: 0.25...2,
                       display: String(format: "%.2f×", binding.wrappedValue.flickStickSensitivity))
            gyroSlider(title: "Engage Threshold",
                       value: binding.flickStickActivationThreshold,
                       range: 0.15...0.9,
                       display: String(format: "%.0f%%", binding.wrappedValue.flickStickActivationThreshold * 100))
            HStack {
                Text("Snap To Heading")
                    .font(.settingsFont(size: 11 * uiScale, weight: .medium))
                    .foregroundStyle(OPNDesign.Text.tertiary)
                Spacer()
                Toggle(isOn: binding.flickStickSnap, uiScale: uiScale)
            }
            gyroNote("Flick stick turns by heading, so it needs the mouse channel — the game will show keyboard prompts while it is in use. Pair it with a vertical scale near 40% and let gyro do the aiming.")
        }
    }

    // MARK: - Shared rows

    func gyroSlider(title: String,
                    value: Binding<Float>,
                    range: ClosedRange<Float>,
                    display: String) -> some View {
        VStack(alignment: .leading, spacing: 2 * uiScale) {
            HStack {
                Text(title)
                    .font(.settingsFont(size: 11 * uiScale, weight: .medium))
                    .foregroundStyle(OPNDesign.Text.tertiary)
                Spacer()
                Text(display)
                    .font(.settingsFont(size: 11 * uiScale, weight: .bold))
                    .foregroundStyle(OPNDesign.accentInk)
                    .monospacedDigit()
            }
            Slider(value: value, in: range)
                .tint(OPNDesign.accent)
        }
    }

    func gyroNote(_ text: String) -> some View {
        Text(text)
            .font(.settingsFont(size: 10 * uiScale, weight: .medium))
            .foregroundStyle(OPNDesign.Text.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func gyroValueChip(_ label: String, _ value: String) -> some View {
        HStack(spacing: 3 * uiScale) {
            Text(label)
                .font(.settingsFont(size: 10 * uiScale, weight: .bold))
                .foregroundStyle(OPNDesign.Text.muted)
            Text("\(value)°/s")
                .font(.settingsFont(size: 10 * uiScale, weight: .medium))
                .foregroundStyle(OPNDesign.Text.tertiary)
                .monospacedDigit()
        }
        .padding(.horizontal, 6 * uiScale)
        .frame(height: 24 * uiScale)
        .background(OPNDesign.Fill.neutral(0.075))
        .overlay { Rectangle().stroke(OPNDesign.Stroke.subtle, lineWidth: 1) }
    }
}

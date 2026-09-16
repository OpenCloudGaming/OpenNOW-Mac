//  The per-binding editors — gamepad chord, keyboard key, mouse button — and the pad/stick
//  behaviour section.
//
//  Every control here is a square chip from SteamControllerModalChrome; the native segmented and
//  menu pickers this used to draw render rounded system chrome the app shell does not have.
//

import SwiftUI

extension ControllerMappingView {
    // MARK: - Gamepad chord editor

    func gamepadEditor(control: ControllerControl, target: ControllerBindingTarget) -> some View {
        let combo: ControllerButtonChord = {
            if case .gamepadChord(let combo) = target { return combo }
            return ControllerButtonChord()
        }()
        return VStack(alignment: .leading, spacing: OPNDesign.Spacing.section(scale: uiScale)) {
            Text(combo.isEmpty ? "Passthrough (sends its own button)" : ControllerChordTarget.comboLabel(for: combo))
                .font(.settingsFont(size: 11 * uiScale, weight: .medium))
                .foregroundStyle(combo.isEmpty ? OPNDesign.Text.tertiary : OPNDesign.accentInk)
            let columns = [GridItem(.adaptive(minimum: 64 * uiScale), spacing: OPNDesign.Spacing.xSmall(scale: uiScale))]
            LazyVGrid(columns: columns, alignment: .leading, spacing: OPNDesign.Spacing.xSmall(scale: uiScale)) {
                ForEach(ControllerChordTarget.all) { chip in
                    SteamControllerChip(
                        label: chip.label,
                        isSelected: combo.contains(chip.element),
                        height: 26,
                        fontSize: 10,
                        uiScale: uiScale
                    ) {
                        var updated = combo
                        updated.toggle(chip.element)
                        draft?.bindings[control] = updated.isEmpty ? .passthroughButton : .gamepadChord(updated)
                    }
                }
            }
        }
    }

    // MARK: - Keyboard editor

    func keyboardEditor(control: ControllerControl, target: ControllerBindingTarget) -> some View {
        let currentLabel: String = {
            if case .keyboardKey(let keyCode, let modifiers) = target {
                return SteamControllerKeyLabel.label(for: keyCode, modifiers: modifiers)
            }
            return "Click to set a key"
        }()
        return ControllerBindingRecorder(currentLabel: currentLabel) { keyCode, modifiers in
            draft?.bindings[control] = .keyboardKey(keyCode: keyCode, modifiers: modifiers)
        }
    }

    // MARK: - Mouse editor

    func mouseEditor(control: ControllerControl, target: ControllerBindingTarget) -> some View {
        let current: MouseButton? = {
            if case .mouseButton(let button) = target { return button }
            return nil
        }()
        let options: [(MouseButton, String)] = [(.left, "Left Click"), (.right, "Right Click"), (.middle, "Middle Click"), (.back, "Back"), (.forward, "Forward")]
        return VStack(alignment: .leading, spacing: 6 * uiScale) {
            ForEach(options, id: \.0) { button, label in
                SteamControllerChip(
                    label: label,
                    isSelected: current == button,
                    height: 30,
                    alignment: .leading,
                    uiScale: uiScale
                ) {
                    draft?.bindings[control] = .mouseButton(button)
                }
            }
            ForEach([Int16(120), -120], id: \.self) { delta in
                SteamControllerChip(label: delta > 0 ? "Scroll Up" : "Scroll Down", isSelected: target == .mouseScroll(delta), uiScale: uiScale) {
                    draft?.bindings[control] = .mouseScroll(delta)
                }
            }
        }
    }

    // MARK: - Pad/stick behavior section

    enum PadSettingsKind {
        case leftPad, rightPad, leftStick, rightStick, touchpad
    }

    func padSettingsKind(for control: ControllerControl) -> PadSettingsKind? {
        switch control {
        case .leftPadClick: .leftPad
        case .rightPadClick: .rightPad
        case .touchpadClick: .touchpad
        case .leftStickClick: .leftStick
        case .rightStickClick: .rightStick
        default: nil
        }
    }

    func padSettingsBinding(_ kind: PadSettingsKind) -> Binding<ControllerPadSettings> {
        Binding(
            get: {
                guard let draft else { return ControllerPadSettings(mode: .disabled) }
                switch kind {
                case .leftPad: return draft.leftPad
                case .rightPad: return draft.rightPad
                case .leftStick: return draft.leftStick
                case .rightStick: return draft.rightStick
                case .touchpad: return draft.touchpad
                }
            },
            set: { newValue in
                switch kind {
                case .leftPad: draft?.leftPad = newValue
                case .rightPad: draft?.rightPad = newValue
                case .leftStick: draft?.leftStick = newValue
                case .rightStick: draft?.rightStick = newValue
                case .touchpad: draft?.touchpad = newValue
                }
            }
        )
    }

    func behaviorSection(_ kind: PadSettingsKind) -> some View {
        let binding = padSettingsBinding(kind)
        let isStick = kind == .leftStick || kind == .rightStick
        let availableModes: [ControllerPointerMode] = isStick
            ? [.joystickPassthrough, .mouse, .scrollWheel, .disabled]
            : [.mouse, .scrollWheel, .disabled]

        return VStack(alignment: .leading, spacing: OPNDesign.Spacing.section(scale: uiScale)) {
            SteamControllerEyebrow(text: "BEHAVIOR", uiScale: uiScale)
            SteamControllerOptionPicker(
                options: availableModes.map { (value: $0, label: $0.label) },
                selection: binding.wrappedValue.mode,
                uiScale: uiScale
            ) { mode in
                binding.mode.wrappedValue = mode
            }

            if binding.wrappedValue.mode == .mouse || binding.wrappedValue.mode == .scrollWheel {
                HStack {
                    Text("Sensitivity")
                        .font(.settingsFont(size: 11 * uiScale, weight: .medium))
                        .foregroundStyle(OPNDesign.Text.tertiary)
                    Spacer()
                    Text(String(format: "%.0f%%", binding.wrappedValue.sensitivity * 100))
                        .font(.settingsFont(size: 11 * uiScale, weight: .bold))
                        .foregroundStyle(OPNDesign.accentInk)
                        .monospacedDigit()
                }
                Slider(value: binding.sensitivity, in: 0.1...4.0)
                    .tint(OPNDesign.accent)
                HStack {
                    Text("Invert Y-Axis")
                        .font(.settingsFont(size: 11 * uiScale, weight: .medium))
                        .foregroundStyle(OPNDesign.Text.tertiary)
                    Spacer()
                    Toggle(isOn: binding.invertY, uiScale: uiScale)
                }
            }
        }
    }
}

//
//  SteamControllerBindingEditors.swift
//  OpenNOW
//
//  The per-binding editors — gamepad chord, keyboard key, mouse button — and the pad/stick
//  behaviour section. Split out of SteamControllerMappingView.swift.
//

import SwiftUI

extension SteamControllerMappingView {
    // MARK: - Gamepad chord editor

    func gamepadEditor(control: SteamControllerControl, target: SteamControllerBindingTarget) -> some View {
        let combo: SteamControllerGripCombo = {
            if case .gamepadChord(let combo) = target { return combo }
            return SteamControllerGripCombo()
        }()
        return VStack(alignment: .leading, spacing: 10) {
            Text(combo.isEmpty ? "Passthrough (sends its own button)" : SteamControllerGripComboTarget.comboLabel(for: combo))
                .font(OpenNOWNVIDIAFont.font(size: 11, weight: .medium))
                .foregroundStyle(combo.isEmpty ? .white.opacity(0.4) : OpenNOWDesign.accent.opacity(0.9))
            let columns = [GridItem(.adaptive(minimum: 64), spacing: 6)]
            LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                ForEach(SteamControllerGripComboTarget.all) { chip in
                    let selected = combo.contains(chip.element)
                    Button {
                        var updated = combo
                        updated.toggle(chip.element)
                        draft?.bindings[control] = updated.isEmpty ? .passthroughButton : .gamepadChord(updated)
                    } label: {
                        Text(chip.label)
                            .font(OpenNOWNVIDIAFont.font(size: 10, weight: .bold))
                            .foregroundStyle(selected ? .black : .white.opacity(0.55))
                            .frame(maxWidth: .infinity)
                            .frame(height: 24)
                            .background(selected ? OpenNOWDesign.accent : Color.white.opacity(0.05))
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(selected ? OpenNOWDesign.accent.opacity(0.8) : Color.white.opacity(0.1), lineWidth: 1))
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Keyboard editor

    func keyboardEditor(control: SteamControllerControl, target: SteamControllerBindingTarget) -> some View {
        let currentLabel: String = {
            if case .keyboardKey(let keyCode, let modifiers) = target {
                return SteamControllerKeyLabel.label(for: keyCode, modifiers: modifiers)
            }
            return "Click to set a key"
        }()
        return SteamControllerBindingRecorder(currentLabel: currentLabel) { keyCode, modifiers in
            draft?.bindings[control] = .keyboardKey(keyCode: keyCode, modifiers: modifiers)
        }
    }

    // MARK: - Mouse editor

    func mouseEditor(control: SteamControllerControl, target: SteamControllerBindingTarget) -> some View {
        let current: MouseButton? = {
            if case .mouseButton(let button) = target { return button }
            return nil
        }()
        let options: [(MouseButton, String)] = [(.left, "Left Click"), (.right, "Right Click"), (.middle, "Middle Click"), (.back, "Back"), (.forward, "Forward")]
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(options, id: \.0) { button, label in
                Button {
                    draft?.bindings[control] = .mouseButton(button)
                } label: {
                    HStack {
                        Text(label)
                            .font(OpenNOWNVIDIAFont.font(size: 11, weight: .bold))
                            .foregroundStyle(current == button ? .black : .white.opacity(0.7))
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(current == button ? OpenNOWDesign.accent : Color.white.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Pad/stick behavior section

    enum PadSettingsKind {
        case leftPad, rightPad, leftStick, rightStick
    }

    func padSettingsKind(for control: SteamControllerControl) -> PadSettingsKind? {
        switch control {
        case .leftPadClick: .leftPad
        case .rightPadClick: .rightPad
        case .leftStickClick: .leftStick
        case .rightStickClick: .rightStick
        default: nil
        }
    }

    func padSettingsBinding(_ kind: PadSettingsKind) -> Binding<SteamControllerPadSettings> {
        Binding(
            get: {
                guard let draft else { return SteamControllerPadSettings(mode: .disabled) }
                switch kind {
                case .leftPad: return draft.leftPad
                case .rightPad: return draft.rightPad
                case .leftStick: return draft.leftStick
                case .rightStick: return draft.rightStick
                }
            },
            set: { newValue in
                switch kind {
                case .leftPad: draft?.leftPad = newValue
                case .rightPad: draft?.rightPad = newValue
                case .leftStick: draft?.leftStick = newValue
                case .rightStick: draft?.rightStick = newValue
                }
            }
        )
    }

    func behaviorSection(_ kind: PadSettingsKind) -> some View {
        let binding = padSettingsBinding(kind)
        let isStick = kind == .leftStick || kind == .rightStick
        let availableModes: [SteamControllerPointerMode] = isStick
            ? [.joystickPassthrough, .mouse, .scrollWheel, .disabled]
            : [.mouse, .scrollWheel, .disabled]

        return VStack(alignment: .leading, spacing: 10) {
            Text("BEHAVIOR")
                .font(OpenNOWNVIDIAFont.font(size: 9, weight: .bold))
                .tracking(1.0)
                .foregroundStyle(.white.opacity(0.35))
            Picker("", selection: binding.mode) {
                ForEach(availableModes) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()

            if binding.wrappedValue.mode == .mouse || binding.wrappedValue.mode == .scrollWheel {
                HStack {
                    Text("Sensitivity")
                        .font(OpenNOWNVIDIAFont.font(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                    Spacer()
                    Text(String(format: "%.0f%%", binding.wrappedValue.sensitivity * 100))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                }
                Slider(value: binding.sensitivity, in: 0.1...4.0)
                Toggle("Invert Y-Axis", isOn: binding.invertY)
                    .font(OpenNOWNVIDIAFont.font(size: 11, weight: .medium))
                    .toggleStyle(.switch)
            }
        }
    }
}

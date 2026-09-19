import AppKit
import SwiftUI

extension OPNKeyCombo {
    var eventModifiers: EventModifiers {
        var modifiers: EventModifiers = []
        if self.modifiers.contains(.command) { modifiers.insert(.command) }
        if self.modifiers.contains(.control) { modifiers.insert(.control) }
        if self.modifiers.contains(.option) { modifiers.insert(.option) }
        if self.modifiers.contains(.shift) { modifiers.insert(.shift) }
        return modifiers
    }

    /// The SwiftUI menu representation, or nil for a key AppKit has no named equivalent for. The
    /// in-window monitors still honour such a binding; only the menu bar cannot advertise it.
    var keyEquivalent: KeyEquivalent? {
        let label = OPNStreamPreferences.microphonePushToTalkKeyLabel(Int(keyCode))
        switch label {
        case "Return": return .return
        case "Tab": return .tab
        case "Space": return .space
        case "Escape": return .escape
        case "Backspace": return .delete
        case "←": return .leftArrow
        case "→": return .rightArrow
        case "↑": return .upArrow
        case "↓": return .downArrow
        case "Home": return .home
        case "End": return .end
        case "Page Up": return .pageUp
        case "Page Down": return .pageDown
        default:
            guard label.count == 1, let character = label.lowercased().first else { return nil }
            return KeyEquivalent(character)
        }
    }
}

struct OPNKeyboardShortcutModifier: ViewModifier {
    let combo: OPNKeyCombo

    @ViewBuilder func body(content: Content) -> some View {
        if let key = combo.keyEquivalent {
            content.keyboardShortcut(key, modifiers: combo.eventModifiers)
        } else {
            content
        }
    }
}

extension View {
    /// Applies a rebindable chord to a menu item or hidden button when it has a menu representation.
    func opnKeyboardShortcut(_ combo: OPNKeyCombo) -> some View {
        modifier(OPNKeyboardShortcutModifier(combo: combo))
    }
}

/// Every shortcut the app owns, grouped by the surface it acts on. Reuses the controller-binding
/// recorder so capture behaves identically wherever a key is recorded in Settings.
struct KeybindingsSettingsPage: View {
    let uiScale: CGFloat
    @ObservedObject private var keybindings = OPNKeybindingsObserver.shared

    static let sections: [SettingsSection] = [
        SettingsSection("stream", "Stream"),
        SettingsSection("catalog", "Catalog"),
    ]

    var body: some View {
        SettingsStack(spacing: 16 * uiScale) {
            sectionCard(.stream)
            sectionCard(.catalog)
            if keybindings.hasCustomBindings { resetCard }
        }
    }

    private func sectionCard(_ section: KeybindingSection) -> some View {
        let actions = KeybindingAction.allCases.filter { $0.section == section }
        return SettingsCard(title: section.title, uiScale: uiScale) {
            HStack(spacing: 8 * uiScale) {
                Image(systemName: section == .stream ? "play.tv.fill" : "square.grid.2x2.fill")
                    .font(.settingsFont(size: 11 * uiScale, weight: .bold))
                    .foregroundStyle(OPNDesign.accentInk)
                Text(section.subtitle)
                    .font(.settingsFont(size: 12 * uiScale, weight: .medium))
                    .foregroundStyle(OPNDesign.Text.muted)
            }
            .padding(.bottom, 10 * uiScale)
            ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                if index > 0 { SettingsDivider(uiScale: uiScale) }
                KeybindingRecorderRow(action: action, uiScale: uiScale)
            }
        }
        .settingsSection(section.rawValue)
    }

    private var resetCard: some View {
        SettingsCard(title: "Reset", uiScale: uiScale) {
            HStack(spacing: 12 * uiScale) {
                Text("Restore every shortcut here to its default.")
                    .font(.settingsFont(size: 12 * uiScale, weight: .medium))
                    .foregroundStyle(OPNDesign.Text.tertiary)
                Spacer(minLength: 0)
                SettingsActionButton(title: "Reset All", tone: .secondary, uiScale: uiScale) {
                    OPNKeybindings.standard.resetAll()
                    OPNNewSettings.acknowledge(.keybindings)
                }
            }
        }
        .settingsSection("reset")
    }
}

struct KeybindingRecorderRow: View {
    let action: KeybindingAction
    let uiScale: CGFloat
    @ObservedObject private var keybindings = OPNKeybindingsObserver.shared

    private var combo: OPNKeyCombo { keybindings.combo(for: action) }
    private var isCustom: Bool { keybindings.hasCustomBinding(for: action) }
    private var conflicts: [KeybindingAction] { keybindings.conflictingActions(for: action) }

    var body: some View {
        HStack(alignment: .center, spacing: 18 * uiScale) {
            VStack(alignment: .leading, spacing: 5 * uiScale) {
                SettingsRowTitle(title: action.title, isNew: false, uiScale: uiScale)
                Text(action.subtitle)
                    .font(.settingsFont(size: 12 * uiScale, weight: .medium))
                    .foregroundStyle(OPNDesign.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                statusLine
            }
            Spacer(minLength: 12 * uiScale)
            ControllerBindingRecorder(currentLabel: combo.label) { keyCode, modifiers in
                guard OPNKeyCombo.isBindableKeyCode(keyCode) else { return }
                OPNKeybindings.standard.assign(OPNKeyCombo(keyCode: keyCode, modifiers: modifiers), to: action)
                OPNNewSettings.acknowledge(.keybindings)
            }
            .frame(width: 190 * uiScale)
            Button("Reset") {
                OPNKeybindings.standard.reset(action)
                OPNNewSettings.acknowledge(.keybindings)
            }
            .buttonStyle(OPNCompactButtonStyle(uiScale: uiScale))
            .disabled(!isCustom)
        }
    }

    @ViewBuilder private var statusLine: some View {
        if conflicts.isEmpty {
            Text("Default \(action.defaultCombo.label)")
                .font(.settingsFont(size: 11 * uiScale, weight: .medium))
                .foregroundStyle(OPNDesign.Text.muted)
        } else {
            HStack(spacing: 5 * uiScale) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.settingsFont(size: 10 * uiScale, weight: .bold))
                Text("Also used by \(conflicts.map(\.title).joined(separator: ", "))")
                    .font(.settingsFont(size: 11 * uiScale, weight: .bold))
            }
            .foregroundStyle(OPNDesign.Semantic.warning)
        }
    }
}

import SwiftUI

struct StreamHUDCouchCoopPadRow: View {
    let pad: OPNCouchCoopPad
    var isPressed = false
    var isAssignFocused = false
    var isIdentifyFocused = false
    let onAssign: () -> Void
    let onIdentify: () -> Void

    private var assignmentLabel: String {
        OPNCouchCoopControllerCoordinator.playerLabel(for: pad.target)
    }

    private var tint: Color {
        pad.target == .off ? StreamHUDTheme.textTertiary : StreamHUDTheme.accent
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "gamecontroller.fill")
                .font(.streamFont(size: 13, weight: .medium))
                .foregroundStyle(isPressed ? StreamHUDTheme.accentSoft : tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(assignmentLabel.uppercased())
                    .font(.streamFont(size: 9, weight: .bold))
                    .tracking(0.7)
                    .foregroundStyle(StreamHUDTheme.textTertiary)
                Text(pad.name)
                    .font(.streamFont(size: 11, weight: .medium))
                    .foregroundStyle(StreamHUDTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 6)
            StreamHUDCouchCoopTextButton(label: assignmentLabel, color: tint, isFocused: isAssignFocused, action: onAssign)
            StreamHUDParticipantIconButton(
                systemName: "waveform",
                label: "Identify this controller",
                color: StreamHUDTheme.accent,
                isFocused: isIdentifyFocused,
                action: onIdentify
            )
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .background(Color.white.opacity(isPressed ? 0.14 : 0.05))
        .overlay {
            Rectangle().stroke(isPressed ? StreamHUDTheme.accent : StreamHUDTheme.divider, lineWidth: isPressed ? 2 : 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(pad.name), \(assignmentLabel)")
    }
}

private struct StreamHUDCouchCoopTextButton: View {
    let label: String
    let color: Color
    let isFocused: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.streamFont(size: 10, weight: .bold))
                .foregroundStyle(color)
                .padding(.horizontal, 8)
                .frame(minWidth: 62, minHeight: 22)
                .background(Color.white.opacity(isFocused ? 0.16 : 0.07))
                .overlay {
                    Rectangle().stroke(isFocused ? color : color.opacity(0.32), lineWidth: isFocused ? 2 : 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Change player for this controller")
        .help("Cycle Player 1, Player 2 and Off")
    }
}

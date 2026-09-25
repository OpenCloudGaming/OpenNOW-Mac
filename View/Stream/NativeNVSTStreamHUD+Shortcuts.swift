import Foundation
import SwiftUI

/// One row of the shortcut list: the action, what it does, and the chord it is bound to right now.
private struct NativeShortcutHelpRow: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let combo: String
}

extension NativeNVSTMediaStreamSurface {
    var nativeShortcutsHelpOverlay: some View {
        ZStack {
            StreamHUDTheme.scrim
                .ignoresSafeArea(.container, edges: [.horizontal, .bottom])
                .onTapGesture { model.setShortcutsHelpVisible(false) }
            nativeShortcutsHelpPanel
        }
    }

    private var nativeShortcutsHelpPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("SHORTCUTS")
                    .font(.streamFont(size: 10, weight: .bold))
                    .tracking(1.1)
                    .foregroundStyle(StreamHUDTheme.accent)
                Text(configuration.title.isEmpty ? "GeForce NOW" : configuration.title)
                    .font(.streamFont(size: 20, weight: .bold))
                    .foregroundStyle(StreamHUDTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 22)
            .padding(.top, 16)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(StreamHUDTheme.appBar)
            Rectangle().fill(StreamHUDTheme.divider).frame(height: 1)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(nativeShortcutHelpRows) { row in
                        nativeShortcutHelpRow(row)
                        if row.id != nativeShortcutHelpRows.last?.id {
                            Rectangle().fill(StreamHUDTheme.divider).frame(height: 1)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
            }
            .frame(maxHeight: 360)
            Rectangle().fill(StreamHUDTheme.divider).frame(height: 1)
            HStack(spacing: 12) {
                Text("Esc Close")
                    .font(.streamFont(size: 10, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(StreamHUDTheme.textTertiary)
                Spacer(minLength: 0)
                Button { model.setShortcutsHelpVisible(false) } label: {
                    Text("Done")
                        .font(.streamFont(size: 11, weight: .bold))
                        .foregroundStyle(.black.opacity(0.86))
                        .padding(.horizontal, 14)
                        .frame(height: 28)
                        .background(StreamHUDTheme.accent)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        }
        .frame(width: 460)
        .background(StreamHUDTheme.panel.opacity(0.985))
        .overlay { Rectangle().stroke(StreamHUDTheme.accent.opacity(0.28), lineWidth: 1) }
        .overlay(alignment: .top) { Rectangle().fill(StreamHUDTheme.accent).frame(height: 2) }
        .shadow(color: .black.opacity(0.58), radius: 28, x: 0, y: 20)
    }

    private var nativeShortcutHelpRows: [NativeShortcutHelpRow] {
        KeybindingAction.allCases
            .filter { $0.section == .stream }
            .map { action in
                NativeShortcutHelpRow(
                    id: action.rawValue,
                    title: action.title,
                    subtitle: action.subtitle,
                    combo: OPNKeybindings.standard.combo(for: action).label
                )
            }
    }

    private func nativeShortcutHelpRow(_ row: NativeShortcutHelpRow) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.streamFont(size: 12, weight: .bold))
                    .foregroundStyle(StreamHUDTheme.textPrimary)
                Text(row.subtitle)
                    .font(.streamFont(size: 10, weight: .medium))
                    .foregroundStyle(StreamHUDTheme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            Text(row.combo)
                .font(.streamFont(size: 12, weight: .bold).monospacedDigit())
                .foregroundStyle(StreamHUDTheme.accent)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(Color.white.opacity(0.07))
                .overlay { Rectangle().stroke(StreamHUDTheme.divider, lineWidth: 1) }
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }
}

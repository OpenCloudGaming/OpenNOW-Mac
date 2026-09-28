//  The unified HUD's CLIPBOARD panel: the text captured off stream frames, newest first.
//

import Foundation
import SwiftUI

extension NativeNVSTMediaStreamSurface {
    var nativeHUDClipboardPanel: some View {
        StreamHUDClipboardPanel(model: model, clipboard: model.clipboard)
    }

    static func clipboardFocusID(for entry: StreamClipboardEntry) -> String {
        NativeNVSTHostViewModel.clipboardEntryFocusPrefix + entry.id.uuidString
    }

    static func clipboardRemoveFocusID(for entry: StreamClipboardEntry) -> String {
        NativeNVSTHostViewModel.clipboardRemoveFocusPrefix + entry.id.uuidString
    }
}

/// Observes the clipboard controller directly: entries are filed off the copy shortcut while the HUD
/// is open, and the model's own `objectWillChange` does not fire for state the controller owns.
struct StreamHUDClipboardPanel: View {
    let model: NativeNVSTHostViewModel
    @ObservedObject var clipboard: StreamClipboardController

    var body: some View {
        StreamHUDSection(
            label: OPNStreamHUDSection.clipboard.title,
            spacing: 8,
            // A Labs feature, so the panel says so. The section only exists while its flag is on.
            tag: .experimental,
            isCollapsed: model.isHUDSectionCollapsed(.clipboard),
            isFocused: model.isHUDSectionHeaderFocused(.clipboard),
            reorderPayload: OPNStreamHUDSection.clipboard.rawValue,
            onToggle: { model.toggleHUDSection(.clipboard) }
        ) {
            VStack(alignment: .leading, spacing: 8) {
                captureModeRow
                emptyState
                historyList
            }
        }
    }

    /// What the reader reaches for when the copy starts bothering them, and the way into region mode.
    /// The same value the Capture page shows, so a change here is a change everywhere.
    private var captureModeRow: some View {
        StreamHUDSegmentedRow(
            label: "Capture",
            options: StreamTextCaptureMode.allCases.map { ($0, $0.label) },
            selection: clipboard.captureMode,
            isDisabled: false,
            isFocused: model.hudFocusID == NativeNVSTHostViewModel.clipboardCaptureModeFocusID
        ) { mode in
            model.setClipboardCaptureMode(mode)
        }
    }

    @ViewBuilder private var emptyState: some View {
        if clipboard.entries.isEmpty {
            Text(emptyStateMessage)
                .font(.streamFont(size: 11, weight: .medium))
                .foregroundStyle(StreamHUDTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var historyList: some View {
        if !clipboard.entries.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(clipboard.entries) { entry in
                    StreamHUDClipboardRow(
                        entry: entry,
                        isCopyFocused: model.hudFocusID == NativeNVSTMediaStreamSurface.clipboardFocusID(for: entry),
                        isRemoveFocused: model.hudFocusID == NativeNVSTMediaStreamSurface.clipboardRemoveFocusID(for: entry),
                        onCopy: { model.copyClipboardEntry(entry) },
                        onRemove: { model.removeClipboardEntry(entry) }
                    )
                }
            }
            StreamHUDClipboardClearButton(isArmed: clipboard.isClearArmed, isFocused: model.hudFocusID == NativeNVSTHostViewModel.clipboardClearFocusID) {
                model.requestClearClipboardHistory()
            }
        }
    }

    private var emptyStateMessage: String {
        switch clipboard.captureMode {
        case .off: return "Capture is off. Your history is kept."
        case .selection: return "Select text in a stream and press copy to file it here."
        case .region: return "Press copy to freeze the frame, then drag over the text to read."
        }
    }
}

/// One captured text, flattened to a single line, with the time and title beneath it. The row is not
/// itself a button: copy and remove are explicit controls at the trailing edge.
struct StreamHUDClipboardRow: View {
    let entry: StreamClipboardEntry
    var isCopyFocused = false
    var isRemoveFocused = false
    let onCopy: () -> Void
    let onRemove: () -> Void
    @State private var isHovering = false

    private var oneLineText: String {
        entry.text.replacingOccurrences(of: "\n", with: " ")
    }

    /// The row says so itself when the field cut the text off, so the reader knows the rest can be
    /// copied in to join it.
    private var isClipped: Bool {
        StreamTextCaptureFilter.isClipped(entry.text)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(oneLineText)
                    .font(.streamFont(size: 11, weight: .semibold))
                    .foregroundStyle(StreamHUDTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                metadata
            }
            Spacer(minLength: 6)
            StreamHUDParticipantIconButton(
                systemName: "doc.on.doc",
                label: "Copy to clipboard",
                color: StreamHUDTheme.accent,
                isFocused: isCopyFocused,
                action: onCopy
            )
            StreamHUDParticipantIconButton(
                systemName: "trash",
                label: "Remove this entry",
                color: StreamHUDTheme.danger,
                isFocused: isRemoveFocused,
                action: onRemove
            )
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(isHovering ? 0.14 : 0.055))
        .overlay {
            Rectangle().stroke(isFocused ? StreamHUDTheme.accent : StreamHUDTheme.divider, lineWidth: isFocused ? 2 : 1)
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .contain)
        .help(isClipped ? "Cut off \u{2014} scroll the field and copy the rest to join it" : entry.text)
    }

    private var isFocused: Bool { isCopyFocused || isRemoveFocused }

    private var metadata: some View {
        HStack(spacing: 8) {
            Text(entry.capturedAt, style: .relative)
            if isClipped {
                Text("CUT OFF")
                    .foregroundStyle(StreamHUDTheme.warning)
            }
            if !entry.gameTitle.isEmpty {
                Text(entry.gameTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .font(.streamFont(size: 9, weight: .medium))
        .foregroundStyle(StreamHUDTheme.textTertiary)
    }
}

/// The panel footer. Two presses: the first arms, the second clears.
struct StreamHUDClipboardClearButton: View {
    let isArmed: Bool
    var isFocused = false
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(isArmed ? "Confirm clear" : "Clear history")
                .font(.streamFont(size: 11, weight: .bold))
                .foregroundStyle(isArmed ? StreamHUDTheme.danger : StreamHUDTheme.textSecondary)
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .background(Color.white.opacity(isHovering || isFocused ? 0.12 : 0.055))
                .overlay {
                    Rectangle().stroke(isFocused ? StreamHUDTheme.accent : StreamHUDTheme.divider, lineWidth: isFocused ? 2 : 1)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(isArmed ? "Confirm clearing the clipboard history" : "Clear the clipboard history")
    }
}

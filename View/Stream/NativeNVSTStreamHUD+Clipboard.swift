//  The unified HUD's CLIPBOARD panel: the text captured off stream frames, newest first. Reading is
//  free and curation is deliberate — a row only reaches the Mac pasteboard when it is confirmed.
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
                if clipboard.entries.isEmpty {
                    Text(emptyStateText)
                        .font(.streamFont(size: 11, weight: .medium))
                        .foregroundStyle(StreamHUDTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(clipboard.entries) { entry in
                            StreamHUDClipboardRow(
                                entry: entry,
                                isFocused: model.hudFocusID == NativeNVSTMediaStreamSurface.clipboardFocusID(for: entry)
                            ) {
                                model.copyClipboardEntry(entry)
                            }
                        }
                    }
                    StreamHUDClipboardClearButton(isArmed: clipboard.isClearArmed, isFocused: model.hudFocusID == NativeNVSTHostViewModel.clipboardClearFocusID) {
                        model.requestClearClipboardHistory()
                    }
                }
            }
        }
    }

    /// What the reader reaches for when the copy starts bothering them, and the way into region mode.
    /// It is the same value the Capture page shows, so a change here is a change everywhere and it
    /// survives the next session.
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

    private var emptyStateText: String {
        switch clipboard.captureMode {
        case .off: return "Capture is off. Your history is kept."
        case .selection: return "Select text in a stream and press copy to file it here."
        case .region: return "Press copy to freeze the frame, then drag over the text to read."
        }
    }
}

/// One captured text. The recognized text is flattened to a single line so a multi-line OCR result
/// does not turn one row into a paragraph; the time and title below say where it came from.
struct StreamHUDClipboardRow: View {
    let entry: StreamClipboardEntry
    var isFocused = false
    let action: () -> Void
    @State private var isHovering = false

    private var oneLineText: String {
        entry.text.replacingOccurrences(of: "\n", with: " ")
    }

    /// The row says so itself when the field cut the text off, so the reader can see that copying the
    /// rest of it will join the two rather than leave a second fragment.
    private var isClipped: Bool {
        StreamTextCaptureFilter.isClipped(entry.text)
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(oneLineText)
                    .font(.streamFont(size: 11, weight: .semibold))
                    .foregroundStyle(StreamHUDTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
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
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(isHovering ? 0.14 : 0.055))
            .overlay {
                Rectangle().stroke(isFocused ? StreamHUDTheme.accent : StreamHUDTheme.divider, lineWidth: isFocused ? 2 : 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("Copy captured text from \(entry.gameTitle.isEmpty ? "the stream" : entry.gameTitle)\(isClipped ? ", cut off" : "")")
        .help(isClipped ? "Cut off \u{2014} scroll the field and copy the rest to join it" : "Copy to clipboard")
    }
}

/// The panel footer. Two presses: the first arms, the second clears, so a stray pad activate cannot
/// wipe the history mid-game.
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

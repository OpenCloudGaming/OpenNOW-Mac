//  The native NVST surface's own HUD: the unified sidebar dock and the panels it stacks.
//

import Combine
import Foundation
import SwiftUI

extension NativeNVSTMediaStreamSurface {
    var nativeUnifiedHUD: some View {
        StreamUnifiedSidebar(
            title: configuration.title.isEmpty ? "GeForce NOW" : configuration.title,
            closeAction: { model.setUnifiedHUDVisible(false) },
            sessionLimit: model.sessionLimit,
            powerAction: { model.showStreamControls() },
            isPowerFocused: model.hudFocusID == "quit-menu",
            isClockVisible: model.isHUDClockVisible,
            customizeAction: { model.setHUDCustomizeVisible(true) },
            shortcutsHelpAction: { model.setShortcutsHelpVisible(true) },
            shortcutsHelpLabel: OPNKeybindings.standard.combo(for: .showShortcutsHelp).label
        ) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(model.visibleHUDSectionOrder, id: \.self) { section in
                    nativeHUDSectionPanel(section)
                        // Lifted above the panels that follow it while the Co-Op quality menu is open:
                        // that overlay extends past its section and would otherwise paint underneath.
                        .zIndex(section == .coop ? 1 : 0)
                        .overlay(alignment: .top) {
                            if hudSectionDropTarget == section {
                                Rectangle().fill(StreamHUDTheme.accent).frame(height: 2).offset(y: -8)
                            }
                        }
                        .dropDestination(for: String.self) { items, _ in
                            handleHUDSectionDrop(items, to: section)
                        } isTargeted: { targeted in
                            hudSectionDropTarget = targeted ? section : nil
                        }
                }
                Color.clear
                    .frame(height: 28)
                    .contentShape(Rectangle())
                    .overlay(alignment: .bottom) {
                        if isDropTargetingSectionsEnd {
                            Rectangle().fill(StreamHUDTheme.accent).frame(height: 2)
                        }
                    }
                    .dropDestination(for: String.self) { items, _ in
                        handleHUDSectionDrop(items, to: nil)
                    } isTargeted: { isDropTargetingSectionsEnd = $0 }
            }
        }
    }

    @ViewBuilder
    func nativeHUDSectionPanel(_ section: OPNStreamHUDSection) -> some View {
        switch section {
        case .session: nativeHUDSessionPanel
        case .audio: nativeHUDAudioPanel
        case .capture: nativeHUDCapturePanel
        case .display: nativeHUDDisplayPanel
        case .input: nativeHUDInputPanel
        case .controllers: nativeHUDControllersPanel
        case .network: nativeHUDNetworkPanel
        case .stats: nativeHUDStatsPanel
        case .coop: nativeHUDRemoteCoOpPanel
        case .upscaling: nativeHUDUpscalingPanel
        case .stream: nativeHUDStreamInfoPanel
        }
    }

    /// A drop on a section inserts just above it; a drop on the trailing zone moves to the end.
    func handleHUDSectionDrop(_ items: [String], to target: OPNStreamHUDSection?) -> Bool {
        guard let raw = items.first, let dragged = OPNStreamHUDSection(rawValue: raw) else { return false }
        withAnimation(OPNDesign.Motion.panel) {
            model.moveHUDSection(dragged, to: target)
        }
        hudSectionDropTarget = nil
        isDropTargetingSectionsEnd = false
        return true
    }

    /// Shared `label: value` row used by the Co-Op and Stream Info panels.
    func nativeHUDDetailRow(label: String, value: String) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.streamFont(size: 11, weight: .medium))
                .foregroundStyle(StreamHUDTheme.textTertiary)
            Spacer(minLength: 8)
            Text(value)
                .font(.streamFont(size: 11, weight: .bold))
                .foregroundStyle(StreamHUDTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

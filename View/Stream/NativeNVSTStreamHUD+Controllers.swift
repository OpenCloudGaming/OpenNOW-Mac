import Combine
import Foundation
import SwiftUI

extension NativeNVSTMediaStreamSurface {
    /// One row per physical controller with a battery gauge; absent when nothing is connected.
    @ViewBuilder
    var nativeHUDControllersPanel: some View {
        if !model.controllerBatteries.isEmpty {
            let tiles = nativeHUDControllerTiles
            StreamHUDSection(
                label: OPNStreamHUDSection.controllers.title,
                spacing: 6,
                caption: nativeHUDCaption(for: tiles, extra: [("rumble-intensity", "Rumble Intensity · A steps +25%, 0 is off")]),
                isCollapsed: model.isHUDSectionCollapsed(.controllers),
                isFocused: model.isHUDSectionHeaderFocused(.controllers),
                reorderPayload: OPNStreamHUDSection.controllers.rawValue,
                onToggle: { model.toggleHUDSection(.controllers) }
            ) {
                nativeHUDTileGrid(nativeHUDControllerTiles)
                if model.controllerInput.isDiagnosticsVisible {
                    ForEach(model.controllerInput.statusRows) { status in
                        StreamHUDControllerInputRow(label: status.label,
                                                    controllerName: status.controllerName,
                                                    sourceLabel: status.source.label,
                                                    isRaw: status.source == .gamepadAPI,
                                                    stickOutput: status.stickOutput)
                    }
                }
                ForEach(model.controllerBatteries) { battery in
                    StreamHUDControllerRow(label: battery.label, name: battery.name, level: battery.level, isCharging: battery.charging)
                }
                // The same ceiling as Settings → Steam Controller → Rumble Intensity, reachable
                // mid-game: a title whose special moves ignore its own vibration slider is
                // discovered while playing it.
                StreamHUDSliderRow(
                    label: "Rumble Intensity %",
                    value: model.rumbleIntensityPercent,
                    range: ControllerRumblePreference.range,
                    step: ControllerRumblePreference.step,
                    isDisabled: false,
                    isFocused: model.hudVisibleFocusID == "rumble-intensity",
                    action: { model.updateRumbleIntensity(percent: $0) }
                )
                .padding(.top, 4)
            }
        }
    }
}

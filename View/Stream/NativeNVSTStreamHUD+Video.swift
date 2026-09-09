import Combine
import Foundation
import SwiftUI

extension NativeNVSTMediaStreamSurface {
    /// Two boxes, matching how every other HUD group (MIC/REC/AFK, NETWORK) already separates
    /// itself: one for controls you change, one for the stream's own read-only facts. Previously
    /// this was one flat "VIDEO" box mixing both, with a static "Target" info row that duplicated
    /// (and could visibly contradict) the "Target Resolution" control above it.
    var nativeHUDVideoPanel: some View {
        Group {
            nativeHUDUpscalingPanel
            nativeHUDStreamInfoPanel
        }
    }

    var nativeHUDUpscalingPanel: some View {
        StreamHUDSection(label: "UPSCALING") {
            VStack(alignment: .leading, spacing: 10) {
                // Display order is independent of the stored option array's order, which stays
                // fixed for backward compatibility.
                StreamHUDSegmentedRow(
                    label: "Upscaling",
                    options: NativeNVSTHostViewModel.upscalingTierDisplayOrder.map { ($0.value, $0.label) },
                    selection: OPNStreamPreferences.upscalingModeOptions[model.upscalingModeIndex].value,
                    isDisabled: !model.sidebarCapabilities.supports(.videoEnhancement),
                    isFocused: model.hudFocusID == "upscaling-tier",
                    onSelect: { model.updateNativeUpscalingTier(value: $0) }
                )
                StreamHUDDropdown(
                    label: "Target Resolution",
                    options: Array(OPNStreamPreferences.upscalingTargetOptions.enumerated().map { ($0.offset, $0.element.label) }),
                    selection: model.upscalingTargetIndex,
                    isDisabled: !model.isConnected || model.upscalingModeIndex == 0 || !model.sidebarCapabilities.supports(.videoEnhancement),
                    onSelect: { model.updateNativeUpscalingTarget(targetIndex: $0) },
                    isFocused: model.hudFocusID == "upscaling-target"
                )
                nativeHUDSliderRow("Clarity", value: model.upscalingSharpness, range: 0...15, isFocused: model.hudFocusID == "clarity") { model.updateNativeUpscalingClarity(sharpness: $0) }
                nativeHUDSliderRow("Noise Reduction", value: model.upscalingDenoise, range: 0...20, isFocused: model.hudFocusID == "noise-reduction") { model.updateNativeUpscalingClarity(denoise: $0) }
            }
        }
    }

    var nativeHUDStreamInfoPanel: some View {
        StreamHUDSection(label: "STREAM") {
            VStack(alignment: .leading, spacing: 10) {
                StreamHUDDropdown(
                    label: "Pillarbox Fill",
                    options: OPNPillarboxFillMode.pickerCases.map { ($0.rawValue, $0.label) },
                    selection: model.pillarboxFillModeIndex,
                    isDisabled: !model.isConnected,
                    onSelect: { model.updateNativePillarboxFill(modeIndex: $0) },
                    isFocused: model.hudFocusID == "pillarbox-fill"
                )
                nativeHUDDetailRow(label: "Active", value: model.upscalingModeIndex == 0 ? "Native" : OPNStreamPreferences.upscalingModeOptions[model.upscalingModeIndex].label)
                nativeHUDDetailRow(label: "Resolution", value: model.nativeStreamResolutionText)
                nativeHUDDetailRow(label: "Frame Rate", value: model.nativeStreamFrameRateText)
                nativeHUDDetailRow(label: "Codec", value: model.nativeStreamCodecText)
            }
        }
    }

    func nativeHUDSliderRow(_ label: String, value: Int, range: ClosedRange<Int>, isFocused: Bool = false, action: @escaping (Int) -> Void) -> some View {
        StreamHUDSliderRow(
            label: label,
            value: value,
            range: range,
            isDisabled: !model.isConnected || model.upscalingModeIndex == 0 || !model.sidebarCapabilities.supports(.videoEnhancement),
            isFocused: isFocused,
            action: action
        )
    }
}

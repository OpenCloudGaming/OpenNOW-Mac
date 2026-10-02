import Foundation

enum OPNCouchCoopVideoPolicy {
    static let fillAspectLabel = "32:9"

    static func apply(to profile: OPNStreamPreferenceProfile, tile: OPNCouchCoopTile?) -> OPNStreamPreferenceProfile {
        guard let tile, tile.layout == .topAndBottom, let pixelSize = tile.pixelSize,
              let aspectIndex = OPNStreamPreferences.aspectOptions.firstIndex(where: { $0.label == fillAspectLabel }),
              let preset = fillPreset(aspectIndex: aspectIndex, fitting: pixelSize) else { return profile }
        var result = profile
        result.aspectIndex = aspectIndex
        result.aspect = OPNStreamPreferences.aspectOptions[aspectIndex]
        result.resolutionIndex = preset.index
        result.resolution = preset.resolution
        return result
    }

    static func fillPreset(aspectIndex: Int, fitting pixelSize: CGSize) -> (index: Int, resolution: OPNStreamResolutionOption)? {
        let options = Array(OPNStreamPreferences.resolutionOptions(forAspect: aspectIndex).enumerated())
        let fitting = options.last { CGFloat($0.element.width) <= pixelSize.width && CGFloat($0.element.height) <= pixelSize.height }
        guard let chosen = fitting ?? options.first else { return nil }
        return (chosen.offset, chosen.element)
    }
}

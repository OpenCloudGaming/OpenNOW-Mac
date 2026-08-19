import Foundation

/// How to treat the pillarbox columns GeForce NOW bakes into 16:9-only titles
/// when they are displayed on a wider monitor.
///
/// Raw values are persisted and carried across the stream transport, so they must
/// stay stable. Append new cases rather than renumbering.
@objc public enum OPNPillarboxFillMode: Int, CaseIterable, Sendable {
    /// Leave the encoded black bars alone. Free: the source pixels are already black.
    case black = 0
    /// Paint the bars a user-chosen flat colour.
    case solidColor = 1
    /// Mirror the adjacent picture edge outward, blurred. Seam is continuous.
    case blurredMirror = 2
    /// Blow the whole picture up to cover the window, blurred, behind the sharp image.
    case blurredZoom = 3
    /// Stretch the picture across the full width, pushing the distortion to the edges
    /// so the centre stays close to correct. No bars, no mirror, but edge geometry warps.
    case stretchEdges = 4
    /// Scale the picture until it fills the width and crop the overflow off the top and
    /// bottom. No bars and no distortion, at the cost of vertical field of view.
    case cropFill = 5

    public var label: String {
        switch self {
        case .black: return "Black"
        case .solidColor: return "Colour"
        case .blurredMirror: return "Blur Mirror"
        case .blurredZoom: return "Blur Zoom"
        case .stretchEdges: return "Stretch"
        case .cropFill: return "Crop"
        }
    }


    /// Only the blur modes have anything to dim; a chosen flat colour is used as-is.
    public var usesDim: Bool {
        self == .blurredMirror || self == .blurredZoom
    }



    /// Whether the custom Metal render path is required. Black is the encoded
    /// default, so it can stay on WebRTC's own renderer.
    public var needsCustomRenderPath: Bool { self != .black }

    /// Whether the native NVST path can honour this fill.
    ///
    /// On NVST the decoded picture is a Geronimo-owned Metal layer that we host
    /// and aspect-fit ourselves; the pillarbox is the AppKit region left uncovered
    /// around that layer, and we never see the frame's pixels. That makes the
    /// geometry fills (crop/stretch) and flat colours reachable purely by resizing
    /// the layer and painting the uncovered region, but the blur modes — which have
    /// to sample the picture edge — are not. Those fall back to `black`.
    public var isNVSTSupported: Bool {
        switch self {
        case .black, .solidColor, .cropFill, .stretchEdges: return true
        case .blurredMirror, .blurredZoom: return false
        }
    }

    /// The fill actually used on NVST: unsupported modes collapse to `black`.
    public var nvstResolved: OPNPillarboxFillMode { isNVSTSupported ? self : .black }

    /// The subset of modes the native NVST HUD offers, in menu order.
    public static var nvstSupportedCases: [OPNPillarboxFillMode] {
        allCases.filter(\.isNVSTSupported)
    }

    /// Modes offered in the UI. Solid colour was retired; the case stays for
    /// raw-value stability but is never presented as a choice.
    public static var pickerCases: [OPNPillarboxFillMode] {
        allCases.filter { $0 != .solidColor }
    }

    public static func from(_ rawValue: Int) -> OPNPillarboxFillMode {
        OPNPillarboxFillMode(rawValue: rawValue) ?? .black
    }

}

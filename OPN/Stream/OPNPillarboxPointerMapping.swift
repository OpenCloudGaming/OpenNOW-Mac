//  Where a point on the displayed video came from in the decoded frame, once the pillarbox fill
//  has moved the picture around inside the drawable.
//

import CoreGraphics
import Foundation

/// The pillarbox fill one drawn frame actually went through, as the fill pass encoded it.
///
/// Published by that pass rather than recomputed from the detector, because the two disagree
/// routinely. `OPNVideoEnhancementRenderer.pillarboxUniforms` returns its disabled tuple for
/// conditions nothing downstream can observe — a non-identity codec crop, a degenerate source or
/// drawable size, a picture narrower than the two edge insets — and whole render paths (Core
/// Image, the Core Image MetalFX branch, libwebrtc's own renderers) never run the fill pass at
/// all. In every one of those the picture is drawn where the plain aspect fit put it while
/// Stretch or Crop is still selected in preferences, and a pointer that re-derived the geometry
/// from the selected mode would reproject clicks for a transform that never happened.
struct OPNCommittedPillarboxFill: Equatable, Sendable {
    /// The mode the shader switched on. `.black` stands for "no reprojection": the fill was off,
    /// disabled by a guard, or never encoded.
    let mode: OPNPillarboxFillMode
    /// Picture edges inside the source frame as the fill pass sampled them — fractions of frame
    /// width, already trimmed by `OPNVideoEnhancementRenderer.pillarboxEdgeInsetColumns`.
    let contentLeft: Double
    let contentRight: Double
    /// Fraction of source height `cropFill` left visible.
    let cropScaleY: Double
    /// Centre slope of the `stretchEdges` cubic.
    let stretchK: Double

    /// Nothing was drawn through the fill pass.
    static let notApplied = OPNCommittedPillarboxFill(mode: .black, contentLeft: 0, contentRight: 1, cropScaleY: 1, stretchK: 1)

    /// Reads back the uniforms an encoded fill pass was handed. `fill.w` carries the mode the
    /// shader branches on and is 0 for everything `pillarboxUniforms` disabled, so a disabled
    /// tuple — and the `fill.w = 0` fallback taken when the blur history is missing — lands on
    /// ``notApplied`` without the caller repeating any of those guards.
    init(fill: SIMD4<Float>, geometry: SIMD4<Float>) {
        guard fill.w > 0.5,
              let mode = OPNPillarboxFillMode(rawValue: Int(fill.w.rounded())),
              mode != .black else {
            self = .notApplied
            return
        }
        self.mode = mode
        contentLeft = Double(fill.x)
        contentRight = Double(fill.y)
        cropScaleY = Double(geometry.x)
        stretchK = Double(geometry.y)
    }

    private init(mode: OPNPillarboxFillMode,
                 contentLeft: Double,
                 contentRight: Double,
                 cropScaleY: Double,
                 stretchK: Double) {
        self.mode = mode
        self.contentLeft = contentLeft
        self.contentRight = contentRight
        self.cropScaleY = cropScaleY
        self.stretchK = stretchK
    }
}

/// Carries the committed fill from the frame the renderer just drew to whoever asks next.
///
/// Locked rather than actor-isolated: a draw can land on MTKView's own render thread while a
/// pointer event is being mapped on the main one. Deliberately not the once-a-second render
/// diagnostics snapshot — a pointer needs the geometry of the frame on screen now, and the
/// snapshot also carries a *different* detector's measurement.
final class OPNCommittedPillarboxFillBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = OPNCommittedPillarboxFill.notApplied

    var value: OPNCommittedPillarboxFill {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func commit(_ fill: OPNCommittedPillarboxFill) {
        lock.lock()
        stored = fill
        lock.unlock()
    }

    /// The frame on screen did not go through the fill pass.
    func clear() {
        commit(.notApplied)
    }
}

/// Maps between a point on the displayed video and the source pixel drawn there.
///
/// `black`, `solidColor`, `blurredMirror` and `blurredZoom` repaint only the bar columns: the sharp
/// picture stays exactly where the plain aspect fit put it, so those modes map one-to-one.
/// `cropFill` and `stretchEdges` reproject *every* pixel, and a pointer that ignores that lands
/// wrong everywhere except the dead centre of the picture — several hundred pixels out at the edges
/// of a 16:9 title stretched across a 21:9 canvas.
///
/// The fragment shader's `opn_fill_geometry_uv` already runs drawable → source, which is the
/// direction a click needs, so ``sourceUnitPoint(forDisplayed:)`` is its arithmetic restated in
/// `Double`. The constants it restates are the ones the fill pass committed for the frame on
/// screen, so no guard is duplicated here: a fill that did not happen arrives as
/// ``OPNCommittedPillarboxFill/none`` and maps to ``identity``.
///
/// All coordinates are normalised with a top-left origin, matching `texCoord`: displayed `(0, 0)`
/// is the top-left of the video rect, source `(0, 0)` the top-left of the decoded frame.
struct OPNPillarboxPointerMapping: Equatable {
    /// Picture edges inside the source frame, as fractions of frame width, already trimmed by the
    /// same inset the shader's uniforms carry. Using the raw detector rect instead would put the
    /// map four source columns off at each edge.
    let contentLeft: Double
    let contentRight: Double
    /// Fraction of source height still visible once `cropFill` scales the picture to the full width.
    let cropScaleY: Double
    /// Centre slope of the `stretchEdges` cubic, clamped to the range where it stays monotonic.
    let stretchK: Double
    /// The mode whose geometry these numbers describe. `black` also stands for "no reprojection",
    /// which is what every mode collapses to when the fill is off or the geometry is degenerate.
    let mode: OPNPillarboxFillMode

    /// The picture sits where the aspect fit put it: displayed coordinates are source coordinates.
    static let identity = OPNPillarboxPointerMapping(contentLeft: 0,
                                                     contentRight: 1,
                                                     cropScaleY: 1,
                                                     stretchK: 1,
                                                     mode: .black)

    /// Bisection steps used to invert the stretch cubic. The bracket is 2 wide in `u` and a
    /// displayed coordinate is `(u + 1) / 2`, so `n` steps leave an error of `2^-(n+1)` — 5e-7 at
    /// 20 steps, which is a two-hundredth of a pixel on a 5120-wide drawable.
    static let stretchSolveIterations = 20

    /// Builds the mapping for the fill the renderer committed to the frame on screen.
    ///
    /// Only the two reprojecting modes move the picture; everything else — including every case
    /// the fill pass disabled or never ran — is ``identity``, because that is the placement those
    /// cases actually produce.
    init(committed: OPNCommittedPillarboxFill) {
        guard committed.mode == .cropFill || committed.mode == .stretchEdges else {
            self = .identity
            return
        }
        contentLeft = committed.contentLeft
        contentRight = committed.contentRight
        cropScaleY = committed.cropScaleY
        stretchK = committed.stretchK
        mode = committed.mode
    }

    private init(contentLeft: Double,
                 contentRight: Double,
                 cropScaleY: Double,
                 stretchK: Double,
                 mode: OPNPillarboxFillMode) {
        self.contentLeft = contentLeft
        self.contentRight = contentRight
        self.cropScaleY = cropScaleY
        self.stretchK = stretchK
        self.mode = mode
    }

    /// Whether the picture is drawn anywhere other than where the plain aspect fit would put it.
    var relocatesPicture: Bool { mode == .cropFill || mode == .stretchEdges }

    /// The source pixel shown at `point`. Points outside the video rect clamp to its edge, the same
    /// way the shader clamps `texCoord` before sampling.
    func sourceUnitPoint(forDisplayed point: CGPoint) -> CGPoint {
        let displayed = CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
        switch mode {
        case .cropFill:
            // Content spans the full width; the vertical overflow the wider window cannot show is
            // trimmed symmetrically, so the visible rows are the middle `cropScaleY` of the frame.
            return CGPoint(x: contentLeft + Double(displayed.x) * (contentRight - contentLeft),
                           y: 0.5 + (Double(displayed.y) - 0.5) * cropScaleY)
        case .stretchEdges:
            let u = Double(displayed.x) * 2 - 1
            let curve = min(max(stretchK * u + (1 - stretchK) * u * u * u, -1), 1)
            return CGPoint(x: contentLeft + (curve * 0.5 + 0.5) * (contentRight - contentLeft),
                           y: Double(displayed.y))
        case .black, .solidColor, .blurredMirror, .blurredZoom:
            return displayed
        }
    }

    /// Where a source pixel ends up on the display — the inverse of
    /// ``sourceUnitPoint(forDisplayed:)``. Under `cropFill` a row outside the visible band maps
    /// outside `0...1`, which is the honest answer: it was cropped away.
    func displayedUnitPoint(forSource point: CGPoint) -> CGPoint {
        let span = contentRight - contentLeft
        switch mode {
        case .cropFill:
            guard span > 0, cropScaleY > 0 else { return point }
            return CGPoint(x: (Double(point.x) - contentLeft) / span,
                           y: 0.5 + (Double(point.y) - 0.5) / cropScaleY)
        case .stretchEdges:
            guard span > 0 else { return point }
            let curve = min(max(((Double(point.x) - contentLeft) / span) * 2 - 1, -1), 1)
            return CGPoint(x: (Self.stretchInput(forCurve: curve, k: stretchK) + 1) * 0.5,
                           y: Double(point.y))
        case .black, .solidColor, .blurredMirror, .blurredZoom:
            return point
        }
    }

    /// Solves `c = k*u + (1-k)*u^3` for `u` over `-1...1`.
    ///
    /// Bisection rather than Newton: the derivative `k + 3(1-k)u^2` is exactly zero at `u = ±1`
    /// when `k` sits on its 1.5 clamp, so Newton diverges at the edges of a maximally stretched
    /// picture — precisely where the reprojection matters most. The curve is monotone for
    /// `1 <= k <= 1.5` (edge slope `3 - 2k`) and pinned at `c(±1) = ±1`, so the bracket always
    /// holds the one real root. Outside that range there is no unique root to find, and the
    /// clamped input is returned rather than an arbitrary one.
    static func stretchInput(forCurve curve: Double,
                             k: Double,
                             iterations: Int = OPNPillarboxPointerMapping.stretchSolveIterations) -> Double {
        let target = min(max(curve, -1), 1)
        guard curve.isFinite, k > 1 + 1e-9, k <= 1.5 + 1e-9, iterations > 0 else { return target }
        var low = -1.0
        var high = 1.0
        for _ in 0..<iterations {
            let mid = 0.5 * (low + high)
            if k * mid + (1 - k) * mid * mid * mid < target {
                low = mid
            } else {
                high = mid
            }
        }
        return 0.5 * (low + high)
    }
}

import CoreGraphics
import Testing
@testable import OpenNOW

/// A 16:9 title inside the 21:9 canvas GeForce NOW streams it in: 3840 picture columns centred in
/// 5120, the rest baked black.
private let ultrawideSource = CGSize(width: 5120, height: 2160)
private let sixteenNineContent = OPNPillarboxContentRect(left: 0.125, right: 0.875)

/// The span the shader actually samples, four columns trimmed from each edge.
private let insetSpan = (0.875 - 4.0 / 5120) - (0.125 + 4.0 / 5120)

/// Everything the shader was handed is `float`, so a value read back from the committed uniforms
/// carries single-precision error. One 5120-wide pixel is 1.95e-4 of the width; this is three
/// orders inside that.
private let uniformPrecision = 1e-6

/// The fill the renderer would commit for these inputs — the real uniforms, not a restatement of
/// them, so the mapping is pinned to what the shader was actually told to draw.
private func ultrawideFill(_ mode: OPNPillarboxFillMode,
                           contentRect: OPNPillarboxContentRect = sixteenNineContent,
                           codecCropIsIdentity: Bool = true,
                           sourceSize: CGSize = ultrawideSource,
                           displaySize: CGSize = ultrawideSource) -> OPNCommittedPillarboxFill {
    let uniforms = OPNVideoEnhancementRenderer.pillarboxUniforms(mode: mode,
                                                                contentRect: contentRect,
                                                                codecCropIsIdentity: codecCropIsIdentity,
                                                                sourceSize: sourceSize,
                                                                drawableSize: displaySize,
                                                                dim: 0,
                                                                packedColor: 0)
    return OPNCommittedPillarboxFill(fill: uniforms.fill, geometry: uniforms.geometry)
}

private func ultrawideMapping(_ mode: OPNPillarboxFillMode) -> OPNPillarboxPointerMapping {
    OPNPillarboxPointerMapping(committed: ultrawideFill(mode))
}

@Test func pillarboxPointerMappingLeavesRepaintingModesAlone() {
    for mode in [OPNPillarboxFillMode.black, .solidColor, .blurredMirror, .blurredZoom] {
        let mapping = ultrawideMapping(mode)
        #expect(!mapping.relocatesPicture)
        #expect(mapping == .identity)
        #expect(mapping.sourceUnitPoint(forDisplayed: CGPoint(x: 0.3, y: 0.7)) == CGPoint(x: 0.3, y: 0.7))
    }
}

@Test func pillarboxPointerMappingIsIdentityWhenNoFillWasCommitted() {
    // The mode is selected in preferences, but the frame on screen went through a path with no
    // fill pass — the Core Image branch, or libwebrtc's own renderer. Nothing reprojected it.
    let mapping = OPNPillarboxPointerMapping(committed: .notApplied)
    #expect(mapping == .identity)
    #expect(!mapping.relocatesPicture)
    #expect(mapping.sourceUnitPoint(forDisplayed: CGPoint(x: 0.05, y: 0.5)) == CGPoint(x: 0.05, y: 0.5))
    #expect(mapping.sourceUnitPoint(forDisplayed: CGPoint(x: 0.95, y: 0.5)) == CGPoint(x: 0.95, y: 0.5))
}

@Test func pillarboxPointerMappingClampsOutsideTheVideoRect() {
    let mapping = OPNPillarboxPointerMapping.identity
    #expect(mapping.sourceUnitPoint(forDisplayed: CGPoint(x: -0.4, y: 1.9)) == CGPoint(x: 0, y: 1))
    #expect(mapping.sourceUnitPoint(forDisplayed: CGPoint(x: 2, y: -3)) == CGPoint(x: 1, y: 0))
}

@Test func pillarboxPointerMappingDerivesCropGeometryFromTheInsetSpan() {
    let mapping = ultrawideMapping(.cropFill)
    #expect(mapping.relocatesPicture)
    #expect(abs(mapping.contentLeft - (0.125 + 4.0 / 5120)) < uniformPrecision)
    #expect(abs(mapping.contentRight - (0.875 - 4.0 / 5120)) < uniformPrecision)
    // Display aspect equals source aspect here, so the visible height fraction is the span itself.
    #expect(abs(mapping.cropScaleY - insetSpan) < uniformPrecision)
}

@Test func pillarboxPointerMappingExpandsCropFillHorizontallyAndTrimsVertically() {
    let mapping = ultrawideMapping(.cropFill)
    let centre = mapping.sourceUnitPoint(forDisplayed: CGPoint(x: 0.5, y: 0.5))
    #expect(abs(centre.x - 0.5) < uniformPrecision)
    #expect(abs(centre.y - 0.5) < 1e-12)

    // The drawable edges show the picture edges, not the bars.
    let left = mapping.sourceUnitPoint(forDisplayed: CGPoint(x: 0, y: 0.5))
    let right = mapping.sourceUnitPoint(forDisplayed: CGPoint(x: 1, y: 0.5))
    #expect(abs(left.x - mapping.contentLeft) < 1e-12)
    #expect(abs(right.x - mapping.contentRight) < 1e-12)

    // The top of the screen is not the top of the frame: the overflow is cropped symmetrically.
    let top = mapping.sourceUnitPoint(forDisplayed: CGPoint(x: 0.5, y: 0))
    let bottom = mapping.sourceUnitPoint(forDisplayed: CGPoint(x: 0.5, y: 1))
    #expect(abs(top.y - (0.5 - insetSpan / 2)) < uniformPrecision)
    #expect(abs(bottom.y - (0.5 + insetSpan / 2)) < uniformPrecision)
}

@Test func pillarboxPointerMappingPinsStretchEndpointsAndKeepsTheCentreHonest() {
    let mapping = ultrawideMapping(.stretchEdges)
    #expect(abs(mapping.stretchK - 1 / insetSpan) < uniformPrecision)

    let left = mapping.sourceUnitPoint(forDisplayed: CGPoint(x: 0, y: 0.25))
    let right = mapping.sourceUnitPoint(forDisplayed: CGPoint(x: 1, y: 0.25))
    #expect(abs(left.x - mapping.contentLeft) < 1e-12)
    #expect(abs(right.x - mapping.contentRight) < 1e-12)
    // Stretch leaves the vertical axis alone; only x is reprojected.
    #expect(left.y == 0.25)

    let centre = mapping.sourceUnitPoint(forDisplayed: CGPoint(x: 0.5, y: 0.5))
    #expect(abs(centre.x - 0.5) < uniformPrecision)

    // Monotone across the whole width, which is what makes the inverse single-valued.
    var previous = -1.0
    for step in 0...100 {
        let x = mapping.sourceUnitPoint(forDisplayed: CGPoint(x: Double(step) / 100, y: 0.5)).x
        #expect(Double(x) > previous)
        previous = Double(x)
    }
}

@Test func pillarboxPointerMappingRoundTripsWithinAPixelAtFiveK() {
    for mode in [OPNPillarboxFillMode.stretchEdges, .cropFill] {
        let mapping = ultrawideMapping(mode)
        for step in 0...64 {
            let displayed = CGPoint(x: Double(step) / 64, y: Double(64 - step) / 64)
            let source = mapping.sourceUnitPoint(forDisplayed: displayed)
            let back = mapping.displayedUnitPoint(forSource: source)
            // One 5120-wide pixel is 1.95e-4 of the width; the solve is three orders inside that.
            #expect(abs(Double(back.x) - Double(displayed.x)) < 1e-5)
            #expect(abs(Double(back.y) - Double(displayed.y)) < 1e-9)
        }
    }
}

@Test func pillarboxPointerMappingSolvesTheStretchCubicAtTheMonotonicLimit() {
    // k = 1.5 is the clamp, where the curve's edge slope reaches zero and Newton would diverge.
    for k in [1.0000001, 1.2, 1.336, 1.5] {
        for curve in [-1.0, -0.9, -0.5, -0.1, 0.0, 0.1, 0.5, 0.9, 1.0] {
            let u = OPNPillarboxPointerMapping.stretchInput(forCurve: curve, k: k)
            #expect(u >= -1 && u <= 1)
            #expect(abs(k * u + (1 - k) * u * u * u - curve) < 1e-5)
        }
    }
}

@Test func pillarboxPointerMappingRefusesToGuessOutsideTheMonotonicRange() {
    // Above 1.5 the cubic folds back on itself and has up to three roots; returning the clamped
    // input beats returning one of them at random.
    #expect(OPNPillarboxPointerMapping.stretchInput(forCurve: 0.4, k: 3) == 0.4)
    #expect(OPNPillarboxPointerMapping.stretchInput(forCurve: 4, k: 3) == 1)
    // Nonsense in, nonsense out — better than a plausible-looking root the caller would trust.
    #expect(OPNPillarboxPointerMapping.stretchInput(forCurve: .nan, k: 1.4).isNaN)
    #expect(OPNPillarboxPointerMapping.stretchInput(forCurve: 0.7, k: 1) == 0.7)
}

@Test func pillarboxPointerMappingFallsBackToIdentityWhereverTheShaderDisabledTheFill() {
    // Each of these is a case `pillarboxUniforms` refuses to draw: the picture stays where the
    // plain aspect fit put it even though a reprojecting mode is selected.
    #expect(OPNPillarboxPointerMapping(committed: ultrawideFill(.cropFill, contentRect: .full)) == .identity)

    // A non-identity codec crop shifts the content edges out from under the detector's numbers —
    // invisible from the pointer's side, which is why the fill has to say so itself.
    #expect(OPNPillarboxPointerMapping(committed: ultrawideFill(.cropFill, codecCropIsIdentity: false)) == .identity)

    #expect(OPNPillarboxPointerMapping(committed: ultrawideFill(.stretchEdges, sourceSize: .zero)) == .identity)
    #expect(OPNPillarboxPointerMapping(committed: ultrawideFill(.stretchEdges,
                                                                displaySize: CGSize(width: 1600, height: 0))) == .identity)
    #expect(OPNPillarboxPointerMapping(committed: ultrawideFill(.cropFill,
                                                                contentRect: OPNPillarboxContentRect(left: .nan, right: 0.9))) == .identity)

    // A picture narrower than the two insets combined has nothing left to sample.
    #expect(OPNPillarboxPointerMapping(committed: ultrawideFill(.cropFill,
                                                                contentRect: OPNPillarboxContentRect(left: 0.5, right: 0.5005))) == .identity)
}

@Test func pillarboxPointerMappingUsesTheShaderUniformsVerbatim() {
    // The pointer maps with the numbers the fill pass committed, so a change to the renderer's
    // inset or its geometry moves both together instead of putting the pointer four source columns
    // off at each picture edge.
    #expect(OPNVideoEnhancementRenderer.pillarboxEdgeInsetColumns == 4.0)

    let uniforms = OPNVideoEnhancementRenderer.pillarboxUniforms(mode: .cropFill,
                                                                contentRect: sixteenNineContent,
                                                                codecCropIsIdentity: true,
                                                                sourceSize: ultrawideSource,
                                                                drawableSize: ultrawideSource,
                                                                dim: 0,
                                                                packedColor: 0)
    let mapping = ultrawideMapping(.cropFill)
    #expect(Double(uniforms.fill.x) == mapping.contentLeft)
    #expect(Double(uniforms.fill.y) == mapping.contentRight)
    #expect(Double(uniforms.geometry.x) == mapping.cropScaleY)
    #expect(Double(uniforms.geometry.y) == ultrawideMapping(.stretchEdges).stretchK)
}

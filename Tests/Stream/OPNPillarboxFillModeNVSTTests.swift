import Foundation
import Testing
@testable import MacForceNow

/// The native NVST path can honour only the geometry and flat-colour fills; the
/// blur modes need the decoded pixels it never sees and must collapse to black.
@Suite struct OPNPillarboxFillModeNVSTTests {
    @Test func geometryAndColorModesAreSupported() {
        #expect(OPNPillarboxFillMode.black.isNVSTSupported)
        #expect(OPNPillarboxFillMode.solidColor.isNVSTSupported)
        #expect(OPNPillarboxFillMode.cropFill.isNVSTSupported)
        #expect(OPNPillarboxFillMode.stretchEdges.isNVSTSupported)
    }

    @Test func blurModesAreUnsupported() {
        #expect(!OPNPillarboxFillMode.blurredMirror.isNVSTSupported)
        #expect(!OPNPillarboxFillMode.blurredZoom.isNVSTSupported)
    }

    @Test func unsupportedModesResolveToBlack() {
        #expect(OPNPillarboxFillMode.blurredMirror.nvstResolved == .black)
        #expect(OPNPillarboxFillMode.blurredZoom.nvstResolved == .black)
        #expect(OPNPillarboxFillMode.cropFill.nvstResolved == .cropFill)
    }

    @Test func supportedCasesExcludeBlurAndStayInRawOrder() {
        let cases = OPNPillarboxFillMode.nvstSupportedCases
        #expect(cases == [.black, .solidColor, .stretchEdges, .cropFill])
    }
}

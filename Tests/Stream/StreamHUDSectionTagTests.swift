import Testing
@testable import OpenNOW

/// The trial annotations a HUD section can wear. The dock draws them with one component, so the only
/// thing that separates a shipped-but-settling feature from a Labs one is the word on the tag.
struct StreamHUDSectionTagTests {
    @Test func aShippedTrialReadsAsBeta() {
        #expect(StreamHUDSectionTag.beta.label == "BETA")
    }

    @Test func aLabsFeatureReadsAsExperimental() {
        #expect(StreamHUDSectionTag.experimental.label == "EXPERIMENTAL")
    }
}

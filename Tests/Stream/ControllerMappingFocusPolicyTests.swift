import Testing
@testable import OpenNOW

@Suite struct ControllerMappingFocusPolicyTests {
    @Test func mappingsRequireTheActualFrontmostStreamWithoutAnOverlay() {
        for active in [false, true] {
            for key in [false, true] {
                for remote in [false, true] {
                    for overlay in [false, true] {
                        let enabled = ControllerMappingFocusPolicy.allowsMappings(
                            appIsActive: active, windowIsKey: key, remoteInputEnabled: remote,
                            overlayCapturesInput: overlay
                        )
                        #expect(enabled == (active && key && remote && !overlay))
                    }
                }
            }
        }
    }
}

import Foundation
import Testing
@testable import OpenNOW

@Suite struct NvstRtspVideoPreferencesTests {
    @Test func defaultPreferencesKeepVideoFeaturesDisabled() {
        let lines = NvstRtspSdp.buildAnnounceSdp(.init()).components(separatedBy: "\r\n")
        #expect(lines.contains("a=x-nv-video[0].dx9EnableHdr:0"))
        #expect(lines.contains("a=x-nv-video[0].cloudGsync:0"))
    }

    @Test(arguments: [false, true], [false, true])
    func requestedVideoPreferencesOverrideConflictingOffers(isHDREnabled: Bool, isCloudGsyncEnabled: Bool) {
        let options = NvstRtspSdp.AnnounceOptions(
            bitDepth: 10,
            chromaFormat: 1,
            isHDREnabled: isHDREnabled,
            isCloudGsyncEnabled: isCloudGsyncEnabled,
            offeredAttributes: [
                ("x-nv-video[0].dx9EnableHdr", isHDREnabled ? "0" : "1"),
                ("x-nv-video[0].cloudGsync", isCloudGsyncEnabled ? "0" : "1"),
            ],
            codec: .hevc,
            echoesOfferedAttributes: true
        )
        let lines = NvstRtspSdp.buildAnnounceSdp(options).components(separatedBy: "\r\n")

        #expect(lines.filter { $0.hasPrefix("a=x-nv-video[0].dx9EnableHdr:") }
            == ["a=x-nv-video[0].dx9EnableHdr:\(isHDREnabled ? 1 : 0)"])
        #expect(lines.filter { $0.hasPrefix("a=x-nv-video[0].cloudGsync:") }
            == ["a=x-nv-video[0].cloudGsync:\(isCloudGsyncEnabled ? 1 : 0)"])
        #expect(lines.contains("a=x-nv-video[0].bitDepth:10"))
        #expect(lines.contains("a=x-nv-video[0].chromaFormat:1"))
    }
}

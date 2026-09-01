import Testing
@testable import OpenNOW

@Test func streamSidebarsExposeOneVisibleFeatureSet() {
    #expect(StreamSidebarCapabilities.webRTC.visibleFeatures == StreamSidebarFeature.allCases)
    #expect(StreamSidebarCapabilities.nativeNVST.visibleFeatures == StreamSidebarFeature.allCases)
}

@Test func streamSidebarCapabilitiesDescribeTransportSupport() {
    #expect(StreamSidebarCapabilities.webRTC.supports(.recording))
    #expect(StreamSidebarCapabilities.webRTC.supports(.remoteCoOp))
    #expect(StreamSidebarCapabilities.webRTC.supports(.videoEnhancement))
    #expect(StreamSidebarCapabilities.nativeNVST.supports(.microphone))
    #expect(StreamSidebarCapabilities.nativeNVST.supports(.antiAFK))
    #expect(StreamSidebarCapabilities.nativeNVST.supports(.floatingStats))
    #expect(StreamSidebarCapabilities.nativeNVST.supports(.videoEnhancement))
    #expect(StreamSidebarCapabilities.nativeNVST.supports(.recording))
    #expect(StreamSidebarCapabilities.nativeNVST.supports(.remoteCoOp))
}

/// Both transports now host Remote Co-Op. They were briefly asymmetric - the native path had no
/// frame tap to relay from - and the HUD still branches on this, so a regression here is what a
/// permanently disabled "Create Invite" button would look like.
@Test func bothStreamTransportsHostRemoteCoOp() {
    #expect(StreamSidebarCapabilities.webRTC.supports(.remoteCoOp))
    #expect(StreamSidebarCapabilities.nativeNVST.supports(.remoteCoOp))
}

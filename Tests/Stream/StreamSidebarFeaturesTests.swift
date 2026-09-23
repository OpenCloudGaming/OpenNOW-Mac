import Testing
@testable import OpenNOW

@Test func streamSidebarsExposeOneVisibleFeatureSet() {
    #expect(StreamSidebarCapabilities.nativeNVST.visibleFeatures == StreamSidebarFeature.allCases)
}

@Test func streamSidebarCapabilitiesDescribeTransportSupport() {
    #expect(StreamSidebarCapabilities.nativeNVST.supports(.microphone))
    #expect(StreamSidebarCapabilities.nativeNVST.supports(.antiAFK))
    #expect(StreamSidebarCapabilities.nativeNVST.supports(.floatingStats))
    #expect(StreamSidebarCapabilities.nativeNVST.supports(.videoEnhancement))
    #expect(StreamSidebarCapabilities.nativeNVST.supports(.recording))
    #expect(StreamSidebarCapabilities.nativeNVST.supports(.remoteCoOp))
}

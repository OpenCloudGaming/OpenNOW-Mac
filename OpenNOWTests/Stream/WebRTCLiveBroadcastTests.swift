import Testing
@testable import OpenNOW

@Suite("WebRTCLiveBroadcast")
struct WebRTCLiveBroadcastTests {
    @Test("broadcast source selector uses native frames when enhanced video is disabled")
    func sourceSelectorUsesNativeFramesWhenEnhancedVideoIsDisabled() {
        var selector = WebRTCBroadcastVideoSourceSelector()

        let enhanced = selector.accept(source: .enhanced, enhancedVideoEnabled: false, hostTime: 1)
        let native = selector.accept(source: .native, enhancedVideoEnabled: false, hostTime: 2)

        #expect(enhanced.accepted == false)
        #expect(enhanced.reason == "enhanced_disabled")
        #expect(native.accepted == true)
        #expect(native.selectedSource == .native)
        #expect(selector.selectedSource == .native)
        #expect(selector.enhancedFramesDropped == 1)
        #expect(selector.nativeFramesDropped == 0)
    }

    @Test("broadcast source selector switches to enhanced frames and drops duplicate native frames")
    func sourceSelectorSwitchesToEnhancedFramesAndDropsDuplicateNativeFrames() {
        var selector = WebRTCBroadcastVideoSourceSelector()

        let nativeFallback = selector.accept(source: .native, enhancedVideoEnabled: true, hostTime: 1)
        let enhanced = selector.accept(source: .enhanced, enhancedVideoEnabled: true, hostTime: 1.01)
        let duplicateNative = selector.accept(source: .native, enhancedVideoEnabled: true, hostTime: 1.02)

        #expect(nativeFallback.accepted == true)
        #expect(nativeFallback.selectedSource == .native)
        #expect(enhanced.accepted == true)
        #expect(enhanced.selectedSource == .enhanced)
        #expect(enhanced.didChangeSource == true)
        #expect(duplicateNative.accepted == false)
        #expect(duplicateNative.reason == "enhanced_preferred")
        #expect(selector.selectedSource == .enhanced)
        #expect(selector.nativeFramesDropped == 1)
    }

    @Test("broadcast source selector falls back to native when enhanced frames stop")
    func sourceSelectorFallsBackToNativeWhenEnhancedFramesStop() {
        var selector = WebRTCBroadcastVideoSourceSelector(enhancedFallbackTimeoutSeconds: 0.5)

        _ = selector.accept(source: .enhanced, enhancedVideoEnabled: true, hostTime: 1)
        let nativeDuringEnhanced = selector.accept(source: .native, enhancedVideoEnabled: true, hostTime: 1.2)
        let nativeAfterTimeout = selector.accept(source: .native, enhancedVideoEnabled: true, hostTime: 1.6)

        #expect(nativeDuringEnhanced.accepted == false)
        #expect(nativeAfterTimeout.accepted == true)
        #expect(nativeAfterTimeout.selectedSource == .native)
        #expect(nativeAfterTimeout.reason == "enhanced_timeout")
        #expect(selector.selectedSource == .native)
        #expect(selector.nativeFramesDropped == 1)
    }
}

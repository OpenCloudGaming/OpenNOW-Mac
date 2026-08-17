import Testing
@testable import MacForceNow

@Suite(.serialized)
struct NativeNVSTMicrophoneProcessingTests {
    @Test func gainIsBoundedAndDoesNotClip() {
        var state = voiceState()
        var samples: [Int16] = [.min, .max, -20_000, 20_000]

        let result = process(&samples, volume: 2, vadEnabled: false, state: &state)

        #expect(result == 0)
        #expect(samples == [.min, .max, -20_000, 20_000])

        samples = [.min, .max]
        #expect(process(&samples, volume: 0.5, vadEnabled: false, state: &state) == 0)
        #expect(samples == [-16_384, 16_384])
    }

    @Test func zeroAndNegativeVolumeProduceSilence() {
        var state = voiceState()
        var samples = [Int16](repeating: 12_000, count: 960)
        #expect(process(&samples, volume: 0, vadEnabled: false, state: &state) == 0)
        #expect(samples.allSatisfy { $0 == 0 })

        samples = [Int16](repeating: -12_000, count: 960)
        #expect(process(&samples, volume: -1, vadEnabled: false, state: &state) == 0)
        #expect(samples.allSatisfy { $0 == 0 })
    }

    @Test func voiceActivityUsesTwoFrameAttackAndTwentyFrameHangover() {
        var state = voiceState()
        var speech = [Int16](repeating: 8_000, count: 960)

        #expect(process(&speech, volume: 1, vadEnabled: true, state: &state) == 0)
        #expect(speech.allSatisfy { $0 == 0 })

        speech = [Int16](repeating: 8_000, count: 960)
        #expect(process(&speech, volume: 1, vadEnabled: true, state: &state) == 0)
        #expect(speech.allSatisfy { $0 == 8_000 })

        for _ in 0..<20 {
            var quiet = [Int16](repeating: 100, count: 960)
            #expect(process(&quiet, volume: 1, vadEnabled: true, state: &state) == 0)
            #expect(quiet.allSatisfy { $0 == 100 })
        }
        var afterHangover = [Int16](repeating: 100, count: 960)
        #expect(process(&afterHangover, volume: 1, vadEnabled: true, state: &state) == 0)
        #expect(afterHangover.allSatisfy { $0 == 0 })
    }

    @Test func silenceRemainsSilenceWithVoiceActivityEnabled() {
        var state = voiceState()
        var samples = [Int16](repeating: 0, count: 960)
        #expect(process(&samples, volume: 1, vadEnabled: true, state: &state) == 0)
        #expect(samples.allSatisfy { $0 == 0 })
    }

    @Test func onlyVerifiedMicrophoneFramesAreSupported() {
        #expect(MacForceNowNativeNVSTGeronimoTestMicrophoneFrameSupported(48_000, 16, 2, 4, 1_920) == 1)
        #expect(MacForceNowNativeNVSTGeronimoTestMicrophoneFrameSupported(44_100, 16, 2, 4, 1_920) == 0)
        #expect(MacForceNowNativeNVSTGeronimoTestMicrophoneFrameSupported(48_000, 32, 2, 4, 1_920) == 0)
        #expect(MacForceNowNativeNVSTGeronimoTestMicrophoneFrameSupported(48_000, 16, 1, 4, 1_920) == 0)
        #expect(MacForceNowNativeNVSTGeronimoTestMicrophoneFrameSupported(48_000, 16, 2, 3, 1_920) == 0)
        #expect(MacForceNowNativeNVSTGeronimoTestMicrophoneFrameSupported(48_000, 16, 2, 4, 960) == 0)
    }

    @Test func unsupportedFramePassesThroughWithoutMutation() {
        var state = voiceState()
        var frame = [UInt8](repeating: 0x5a, count: 0x58)
        let original = frame
        let stateSize = MacForceNowNativeNVSTGeronimoTestVoiceActivityStateSize()

        let result = state.withUnsafeMutableBytes { stateBuffer in
            frame.withUnsafeMutableBytes { frameBuffer in
                MacForceNowNativeNVSTGeronimoTestProcessMicrophoneFrame(
                    frameBuffer.baseAddress,
                    frameBuffer.count,
                    0.5,
                    1,
                    stateBuffer.baseAddress,
                    stateSize
                )
            }
        }

        #expect(result == 0)
        #expect(frame == original)
    }

    @Test func routeTeardownRemovesTheClientSlot() {
        let baseline = MacForceNowNativeNVSTGeronimoTestMicrophoneRouteCount()
        let client = UnsafeMutableRawPointer(bitPattern: 0x1234)
        let route = MacForceNowNativeNVSTGeronimoTestRegisterMicrophoneRoute(client)
        #expect(route != nil)
        #expect(MacForceNowNativeNVSTGeronimoTestMicrophoneRouteCount() == baseline + 1)

        MacForceNowNativeNVSTGeronimoTestUnregisterMicrophoneRoute(route)

        #expect(MacForceNowNativeNVSTGeronimoTestMicrophoneRouteCount() == baseline)
    }

    @Test func settingsPreserveDisabledPushToTalkAndVoiceActivitySemantics() {
        let disabled = NativeNVSTMicrophoneConfiguration.settings(volume: -1, mode: "disabled")
        #expect(disabled.volume == 0)
        #expect(!disabled.captureRequested)
        #expect(!disabled.initiallyEnabled)
        #expect(!disabled.voiceActivityEnabled)

        let pushToTalk = NativeNVSTMicrophoneConfiguration.settings(volume: 0.4, mode: "push-to-talk")
        #expect(pushToTalk.captureRequested)
        #expect(!pushToTalk.initiallyEnabled)
        #expect(!pushToTalk.voiceActivityEnabled)

        let voiceActivity = NativeNVSTMicrophoneConfiguration.settings(volume: 2, mode: "voice-activity")
        #expect(voiceActivity.volume == 1)
        #expect(voiceActivity.captureRequested)
        #expect(voiceActivity.initiallyEnabled)
        #expect(voiceActivity.voiceActivityEnabled)
    }

    private func voiceState() -> [UInt64] {
        let size = MacForceNowNativeNVSTGeronimoTestVoiceActivityStateSize()
        var state = [UInt64](repeating: 0, count: (size + MemoryLayout<UInt64>.size - 1) / MemoryLayout<UInt64>.size)
        let result = state.withUnsafeMutableBytes {
            MacForceNowNativeNVSTGeronimoTestResetVoiceActivityState($0.baseAddress, size)
        }
        #expect(result == 0)
        return state
    }

    private func process(_ samples: inout [Int16], volume: Double, vadEnabled: Bool, state: inout [UInt64]) -> Int32 {
        let stateSize = MacForceNowNativeNVSTGeronimoTestVoiceActivityStateSize()
        return state.withUnsafeMutableBytes { stateBuffer in
            samples.withUnsafeMutableBufferPointer { sampleBuffer in
                MacForceNowNativeNVSTGeronimoTestProcessMicrophonePCM(
                    sampleBuffer.baseAddress,
                    sampleBuffer.count,
                    volume,
                    vadEnabled ? 1 : 0,
                    stateBuffer.baseAddress,
                    stateSize
                )
            }
        }
    }
}

@_silgen_name("MacForceNowNativeNVSTGeronimoTestVoiceActivityStateSize")
private func MacForceNowNativeNVSTGeronimoTestVoiceActivityStateSize() -> Int

@_silgen_name("MacForceNowNativeNVSTGeronimoTestResetVoiceActivityState")
private func MacForceNowNativeNVSTGeronimoTestResetVoiceActivityState(_ state: UnsafeMutableRawPointer?, _ stateByteCount: Int) -> Int32

@_silgen_name("MacForceNowNativeNVSTGeronimoTestProcessMicrophonePCM")
private func MacForceNowNativeNVSTGeronimoTestProcessMicrophonePCM(_ samples: UnsafeMutablePointer<Int16>?, _ sampleCount: Int, _ volume: Double, _ vadEnabled: Int32, _ state: UnsafeMutableRawPointer?, _ stateByteCount: Int) -> Int32

@_silgen_name("MacForceNowNativeNVSTGeronimoTestMicrophoneFrameSupported")
private func MacForceNowNativeNVSTGeronimoTestMicrophoneFrameSupported(_ sampleRate: UInt32, _ bitsPerSample: UInt32, _ channels: UInt32, _ format: UInt32, _ byteCount: UInt32) -> Int32

@_silgen_name("MacForceNowNativeNVSTGeronimoTestProcessMicrophoneFrame")
private func MacForceNowNativeNVSTGeronimoTestProcessMicrophoneFrame(_ frame: UnsafeMutableRawPointer?, _ frameByteCount: Int, _ volume: Double, _ vadEnabled: Int32, _ state: UnsafeMutableRawPointer?, _ stateByteCount: Int) -> Int32

@_silgen_name("MacForceNowNativeNVSTGeronimoTestRegisterMicrophoneRoute")
private func MacForceNowNativeNVSTGeronimoTestRegisterMicrophoneRoute(_ client: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?

@_silgen_name("MacForceNowNativeNVSTGeronimoTestUnregisterMicrophoneRoute")
private func MacForceNowNativeNVSTGeronimoTestUnregisterMicrophoneRoute(_ route: UnsafeMutableRawPointer?)

@_silgen_name("MacForceNowNativeNVSTGeronimoTestMicrophoneRouteCount")
private func MacForceNowNativeNVSTGeronimoTestMicrophoneRouteCount() -> Int

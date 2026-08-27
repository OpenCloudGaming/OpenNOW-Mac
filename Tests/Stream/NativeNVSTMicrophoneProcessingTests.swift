import Testing
@testable import OpenNOW

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
        #expect(OpenNOWNativeNVSTGeronimoTestMicrophoneFrameSupported(48_000, 16, 2, 4, 1_920) == 1)
        #expect(OpenNOWNativeNVSTGeronimoTestMicrophoneFrameSupported(44_100, 16, 2, 4, 1_920) == 0)
        #expect(OpenNOWNativeNVSTGeronimoTestMicrophoneFrameSupported(48_000, 32, 2, 4, 1_920) == 0)
        #expect(OpenNOWNativeNVSTGeronimoTestMicrophoneFrameSupported(48_000, 16, 1, 4, 1_920) == 0)
        #expect(OpenNOWNativeNVSTGeronimoTestMicrophoneFrameSupported(48_000, 16, 2, 3, 1_920) == 0)
        #expect(OpenNOWNativeNVSTGeronimoTestMicrophoneFrameSupported(48_000, 16, 2, 4, 960) == 0)
    }

    @Test func unsupportedFramePassesThroughWithoutMutation() {
        var state = voiceState()
        var frame = [UInt8](repeating: 0x5a, count: 0x58)
        let original = frame
        let stateSize = OpenNOWNativeNVSTGeronimoTestVoiceActivityStateSize()

        let result = state.withUnsafeMutableBytes { stateBuffer in
            frame.withUnsafeMutableBytes { frameBuffer in
                OpenNOWNativeNVSTGeronimoTestProcessMicrophoneFrame(
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
        let baseline = OpenNOWNativeNVSTGeronimoTestMicrophoneRouteCount()
        let client = UnsafeMutableRawPointer(bitPattern: 0x1234)
        let route = OpenNOWNativeNVSTGeronimoTestRegisterMicrophoneRoute(client)
        #expect(route != nil)
        #expect(OpenNOWNativeNVSTGeronimoTestMicrophoneRouteCount() == baseline + 1)

        OpenNOWNativeNVSTGeronimoTestUnregisterMicrophoneRoute(route)

        #expect(OpenNOWNativeNVSTGeronimoTestMicrophoneRouteCount() == baseline)
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
        let size = OpenNOWNativeNVSTGeronimoTestVoiceActivityStateSize()
        var state = [UInt64](repeating: 0, count: (size + MemoryLayout<UInt64>.size - 1) / MemoryLayout<UInt64>.size)
        let result = state.withUnsafeMutableBytes {
            OpenNOWNativeNVSTGeronimoTestResetVoiceActivityState($0.baseAddress, size)
        }
        #expect(result == 0)
        return state
    }

    private func process(_ samples: inout [Int16], volume: Double, vadEnabled: Bool, state: inout [UInt64]) -> Int32 {
        let stateSize = OpenNOWNativeNVSTGeronimoTestVoiceActivityStateSize()
        return state.withUnsafeMutableBytes { stateBuffer in
            samples.withUnsafeMutableBufferPointer { sampleBuffer in
                OpenNOWNativeNVSTGeronimoTestProcessMicrophonePCM(
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

@_silgen_name("OpenNOWNativeNVSTGeronimoTestVoiceActivityStateSize")
private func OpenNOWNativeNVSTGeronimoTestVoiceActivityStateSize() -> Int

@_silgen_name("OpenNOWNativeNVSTGeronimoTestResetVoiceActivityState")
private func OpenNOWNativeNVSTGeronimoTestResetVoiceActivityState(_ state: UnsafeMutableRawPointer?, _ stateByteCount: Int) -> Int32

@_silgen_name("OpenNOWNativeNVSTGeronimoTestProcessMicrophonePCM")
private func OpenNOWNativeNVSTGeronimoTestProcessMicrophonePCM(_ samples: UnsafeMutablePointer<Int16>?, _ sampleCount: Int, _ volume: Double, _ vadEnabled: Int32, _ state: UnsafeMutableRawPointer?, _ stateByteCount: Int) -> Int32

@_silgen_name("OpenNOWNativeNVSTGeronimoTestMicrophoneFrameSupported")
private func OpenNOWNativeNVSTGeronimoTestMicrophoneFrameSupported(_ sampleRate: UInt32, _ bitsPerSample: UInt32, _ channels: UInt32, _ format: UInt32, _ byteCount: UInt32) -> Int32

@_silgen_name("OpenNOWNativeNVSTGeronimoTestProcessMicrophoneFrame")
private func OpenNOWNativeNVSTGeronimoTestProcessMicrophoneFrame(_ frame: UnsafeMutableRawPointer?, _ frameByteCount: Int, _ volume: Double, _ vadEnabled: Int32, _ state: UnsafeMutableRawPointer?, _ stateByteCount: Int) -> Int32

@_silgen_name("OpenNOWNativeNVSTGeronimoTestRegisterMicrophoneRoute")
private func OpenNOWNativeNVSTGeronimoTestRegisterMicrophoneRoute(_ client: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?

@_silgen_name("OpenNOWNativeNVSTGeronimoTestUnregisterMicrophoneRoute")
private func OpenNOWNativeNVSTGeronimoTestUnregisterMicrophoneRoute(_ route: UnsafeMutableRawPointer?)

@_silgen_name("OpenNOWNativeNVSTGeronimoTestMicrophoneRouteCount")
private func OpenNOWNativeNVSTGeronimoTestMicrophoneRouteCount() -> Int

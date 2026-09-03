import Foundation
import Testing
@testable import OpenNOW

/// The Bifrost-free transport derives everything it needs from the session allocation. These tests
/// pin that plumbing — endpoint discovery, profile extraction, and the honest failures for the
/// planes that still need the ICE/DTLS bundle.
@Suite struct NvstBifrostFreeTransportTests {
    private func allocation(rawSessionJSON: String,
                            sessionInfoJSON: String = "{}",
                            settingsJSON: String = "{}",
                            signalingServer: String = "seat.example.com:443") -> NativeNVSTSessionAllocation {
        NativeNVSTSessionAllocation(
            session: StreamSessionDescriptor(id: "session-1", applicationID: "100", serverAddress: "seat.example.com", title: "Test"),
            signalingServer: signalingServer,
            signalingURL: "wss://seat.example.com/nvst/",
            signalingQueryParameters: "",
            signalingHeaders: [],
            streamingBaseURL: "https://seat.example.com",
            mediaHost: "seat.example.com",
            mediaPort: 48_322,
            serverType: 1,
            settingsJSON: settingsJSON,
            sessionInfoJSON: sessionInfoJSON,
            rawSessionJSON: rawSessionJSON
        )
    }

    @Test func prepareReportsNoNvidiaLibraries() async throws {
        let transport = NvstBifrostFreeTransport()
        let status = try await transport.prepare()
        // The whole point: nothing to dlopen.
        #expect(status.runtimeAvailable)
        #expect(status.bundledArtifactURLs.isEmpty)
        #expect(status.resolvedSymbols.isEmpty)
    }

    @Test func aSessionWithNoReachableControlEndpointFailsWithAClearReason() async throws {
        // A short control timeout keeps the test honest without waiting out the real 20 s budget.
        let transport = NvstBifrostFreeTransport(controlTimeout: .milliseconds(200))
        let receiver = NativeNVSTMediaSession()
        // Only a signaling endpoint: the assumed `:322` candidate is tried and cannot connect.
        let noControlEndpoint = #"{"connectionInfo":[{"usage":14,"port":443,"resourcePath":"/nvst/"}]}"#
        await #expect(throws: NativeNVSTError.self) {
            _ = try await transport.connect(
                allocation: allocation(rawSessionJSON: noControlEndpoint, signalingServer: "127.0.0.1:443"),
                mediaReceiver: receiver
            )
        }
    }

    @Test func aSessionWithoutAnyHostCannotNegotiate() async throws {
        let transport = NvstBifrostFreeTransport(controlTimeout: .milliseconds(200))
        let receiver = NativeNVSTMediaSession()
        await #expect(throws: NativeNVSTError.self) {
            _ = try await transport.connect(
                allocation: allocation(rawSessionJSON: "{}", signalingServer: ""),
                mediaReceiver: receiver
            )
        }
    }

    @Test func theControlEndpointIsSynthesizedFromTheSessionHost() {
        let json = #"{"connectionInfo":[{"usage":16,"port":322},{"usage":14,"port":443}]}"#
        let endpoints = NvstRtspEndpoints.collect(
            rawSessionJSON: json,
            fallbackHost: NvstBifrostFreeTransport.host(from: "seat.example.com:443")
        )
        #expect(endpoints == ["rtsps://seat.example.com:322"])
        #expect(NvstBifrostFreeTransport.host(from: "10.0.0.5:443") == "10.0.0.5")
        #expect(NvstBifrostFreeTransport.host(from: "  ") == nil)
    }

    @Test func theServerLocationComesFromTheSessionNotThePeerIp() {
        let named = #"{"serverLocation": "np-tyo-01", "zoneName": "NP-TYO"}"#
        #expect(NvstBifrostFreeTransport.sessionServerLocation(fromRawSessionJSON: named) == "np-tyo-01")
        let zoneOnly = #"{"zoneName": "NP-TYO", "sessionRequestData": {}}"#
        #expect(NvstBifrostFreeTransport.sessionServerLocation(fromRawSessionJSON: zoneOnly) == "NP-TYO")
        let nested = #"{"sessionRequestData": {"serverLocation": "np-sin-02"}}"#
        #expect(NvstBifrostFreeTransport.sessionServerLocation(fromRawSessionJSON: nested) == "np-sin-02")
        #expect(NvstBifrostFreeTransport.sessionServerLocation(fromRawSessionJSON: "{}") == nil)
        #expect(NvstBifrostFreeTransport.sessionServerLocation(fromRawSessionJSON: #"{"serverLocation": "  "}"#) == nil)
    }

    @Test func theServerLocationFallsBackToTheZoneEndpointNotAnIp() {
        // CloudMatch leaves serverLocation/zoneName out of this path's session JSON, so the HUD
        // used to fall through to the video peer IP. The region endpoint names the zone.
        #expect(NvstBifrostFreeTransport.endpointLabel(forStreamingBaseURL: "https://np-tyo-01.cloudmatch.example/") == "np-tyo-01")
        #expect(NvstBifrostFreeTransport.endpointLabel(forStreamingBaseURL: "np-sin-02.cloudmatch.example") == "np-sin-02")
        #expect(NvstBifrostFreeTransport.endpointLabel(forStreamingBaseURL: "https://10.0.0.5/") == nil)
        #expect(NvstBifrostFreeTransport.endpointLabel(forStreamingBaseURL: "") == nil)
    }

    @Test func theNegotiatedProfileIsReadFromTheSessionJson() {
        let sessionInfo = #"{"negotiatedStreamProfile":{"resolution":"3840x2160","fps":120,"codec":"HEVC"}}"#
        let profile = NvstBifrostFreeTransport.streamProfile(from: allocation(rawSessionJSON: "{}", sessionInfoJSON: sessionInfo))
        #expect(profile.resolution == "3840x2160")
        #expect(profile.fps == 120)
        #expect(profile.codec == "HEVC")
    }

    @Test func aFlatSettingsBlobAlsoSuppliesTheProfile() {
        let settings = #"{"resolution":"2560x1440","fps":60,"codec":"H264"}"#
        let profile = NvstBifrostFreeTransport.streamProfile(from: allocation(rawSessionJSON: "{}", settingsJSON: settings))
        #expect(profile.resolution == "2560x1440")
        #expect(profile.fps == 60)
        #expect(profile.codec == "H264")
    }

    @Test func aMissingProfileLeavesTheAnnounceDefaults() {
        let profile = NvstBifrostFreeTransport.streamProfile(from: allocation(rawSessionJSON: "{}"))
        #expect(profile.resolution == nil)
        #expect(profile.fps == nil)
        // The ANNOUNCE builder then falls back to 1080p60.
        let sdp = NvstRtspSdp.buildAnnounceSdp(NvstRtspSdp.AnnounceOptions(resolution: profile.resolution, fps: profile.fps))
        #expect(sdp.contains("a=x-nv-video[0].clientViewportWd:1920"))
        // No `maxFPS`: the official client announces none and the seat uses the session profile.
        #expect(!sdp.contains("a=x-nv-video[0].maxFPS:"))
    }

    @Test func inputAndMicrophoneFailLoudlyUntilTheBundleIsUp() async throws {
        let transport = NvstBifrostFreeTransport()
        await #expect(throws: NativeNVSTError.self) {
            try await transport.send(.text(deviceID: InputDeviceID("keyboard"), value: "hello", timestamp: MediaTimestamp(nanoseconds: 0)))
        }
        await #expect(throws: NativeNVSTError.self) {
            try await transport.setMicrophoneEnabled(true)
        }
    }

    /// The configuration is stored for the bundle bring-up to read when the session negotiates;
    /// what it holds is what the mic decision is made from.
    @Test func theStoredMicrophoneConfigurationIsWhatTheBundleBringUpReads() async throws {
        let transport = NvstBifrostFreeTransport()
        try await transport.setMicrophoneConfiguration(
            NativeNVSTMicrophoneConfiguration(volume: 0.5,
                                              voiceActivityEnabled: false,
                                              captureRequested: true,
                                              initiallyEnabled: false))
        let stored = await transport.microphoneConfiguration
        #expect(stored?.captureRequested == true)
        #expect(stored?.initiallyEnabled == false)
        #expect(stored?.volume == 0.5)
    }

    @Test func diagnosticsNameTheTransportEvenBeforeConnecting() async {
        let transport = NvstBifrostFreeTransport()
        let metadata = await transport.diagnosticMetadata()
        #expect(metadata["transport"] == "nvst-bifrost-free")
        #expect(metadata["nvidiaLibraries"] == "none")
        #expect(metadata["framesDecoded"] == "0")
    }

    @Test func codecMappingCoversEveryNvstCodec() {
        #expect(NvstBifrostFreeTransport.mediaCodec(.h264) == .h264)
        #expect(NvstBifrostFreeTransport.mediaCodec(.hevc) == .h265)
        #expect(NvstBifrostFreeTransport.mediaCodec(.av1) == .av1)
    }

    @Test func twoSocketsAreReservedWithOfficialLengthIceCredentials() async throws {
        let reserver = NvstLocalBundleReserver()
        let reservation = try await reserver.reserveBundle()
        #expect(reservation.bundlePort != 0)
        #expect(reservation.mjolnirPort != 0)
        // The bundle and the raw-SRTP video socket are distinct in the official cloud model.
        #expect(reservation.bundlePort != reservation.mjolnirPort)
        #expect(reservation.iceCredentials?.usernameFragment.count == 4)
        #expect(reservation.iceCredentials?.password.count == 22)
        // The descriptor transfers to the receiver so the NAT mapping survives.
        let descriptor = reserver.takeMjolnirDescriptor()
        #expect(descriptor >= 0)
        #expect(reserver.takeMjolnirDescriptor() == -1)
        close(descriptor)
        reserver.release()
    }
}

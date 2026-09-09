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

    /// A seat that never publishes a cursor notification would otherwise composite its pointer for
    /// the whole session, under the client's own — two cursors, forever. The deadline is fired
    /// directly here rather than waited out; `cursorCaptureWatchdogDelay` is what schedules it.
    @Test func theCursorWatchdogDisablesTheSeatPointerWhenNoNotificationArrives() async {
        let transport = NvstBifrostFreeTransport()
        await transport.startCursorCaptureWatchdog()
        let armed = await transport.cursorCaptureWatchdogTask
        #expect(armed != nil)
        await transport.disableCursorCaptureAfterSilentSeat()
        #expect(await transport.didDisableCursorCapture)
        let cleared = await transport.cursorCaptureWatchdogTask
        #expect(cleared == nil)
        // The seat is silent by definition here, so nothing may have decided the pointer's state.
        #expect(await transport.remoteCursorVisible == nil)
    }

    /// The first notification is what the watchdog was waiting for, so it stands down — and a
    /// bitmap shape push counts, which is why `NvstRemoteCursor` parses `0x0110` at all.
    @Test func aSeatCursorNotificationStandsTheWatchdogDown() async throws {
        let transport = NvstBifrostFreeTransport()
        await transport.startCursorCaptureWatchdog()
        var bitmapPayload = NvstByteWriter(capacity: 8)
        bitmapPayload.u32LE(4)
        bitmapPayload.u32LE(1024)
        let bitmap = try #require(NvstRemoteCursor.from(
            NvstControlCommand(code: NvstRemoteCursor.bitmapCursorCode, payload: bitmapPayload.data)))
        await transport.handleRemoteCursor(bitmap)
        let cancelled = await transport.cursorCaptureWatchdogTask
        #expect(cancelled == nil)
    }

    /// The same invariant as the parser's, held at the seam that actually owns the pointer state:
    /// a shape push arriving during mouselook must not raise the cursor the game hid.
    @Test func aBitmapPushDoesNotUnhideThePointerOnTheTransport() async throws {
        let transport = NvstBifrostFreeTransport()
        await transport.handleRemoteCursor(NvstRemoteCursor(isVisible: false))
        #expect(await transport.remoteCursorVisible == false)
        var bitmapPayload = NvstByteWriter(capacity: 8)
        bitmapPayload.u32LE(1)
        bitmapPayload.u32LE(256)
        let bitmap = try #require(NvstRemoteCursor.from(
            NvstControlCommand(code: NvstRemoteCursor.bitmapCursorCode, payload: bitmapPayload.data)))
        await transport.handleRemoteCursor(bitmap)
        #expect(await transport.remoteCursorVisible == false)
    }

    /// Teardown is the one path both a disconnect and the in-place reconnect run through, and it
    /// clears the deadline alongside the flag it guards: a watchdog surviving into the next
    /// session would disable a capture that had just been switched on.
    @Test func teardownClearsTheCursorWatchdogWithTheCaptureFlag() async {
        let transport = NvstBifrostFreeTransport()
        await transport.startCursorCaptureWatchdog()
        await transport.disableCursorCaptureAfterSilentSeat()
        await transport.disconnect()
        let cleared = await transport.cursorCaptureWatchdogTask
        #expect(cleared == nil)
        #expect(await transport.didDisableCursorCapture == false)
        // Nothing re-arms while the transport is torn down: the flag is cleared by the next
        // `connect`, not by the watchdog asking again.
        await transport.startCursorCaptureWatchdog()
        let rearmed = await transport.cursorCaptureWatchdogTask
        #expect(rearmed == nil)
    }

    /// `isTornDown` is per-connection, and an in-place reconnect runs on the same actor the last
    /// teardown latched it on. Left latched, the reconnected session armed no cursor watchdog, no
    /// QoS feedback and — the one that ends the session — no control keepalive: the seat kills a
    /// client that goes 10 s without command `0x200`.
    @Test func aReconnectOnTheSameTransportArmsItsTimersAgain() async {
        let transport = NvstBifrostFreeTransport(controlTimeout: .milliseconds(200))
        await transport.disconnect()
        #expect(await transport.isTornDown)

        // Fails on the missing endpoint, which is the point: the flag belongs to the start of a
        // connection attempt, not to whether that attempt succeeds.
        _ = try? await transport.connect(allocation: allocation(rawSessionJSON: "{}", signalingServer: ""),
                                         mediaReceiver: NativeNVSTMediaSession())
        #expect(await transport.isTornDown == false)

        await transport.startCursorCaptureWatchdog()
        #expect(await transport.cursorCaptureWatchdogTask != nil)
        await transport.startControlKeepAlive()
        #expect(await transport.controlKeepAliveTask != nil)
        await transport.startQosFeedback()
        #expect(await transport.qosFeedbackTask != nil)
        await transport.disconnect()
    }

    /// The seat can stop compositing its pointer without ever publishing a visibility: the watchdog
    /// deadline on a seat that publishes nothing, and a bitmap-only push that resolves to the state
    /// already held. The client suppresses its own pointer while the seat draws one, so unless it
    /// hears about the capture itself both of those leave the session with no pointer at all.
    @Test @MainActor func theClientHearsWhenTheSeatStopsCompositingItsPointer() async throws {
        let recorder = SeatCursorCaptureRecorder()
        let transport = NvstBifrostFreeTransport()
        await transport.setRemoteCursorCaptureHandler { isCompositing in recorder.record(isCompositing) }

        await transport.disableCursorCaptureAfterSilentSeat()
        await Task.yield()
        #expect(recorder.values == [false])
        #expect(await transport.remoteCursorVisible == nil)

        let bitmapTransport = NvstBifrostFreeTransport()
        await bitmapTransport.setRemoteCursorCaptureHandler { isCompositing in recorder.record(isCompositing) }
        var bitmapPayload = NvstByteWriter(capacity: 8)
        bitmapPayload.u32LE(4)
        bitmapPayload.u32LE(1024)
        let bitmap = try #require(NvstRemoteCursor.from(
            NvstControlCommand(code: NvstRemoteCursor.bitmapCursorCode, payload: bitmapPayload.data)))
        await bitmapTransport.handleRemoteCursor(bitmap)
        await Task.yield()
        #expect(recorder.values == [false, false])
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

/// The transport's capture notifications land on the main actor, where the stream view lives.
@MainActor final class SeatCursorCaptureRecorder {
    private(set) var values: [Bool] = []

    func record(_ isCompositing: Bool) {
        values.append(isCompositing)
    }
}

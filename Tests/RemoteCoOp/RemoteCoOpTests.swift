import Testing
import AudioUnit
import Foundation
import CoreVideo
@preconcurrency import WebRTC
@testable import OpenNOW

@Suite("Remote Co-Op", .serialized)
struct RemoteCoOpTests {

    @Test("preferences clamp guest slots")
    func preferencesClampGuestSlots() {
        #expect(OPNRemoteCoOpPreferences(isEnabled: true, reservedGuestSlots: -2).reservedGuestSlots == 0)
        #expect(OPNRemoteCoOpPreferences(isEnabled: true, reservedGuestSlots: 7).reservedGuestSlots == 3)
        #expect(OPNRemoteCoOpPreferences(isEnabled: false, reservedGuestSlots: 2).effectiveReservedGuestSlots == 0)
        #expect(OPNRemoteCoOpPreferences(isEnabled: true, reservedGuestSlots: 2).effectiveReservedGuestSlots == 2)
        #expect(!OPNRemoteCoOpPreferences(isAlphaOptedIn: false, isEnabled: true, reservedGuestSlots: 2).isAvailable)
        #expect(OPNRemoteCoOpPreferences(isAlphaOptedIn: false, isEnabled: true, reservedGuestSlots: 2).effectiveReservedGuestSlots == 0)
        #expect(OPNRemoteCoOpPreferences().transportMode == .automatic)
        #expect(OPNRemoteCoOpPreferences().latencyMode == .lowLatency)
        #expect(!OPNRemoteCoOpPreferences().hideGuestInviteDetails)
    }

    @Test("preferences store defaults remote co-op alpha gate off")
    func preferencesStoreDefaultsRemoteCoOpAlphaGateOff() {
        RemoteCoOpFixtures.withPreservedRemoteCoOpPreferences {
            RemoteCoOpFixtures.removePreferenceValue(RemoteCoOpFixtures.alphaOptInKey)
            RemoteCoOpFixtures.setPreferenceValue(true, forKey: RemoteCoOpFixtures.enabledKey)
            RemoteCoOpFixtures.setPreferenceValue(2, forKey: RemoteCoOpFixtures.reservedGuestSlotsKey)

            let preferences = OPNRemoteCoOpPreferencesStore.load()

            #expect(!preferences.isAlphaOptedIn)
            #expect(!preferences.isAvailable)
            #expect(preferences.effectiveReservedGuestSlots == 0)
            #expect(OPNRemoteCoOpPreferencesStore.reservedControllerSlotsForLaunch() == 0)
            #expect(preferences.launchMetadata[OPNRemoteCoOpPreferences.launchMetadataEnabledKey] == "false")
            #expect(preferences.launchMetadata[OPNRemoteCoOpPreferences.launchMetadataReservedGuestSlotsKey] == "0")
            #expect(preferences.launchMetadata[OPNRemoteCoOpPreferences.launchMetadataSignalingServerURLKey] == nil)
        }
    }

    @Test("preferences store ignores remote co-op setting writes before alpha opt in")
    func preferencesStoreIgnoresRemoteCoOpSettingWritesBeforeAlphaOptIn() {
        RemoteCoOpFixtures.withPreservedRemoteCoOpPreferences {
            RemoteCoOpFixtures.removePreferenceValue(RemoteCoOpFixtures.alphaOptInKey)
            RemoteCoOpFixtures.setPreferenceValue(false, forKey: RemoteCoOpFixtures.enabledKey)
            RemoteCoOpFixtures.setPreferenceValue(0, forKey: RemoteCoOpFixtures.reservedGuestSlotsKey)

            OPNRemoteCoOpPreferencesStore.setEnabled(true)
            OPNRemoteCoOpPreferencesStore.setReservedGuestSlots(2)

            let preferences = OPNRemoteCoOpPreferencesStore.load()

            #expect(!preferences.isAlphaOptedIn)
            #expect(!preferences.isEnabled)
            #expect(preferences.reservedGuestSlots == 0)
            #expect(preferences.effectiveReservedGuestSlots == 0)
        }
    }

    @Test("preferences store remote co-op alpha opt in reveals saved settings")
    func preferencesStoreRemoteCoOpAlphaOptInRevealsSavedSettings() {
        RemoteCoOpFixtures.withPreservedRemoteCoOpPreferences {
            RemoteCoOpFixtures.removePreferenceValue(RemoteCoOpFixtures.alphaOptInKey)
            RemoteCoOpFixtures.setPreferenceValue(true, forKey: RemoteCoOpFixtures.enabledKey)
            RemoteCoOpFixtures.setPreferenceValue(2, forKey: RemoteCoOpFixtures.reservedGuestSlotsKey)

            OPNRemoteCoOpPreferencesStore.setAlphaOptedIn(true)

            let preferences = OPNRemoteCoOpPreferencesStore.load()

            #expect(preferences.isAlphaOptedIn)
            #expect(preferences.isAvailable)
            #expect(preferences.effectiveReservedGuestSlots == 2)
            #expect(OPNRemoteCoOpPreferencesStore.reservedControllerSlotsForLaunch() == 2)
        }
    }

    @Test("preferences store remote co-op alpha opt out disables remote co-op")
    func preferencesStoreRemoteCoOpAlphaOptOutDisablesRemoteCoOp() {
        RemoteCoOpFixtures.withPreservedRemoteCoOpPreferences {
            RemoteCoOpFixtures.setPreferenceValue(true, forKey: RemoteCoOpFixtures.alphaOptInKey)
            RemoteCoOpFixtures.setPreferenceValue(true, forKey: RemoteCoOpFixtures.enabledKey)
            RemoteCoOpFixtures.setPreferenceValue(2, forKey: RemoteCoOpFixtures.reservedGuestSlotsKey)

            OPNRemoteCoOpPreferencesStore.setAlphaOptedIn(false)

            let preferences = OPNRemoteCoOpPreferencesStore.load()

            #expect(!preferences.isAlphaOptedIn)
            #expect(!preferences.isEnabled)
            #expect(!preferences.isAvailable)
            #expect(preferences.effectiveReservedGuestSlots == 0)
        }
    }

    @Test("preferences store migrates old quality latency default to low latency")
    func preferencesStoreMigratesOldQualityLatencyDefaultToLowLatency() {
        RemoteCoOpFixtures.withPreservedRemoteCoOpPreferences {
            RemoteCoOpFixtures.setPreferenceValue(OPNRemoteCoOpLatencyMode.quality.rawValue, forKey: RemoteCoOpFixtures.latencyModeKey)
            RemoteCoOpFixtures.removePreferenceValue(RemoteCoOpFixtures.lowLatencyDefaultMigrationVersionKey)

            let preferences = OPNRemoteCoOpPreferencesStore.load()

            #expect(preferences.latencyMode == .lowLatency)
            #expect(UserDefaults.standard.string(forKey: RemoteCoOpFixtures.latencyModeKey) == OPNRemoteCoOpLatencyMode.lowLatency.rawValue)
            #expect(UserDefaults.standard.integer(forKey: RemoteCoOpFixtures.lowLatencyDefaultMigrationVersionKey) == 1)
        }
    }

    @Test("preferences store keeps explicit quality latency after migration")
    func preferencesStoreKeepsExplicitQualityLatencyAfterMigration() {
        RemoteCoOpFixtures.withPreservedRemoteCoOpPreferences {
            RemoteCoOpFixtures.setPreferenceValue(OPNRemoteCoOpLatencyMode.quality.rawValue, forKey: RemoteCoOpFixtures.latencyModeKey)
            RemoteCoOpFixtures.setPreferenceValue(1, forKey: RemoteCoOpFixtures.lowLatencyDefaultMigrationVersionKey)

            let preferences = OPNRemoteCoOpPreferencesStore.load()

            #expect(preferences.latencyMode == .quality)
            #expect(UserDefaults.standard.string(forKey: RemoteCoOpFixtures.latencyModeKey) == OPNRemoteCoOpLatencyMode.quality.rawValue)
        }
    }

    @Test("preferences default to production broker URLs")
    func preferencesDefaultToProductionBrokerURLs() {
        let preferences = OPNRemoteCoOpPreferences()

        #expect(preferences.signalingServerURL == "wss://198.12.95.48:32188/remote-coop")
        #expect(preferences.guestJoinBaseURL == "https://198.12.95.48:32188/")
    }

    /// The plaintext form of the *current* broker endpoint is a valid operator choice - it is what
    /// `run-servers.mjs` serves in its documented production configuration - and used to be
    /// rewritten back to `wss://` on every load, so the working URL could not be kept.
    @Test("an explicit plaintext URL for the current broker survives a reload")
    func plaintextCurrentBrokerURLIsNotMigratedAway() {
        let metadata = [
            OPNRemoteCoOpPreferences.launchMetadataSignalingServerURLKey: "ws://198.12.95.48:32188/remote-coop",
            OPNRemoteCoOpPreferences.launchMetadataGuestJoinBaseURLKey: "http://198.12.95.48:32188"
        ]
        let preferences = OPNRemoteCoOpPreferences.launchPreferences(from: metadata, fallback: OPNRemoteCoOpPreferences())

        #expect(preferences.signalingServerURL == "ws://198.12.95.48:32188/remote-coop")
        #expect(preferences.guestJoinBaseURL == "http://198.12.95.48:32188")
    }

    /// Retired hosts still migrate: the point of the change above was to stop rewriting a live
    /// endpoint, not to stop rewriting dead ones.
    @Test("retired broker hosts still migrate to the current default")
    func retiredBrokerHostsStillMigrate() {
        let metadata = [
            OPNRemoteCoOpPreferences.launchMetadataSignalingServerURLKey: "ws://198.12.95.48:8788/remote-coop",
            OPNRemoteCoOpPreferences.launchMetadataGuestJoinBaseURLKey: "http://relay.jayian.dev:8788"
        ]
        let preferences = OPNRemoteCoOpPreferences.launchPreferences(from: metadata, fallback: OPNRemoteCoOpPreferences())

        #expect(preferences.signalingServerURL == OPNRemoteCoOpPreferences.defaultSignalingServerURL)
        #expect(preferences.guestJoinBaseURL == OPNRemoteCoOpPreferences.defaultGuestJoinBaseURL)
    }

    @Test("preferences migrate legacy invite URL defaults")
    func preferencesMigrateLegacyInviteURLDefaults() {
        let metadata = [
            OPNRemoteCoOpPreferences.launchMetadataSignalingServerURLKey: "ws://127.0.0.1:8787/remote-coop",
            OPNRemoteCoOpPreferences.launchMetadataGuestJoinBaseURLKey: "http://127.0.0.1:8787/"
        ]
        let preferences = OPNRemoteCoOpPreferences.launchPreferences(from: metadata, fallback: OPNRemoteCoOpPreferences())

        #expect(preferences.signalingServerURL == OPNRemoteCoOpPreferences.defaultSignalingServerURL)
        #expect(preferences.guestJoinBaseURL == OPNRemoteCoOpPreferences.defaultGuestJoinBaseURL)
        #expect(OPNRemoteCoOpPreferences.migratedSignalingServerURL("wss://relay.jayian.dev:8788/remote-coop") == OPNRemoteCoOpPreferences.defaultSignalingServerURL)
        #expect(OPNRemoteCoOpPreferences.migratedGuestJoinBaseURL("https://relay.jayian.dev:8788/") == OPNRemoteCoOpPreferences.defaultGuestJoinBaseURL)
    }

    @Test("preferences round-trip through stream launch metadata")
    func preferencesRoundTripThroughStreamLaunchMetadata() {
        let preferences = OPNRemoteCoOpPreferences(
            isEnabled: true,
            reservedGuestSlots: 2,
            transportMode: .relayOnly,
            qualityPreset: .p1080f60,
            latencyMode: .lowLatency,
            requireHostApproval: false,
            signalingServerURL: "wss://coop.example.test/remote-coop",
            guestJoinBaseURL: "https://coop.example.test/",
            hideGuestInviteDetails: true
        )

        #expect(OPNRemoteCoOpPreferences.launchPreferences(from: preferences.launchMetadata, fallback: OPNRemoteCoOpPreferences()) == preferences)
    }

    @Test("transport modes map to ICE policies for router traversal")
    func transportModesMapToICEPoliciesForRouterTraversal() {
        #expect(OPNRemoteCoOpTransportMode.automatic.iceTransportPolicy == .all)
        #expect(OPNRemoteCoOpTransportMode.automatic.allowsRelayFallback)
        #expect(OPNRemoteCoOpTransportMode.directOnly.iceTransportPolicy == .all)
        #expect(!OPNRemoteCoOpTransportMode.directOnly.allowsRelayFallback)
        #expect(OPNRemoteCoOpTransportMode.relayOnly.iceTransportPolicy == .relay)
        #expect(OPNRemoteCoOpTransportMode.relayOnly.hidesDirectPeerCandidates)
    }

    @Test("wire codec maps browser messages into signaling events")
    func wireCodecMapsBrowserMessagesIntoSignalingEvents() throws {
        let participantID = UUID()
        let packet = OPNRemoteCoOpInputPacket(participantID: participantID, sequenceNumber: 42, buttons: [.south, .dpadRight], leftTrigger: 0.75, rightStickX: -0.5)
        let join = OPNRemoteCoOpWireMessage(kind: .guestJoinRequested, roomID: UUID(), participantID: participantID, inviteToken: "token", displayName: "Mia")
        let input = OPNRemoteCoOpWireMessage(kind: .guestInput, roomID: UUID(), participantID: participantID, input: packet)

        let decodedJoin = try OPNRemoteCoOpWireCodec.decode(OPNRemoteCoOpWireCodec.encode(join))
        let decodedInput = try OPNRemoteCoOpWireCodec.decode(OPNRemoteCoOpWireCodec.encode(input))

        #expect(decodedJoin.signalingEvent() == .guestJoinRequested(participantID: participantID, inviteToken: "token", displayName: "Mia"))
        #expect(decodedInput.signalingEvent() == .guestInput(packet))
    }

    @Test("wire codec decodes browser numeric gamepad button masks")
    func wireCodecDecodesBrowserNumericGamepadButtonMasks() throws {
        let participantID = UUID()
        let json = """
        {
          "kind": "guestInput",
          "participantID": "\(participantID.uuidString)",
          "input": {
            "participantID": "\(participantID.uuidString)",
            "sequenceNumber": 7,
            "buttons": \(GamepadButtons([.south, .dpadRight]).rawValue),
            "leftTrigger": 1,
            "rightTrigger": 0,
            "leftStickX": 0,
            "leftStickY": 0,
            "rightStickX": 0,
            "rightStickY": 0,
            "sentAtNanoseconds": 100
          }
        }
        """

        let message = try OPNRemoteCoOpWireCodec.decode(json)

        guard case .guestInput(let packet)? = message.signalingEvent() else {
            Issue.record("Expected guest input event")
            return
        }
        #expect(packet.buttons == [.south, .dpadRight])
    }

    @Test("wire codec maps host commands into broker messages")
    func wireCodecMapsHostCommandsIntoBrokerMessages() throws {
        let roomID = UUID()
        let participant = OPNRemoteCoOpParticipant(id: UUID(), displayName: "Mia", role: .guest, connectionState: .connected, inputEnabled: true, playerIndex: 1)

        let participantMessage = try #require(OPNRemoteCoOpWireMessage.message(for: .participantUpdated(participant), roomID: roomID))
        let rejectionMessage = try #require(OPNRemoteCoOpWireMessage.message(for: .inputRejected(participantID: participant.id, result: .stalePacket), roomID: roomID))

        #expect(participantMessage.kind == .participantUpdated)
        #expect(participantMessage.roomID == roomID)
        #expect(participantMessage.participant == participant)
        #expect(rejectionMessage.kind == .inputRejected)
        #expect(rejectionMessage.inputRejection == .stalePacket)
    }

    @Test("wire codec carries ICE network configuration")
    func wireCodecCarriesICENetworkConfiguration() throws {
        let configuration = OPNRemoteCoOpNetworkConfiguration(
            transportMode: .relayOnly,
            latencyMode: .lowLatency,
            iceServers: [OPNRemoteCoOpICEServer(urls: ["turns:turn.example.test:443?transport=tcp"], username: "room", credential: "secret")]
        )
        let message = OPNRemoteCoOpWireMessage(kind: .networkConfiguration, roomID: UUID(), networkConfiguration: configuration)

        let decoded = try OPNRemoteCoOpWireCodec.decode(OPNRemoteCoOpWireCodec.encode(message))

        #expect(decoded.networkConfiguration == configuration)
        #expect(decoded.networkConfiguration?.iceTransportPolicy == .relay)
        #expect(decoded.networkConfiguration?.latencyMode == .lowLatency)
    }

    @Test("wire codec maps broker network config into signaling event")
    func wireCodecMapsBrokerNetworkConfigIntoSignalingEvent() throws {
        let configuration = OPNRemoteCoOpNetworkConfiguration(
            transportMode: .relayOnly,
            iceServers: [OPNRemoteCoOpICEServer(urls: ["turns:turn.example.test:443?transport=tcp"], username: "room", credential: "secret")]
        )
        let message = OPNRemoteCoOpWireMessage(kind: .networkConfiguration, roomID: UUID(), networkConfiguration: configuration)

        let decoded = try OPNRemoteCoOpWireCodec.decode(OPNRemoteCoOpWireCodec.encode(message))

        #expect(decoded.signalingEvent() == .networkConfiguration(configuration))
    }

    @Test("invite token signs and verifies launch metadata")
    func inviteTokenSignsAndVerifiesLaunchMetadata() async throws {
        let signer = OPNRemoteCoOpInviteTokenSigner(secret: Data(repeating: 7, count: 32))
        let preferences = OPNRemoteCoOpPreferences(isEnabled: true, reservedGuestSlots: 2, transportMode: .relayOnly, qualityPreset: .p1080f60, latencyMode: .lowLatency, requireHostApproval: false)
        let host = OPNRemoteCoOpHostSession(preferences: preferences, inviteSigner: signer)

        let invite = try await host.startInvite(applicationID: "123", title: "Portal", lifetimeSeconds: 120)
        let payload = try signer.verify(invite.token)

        #expect(payload.inviteID == invite.id)
        #expect(payload.code == invite.code)
        #expect(invite.code.count == 6)
        #expect(payload.applicationID == "123")
        #expect(payload.title == "Portal")
        #expect(payload.reservedGuestSlots == 2)
        #expect(payload.transportMode == .relayOnly)
        #expect(payload.qualityPreset == .p1080f60)
        #expect(payload.latencyMode == .lowLatency)
        #expect(!payload.requireHostApproval)
        #expect(!payload.hideGuestInviteDetails)
    }

    @Test("private invites hide guest visible title and app id")
    func privateInvitesHideGuestVisibleTitleAndAppID() async throws {
        let signer = OPNRemoteCoOpInviteTokenSigner(secret: Data(repeating: 9, count: 32))
        let preferences = OPNRemoteCoOpPreferences(isEnabled: true, reservedGuestSlots: 1, hideGuestInviteDetails: true)
        let host = OPNRemoteCoOpHostSession(preferences: preferences, inviteSigner: signer)

        let invite = try await host.startInvite(applicationID: "secret-app", title: "Secret Game", joinBaseURL: URL(string: "https://join.example.test/")!, signalingServerURL: "wss://signal.example.test/remote-coop", lifetimeSeconds: 120)
        let payload = try signer.verify(invite.token)
        let joinURL = try #require(invite.joinURL)
        let components = try #require(URLComponents(url: joinURL, resolvingAgainstBaseURL: false))

        #expect(payload.applicationID.isEmpty)
        #expect(payload.title.isEmpty)
        #expect(payload.hideGuestInviteDetails)
        #expect(invite.applicationID == "secret-app")
        #expect(invite.title == "Secret Game")
        #expect(invite.hideGuestInviteDetails)
        #expect(invite.code.count == 6)
        #expect(components.queryItems?.contains(URLQueryItem(name: "server", value: "wss://signal.example.test/remote-coop")) == true)

        // The link carries the signed token, because a bare code cannot pass the broker's signature
        // gate. Privacy is preserved by what the payload *contains* rather than by withholding it:
        // a private invite blanks the title and app ID at signing time, so handing the guest the
        // whole token still tells them nothing about the game.
        let linkedInvite = try #require(components.queryItems?.first { $0.name == "invite" }?.value)
        #expect(linkedInvite == invite.token)
        let linkedPayload = try signer.verify(linkedInvite)
        #expect(linkedPayload.applicationID.isEmpty)
        #expect(linkedPayload.title.isEmpty)
        #expect(linkedPayload.hideGuestInviteDetails)
    }

    @Test("invite URLs omit same origin signaling server")
    func inviteURLsOmitSameOriginSignalingServer() async throws {
        let host = OPNRemoteCoOpHostSession(preferences: OPNRemoteCoOpPreferences(isEnabled: true, reservedGuestSlots: 1))

        let invite = try await host.startInvite(joinBaseURL: URL(string: OPNRemoteCoOpPreferences.defaultGuestJoinBaseURL)!, signalingServerURL: OPNRemoteCoOpPreferences.defaultSignalingServerURL, lifetimeSeconds: 120)
        let joinURL = try #require(invite.joinURL)
        let components = try #require(URLComponents(url: joinURL, resolvingAgainstBaseURL: false))

        #expect(components.queryItems?.contains(URLQueryItem(name: "invite", value: invite.token)) == true)
        #expect(components.queryItems?.contains { $0.name == "server" } == false)
    }

    /// The guest link has to carry something the broker will accept. `verifyInviteToken` requires
    /// two dot-separated segments and rejects everything else before it ever looks up a room, so a
    /// link carrying the six-character code was refused by every broker — the guest connected, sat
    /// in "Waiting", and the host was never told anyone had arrived.
    @Test("invite URLs carry the signed token, not the short code")
    func inviteURLsCarryTheSignedToken() async throws {
        let signer = OPNRemoteCoOpInviteTokenSigner(secret: Data(repeating: 7, count: 32))
        let host = OPNRemoteCoOpHostSession(preferences: OPNRemoteCoOpPreferences(isEnabled: true, reservedGuestSlots: 1), inviteSigner: signer)

        let invite = try await host.startInvite(joinBaseURL: URL(string: "https://join.example.test/")!, lifetimeSeconds: 120)
        let joinURL = try #require(invite.joinURL)
        let components = try #require(URLComponents(url: joinURL, resolvingAgainstBaseURL: false))
        let linked = try #require(components.queryItems?.first { $0.name == "invite" }?.value)

        #expect(linked == invite.token)
        #expect(linked.split(separator: ".").count == 2)
        #expect(linked != invite.code)
        // Round-trips: what the link hands the broker is exactly what the host will verify back.
        #expect(try signer.verify(linked).code == invite.code)
    }

    @Test("stream settings advertise reserved controller bitmap")
    func streamSettingsAdvertiseReservedControllerBitmap() {
        let settings = WebRTCMediaStreamSettingsResolver.resolve(
            profile: WebRTCMediaStreamProfile(),
            capabilities: WebRTCMediaDeviceCapabilities(connectedGamepadCount: 4)
        )

        #expect(settings.remoteControllersBitmap == 0x0f)
    }

}

actor RemoteCoOpInputRecorder {
    private var recordedEvents: [UserInputEvent] = []

    func append(_ event: UserInputEvent) {
        recordedEvents.append(event)
    }

    func events() -> [UserInputEvent] {
        recordedEvents
    }

    /// Waits for the host peer's coalescing drain to deliver `count` events, up to two seconds.
    /// A fixed sleep raced it: the drain is a 4 ms `Task.sleep`, and in a loaded parallel test run
    /// its wake-up slips well past the 30 ms the tests used to allow. Returns as soon as the count
    /// is reached, or whatever arrived by the deadline so the expectation still reports the miss.
    func waitForEvents(count: Int) async -> [UserInputEvent] {
        for _ in 0..<200 {
            if recordedEvents.count >= count { return recordedEvents }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return recordedEvents
    }
}

final class RecordingRemoteCoOpHostPeerFactory: OPNRemoteCoOpHostPeerFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var peers: [UUID: RecordingRemoteCoOpHostPeer] = [:]

    func makePeer(participantID: UUID,
                  networkConfiguration: OPNRemoteCoOpNetworkConfiguration,
                  qualityPreset: OPNRemoteCoOpQualityPreset,
                  latencyMode: OPNRemoteCoOpLatencyMode,
                  callbacks: OPNRemoteCoOpHostPeerCallbacks) -> any OPNRemoteCoOpHostPeer {
        let peer = RecordingRemoteCoOpHostPeer(participantID: participantID, networkConfiguration: networkConfiguration, qualityPreset: qualityPreset, latencyMode: latencyMode, callbacks: callbacks)
        lock.withLock { peers[participantID] = peer }
        return peer
    }

    func peer(for participantID: UUID) -> RecordingRemoteCoOpHostPeer? {
        lock.withLock { peers[participantID] }
    }
}

final class RecordingRemoteCoOpHostPeer: OPNRemoteCoOpHostPeer, OPNRemoteCoOpHostVideoSink, OPNRemoteCoOpHostAudioSink, @unchecked Sendable {
    let participantID: UUID
    let networkConfiguration: OPNRemoteCoOpNetworkConfiguration
    let qualityPreset: OPNRemoteCoOpQualityPreset
    let latencyMode: OPNRemoteCoOpLatencyMode
    private let callbacks: OPNRemoteCoOpHostPeerCallbacks
    private let lock = NSLock()
    private var started = 0
    private var closed = 0
    private var renderedFrames = 0
    private var renderedAudioFrames = 0
    private var signals: [OPNRemoteCoOpWirePeerSignal] = []

    init(participantID: UUID, networkConfiguration: OPNRemoteCoOpNetworkConfiguration, qualityPreset: OPNRemoteCoOpQualityPreset, latencyMode: OPNRemoteCoOpLatencyMode, callbacks: OPNRemoteCoOpHostPeerCallbacks) {
        self.participantID = participantID
        self.networkConfiguration = networkConfiguration
        self.qualityPreset = qualityPreset
        self.latencyMode = latencyMode
        self.callbacks = callbacks
    }

    func start() async throws {
        lock.withLock { started += 1 }
        await callbacks.sendSignal(OPNRemoteCoOpWirePeerSignal(kind: .offer, sdp: "offer-\(participantID.uuidString)"))
    }

    func apply(_ signal: OPNRemoteCoOpWirePeerSignal) async throws {
        lock.withLock { signals.append(signal) }
    }

    func close() async {
        lock.withLock { closed += 1 }
    }

    func receiveDataChannelText(_ text: String) async {
        for packet in OPNRemoteCoOpHostPeerInputDecoder.decodePackets(text, expectedParticipantID: participantID) {
            await callbacks.receiveInput(packet)
        }
    }

    func renderVideoFrame(_ frame: RTCVideoFrame) {
        lock.withLock { renderedFrames += 1 }
    }

    func renderAudioFrame(_ frame: OPNRemoteCoOpHostAudioFrame) {
        lock.withLock { renderedAudioFrames += 1 }
    }

    func startCount() -> Int {
        lock.withLock { started }
    }

    func closeCount() -> Int {
        lock.withLock { closed }
    }

    func appliedSignals() -> [OPNRemoteCoOpWirePeerSignal] {
        lock.withLock { signals }
    }

    func renderedVideoFrameCount() -> Int {
        lock.withLock { renderedFrames }
    }

    func renderedAudioFrameCount() -> Int {
        lock.withLock { renderedAudioFrames }
    }
}

final class RecordingRemoteCoOpAudioSink: OPNRemoteCoOpHostAudioSink, @unchecked Sendable {
    let participantID: UUID
    private let lock = NSLock()
    private var frames: [OPNRemoteCoOpHostAudioFrame] = []

    init(participantID: UUID) {
        self.participantID = participantID
    }

    func renderAudioFrame(_ frame: OPNRemoteCoOpHostAudioFrame) {
        lock.withLock { frames.append(frame) }
    }

    func renderedAudioFrames() -> [OPNRemoteCoOpHostAudioFrame] {
        lock.withLock { frames }
    }
}

extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

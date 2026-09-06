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
        #expect(OPNRemoteCoOpPreferences().transportMode == .automatic)
        #expect(OPNRemoteCoOpPreferences().latencyMode == .lowLatency)
        #expect(!OPNRemoteCoOpPreferences().hideGuestInviteDetails)
    }

    /// Remote Co-Op shipped behind an alpha opt-in that defaulted off. That gate is gone, so hosting
    /// is decided by `isEnabled` alone - and must still default off, because enabling it starts a
    /// listener and reserves a controller slot on the next launch.
    @Test("hosting is off by default now that the alpha gate is gone")
    func hostingIsOffByDefault() {
        RemoteCoOpFixtures.withPreservedRemoteCoOpPreferences {
            RemoteCoOpFixtures.removePreferenceValue(RemoteCoOpFixtures.enabledKey)

            let preferences = OPNRemoteCoOpPreferencesStore.load()

            #expect(!preferences.isEnabled)
            #expect(!preferences.isAvailable)
            #expect(preferences.effectiveReservedGuestSlots == 0)
            // Only the two keys that say it is off, so nothing downstream reads a stale slot count.
            #expect(preferences.launchMetadata.count == 2)
        }
    }

    /// Remote Co-Op is drawn unconditionally now. The filtered list survives for Labs, which exists
    /// only while a feature is on trial, and the rail and pad navigation both read it - a mismatch is
    /// what let the pad land on a tab nobody drew.
    @MainActor @Test("Remote Co-Op is always a destination")
    func remoteCoOpIsAlwaysADestination() {
        #expect(CatalogSettingsGroup.visibleCases().contains(.remoteCoOp))
    }

    @Test("preferences store points a fresh install at this repo's Pages guest page")
    func preferencesStoreDefaultsHostedGuestPageURLOnFreshInstall() {
        RemoteCoOpFixtures.withPreservedRemoteCoOpPreferences {
            RemoteCoOpFixtures.removePreferenceValue(RemoteCoOpFixtures.hostedGuestPageURLKey)

            let preferences = OPNRemoteCoOpPreferencesStore.load()

            #expect(preferences.hostedGuestPageURL == OPNRemoteCoOpPreferencesStore.defaultHostedGuestPageURL)
            #expect(preferences.effectiveHostedGuestPageURL != nil)
        }
    }

    @Test("an explicitly cleared hosted guest page URL stays cleared, not reset to the default")
    func preferencesStoreRespectsAnExplicitlyClearedHostedGuestPageURL() {
        RemoteCoOpFixtures.withPreservedRemoteCoOpPreferences {
            RemoteCoOpFixtures.setPreferenceValue("", forKey: RemoteCoOpFixtures.hostedGuestPageURLKey)

            let preferences = OPNRemoteCoOpPreferencesStore.load()

            #expect(preferences.hostedGuestPageURL.isEmpty)
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

    /// Nothing about a server is configured to play. OpenNOW hosts the session itself and derives
    /// every address from the listener it binds, so there is no broker URL, no guest-join URL and no
    /// shared signing secret - the three things that previously had to agree for a join to work.
    @Test("preferences need no server configuration")
    func preferencesNeedNoServerConfiguration() {
        let preferences = OPNRemoteCoOpPreferences()

        #expect(preferences.publicAddress.isEmpty)
        #expect(preferences.effectivePublicAddress == nil)
        #expect(preferences.transportMode == .automatic)
    }

    @Test("preferences round-trip through stream launch metadata")
    func preferencesRoundTripThroughStreamLaunchMetadata() {
        let preferences = OPNRemoteCoOpPreferences(
            isEnabled: true,
            reservedGuestSlots: 2,
            transportMode: .directOnly,
            qualityPreset: .p1080f60,
            latencyMode: .lowLatency,
            requireHostApproval: false,
            hideGuestInviteDetails: true,
            publicAddress: "https://coop.example.test"
        )

        #expect(OPNRemoteCoOpPreferences.launchPreferences(from: preferences.launchMetadata, fallback: OPNRemoteCoOpPreferences()) == preferences)
    }

    /// Catches a dropped field automatically, which the literal-based test above cannot.
    ///
    /// `hostedGuestPageURL` was missing from this round trip and nothing failed: the test above only
    /// notices a lost field if its own literal happens to set that field away from its default, and
    /// the consequence was that Settings' guest page URL had no effect on any invite. Reflection
    /// makes the *next* omission fail here instead of in a session.
    @Test("every stored preference survives the launch metadata round trip")
    func everyStoredPreferenceSurvivesTheLaunchMetadataRoundTrip() {
        // Every field set away from the memberwise default, so none can round-trip by luck.
        let preferences = OPNRemoteCoOpPreferences(
            isEnabled: true,
            reservedGuestSlots: 3,
            transportMode: .directOnly,
            qualityPreset: .p1080f60,
            latencyMode: .lowLatency,
            requireHostApproval: false,
            hideGuestInviteDetails: true,
            publicAddress: "https://tunnel.example.test",
            hostedGuestPageURL: "https://pages.example.test/guest/"
        )
        let roundTripped = OPNRemoteCoOpPreferences.launchPreferences(from: preferences.launchMetadata, fallback: OPNRemoteCoOpPreferences())

        // Field by field, so a failure names the field rather than just reporting inequality.
        let original = Mirror(reflecting: preferences).children
        let restored = Dictionary(uniqueKeysWithValues: Mirror(reflecting: roundTripped).children.map { ($0.label ?? "", $0.value) })
        for child in original {
            guard let label = child.label, let restoredValue = restored[label] else { continue }
            #expect(String(describing: restoredValue) == String(describing: child.value),
                    "\(label) did not survive the launch metadata round trip")
        }
        // A field added to the struct but not to `launchMetadata` still has to fail: the loop above
        // compares what came back, so the count is what notices an omission on the way out.
        #expect(preferences.launchMetadata.count == original.count,
                "launchMetadata carries \(preferences.launchMetadata.count) of \(original.count) stored preferences")
    }

    /// The stream-launch round trip is what `startRemoteCoOpInvite` actually reads its preferences
    /// from - not a fresh `OPNRemoteCoOpPreferencesStore.load()` - so a field missing from
    /// `launchMetadata`/`launchPreferences` silently resets to the memberwise init's own default on
    /// every invite, no matter what is saved. That is exactly how the shipped Pages default above
    /// stopped reaching real invites: this field was never round-tripped at all.
    @Test("the hosted guest page URL survives the stream launch metadata round trip")
    func hostedGuestPageURLSurvivesStreamLaunchMetadataRoundTrip() {
        let preferences = OPNRemoteCoOpPreferences(
            isEnabled: true,
            reservedGuestSlots: 1,
            hostedGuestPageURL: "https://opencloudgaming.github.io/OpenNOW-Mac/"
        )

        let roundTripped = OPNRemoteCoOpPreferences.launchPreferences(from: preferences.launchMetadata, fallback: OPNRemoteCoOpPreferences())

        #expect(roundTripped.hostedGuestPageURL == "https://opencloudgaming.github.io/OpenNOW-Mac/")
        #expect(roundTripped == preferences)
    }

    /// STUN is what separates the two modes, and it is not cosmetic: without server-reflexive
    /// candidates a guest only ever receives this machine's own interface addresses, so media cannot
    /// connect from a network with no route to one of them however well signaling works. A locally
    /// hosted session was previously in exactly that state, which is why a LAN guest's selected route
    /// was always `host/udp -> host/udp`. A VPN interface counts as a route, so `directOnly` is not
    /// limited to the local network.
    @Test("only automatic mode offers STUN, and neither mode forces a relay")
    func transportModesDifferOnlyByStun() {
        #expect(OPNRemoteCoOpTransportMode.automatic.usesSTUN)
        #expect(!OPNRemoteCoOpTransportMode.directOnly.usesSTUN)
        // `.relay` discards host and reflexive candidates, which is only meaningful with a TURN
        // relay to replace them. There is none, so neither mode may ask for it.
        #expect(OPNRemoteCoOpTransportMode.automatic.iceTransportPolicy == .all)
        #expect(OPNRemoteCoOpTransportMode.directOnly.iceTransportPolicy == .all)
        #expect(OPNRemoteCoOpTransportMode.allCases.count == 2)
    }

    /// The raw values are persisted in `UserDefaults` and travel in a stream's launch metadata, so
    /// they are not free to rename even though the labels shown next to them are. Renaming a case
    /// would silently reset every host's transport choice back to the default on upgrade.
    @Test("transport mode raw values are stable, whatever the labels say")
    func transportModeRawValuesAreStable() {
        #expect(OPNRemoteCoOpTransportMode.automatic.rawValue == "automatic")
        #expect(OPNRemoteCoOpTransportMode.directOnly.rawValue == "directOnly")
        #expect(OPNRemoteCoOpTransportMode(rawValue: "directOnly") == .directOnly)
        // Labels are presentation and may change; they must simply exist and differ.
        #expect(OPNRemoteCoOpTransportMode.automatic.label != OPNRemoteCoOpTransportMode.directOnly.label)
        #expect(OPNRemoteCoOpTransportMode.allCases.allSatisfy { !$0.label.isEmpty && !$0.description.isEmpty })
    }

    /// The configuration the guest actually receives. This defaulted to an empty server list at every
    /// construction site, which is the bug the mode mapping above exists to prevent recurring.
    @Test("a network configuration carries STUN unless the mode opts out")
    func networkConfigurationCarriesSTUN() {
        let automatic = OPNRemoteCoOpNetworkConfiguration(transportMode: .automatic)
        #expect(automatic.iceServers.count == 1)
        #expect(automatic.iceServers.first?.urls == OPNRemoteCoOpNetworkConfiguration.defaultSTUNServers)
        // More than one provider, so a single operator's outage does not take Remote Co-Op with it.
        #expect(OPNRemoteCoOpNetworkConfiguration.defaultSTUNServers.count >= 2)
        #expect(OPNRemoteCoOpNetworkConfiguration.defaultSTUNServers.allSatisfy { $0.hasPrefix("stun:") })

        let sameNetwork = OPNRemoteCoOpNetworkConfiguration(transportMode: .directOnly)
        #expect(sameNetwork.iceServers.isEmpty)

        // An explicit list still wins, so a caller can override.
        let explicit = OPNRemoteCoOpNetworkConfiguration(transportMode: .automatic, iceServers: [])
        #expect(explicit.iceServers.isEmpty)
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

    /// The guest page reads the ICE servers straight out of this message, so the encoding has to
    /// survive a round trip with credentials intact - a relay a user points at needs its username
    /// and credential to arrive.
    @Test("wire codec carries ICE network configuration")
    func wireCodecCarriesICENetworkConfiguration() throws {
        let configuration = OPNRemoteCoOpNetworkConfiguration(
            transportMode: .automatic,
            latencyMode: .lowLatency,
            iceServers: [OPNRemoteCoOpICEServer(urls: ["turns:turn.example.test:443?transport=tcp"], username: "room", credential: "secret")]
        )
        let message = OPNRemoteCoOpWireMessage(kind: .networkConfiguration, roomID: UUID(), networkConfiguration: configuration)

        let decoded = try OPNRemoteCoOpWireCodec.decode(OPNRemoteCoOpWireCodec.encode(message))

        #expect(decoded.networkConfiguration == configuration)
        #expect(decoded.networkConfiguration?.iceTransportPolicy == .all)
        #expect(decoded.networkConfiguration?.latencyMode == .lowLatency)
        #expect(decoded.networkConfiguration?.iceServers.first?.username == "room")
        #expect(decoded.networkConfiguration?.iceServers.first?.credential == "secret")
    }

    @Test("wire codec maps broker network config into signaling event")
    func wireCodecMapsBrokerNetworkConfigIntoSignalingEvent() throws {
        let configuration = OPNRemoteCoOpNetworkConfiguration(
            transportMode: .directOnly,
            iceServers: [OPNRemoteCoOpICEServer(urls: ["turns:turn.example.test:443?transport=tcp"], username: "room", credential: "secret")]
        )
        let message = OPNRemoteCoOpWireMessage(kind: .networkConfiguration, roomID: UUID(), networkConfiguration: configuration)

        let decoded = try OPNRemoteCoOpWireCodec.decode(OPNRemoteCoOpWireCodec.encode(message))

        #expect(decoded.signalingEvent() == .networkConfiguration(configuration))
    }

    @Test("invite token signs and verifies launch metadata")
    func inviteTokenSignsAndVerifiesLaunchMetadata() async throws {
        let signer = OPNRemoteCoOpInviteTokenSigner(secret: Data(repeating: 7, count: 32))
        let preferences = OPNRemoteCoOpPreferences(isEnabled: true, reservedGuestSlots: 2, transportMode: .directOnly, qualityPreset: .p1080f60, latencyMode: .lowLatency, requireHostApproval: false)
        let host = OPNRemoteCoOpHostSession(preferences: preferences, inviteSigner: signer)

        let invite = try await host.startInvite(applicationID: "123", title: "Portal", lifetimeSeconds: 120)
        let payload = try signer.verify(invite.token)

        #expect(payload.inviteID == invite.id)
        #expect(payload.code == invite.code)
        #expect(invite.code.count == 6)
        #expect(payload.applicationID == "123")
        #expect(payload.title == "Portal")
        #expect(payload.reservedGuestSlots == 2)
        #expect(payload.transportMode == .directOnly)
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

    /// The `server` parameter is only worth carrying when the signaling socket lives somewhere the
    /// page cannot infer from its own origin. Uses a concrete pair rather than the shipped defaults,
    /// which are deliberately empty now that OpenNOW hosts sessions itself.
    @Test("invite URLs omit same origin signaling server")
    func inviteURLsOmitSameOriginSignalingServer() async throws {
        let host = OPNRemoteCoOpHostSession(preferences: OPNRemoteCoOpPreferences(isEnabled: true, reservedGuestSlots: 1))
        let joinBase = try #require(URL(string: "https://join.example.test:32188/"))

        let invite = try await host.startInvite(joinBaseURL: joinBase, signalingServerURL: "wss://join.example.test:32188/remote-coop", lifetimeSeconds: 120)
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
    private var retargetedPresets: [OPNRemoteCoOpQualityPreset] = []

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

    @discardableResult
    func updateQualityPreset(_ preset: OPNRemoteCoOpQualityPreset) async -> Bool {
        lock.withLock { retargetedPresets.append(preset) }
        return true
    }

    /// Every preset this peer was retargeted to after it started, in order. A rebuild would show up as
    /// a second `start()` on a new peer instead, which is what the retarget path exists to avoid.
    func retargetHistory() -> [OPNRemoteCoOpQualityPreset] {
        lock.withLock { retargetedPresets }
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

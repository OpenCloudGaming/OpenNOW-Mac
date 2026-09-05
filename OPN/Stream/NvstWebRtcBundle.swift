import Foundation
@preconcurrency import WebRTC

/// The NVST ICE/DTLS/SCTP bundle, driven by `WebRTC.framework`.
///
/// NVST has no WebRTC signaling: the seat's identity arrives through RTSP (DESCRIBE's DTLS
/// fingerprint and ICE password, SETUP's ping payload), and ours goes back in ANNOUNCE. So the
/// remote description is **synthesized** from those RTSP answers, and only the answer is real.
///
/// Facts this is built to match, captured from the official client (2026-08-23):
/// - the client is the DTLS **client**: it sends the ClientHello on the bundle socket ~37 ms
///   after the first STUN Binding Request, and the handshake completes ~11 ms later;
/// - the bundle authenticates with the **`ping+1`** remote ufrag while the video socket uses the
///   raw ping payload — one shared 4-character local ufrag serves both;
/// - the seat gates media on this handshake: without it the video relay is never armed.
///
/// `libBifrost2` embeds libwebrtc itself (`net/dcsctp`, `SctpTransport`, `a=sctp-port:5000`), so
/// this is the same stack the official client uses rather than an approximation of it.
public final class NvstWebRtcBundle: NSObject, RTCPeerConnectionDelegate, RTCDataChannelDelegate, @unchecked Sendable {
    public struct Identity: Equatable, Sendable {
        /// Port of the local host candidate, announced as `general.clientBundlePort`.
        public let bundlePort: UInt16
        public let localAddress: String?
        /// SHA-256 colon hex of the local DTLS certificate.
        public let dtlsFingerprint: String
        /// True when libwebrtc accepted the official 4/22 ICE credentials; false means it kept its
        /// own, which Bifrost's length checks are documented to reject.
        public let usesOfficialIceCredentials: Bool
    }

    /// What the microphone send section needs at `prepare()` time. NVST has no renegotiation, so
    /// the decision to carry mic audio is made once, before the answer is created.
    public struct MicrophoneSetup: Equatable, Sendable {
        public let volume: Double
        public let initiallyEnabled: Bool

        public init(volume: Double, initiallyEnabled: Bool) {
            self.volume = min(max(volume.isFinite ? volume : 1, 0), 1)
            self.initiallyEnabled = initiallyEnabled
        }
    }

    public enum BundleError: LocalizedError, Equatable, Sendable {
        case factoryUnavailable
        case missingRemoteFingerprint
        case missingRemoteCredentials
        case answerFailed(String)
        case localDescriptionFailed(String)
        case noHostCandidate
        case missingLocalFingerprint
        case microphoneNotArmed

        public var errorDescription: String? {
            switch self {
            case .factoryUnavailable: "The NVST bundle could not create a WebRTC peer connection."
            case .missingRemoteFingerprint: "DESCRIBE did not advertise a remote DTLS fingerprint, so the bundle cannot be brought up."
            case .missingRemoteCredentials: "The NVST bundle needs the version-6 ICE credentials."
            case .answerFailed(let reason): "The NVST bundle could not create its answer: \(reason)"
            case .localDescriptionFailed(let reason): "The NVST bundle could not apply its answer: \(reason)"
            case .noHostCandidate: "The NVST bundle gathered no host candidate, so no port can be announced."
            case .missingLocalFingerprint: "The NVST bundle answer carried no local DTLS fingerprint."
            case .microphoneNotArmed: "The NVST bundle could not arm the microphone sender before the answer."
            }
        }
    }

    /// The SCTP data channels the official client opens, in creation order. The seat assigns each
    /// label a **fixed** stream id and validates it: captured from `libBifrost2`'s own log,
    ///
    ///     id 0  control_channel_reliable
    ///     id 2  custom_message_on_sctp_private_reliable
    ///     id 4  custom_message_on_sctp_private_partially_reliable
    ///     id 6  control_channel_partially_reliable
    ///     id 8  control_channel_unreliable
    ///     id 10 input_channel_partially_reliable
    ///     id 12 cursor_channel
    ///     id 14 rtcp_on_sctp_private
    ///
    /// As DTLS client we are given the even ids in creation order, so creating the list in order
    /// reproduces that mapping exactly — no negotiated-id trick required.
    ///
    /// Opening `rtcp_on_sctp_private` across ids 0…14 squatted every one of those and the seat
    /// answered by resetting all streams and closing DTLS 114 ms after PLAY. Appending it to the
    /// six-channel list failed the same way for a narrower reason: it landed on id 12, which is
    /// the cursor channel's, under the wrong label.
    struct ChannelDefinition {
        let label: String
        /// `nil` is fully reliable; a lifetime marks partially-reliable; zero retransmits is
        /// unreliable.
        let maxPacketLifeTimeMilliseconds: Int32?
        let isUnreliable: Bool

        init(_ label: String, lifetime: Int32? = nil, unreliable: Bool = false) {
            self.label = label
            self.maxPacketLifeTimeMilliseconds = lifetime
            self.isUnreliable = unreliable
        }
    }

    /// `config.maxRetransmitTime = 300` for the partially-reliable channels, per the same log.
    ///
    /// Eight channels, matching OpenNOW's native streamer profile. This list read "exactly six, and
    /// no feedback channel — that channel is the seat's to open" until a session showed the seat
    /// never opens it: `feedbackOpen=false reportsSent=0`, so our receiver reports had nowhere to
    /// go and the seat's congestion control had no evidence to act on.
    static let officialChannels: [ChannelDefinition] = [
        ChannelDefinition("control_channel_reliable"),
        ChannelDefinition("custom_message_on_sctp_private_reliable"),
        ChannelDefinition("custom_message_on_sctp_private_partially_reliable", lifetime: 300),
        ChannelDefinition("control_channel_partially_reliable", lifetime: 300),
        ChannelDefinition("control_channel_unreliable", unreliable: true),
        ChannelDefinition("input_channel_partially_reliable", lifetime: 300),
        // The last two come from OpenNOW's native streamer, whose profile is eight channels with
        // fixed stream ids: cursor on 12, RTCP on 14. Ours stopped at six, and the earlier attempt
        // to open the feedback channel appended it as the SEVENTH — landing it on id 12, the
        // cursor channel's id, with the wrong label. That mismatch is what made the seat reset
        // every stream and drop DTLS, and it was read at the time as "the seat refuses a feedback
        // channel". Creating the cursor channel first puts RTCP back on 14 where it belongs.
        //
        // Why it matters beyond tidiness: with no feedback channel the seat's congestion control
        // never hears our receiver reports (`feedbackOpen=false reportsSent=0` in every session so
        // far), so it has no evidence to reduce its output when we are losing packets.
        ChannelDefinition("cursor_channel"),
        ChannelDefinition(NvstFeedbackSender.channelLabel),
    ]

    /// Official feedback channel label. `rtcp1` is refused by the seat.
    public static let feedbackChannelLabel = NvstFeedbackSender.channelLabel

    /// `OPN_NVST_FEEDBACK=0` opens the channels but never writes to them, isolating "the seat
    /// dislikes our reports" from "the seat dislikes the channel".
    public static var sendsFeedback: Bool {
        ProcessInfo.processInfo.environment["OPN_NVST_FEEDBACK"] != "0"
    }

    /// `OPN_NVST_WEBRTC_LOG=1` forwards libwebrtc's own ICE/DTLS/SCTP logging into our log, which is
    /// the only way to see *why* an association drops rather than just that it did.
    static var forwardsWebRtcLogging: Bool {
        ProcessInfo.processInfo.environment["OPN_NVST_WEBRTC_LOG"] == "1"
    }

    static let interestingLogFragments = ["ice", "dtls", "sctp", "candidate", "consent", "transport", "srtp", "stun"]

    let handoff: NVSTVideoHandoff
    /// The routed NIC address. libwebrtc gathers on every interface — including Docker/VM bridges
    /// that cannot reach the seat — and ANNOUNCE can carry only one port, so the candidate on this
    /// address is the one that must be announced.
    let preferredLocalAddress: String?
    let logger: (@Sendable (String) -> Void)?
    let lock = NSLock()
    var lastRoundTripMilliseconds = -1.0
    var statisticsRequestInFlight = false
    var didDescribeStatistics = false
    var factory: RTCPeerConnectionFactory?
    var peerConnection: RTCPeerConnection?
    var createdChannels: [RTCDataChannel] = []
    var openFeedbackChannel: RTCDataChannel?
    var openControlChannel: RTCDataChannel?
    var openInputChannel: RTCDataChannel?
    var openReliableInputChannel: RTCDataChannel?
    var openPartiallyReliableControlChannel: RTCDataChannel?
    var remoteAudioTracks: [RTCAudioTrack] = []
    /// Guarded by `lock`: written on libwebrtc's delegate thread, read from the transport's actor.
    var trackedRemoteAudioCount = 0
    public var remoteAudioTrackCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return trackedRemoteAudioCount
    }
    /// Silences the seat's audio on this Mac's speakers only.
    ///
    /// Goes to the audio device, not to `remoteAudioTracks`: disabling the track (or zeroing the
    /// source volume) stops libwebrtc producing samples at all, which silenced Remote Co-Op guests
    /// and recordings too - observed on hardware. The device mutes after teeing the frame to the
    /// relay, so only playout is affected.
    public func setRemoteAudioMuted(_ muted: Bool) {
        lock.lock()
        let device = audioDevice
        lock.unlock()
        device?.isPlayoutMuted = muted
    }

    var negotiatedInputProtocolVersion: UInt16?
    var openCustomChannels: [String: RTCDataChannel] = [:]
    var inputMessagesSent = 0
    var inputSendFailures = 0
    var controlSendFailures = 0
    var controlMessagesSent = 0
    /// Per-command counters for the `0x313` control-channel statistics report, keyed by command
    /// code. The official client aggregates the same figures in its `ControlStatsManager`.
    var controlCommandStats: [UInt16: ControlCommandCounters] = [:]

    struct ControlCommandCounters: Equatable, Sendable {
        var messagesSent: UInt64 = 0
        var messagesFailed: UInt64 = 0
        var aggregatedBytes: UInt64 = 0
    }
    var hostCandidateContinuation: CheckedContinuation<[RTCIceCandidate], Error>?
    var hostCandidates: [RTCIceCandidate] = []
    var gatheringComplete = false
    var inboundFeedbackBytes = 0
    var feedbackSendFailures = 0
    var inboundMessagesByLabel: [String: Int] = [:]
    var loggedInboundMessages = 0
    var iceStateDescription = "new"
    var callbackLogger: RTCCallbackLogger?
    var forwardedLogLines = 0

    /// Fires when a `rtcp_on_sctp_private` channel opens, so the feedback sender can start.
    public var onFeedbackChannelOpen: (@Sendable () -> Void)?

    /// Fires when the seat announces its remote-input protocol version.
    public var onInputProtocolNegotiated: (@Sendable (UInt16) -> Void)?

    /// Fires when `control_channel_reliable` opens. The seat starts its 10 s client-timeout the
    /// moment the association is up, so the keepalive has to begin here rather than when video
    /// arrives.
    public var onControlChannelOpen: (@Sendable () -> Void)?

    public init(handoff: NVSTVideoHandoff,
                preferredLocalAddress: String? = NvstRoutedIPv4.discover(),
                logger: (@Sendable (String) -> Void)? = nil) {
        self.handoff = handoff
        self.preferredLocalAddress = preferredLocalAddress
        self.logger = logger
        super.init()
    }

    var lastCursorNotification: String?
    var lastUnparsedCursorPayload: String?
    var cursorNotificationCount = 0
    public var onRemoteCursor: (@Sendable (NvstRemoteCursor) -> Void)?
    /// The seat's periodic `0x0101` statistics: game render rate and its latency estimate.
    public var onSeatStats: (@Sendable (NvstSeatStats) -> Void)?
    /// Rumble from the seat (`0x010b`), one call per command with every record it carried.
    public var onHapticEvents: (@Sendable ([NvstHapticEvent]) -> Void)?
    var hapticCommandCount = 0
    var hapticEventCount = 0
    var hapticChangeCount = 0
    var lastHapticSignature = ""
    /// The seat's HDR mode notification (`0x010e`): the game's HDR state as a mode word.
    public var onHdrMode: (@Sendable (NvstHdrModeNotification) -> Void)?
    public var onRemoteAudio: (@Sendable (Int) -> Void)?
    /// Decoded playout PCM (Int16 interleaved) on its way to the output device, so a recording can
    /// capture game audio. Called on the CoreAudio render thread: it must copy and return, never
    /// block, and never hop to an actor.
    public var onGameAudioFrame: (@Sendable (UnsafeRawPointer?, UInt32, Double, UInt32) -> Void)?
    /// Held for the lifetime of the bundle because `OPNCoreAudioRTCDevice.owner` is weak and the
    /// factory holds only the device.
    var audioDevice: OPNCoreAudioRTCDevice?
    /// Output device latency plus its IO buffer, in seconds; nil before the device exists.
    public var audioOutputLatencySeconds: Double? {
        lock.withLock { audioDevice?.outputPathLatencySeconds }
    }
    /// Fires when `control_channel_partially_reliable` opens, so QoS feedback can start.
    public var onPartiallyReliableControlOpen: (@Sendable () -> Void)?

    // MARK: - Microphone

    /// The mic sender chain, created at `prepare()` time when a `MicrophoneSetup` is supplied so
    /// the answer carries the sendonly mid-2 section. All guarded by `lock`.
    var microphoneSource: RTCAudioSource?
    var microphoneTrack: RTCAudioTrack?
    var microphoneSender: RTCRtpSender?
    var microphoneNegotiated = false
    /// The SSRC libwebrtc assigned to the mic sender; ANNOUNCE advertises it as
    /// `x-nv-mic.micSsrcConfig.senderSsrc` since NVST has no SDP transport to the seat.
    var microphoneSenderSsrc: UInt32?
    /// The CoreAudio device gate: while false the device hands libwebrtc silence, so the mic
    /// hardware stays idle even though the negotiated track exists.
    var microphoneCaptureEnabled = false
    /// Mic chat bytes sent, sampled from libwebrtc's `outbound-rtp` audio counters; feeds the
    /// `0x208` report's `micChatTotalSentDataBytes` field.
    var microphoneSentDataBytes: UInt64 = 0
    /// RTP packets the *seat* reports receiving on the mic stream, from its RTCP Receiver
    /// Reports (`remote-inbound-rtp`). Separates "we send but the seat never binds a receiver"
    /// from "the seat receives and the guest-side routing is the problem".
    var microphoneSeatReportedPackets: UInt64 = 0
    /// What libwebrtc actually packetizes on the mic sender (`outbound-rtp.codecId` resolved to
    /// its `codec` entry), e.g. `audio/red:63` or `audio/opus:111`. Proves the RED A/B took.
    var microphoneOutboundCodec: String?

    /// Captured mic level (RMS, 0…1) on the CoreAudio capture thread, throttled by the device.
    public var onMicrophoneLevel: (@Sendable (Double) -> Void)?
    /// Raw captured mic PCM (Int16 interleaved) on the CoreAudio capture thread, mirroring
    /// `onGameAudioFrame`. Optional tees only — the send path is libwebrtc's own.
    public var onMicrophoneAudioFrame: (@Sendable (UnsafeRawPointer?, UInt32, Double, UInt32) -> Void)?

    /// What the transport needs to report up the negotiation chain: whether the answer really
    /// carries the mic send section, and the SSRC that RTP will arrive with.
    public var microphoneNegotiation: (negotiated: Bool, senderSsrc: UInt32?) {
        lock.lock()
        defer { lock.unlock() }
        return (microphoneNegotiated, microphoneSenderSsrc)
    }

    /// Mic chat bytes uploaded so far, for the `0x208` RTP statistics report.
    public var microphoneSentBytes: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return microphoneSentDataBytes
    }

    /// Flips both halves of the mic path: the device gate (real PCM vs silence into libwebrtc)
    /// and the track itself. Push-to-talk and voice-activity drive this per key press; the HUD
    /// toggle drives it per click.
    public func setMicrophoneCaptureEnabled(_ enabled: Bool) {
        lock.lock()
        microphoneCaptureEnabled = enabled
        microphoneTrack?.isEnabled = enabled
        lock.unlock()
    }

    /// Gain on the mic source, 0…1. Applied by libwebrtc ahead of encoding, the same lever the
    /// WebRTC transport uses.
    public func setMicrophoneVolume(_ volume: Double) {
        lock.lock()
        let source = microphoneSource
        lock.unlock()
        source?.volume = min(max(volume.isFinite ? volume : 1, 0), 1)
    }

}

/// The bundle owns the CoreAudio RTC device so decoded game audio crosses into our code, which is
/// what a recording needs. The capture side is the microphone send path: while
/// `microphoneCaptureEnabled` is false the device hands libwebrtc silence, and flipping it lets
/// real PCM flow to the negotiated mic sender.
extension NvstWebRtcBundle: OPNCoreAudioRTCDeviceOwner {
    func handleGameAudioFrame(_ audioBufferList: UnsafeRawPointer?, frameCount: UInt32, sampleRate: Double, channels: UInt32) {
        onGameAudioFrame?(audioBufferList, frameCount, sampleRate, channels)
    }

    func handleMicrophoneAudioFrame(_ audioBufferList: UnsafeRawPointer?, frameCount: UInt32, sampleRate: Double, channels: UInt32) {
        onMicrophoneAudioFrame?(audioBufferList, frameCount, sampleRate, channels)
    }

    func handleCapturedMicrophoneLevel(_ level: Double) {
        onMicrophoneLevel?(level)
    }

    func isMicrophoneCaptureEnabled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return microphoneCaptureEnabled
    }
}

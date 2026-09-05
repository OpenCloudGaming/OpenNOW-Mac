//  The values the native NVST path exchanges: a live connection, a performance snapshot, how a
//  session ended and whether it should be recovered.
//

import Foundation

public struct NativeNVSTTransportConnection: Equatable, Sendable {
    public let session: StreamSessionDescriptor
    public let runtimeStatus: NVSTNativeBridgeStatus
    public let startedAt: Date

    public init(session: StreamSessionDescriptor, runtimeStatus: NVSTNativeBridgeStatus, startedAt: Date = Date()) {
        self.session = session
        self.runtimeStatus = runtimeStatus
        self.startedAt = startedAt
    }
}

public struct NativeNVSTPerformanceSnapshot: Equatable, Sendable {
    public let available: Bool
    public let gameFramesPerSecond: Double
    public let streamFramesPerSecond: Double
    public let latencyMilliseconds: Double
    public let jitterMilliseconds: Double
    public let frameLoss: UInt64
    public let totalFrameLoss: UInt64
    public let packetLoss: UInt64
    public let totalPacketLoss: UInt64
    /// Loss over the last poll interval, as the WebRTC path reports it: lost / (received + lost).
    /// Negative when it cannot be computed yet.
    public let packetLossPercent: Double
    /// Mean client-side decode cost per frame. Distinct from `latencyMilliseconds`, which is the
    /// network round trip.
    public let decodeMilliseconds: Double
    public let bitrateMegabitsPerSecond: Double
    public let bandwidthUtilizationPercent: Double
    public let resolution: String
    public let codec: String
    public let serverLocation: String
    /// The frame rate the session negotiated; -1 when unknown. Lets the HUD tell a quiet scene
    /// (low bitrate, full frame rate) from a starved one (low bitrate, frame rate collapsing).
    public let negotiatedFramesPerSecond: Double
    /// Whether VideoToolbox is actually decoding in hardware. False is the software fallback,
    /// which a 4:4:4 request can land on.
    public let decoderIsHardware: Bool
    /// What the bitstream declares (`10-bit 4:2:0`) and the surface the decoder emits (`xf20`).
    public let bitstreamFormat: String
    public let decoderOutputFormat: String
    /// The ceiling the user configured, so the HUD can show used bitrate against it; -1 if unset.
    public let targetBitrateMegabitsPerSecond: Double
    /// Mean time audio spent in libwebrtc's jitter buffer over the last snapshot interval, ms; -1
    /// when unknown. Against video's decode + present time it gives an A/V offset estimate.
    public let audioJitterBufferMilliseconds: Double
    /// The output device's own latency plus its IO buffer, ms; -1 when unknown. The part of the
    /// audio path after the jitter buffer that the A/V estimate would otherwise leave out.
    public let audioOutputLatencyMilliseconds: Double
    /// The seat's GPU as named by the session response ("NVIDIA GeForce RTX 4080"); the rig.
    public let serverGPU: String

    public init(available: Bool,
                gameFramesPerSecond: Double,
                streamFramesPerSecond: Double,
                latencyMilliseconds: Double,
                jitterMilliseconds: Double,
                frameLoss: UInt64,
                totalFrameLoss: UInt64,
                packetLoss: UInt64,
                totalPacketLoss: UInt64,
                packetLossPercent: Double = -1,
                decodeMilliseconds: Double = -1,
                bitrateMegabitsPerSecond: Double,
                bandwidthUtilizationPercent: Double,
                resolution: String,
                codec: String,
                serverLocation: String,
                negotiatedFramesPerSecond: Double = -1,
                decoderIsHardware: Bool = true,
                bitstreamFormat: String = "",
                decoderOutputFormat: String = "",
                targetBitrateMegabitsPerSecond: Double = -1,
                serverGPU: String = "",
                audioJitterBufferMilliseconds: Double = -1,
                audioOutputLatencyMilliseconds: Double = -1) {
        self.audioJitterBufferMilliseconds = audioJitterBufferMilliseconds
        self.audioOutputLatencyMilliseconds = audioOutputLatencyMilliseconds
        self.serverGPU = serverGPU
        self.targetBitrateMegabitsPerSecond = targetBitrateMegabitsPerSecond
        self.negotiatedFramesPerSecond = negotiatedFramesPerSecond
        self.decoderIsHardware = decoderIsHardware
        self.bitstreamFormat = bitstreamFormat
        self.decoderOutputFormat = decoderOutputFormat
        self.available = available
        self.gameFramesPerSecond = gameFramesPerSecond
        self.streamFramesPerSecond = streamFramesPerSecond
        self.latencyMilliseconds = latencyMilliseconds
        self.jitterMilliseconds = jitterMilliseconds
        self.frameLoss = frameLoss
        self.totalFrameLoss = totalFrameLoss
        self.packetLoss = packetLoss
        self.totalPacketLoss = totalPacketLoss
        self.packetLossPercent = packetLossPercent
        self.decodeMilliseconds = decodeMilliseconds
        self.bitrateMegabitsPerSecond = bitrateMegabitsPerSecond
        self.bandwidthUtilizationPercent = bandwidthUtilizationPercent
        self.resolution = resolution
        self.codec = codec
        self.serverLocation = serverLocation
    }
}

enum NativeNVSTStreamHealthFailure: Equatable, Sendable {
    case rendererUnavailable
    case firstFrameTimedOut
    case streamStalled

    var message: String {
        switch self {
        case .rendererUnavailable:
            "Native NVST lost its video renderer surface."
        case .firstFrameTimedOut:
            "Native NVST connected but did not begin receiving video frames."
        case .streamStalled:
            "Native NVST stopped receiving video frames."
        }
    }
}

struct NativeNVSTStreamHealthMonitor: Equatable, Sendable {
    let firstFrameSampleLimit: Int
    let stalledSampleLimit: Int
    let rendererSampleLimit: Int
    private(set) var receivedFrames = false
    private var zeroFrameSamples = 0
    private var missingRendererSamples = 0

    init(firstFrameSampleLimit: Int = 15, stalledSampleLimit: Int = 10, rendererSampleLimit: Int = 5) {
        self.firstFrameSampleLimit = max(1, firstFrameSampleLimit)
        self.stalledSampleLimit = max(1, stalledSampleLimit)
        self.rendererSampleLimit = max(1, rendererSampleLimit)
    }

    /// Consecutive samples with no frames, so a network-path change can act before the stall
    /// verdict when the picture has already stopped.
    var zeroFrameStreak: Int { zeroFrameSamples }

    mutating func observe(snapshot: NativeNVSTPerformanceSnapshot?, rendererReady: Bool) -> NativeNVSTStreamHealthFailure? {
        guard let snapshot, snapshot.available else { return nil }
        missingRendererSamples = rendererReady ? 0 : missingRendererSamples + 1
        if missingRendererSamples >= rendererSampleLimit { return .rendererUnavailable }

        guard snapshot.streamFramesPerSecond >= 0 else { return nil }
        if snapshot.streamFramesPerSecond > 0 {
            receivedFrames = true
            zeroFrameSamples = 0
            return nil
        }
        zeroFrameSamples += 1
        if receivedFrames {
            return zeroFrameSamples >= stalledSampleLimit ? .streamStalled : nil
        }
        return zeroFrameSamples >= firstFrameSampleLimit ? .firstFrameTimedOut : nil
    }
}

public struct NativeNVSTTerminationValue: Equatable, Sendable {
    public let code: Int32
    public let name: String?

    public init(code: Int32, name: String? = nil) {
        self.code = code
        self.name = name
    }
}

public struct NativeNVSTTerminationReason: Equatable, Sendable {
    /// `NVB_SN_PAUSED_BY_USER`. Geronimo reports a completed pause through the same
    /// session-notification channel it uses for terminations, but the cloud session
    /// stays alive and resumable, so it must never be reported as a stream end.
    public static let pausedByUser: UInt32 = 59

    public let rawValue: UInt32
    public let resultName: String?

    public init(rawValue: UInt32, resultName: String? = nil) {
        self.rawValue = rawValue
        self.resultName = resultName
    }

    public var isPause: Bool { rawValue == Self.pausedByUser }
}

public struct NativeNVSTSessionTermination: Equatable, Sendable {
    public let reason: NativeNVSTTerminationReason
    public let extendedResult: NativeNVSTTerminationValue
    public let isResumable: Bool
    public let isSessionAlive: Bool
    public let message: String

    public init(reason: NativeNVSTTerminationReason,
                extendedResult: NativeNVSTTerminationValue,
                isResumable: Bool,
                isSessionAlive: Bool,
                message: String) {
        self.reason = reason
        self.extendedResult = extendedResult
        self.isResumable = isResumable
        self.isSessionAlive = isSessionAlive
        self.message = message
    }

    public var permitsSameSessionRecovery: Bool {
        isResumable && isSessionAlive && NativeNVSTRecoveryPolicy.isTransient(reason) && NativeNVSTRecoveryPolicy.isTransient(extendedResult)
    }

    /// A paused session is not an ended session: the cloud session must survive so the
    /// user can resume it.
    public var isPause: Bool { reason.isPause }
}

public struct NativeNVSTTransportFailure: Equatable, Sendable {
    public enum RecoveryClassification: Equatable, Sendable {
        case transientNetwork
        case permanent
    }

    public let message: String
    public let result: NativeNVSTTerminationValue?
    public let recoveryClassification: RecoveryClassification

    public init(message: String,
                result: NativeNVSTTerminationValue? = nil,
                recoveryClassification: RecoveryClassification) {
        self.message = message
        self.result = result
        self.recoveryClassification = recoveryClassification
    }
}

public enum NativeNVSTTransportTermination: Equatable, Sendable {
    case sessionTerminated(NativeNVSTSessionTermination)
    case transportFailed(NativeNVSTTransportFailure)
}

public enum NativeNVSTRecoveryPolicy {
    private static let transientResults: Set<String> = [
        "NVB_R_ADDRESS_RESOLVE_FAILED",
        "NVB_R_CONNECT_FAILED",
        "NVB_R_CONNECTION_TIMEOUT",
        "NVB_R_DATA_RECEIVE_FAILURE",
        "NVB_R_DATA_RECEIVE_TIMEOUT",
        "NVB_R_DATA_SEND_FAILURE",
        "NVB_R_NETWORK_ERROR",
        "NVB_R_NETWORK_ERROR_UNKNOWN",
        "NVB_R_PEER_NO_RESPONSE",
        "NVB_R_SERVER_INTERNAL_TIMEOUT",
        "NVB_R_SOCKET_ERROR",
        "NVB_R_STREAMER_NETWORK_ERROR",
    ]

    public static func isTransient(_ value: NativeNVSTTerminationValue) -> Bool {
        guard let name = value.name else { return false }
        return transientResults.contains(name)
    }

    public static func isTransient(_ reason: NativeNVSTTerminationReason) -> Bool {
        guard let name = reason.resultName else { return false }
        return transientResults.contains(name)
    }

    public static func permitsRecovery(_ termination: NativeNVSTTransportTermination) -> Bool {
        switch termination {
        case .sessionTerminated(let info):
            info.permitsSameSessionRecovery
        case .transportFailed(let failure):
            // The transport's own verdict: a network-class failure leaves the cloud session alive
            // and resumable, a decoder that gave up does not.
            failure.recoveryClassification == .transientNetwork
        }
    }

}

/// Whether the streaming path reconnects to the same cloud session on its own when the transport
/// dies or stalls. `singleAttempt` is the historical name; since 2026-09-05 it means "a bounded
/// series of attempts" (`NativeNVSTStreamingPath.maximumRecoveryAttempts` within
/// `recoveryAttemptWindow`), because one try at the instant a Wi-Fi network drops is the one try
/// most likely to fail.
public enum NativeNVSTAutomaticRecovery: Equatable, Sendable {
    case disabled
    case singleAttempt
}

public enum NativeNVSTDynamicStreamingMode: UInt32, Equatable, Sendable {
    case off = 0
    case preferFrameRate = 1
    case preferResolution = 2
    case on = 3
}

public struct NativeNVSTMicrophoneConfiguration: Equatable, Sendable {
    public let volume: Double
    public let voiceActivityEnabled: Bool
    public let captureRequested: Bool
    public let initiallyEnabled: Bool

    public init(volume: Double, voiceActivityEnabled: Bool, captureRequested: Bool, initiallyEnabled: Bool) {
        self.volume = min(max(volume.isFinite ? volume : 1, 0), 1)
        self.captureRequested = captureRequested
        self.voiceActivityEnabled = voiceActivityEnabled && captureRequested
        self.initiallyEnabled = initiallyEnabled && captureRequested
    }

    public static func settings(volume: Double, mode: String) -> NativeNVSTMicrophoneConfiguration {
        switch mode.lowercased() {
        case "voice-activity":
            NativeNVSTMicrophoneConfiguration(volume: volume, voiceActivityEnabled: true, captureRequested: true, initiallyEnabled: true)
        case "push-to-talk":
            NativeNVSTMicrophoneConfiguration(volume: volume, voiceActivityEnabled: false, captureRequested: true, initiallyEnabled: false)
        default:
            NativeNVSTMicrophoneConfiguration(volume: volume, voiceActivityEnabled: false, captureRequested: false, initiallyEnabled: false)
        }
    }
}

public struct NativeNVSTHapticCommand: Equatable, Sendable {
    public let playerIndex: Int
    public let lowFrequency: UInt16
    public let highFrequency: UInt16
    public let durationMilliseconds: UInt16

    public init(playerIndex: Int, lowFrequency: UInt16, highFrequency: UInt16, durationMilliseconds: UInt16) {
        self.playerIndex = playerIndex
        self.lowFrequency = lowFrequency
        self.highFrequency = highFrequency
        self.durationMilliseconds = durationMilliseconds
    }
}

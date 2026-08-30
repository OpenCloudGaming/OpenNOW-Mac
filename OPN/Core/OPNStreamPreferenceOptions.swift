//
//  OPNStreamPreferenceOptions.swift
//  OpenNOW
//
//  The option tables' element types and the resolved profile they add up to. Split out of
//  OPNStreamPreferences.swift, which keeps the store that reads and writes them.
//

import AppKit
import CoreAudio
import CoreMedia
import Foundation
import VideoToolbox

public struct OPNStreamAspectOption: Equatable, Sendable {
    public var label: String
    public var widthRatio: Int
    public var heightRatio: Int

    public init(label: String, widthRatio: Int, heightRatio: Int) {
        self.label = label
        self.widthRatio = widthRatio
        self.heightRatio = heightRatio
    }
}

public struct OPNStreamResolutionOption: Equatable, Sendable {
    public var width: Int
    public var height: Int

    public var value: String { "\(width)x\(height)" }
    public var label: String { "\(width) x \(height)" }

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public struct OPNStreamRegionOption: Equatable, Sendable {
    public var name: String
    public var url: String
    public var latencyMs: Int = -1
    public var automatic = false

    public var label: String {
        if automatic { return "Automatic" }
        if latencyMs >= 0 { return "\(name) (\(latencyMs) ms)" }
        return name
    }

    public init(name: String, url: String, latencyMs: Int = -1, automatic: Bool = false) {
        self.name = name
        self.url = url
        self.latencyMs = latencyMs
        self.automatic = automatic
    }
}

public struct OPNStreamCodecOption: Equatable, Sendable {
    public var label: String
    public var value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

public struct OPNStreamBitrateOption: Equatable, Sendable {
    public var label: String
    public var mbps: Int

    public init(label: String, mbps: Int) {
        self.label = label
        self.mbps = mbps
    }
}

public struct OPNStreamColorQualityOption: Equatable, Sendable {
    public var label: String
    public var value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

public struct OPNStreamPrefilterModeOption: Equatable, Sendable {
    public var label: String
    public var value: Int

    public init(label: String, value: Int) {
        self.label = label
        self.value = value
    }
}

public struct OPNStreamUpscalingModeOption: Equatable, Sendable {
    public var label: String
    public var value: Int

    public init(label: String, value: Int) {
        self.label = label
        self.value = value
    }
}

public struct OPNStreamUpscalingTargetOption: Equatable, Sendable {
    public var label: String
    public var height: Int

    public init(label: String, height: Int) {
        self.label = label
        self.height = height
    }
}

public struct OPNStreamTransportModeOption: Equatable, Sendable {
    public var label: String
    public var value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

public struct OPNStreamQualityProfileOption: Equatable, Sendable {
    public var label: String
    public var value: Int

    public init(label: String, value: Int) {
        self.label = label
        self.value = value
    }
}

public struct OPNStreamHudModeOption: Equatable, Sendable {
    public var label: String
    public var value: Int

    public init(label: String, value: Int) {
        self.label = label
        self.value = value
    }
}

public struct OPNStreamColorSpaceOption: Equatable, Sendable {
    public var label: String
    public var value: Int

    public init(label: String, value: Int) {
        self.label = label
        self.value = value
    }
}

public struct OPNStreamMicrophoneModeOption: Equatable, Sendable {
    public var label: String
    public var value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

public struct OPNStreamMicrophoneDeviceOption: Equatable, Sendable {
    public var label: String
    public var uniqueId: String
    public var automatic = false

    public init(label: String, uniqueId: String, automatic: Bool = false) {
        self.label = label
        self.uniqueId = uniqueId
        self.automatic = automatic
    }
}

public struct OPNStreamNetworkPreflightResult: Equatable, Sendable {
    public var streamingBaseUrl = ""
    public var networkTestSessionId = ""
    public var networkType = "Unknown"
    public var latencyMs = -1
    public var measuredBandwidthMbps = 0.0
    public var packetLossPercent = -1.0
    public var jitterMs = -1
    public var maxPacketSize = 0
    public var recommendedMaxBitrateMbps = 0
    public var serverReportedWarning = false
    public var continueRecommended = true
    public var usedAutomaticRegion = false
    public var warningMessage = ""

    public init() {}
}

public struct OPNStreamCloudVariables: Equatable, Sendable {
    public var fetched = false
    public var allowH265 = true
    public var allowAV1 = true
    public var allowHDR = true
    public var allowL4S = true
    public var allowReflex = true
    public var allowPrefilter = true
    public var maxBitrateMbps = 0
    public var maxSupportedPrefilterMode = 2
    public var supportedPrefilterModes: [Int] = []
    public var refreshIntervalSeconds = 3600
    public var gpuName = ""

    public init() {}
}

public struct OPNStreamDeviceCapabilities: Equatable, Sendable {
    public var h264HardwareDecodeSupported = true
    public var h265HardwareDecodeSupported = false
    public var av1HardwareDecodeSupported = false
    public var hdrDisplaySupported = false
    public var maxDisplayWidth = 0
    public var maxDisplayHeight = 0
    public var maxDisplayRefreshRate = 0
    public var displayDpi = 100

    public init() {}
}

struct OPNStreamScreenSnapshot: Sendable {
    let backingScaleFactor: CGFloat
    let screenNumber: UInt32?
    let frameSize: CGSize
    let maximumFramesPerSecond: Int
    let maximumPotentialExtendedDynamicRangeColorComponentValue: CGFloat

    @MainActor init?(screen: NSScreen?) {
        guard let screen else { return nil }
        backingScaleFactor = screen.backingScaleFactor
        screenNumber = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        frameSize = screen.frame.size
        maximumFramesPerSecond = screen.maximumFramesPerSecond
        maximumPotentialExtendedDynamicRangeColorComponentValue = screen.maximumPotentialExtendedDynamicRangeColorComponentValue
    }
}

public struct OPNStreamPresentationCapability: Equatable, Sendable {
    public let supportsTenBit: Bool
    public let supportsHDR: Bool

    public init(supportsTenBit: Bool, supportsHDR: Bool) {
        self.supportsTenBit = supportsTenBit
        self.supportsHDR = supportsHDR
    }
}

public struct OPNStreamPreferenceProfile: Equatable, Sendable {
    public var aspectIndex = 1
    public var resolutionIndex = 3
    public var fpsIndex = 1
    public var codecIndex = 0
    public var bitrateIndex = 2
    public var colorQualityIndex = 0
    public var transportModeIndex = 1
    public var streamingQualityProfileIndex = 0
    public var hudStreamingModeIndex = 0
    public var sdrColorSpaceIndex = 2
    public var hdrColorSpaceIndex = 0
    public var fps = 60
    public var maxBitrateMbps = 50
    public var prefilterModeIndex = 0
    public var prefilterMode = 0
    public var prefilterSharpness = 0
    public var prefilterDenoise = 0
    public var prefilterModel = 0
    public var upscalingModeIndex = 0
    public var upscalingMode = 0
    public var upscalingTargetIndex = 1
    public var upscalingTargetHeight = 2160
    public var upscalingSharpness = 10
    public var upscalingDenoise = 0
    public var pillarboxFillModeIndex = 0
    public var pillarboxFillColor = OPNStreamPreferences.defaultPillarboxFillColor
    public var pillarboxFillDim = 55
    public var recordingVideoBitrateMbps = 0
    public var recordingAudioBitrateKbps = 160
    public var recordingEnhancedVideoEnabled = true
    public var transportMode = OPNStreamPreferences.transportModeOptions[1]
    public var streamingQualityProfile = 0
    public var streamingQualityProfileOption = OPNStreamPreferences.streamingQualityProfileOptions[0]
    public var enableCloudGsync = false
    public var fallbackToLogicalResolution = false
    public var hudStreamingMode = 0
    public var hudStreamingModeOption = OPNStreamPreferences.hudStreamingModeOptions[0]
    public var sdrColorSpace = 2
    public var sdrColorSpaceOption = OPNStreamPreferences.colorSpaceOptions[2]
    public var hdrColorSpace = 0
    public var hdrColorSpaceOption = OPNStreamPreferences.colorSpaceOptions[0]
    public var enableL4S = false
    public var enableHdr = false
    public var enablePowerSaver = false
    public var suppressInputWhenInactive = true
    public var directMouseInput = true
    public var antiAFKMouseMovementEnabled = false
    public var preventDisplaySleepWhileStreaming = true
    public var gameVolume = 1.0
    public var microphoneVolume = 1.0
    public var microphoneMode = "disabled"
    public var microphoneDeviceId = ""
    public var microphonePushToTalkKeyCode = 9
    public var microphonePushToTalkModifierMask = 0
    public var microphonePushToTalkKeyLabel = "V"
    public var microphonePushToTalkComboLabel = "V"
    public var selectedRegionUrl = ""
    public var aspect = OPNStreamPreferences.aspectOptions[1]
    public var resolution = OPNStreamResolutionOption(width: 1920, height: 1200)
    public var codec = OPNStreamPreferences.codecOptions[0]
    public var bitrate = OPNStreamPreferences.bitrateOptions[2]
    public var colorQuality = OPNStreamPreferences.colorQualityOptions[0]
    public var prefilterModeOption = OPNStreamPreferences.prefilterModeOptions[0]
    public var upscalingModeOption = OPNStreamPreferences.upscalingModeOptions[0]
    public var upscalingTargetOption = OPNStreamPreferences.upscalingTargetOptions[1]
    public var pillarboxFillMode = OPNPillarboxFillMode.black

    public var allowsStreamingCustomization: Bool {
        streamingQualityProfileIndex == 0
    }

    public var aspectRatio: Double {
        aspect.heightRatio > 0 ? Double(aspect.widthRatio) / Double(aspect.heightRatio) : 16.0 / 9.0
    }

    public init() {}
}

import Foundation

public struct WebRTCMediaResolution: Equatable, Sendable {
    public var width: Int
    public var height: Int

    public var value: String { "\(width)x\(height)" }

    public init(width: Int, height: Int) {
        self.width = max(1, width)
        self.height = max(1, height)
    }
}

public struct WebRTCMediaDeviceCapabilities: Equatable, Sendable {
    public var h264HardwareDecodeSupported: Bool
    public var h265HardwareDecodeSupported: Bool
    public var av1HardwareDecodeSupported: Bool
    public var hdrDisplaySupported: Bool
    public var maxDisplayWidth: Int
    public var maxDisplayHeight: Int
    public var maxDisplayRefreshRate: Int
    public var displayDpi: Int
    public var connectedGamepadCount: Int

    public init(h264HardwareDecodeSupported: Bool = true,
                h265HardwareDecodeSupported: Bool = false,
                av1HardwareDecodeSupported: Bool = false,
                hdrDisplaySupported: Bool = false,
                maxDisplayWidth: Int = 0,
                maxDisplayHeight: Int = 0,
                maxDisplayRefreshRate: Int = 0,
                displayDpi: Int = 100,
                connectedGamepadCount: Int = 0) {
        self.h264HardwareDecodeSupported = h264HardwareDecodeSupported
        self.h265HardwareDecodeSupported = h265HardwareDecodeSupported
        self.av1HardwareDecodeSupported = av1HardwareDecodeSupported
        self.hdrDisplaySupported = hdrDisplaySupported
        self.maxDisplayWidth = max(0, maxDisplayWidth)
        self.maxDisplayHeight = max(0, maxDisplayHeight)
        self.maxDisplayRefreshRate = max(0, maxDisplayRefreshRate)
        self.displayDpi = max(0, displayDpi)
        self.connectedGamepadCount = max(0, min(4, connectedGamepadCount))
    }
}

public struct WebRTCMediaCloudVariables: Equatable, Sendable {
    public var fetched: Bool
    public var allowH265: Bool
    public var allowAV1: Bool
    public var allowHDR: Bool
    public var allowL4S: Bool
    public var allowReflex: Bool
    public var allowPrefilter: Bool
    public var maxBitrateMbps: Int

    public init(fetched: Bool = false,
                allowH265: Bool = true,
                allowAV1: Bool = true,
                allowHDR: Bool = true,
                allowL4S: Bool = true,
                allowReflex: Bool = true,
                allowPrefilter: Bool = true,
                maxBitrateMbps: Int = 0) {
        self.fetched = fetched
        self.allowH265 = allowH265
        self.allowAV1 = allowAV1
        self.allowHDR = allowHDR
        self.allowL4S = allowL4S
        self.allowReflex = allowReflex
        self.allowPrefilter = allowPrefilter
        self.maxBitrateMbps = max(0, maxBitrateMbps)
    }
}

public struct WebRTCMediaStreamProfile: Equatable, Sendable {
    public var resolution: WebRTCMediaResolution
    public var fps: Int
    public var codec: String
    public var colorQuality: String
    public var maxBitrateMbps: Int
    public var prefilterMode: Int
    public var prefilterSharpness: Int
    public var prefilterDenoise: Int
    public var prefilterModel: Int
    public var enableL4S: Bool
    public var enableHdr: Bool
    public var lowLatencyMode: Bool
    public var enablePowerSaver: Bool
    public var microphoneMode: String
    public var microphoneDeviceId: String
    public var microphonePushToTalkKeyCode: Int
    public var microphonePushToTalkModifierMask: Int
    public var gameVolume: Double
    public var microphoneVolume: Double
    public var upscalingMode: Int
    public var upscalingSharpness: Int
    public var upscalingDenoise: Int
    public var upscalingTargetHeight: Int
    public var suppressInputWhenInactive: Bool
    public var directMouseInput: Bool

    public init(resolution: WebRTCMediaResolution = WebRTCMediaResolution(width: 1920, height: 1080),
                fps: Int = 60,
                codec: String = "H264",
                colorQuality: String = "8bit_420",
                maxBitrateMbps: Int = 50,
                prefilterMode: Int = 0,
                prefilterSharpness: Int = 0,
                prefilterDenoise: Int = 0,
                prefilterModel: Int = 0,
                enableL4S: Bool = false,
                enableHdr: Bool = false,
                lowLatencyMode: Bool = false,
                enablePowerSaver: Bool = false,
                microphoneMode: String = "disabled",
                microphoneDeviceId: String = "",
                microphonePushToTalkKeyCode: Int = 9,
                microphonePushToTalkModifierMask: Int = 0,
                gameVolume: Double = 1,
                microphoneVolume: Double = 1,
                upscalingMode: Int = 0,
                upscalingSharpness: Int = 4,
                upscalingDenoise: Int = 0,
                upscalingTargetHeight: Int = 2160,
                suppressInputWhenInactive: Bool = true,
                directMouseInput: Bool = true) {
        self.resolution = resolution
        self.fps = fps
        self.codec = codec
        self.colorQuality = colorQuality
        self.maxBitrateMbps = maxBitrateMbps
        self.prefilterMode = prefilterMode
        self.prefilterSharpness = prefilterSharpness
        self.prefilterDenoise = prefilterDenoise
        self.prefilterModel = prefilterModel
        self.enableL4S = enableL4S
        self.enableHdr = enableHdr
        self.lowLatencyMode = lowLatencyMode
        self.enablePowerSaver = enablePowerSaver
        self.microphoneMode = microphoneMode
        self.microphoneDeviceId = microphoneDeviceId
        self.microphonePushToTalkKeyCode = microphonePushToTalkKeyCode
        self.microphonePushToTalkModifierMask = microphonePushToTalkModifierMask
        self.gameVolume = min(max(gameVolume, 0), 1)
        self.microphoneVolume = min(max(microphoneVolume, 0), 1)
        self.upscalingMode = upscalingMode
        self.upscalingSharpness = upscalingSharpness
        self.upscalingDenoise = upscalingDenoise
        self.upscalingTargetHeight = upscalingTargetHeight
        self.suppressInputWhenInactive = suppressInputWhenInactive
        self.directMouseInput = directMouseInput
    }
}

public struct WebRTCMediaResolvedStreamSettings: Equatable, Sendable {
    public var resolution: String
    public var fps: Int
    public var codec: String
    public var colorQuality: String
    public var maxBitrateMbps: Int
    public var prefilterMode: Int
    public var prefilterSharpness: Int
    public var prefilterDenoise: Int
    public var prefilterModel: Int
    public var enableL4S: Bool
    public var enableHdr: Bool
    public var enableReflex: Bool
    public var lowLatencyMode: Bool
    public var microphoneMode: String
    public var microphoneDeviceId: String
    public var microphonePushToTalkKeyCode: Int
    public var microphonePushToTalkModifierMask: Int
    public var gameVolume: Double
    public var microphoneVolume: Double
    public var upscalingMode: Int
    public var upscalingSharpness: Int
    public var upscalingDenoise: Int
    public var upscalingTargetHeight: Int
    public var suppressInputWhenInactive: Bool
    public var directMouseInput: Bool
    public var remoteControllersBitmap: UInt32
    public var supportedHidDevices: UInt32
    public var availableSupportedControllers: [String]

    public func dictionary(gameLanguage: String, accountLinked: Bool, selectedStore: String) -> [String: Any] {
        [
            "resolution": resolution,
            "fps": fps,
            "codec": codec,
            "colorQuality": colorQuality,
            "maxBitrateMbps": maxBitrateMbps,
            "prefilterMode": prefilterMode,
            "prefilterSharpness": prefilterSharpness,
            "prefilterDenoise": prefilterDenoise,
            "prefilterModel": prefilterModel,
            "enableL4S": enableL4S,
            "enableHdr": enableHdr,
            "enableReflex": enableReflex,
            "lowLatencyMode": lowLatencyMode,
            "microphoneMode": microphoneMode,
            "microphoneDeviceId": microphoneDeviceId,
            "microphonePushToTalkKeyCode": microphonePushToTalkKeyCode,
            "microphonePushToTalkModifierMask": microphonePushToTalkModifierMask,
            "gameVolume": gameVolume,
            "microphoneVolume": microphoneVolume,
            "upscalingMode": upscalingMode,
            "upscalingSharpness": upscalingSharpness,
            "upscalingDenoise": upscalingDenoise,
            "upscalingTargetHeight": upscalingTargetHeight,
            "suppressInputWhenInactive": suppressInputWhenInactive,
            "directMouseInput": directMouseInput,
            "gameLanguage": gameLanguage,
            "accountLinked": accountLinked,
            "selectedStore": selectedStore,
            "remoteControllersBitmap": Int(remoteControllersBitmap),
            "supportedHidDevices": Int(supportedHidDevices),
            "availableSupportedControllers": availableSupportedControllers,
        ]
    }
}

public enum WebRTCMediaStreamSettingsResolver {
    public static func resolve(profile: WebRTCMediaStreamProfile,
                               capabilities: WebRTCMediaDeviceCapabilities,
                               cloudVariables: WebRTCMediaCloudVariables = WebRTCMediaCloudVariables(),
                               libWebRTCAvailable: Bool = true) -> WebRTCMediaResolvedStreamSettings {
        var codec = resolvedCodec(profile: profile, capabilities: capabilities, libWebRTCAvailable: libWebRTCAvailable)
        if !cloudVariables.allowH265, codec == "H265" { codec = "H264" }
        if !cloudVariables.allowAV1, codec == "AV1" { codec = "H264" }
        let lowLatency = profile.lowLatencyMode
        let controllerCount = capabilities.connectedGamepadCount
        return WebRTCMediaResolvedStreamSettings(
            resolution: profile.resolution.value,
            fps: profile.enablePowerSaver ? min(profile.fps, 30) : profile.fps,
            codec: codec,
            colorQuality: profile.colorQuality.isEmpty ? "8bit_420" : profile.colorQuality,
            maxBitrateMbps: max(1, min(profile.enablePowerSaver ? min(profile.maxBitrateMbps, 15) : profile.maxBitrateMbps, cloudVariables.maxBitrateMbps > 0 ? cloudVariables.maxBitrateMbps : Int.max)),
            prefilterMode: lowLatency || (cloudVariables.fetched && !cloudVariables.allowPrefilter) ? 0 : profile.prefilterMode,
            prefilterSharpness: lowLatency || profile.prefilterMode == 0 ? 0 : profile.prefilterSharpness,
            prefilterDenoise: lowLatency || profile.prefilterMode == 0 ? 0 : profile.prefilterDenoise,
            prefilterModel: lowLatency || profile.prefilterMode == 0 ? 0 : profile.prefilterModel,
            enableL4S: cloudVariables.allowL4S && profile.enableL4S,
            enableHdr: cloudVariables.allowHDR && capabilities.hdrDisplaySupported && profile.enableHdr,
            enableReflex: cloudVariables.allowReflex,
            lowLatencyMode: lowLatency,
            microphoneMode: profile.microphoneMode,
            microphoneDeviceId: profile.microphoneDeviceId,
            microphonePushToTalkKeyCode: profile.microphonePushToTalkKeyCode,
            microphonePushToTalkModifierMask: profile.microphonePushToTalkModifierMask,
            gameVolume: profile.gameVolume,
            microphoneVolume: profile.microphoneVolume,
            upscalingMode: lowLatency ? 0 : profile.upscalingMode,
            upscalingSharpness: lowLatency ? 0 : profile.upscalingSharpness,
            upscalingDenoise: lowLatency ? 0 : profile.upscalingDenoise,
            upscalingTargetHeight: profile.upscalingTargetHeight,
            suppressInputWhenInactive: profile.suppressInputWhenInactive,
            directMouseInput: profile.directMouseInput,
            remoteControllersBitmap: controllerBitmap(count: controllerCount),
            supportedHidDevices: 0,
            availableSupportedControllers: []
        )
    }

    private static func resolvedCodec(profile: WebRTCMediaStreamProfile, capabilities: WebRTCMediaDeviceCapabilities, libWebRTCAvailable: Bool) -> String {
        let requested = profile.codec.isEmpty ? "H264" : profile.codec.uppercased()
        if requested != "AUTO" { return codecSupported(requested, capabilities: capabilities) ? requested : "H264" }
        if !libWebRTCAvailable { return "H264" }
        let pixels = max(1, profile.resolution.width) * max(1, profile.resolution.height)
        let prefersTenBit = profile.colorQuality.hasPrefix("10bit")
        let prefersHighResolution = pixels >= 2560 * 1440
        let prefersVeryHighResolution = pixels >= 3840 * 2160
        let highFps = profile.fps >= 144
        if !highFps, prefersVeryHighResolution, capabilities.av1HardwareDecodeSupported { return "AV1" }
        if !highFps, (prefersTenBit || prefersHighResolution || profile.maxBitrateMbps >= 75), capabilities.h265HardwareDecodeSupported { return "H265" }
        return "H264"
    }

    private static func codecSupported(_ codec: String, capabilities: WebRTCMediaDeviceCapabilities) -> Bool {
        switch codec {
        case "AUTO", "H264": true
        case "H265", "HEVC": capabilities.h265HardwareDecodeSupported
        case "AV1": capabilities.av1HardwareDecodeSupported
        default: false
        }
    }

    private static func controllerBitmap(count: Int) -> UInt32 {
        guard count > 0 else { return 0 }
        return (0..<min(4, count)).reduce(UInt32(0)) { partial, index in partial | (1 << UInt32(index)) }
    }
}

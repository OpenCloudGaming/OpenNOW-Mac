//  Runtime video/audio settings carried between the stream host and the render surface. Pure value
//  types: no UI framework, so the model layer can own them and tests can build them directly.
//

import Foundation

enum StreamInputAction {
    case send
    case drop
    case setMicrophone(Bool)
}

struct StreamRuntimeSettings: Equatable {
    static let upscalingModes = [
        VideoEnhancementMode(label: "Off", value: 0),
        VideoEnhancementMode(label: "MetalFX", value: 3),
        VideoEnhancementMode(label: "Spatial", value: 2),
    ]

    var resolutionWidth = 1920
    var resolutionHeight = 1080
    var fps = 60
    var microphoneMode = "disabled"
    var microphonePushToTalkKeyCode = 9
    var microphonePushToTalkModifierMask = 0
    var suppressInputWhenInactive = true
    var directMouseInput = true
    var antiAFKMouseMovementEnabled = false
    var upscalingMode = 0
    var upscalingSharpness = 10
    var upscalingDenoise = 0
    var upscalingTargetHeight = 2160
    var pillarboxFillMode = 0
    var pillarboxFillDim = 55
    var pillarboxFillColor = 0
    var recordingVideoBitrateMbps = 0
    var recordingAudioBitrateKbps = 160
    var recordingEnhancedVideoEnabled = true

    var upscalingModeLabel: String {
        switch upscalingMode {
        case 0: return "Off"
        case 3: return "MetalFX"
        default: return "Mode \(upscalingMode)"
        }
    }

    init() {}

    mutating func updateVideoEnhancement(mode: Int? = nil, sharpness: Int? = nil, denoise: Int? = nil, targetHeight: Int? = nil, pillarboxFillMode: Int? = nil, pillarboxFillDim: Int? = nil, pillarboxFillColor: Int? = nil) {
        if let mode {
            upscalingMode = Self.normalizedUpscalingMode(mode)
        }
        if let sharpness { upscalingSharpness = min(max(sharpness, 0), 15) }
        if let denoise { upscalingDenoise = min(max(denoise, 0), 20) }
        if let targetHeight { upscalingTargetHeight = targetHeight > 0 ? targetHeight : 2160 }
        if let pillarboxFillMode { self.pillarboxFillMode = OPNPillarboxFillMode.from(pillarboxFillMode).rawValue }
        if let pillarboxFillDim { self.pillarboxFillDim = min(max(pillarboxFillDim, 0), 100) }
        if let pillarboxFillColor { self.pillarboxFillColor = pillarboxFillColor }
    }

    init(json: String?) {
        guard let json,
              let data = json.data(using: .utf8),
              let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let resolution = Self.resolution(Self.string(dictionary["resolution"], fallback: "1920x1080"))
        resolutionWidth = resolution.width
        resolutionHeight = resolution.height
        fps = Self.int(dictionary["fps"], fallback: 60)
        microphoneMode = Self.string(dictionary["microphoneMode"], fallback: "disabled")
        microphonePushToTalkKeyCode = Self.int(dictionary["microphonePushToTalkKeyCode"], fallback: 9)
        microphonePushToTalkModifierMask = Self.int(dictionary["microphonePushToTalkModifierMask"])
        suppressInputWhenInactive = Self.bool(dictionary["suppressInputWhenInactive"], fallback: true)
        directMouseInput = Self.bool(dictionary["directMouseInput"], fallback: true)
        antiAFKMouseMovementEnabled = Self.bool(dictionary["antiAFKMouseMovementEnabled"])
        pillarboxFillMode = OPNPillarboxFillMode.from(Self.int(dictionary["pillarboxFillMode"], fallback: 0)).rawValue
        pillarboxFillDim = Self.int(dictionary["pillarboxFillDim"], fallback: 55)
        pillarboxFillColor = Self.packedColor(Self.string(dictionary["pillarboxFillColor"], fallback: "#000000"))
        upscalingMode = Self.normalizedUpscalingMode(Self.int(dictionary["upscalingMode"]))
        upscalingSharpness = Self.int(dictionary["upscalingSharpness"], fallback: 10)
        upscalingDenoise = Self.int(dictionary["upscalingDenoise"])
        upscalingTargetHeight = Self.int(dictionary["upscalingTargetHeight"], fallback: 2160)
        recordingVideoBitrateMbps = Self.int(dictionary["recordingVideoBitrateMbps"])
        recordingAudioBitrateKbps = Self.int(dictionary["recordingAudioBitrateKbps"], fallback: 160)
        recordingEnhancedVideoEnabled = Self.bool(dictionary["recordingEnhancedVideoEnabled"], fallback: true)
    }

    static func string(_ value: Any?, fallback: String = "") -> String {
        if let value = value as? String { return value.isEmpty ? fallback : value }
        if let value = value as? NSString { let string = value as String; return string.isEmpty ? fallback : string }
        if let value = value as? NSNumber { return value.stringValue }
        return fallback
    }

    static func int(_ value: Any?, fallback: Int = 0) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) ?? fallback }
        return fallback
    }

    /// "#RRGGBB" to packed 0xRRGGBB, so the render path never parses a string.
    private static func packedColor(_ hex: String) -> Int {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = Int(digits, radix: 16) else { return 0 }
        return value
    }

    static func bool(_ value: Any?, fallback: Bool = false) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String { return value == "1" || value.caseInsensitiveCompare("true") == .orderedSame || value.caseInsensitiveCompare("yes") == .orderedSame }
        return fallback
    }

    private static func resolution(_ value: String) -> (width: Int, height: Int) {
        let parts = value.split(separator: "x").compactMap { Int($0) }
        return (max(1, parts.first ?? 1920), max(1, parts.count > 1 ? parts[1] : 1080))
    }

    private static func normalizedUpscalingMode(_ mode: Int) -> Int {
        switch mode {
        case 0: return 0
        case 1...4: return 3
        default: return 0
        }
    }
}

struct VideoEnhancementMode: Equatable {
    let label: String
    let value: Int
}

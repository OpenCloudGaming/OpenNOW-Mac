//  The Objective-C-facing snapshot of the stream preferences, and the region-measurement scratch
//  state.
//

import AppKit
import CoreAudio
import CoreMedia
import Foundation
import VideoToolbox

@objc(OPNStreamViewPreferenceSnapshot)
public final class OPNStreamViewPreferenceSnapshot: NSObject {
    @objc public let directMouseInput: Bool
    @objc public let microphoneShortcutEnabled: Bool
    @objc public let gameVolume: Double
    @objc public let microphoneVolume: Double
    @objc public let maxBitrateMbps: Int
    @objc public let transportMode: String
    @objc public let streamingQualityProfile: Int
    @objc public let enableCloudGsync: Bool
    @objc public let fallbackToLogicalResolution: Bool
    @objc public let upscalingModeIndex: Int
    @objc public let upscalingMode: Int
    @objc public let upscalingTargetHeight: Int
    @objc public let upscalingSharpness: Int
    @objc public let upscalingDenoise: Int
    @objc public let pillarboxFillModeIndex: Int
    @objc public let pillarboxFillMode: OPNPillarboxFillMode
    @objc public let pillarboxFillColor: String
    @objc public let pillarboxFillDim: Int
    @objc public let streamWidth: Int
    @objc public let streamHeight: Int
    @objc public let recordingEnhancedVideoEnabled: Bool
    @objc public let preventDisplaySleepWhileStreaming: Bool

    init(profile: OPNStreamPreferenceProfile) {
        directMouseInput = profile.directMouseInput
        microphoneShortcutEnabled = OPNStreamPreferences.loadMicrophoneShortcutEnabled()
        gameVolume = profile.gameVolume
        microphoneVolume = profile.microphoneVolume
        maxBitrateMbps = profile.maxBitrateMbps
        transportMode = profile.transportMode.value
        streamingQualityProfile = profile.streamingQualityProfile
        enableCloudGsync = profile.enableCloudGsync
        fallbackToLogicalResolution = profile.fallbackToLogicalResolution
        upscalingModeIndex = profile.upscalingModeIndex
        upscalingMode = profile.upscalingMode
        upscalingTargetHeight = profile.upscalingTargetHeight
        upscalingSharpness = profile.upscalingSharpness
        upscalingDenoise = profile.upscalingDenoise
        pillarboxFillModeIndex = profile.pillarboxFillModeIndex
        pillarboxFillMode = profile.pillarboxFillMode
        pillarboxFillColor = profile.pillarboxFillColor
        pillarboxFillDim = profile.pillarboxFillDim
        streamWidth = profile.resolution.width
        streamHeight = profile.resolution.height
        recordingEnhancedVideoEnabled = profile.recordingEnhancedVideoEnabled
        preventDisplaySleepWhileStreaming = profile.preventDisplaySleepWhileStreaming
        super.init()
    }
}

@objc(OPNStreamViewPreferences)
public final class OPNStreamViewPreferences: NSObject {
    @objc public static func loadViewPreferenceSnapshot() -> OPNStreamViewPreferenceSnapshot {
        OPNStreamViewPreferenceSnapshot(profile: OPNStreamPreferences.loadProfile())
    }

    @objc public static func upscalingModeLabels() -> [String] {
        OPNStreamPreferences.upscalingModeOptions.map(\.label)
    }

    @objc(upscalingModeValueAtIndex:)
    public static func upscalingModeValue(at index: Int) -> Int {
        let clamped = min(max(index, 0), OPNStreamPreferences.upscalingModeOptions.count - 1)
        return OPNStreamPreferences.upscalingModeOptions[clamped].value
    }

    @objc public static func pillarboxFillModeLabels() -> [String] {
        OPNPillarboxFillMode.allCases.map(\.label)
    }

    @objc(pillarboxFillModeAtIndex:)
    public static func pillarboxFillMode(at index: Int) -> OPNPillarboxFillMode {
        OPNPillarboxFillMode.from(index)
    }

    @objc(pillarboxFillModeValueAtIndex:)
    public static func pillarboxFillModeValue(at index: Int) -> Int {
        OPNPillarboxFillMode.from(index).rawValue
    }

    @objc public static func saveMicrophoneShortcutEnabled(_ enabled: Bool) {
        OPNStreamPreferences.saveMicrophoneShortcutEnabled(enabled)
    }

    @objc public static func saveGameVolume(_ value: Double) {
        OPNStreamPreferences.saveGameVolume(value)
    }

    @objc public static func saveMicrophoneVolume(_ value: Double) {
        OPNStreamPreferences.saveMicrophoneVolume(value)
    }

    @objc public static func saveUpscalingModeIndex(_ index: Int) {
        OPNStreamPreferences.saveUpscalingModeIndex(index)
    }

    @objc public static func saveUpscalingSharpness(_ sharpness: Int) {
        OPNStreamPreferences.saveUpscalingSharpness(sharpness)
    }

    @objc public static func saveUpscalingDenoise(_ denoise: Int) {
        OPNStreamPreferences.saveUpscalingDenoise(denoise)
    }

    @objc public static func savePillarboxFillModeIndex(_ index: Int) {
        OPNStreamPreferences.savePillarboxFillModeIndex(index)
    }

    @objc public static func savePillarboxFillColor(_ color: String) {
        OPNStreamPreferences.savePillarboxFillColor(color)
    }

    @objc public static func savePillarboxFillDim(_ dim: Int) {
        OPNStreamPreferences.savePillarboxFillDim(dim)
    }
}

extension OPNStreamResolutionOption {
    init(_ tuple: (Int, Int)) {
        self.init(width: tuple.0, height: tuple.1)
    }
}

final class RegionIndexBox: @unchecked Sendable {
    let lock = NSLock()
    private var indices: [Int]
    private var cursor = 0

    init(indices: [Int]) {
        self.indices = indices
    }

    func next() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard cursor < indices.count else { return nil }
        let value = indices[cursor]
        cursor += 1
        return value
    }
}

final class RegionMeasurementState: @unchecked Sendable {
    let lock = NSLock()
    private var regions: [OPNStreamRegionOption]

    init(_ regions: [OPNStreamRegionOption]) {
        self.regions = regions
    }

    var values: [OPNStreamRegionOption] {
        lock.lock()
        defer { lock.unlock() }
        return regions
    }

    func region(at index: Int) -> OPNStreamRegionOption {
        lock.lock()
        defer { lock.unlock() }
        return regions[index]
    }

    func setLatency(_ latencyMs: Int, at index: Int) {
        lock.lock()
        defer { lock.unlock() }
        regions[index].latencyMs = latencyMs
    }
}

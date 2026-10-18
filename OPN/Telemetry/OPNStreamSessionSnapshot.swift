import Foundation

/// The session's own configuration, written to the diagnostics log once per session.
/// The counter dump answers "what is the stream doing"; nothing answered "what is this session set to".
struct OPNStreamSessionSnapshot: Equatable, Sendable {
    let applicationID: String
    let displayName: String
    let isBuiltInDisplay: Bool
    let displayPixelWidth: Int
    let displayPixelHeight: Int
    let displayScale: Double
    let displayRefreshRate: Int
    let isHDRDisplaySupported: Bool
    let machineModel: String
    let macOSVersion: String
    let framePacingLabel: String
    let perGameProfileState: String
    let vsyncLabel: String
    let isCloudGsyncEnabled: Bool
    let upscalingModeLabel: String
    let upscalingTargetHeight: Int
    let isRawMouseInputEnabled: Bool
    let isMatchingMacPointerSpeed: Bool
    let controllerBackendLabel: String
    let cursorPolicyLabel: String
    let isHDRStreamEnabled: Bool
    let isReflexEnabled: Bool
    let isL4SEnabled: Bool
    let audioChannelCount: Int

    /// One `key=value` per fact, so a reader answers one question per key.
    var logLine: String {
        [
            "session.config",
            "app=\(applicationID)",
            "display=\"\(displayName)\"",
            "builtin=\(Self.onOffText(isBuiltInDisplay))",
            "px=\(Self.pixelSizeText(width: displayPixelWidth, height: displayPixelHeight))",
            "scale=\(Self.scaleText(displayScale))",
            "hz=\(Self.refreshRateText(displayRefreshRate))",
            "hdrDisplay=\(Self.onOffText(isHDRDisplaySupported))",
            "model=\(machineModel)",
            "macos=\(macOSVersion)",
            "framePacing=\(framePacingLabel)",
            "perGameProfile=\(perGameProfileState)",
            "vsync=\(vsyncLabel)",
            "cloudGsync=\(Self.onOffText(isCloudGsyncEnabled))",
            "upscaling=\(upscalingModeLabel)",
            "upscaleTarget=\(upscalingTargetHeight)",
            "rawMouse=\(Self.onOffText(isRawMouseInputEnabled))",
            "matchMacPointerSpeed=\(Self.onOffText(isMatchingMacPointerSpeed))",
            "controller=\(controllerBackendLabel)",
            "cursor=\(cursorPolicyLabel)",
            "hdr=\(Self.onOffText(isHDRStreamEnabled))",
            "reflex=\(Self.onOffText(isReflexEnabled))",
            "l4s=\(Self.onOffText(isL4SEnabled))",
            "audioChannels=\(audioChannelCount)"
        ].joined(separator: " ")
    }

    /// Reads the facts a session fixes before its first frame: the settings its transport is built
    /// with, the launch profile's pacing, and the screen and machine the app resolved at launch.
    @MainActor
    static func resolved(applicationID: String,
                         settings: ResolvedStreamSettings,
                         presentationMode: Int) -> OPNStreamSessionSnapshot {
        let screen = OPNStreamScreenSnapshotCache.resolvedSnapshot()
        let pacing = OPNVideoPresentationMode(rawValue: presentationMode)
        return OPNStreamSessionSnapshot(
            applicationID: applicationID,
            displayName: screen?.localizedName ?? "unknown",
            isBuiltInDisplay: screen?.isBuiltIn ?? false,
            displayPixelWidth: screen?.pixelWidth ?? 0,
            displayPixelHeight: screen?.pixelHeight ?? 0,
            displayScale: Double(screen?.backingScaleFactor ?? 0),
            // The mode's own rate and the panel's cap answer different questions, and pacing uses both.
            displayRefreshRate: max(screen?.refreshRate ?? 0, screen?.maximumFramesPerSecond ?? 0),
            isHDRDisplaySupported: (screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 0) > 1,
            machineModel: OPNSystemHardware.modelIdentifier,
            macOSVersion: OPNSystemHardware.operatingSystemVersion,
            framePacingLabel: pacing?.label ?? "mode\(presentationMode)",
            perGameProfileState: perGameProfileStateText(applicationID: applicationID),
            vsyncLabel: NvstVsyncMode(rawValue: settings.vsyncMode)?.label ?? "mode\(settings.vsyncMode)",
            isCloudGsyncEnabled: settings.enableCloudGsync,
            upscalingModeLabel: upscalingModeText(settings.upscalingMode),
            upscalingTargetHeight: settings.upscalingTargetHeight,
            isRawMouseInputEnabled: settings.rawMouseInput,
            isMatchingMacPointerSpeed: settings.rawMouseMatchesMacPointerSpeed,
            controllerBackendLabel: ControllerInputBackendPreference.load().label,
            cursorPolicyLabel: OPNCursorPolicy.from(settings.cursorPolicy).label,
            isHDRStreamEnabled: settings.enableHdr,
            isReflexEnabled: settings.enableReflex,
            isL4SEnabled: settings.enableL4S,
            audioChannelCount: settings.audioChannelCount
        )
    }

    /// The line the last session wrote, so a report filed from Settings after the session ended can
    /// still describe it without re-reading a log whose head may already be gone.
    @MainActor private(set) static var lastSessionLogLine = ""

    @MainActor
    static func recordLastSession(_ snapshot: OPNStreamSessionSnapshot) {
        lastSessionLogLine = snapshot.logLine
    }

    /// A per-game profile overrides the global one silently, and a wrong pacing is the first thing a
    /// stutter report is checked against.
    private static func perGameProfileStateText(applicationID: String) -> String {
        guard OPNStreamPreferences.profileExists(forGame: applicationID) else { return "none" }
        return OPNStreamPreferences.profileEnabled(forGame: applicationID) ? "enabled" : "present-disabled"
    }

    private static func upscalingModeText(_ mode: Int) -> String {
        OPNStreamPreferences.upscalingModeOptions.first { $0.value == mode }?.label ?? "mode\(mode)"
    }

    private static func onOffText(_ isOn: Bool) -> String {
        isOn ? "on" : "off"
    }

    private static func pixelSizeText(width: Int, height: Int) -> String {
        width > 0 && height > 0 ? "\(width)x\(height)" : "unknown"
    }

    private static func scaleText(_ scale: Double) -> String {
        scale > 0 ? String(format: "%.2f", scale) : "unknown"
    }

    private static func refreshRateText(_ refreshRate: Int) -> String {
        refreshRate > 0 ? "\(refreshRate)" : "unknown"
    }
}

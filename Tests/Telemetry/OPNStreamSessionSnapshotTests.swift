import Foundation
import Testing
@testable import OpenNOW

/// A support thread asking about a stutter had to ask the reader for the display, the frame pacing,
/// the per-game profile, Cloud G-Sync and the input settings by hand.
@MainActor
@Test func sessionSnapshotDescribesEverySettingASupportThreadAsksFor() {
    var profile = StreamProfile()
    profile.vsyncMode = NvstVsyncMode.off.rawValue
    profile.upscalingMode = 3
    profile.upscalingTargetHeight = 1440
    profile.enableCloudGsync = true
    profile.rawMouseInput = true
    profile.rawMouseMatchesMacPointerSpeed = true
    profile.cursorPolicy = OPNCursorPolicy.stream.rawValue
    let settings = StreamSettingsResolver.resolve(profile: profile, capabilities: StreamDeviceCapabilities())

    let logLine = OPNStreamSessionSnapshot.resolved(applicationID: "session-snapshot-\(UUID().uuidString)",
                                                    settings: settings,
                                                    presentationMode: OPNVideoPresentationMode.lowestLatency.rawValue).logLine

    // One line: a log line is grepped, not read, so every fact stays on it.
    #expect(logLine.hasPrefix("session.config "))
    #expect(!logLine.contains("\n"))
    #expect(logLine.contains("display="))
    #expect(logLine.contains("builtin="))
    #expect(logLine.contains("px="))
    #expect(logLine.contains("hz="))
    #expect(logLine.contains("model="))
    #expect(logLine.contains("macos="))
    #expect(logLine.contains("framePacing=lowest latency"))
    #expect(logLine.contains("perGameProfile=none"))
    #expect(logLine.contains("vsync=Off"))
    #expect(logLine.contains("cloudGsync=on"))
    #expect(logLine.contains("upscaling=MetalFX"))
    #expect(logLine.contains("upscaleTarget=1440"))
    #expect(logLine.contains("rawMouse=on"))
    #expect(logLine.contains("matchMacPointerSpeed=on"))
    #expect(logLine.contains("controller="))
    #expect(logLine.contains("cursor=Stream"))
    #expect(logLine.contains("audioChannels="))
}

/// A per-game profile overrides the global one silently, so the log has to say whether one is in
/// play — a wrong pacing on one title is the first thing a stutter report is checked against.
@MainActor
@Test func sessionSnapshotReportsWhetherAPerGameProfileIsInPlay() {
    withPreservedPreferences(["OpenNOW.Stream.GameProfiles"]) {
        removePreferenceValue("OpenNOW.Stream.GameProfiles")
        let settings = StreamSettingsResolver.resolve(profile: StreamProfile(), capabilities: StreamDeviceCapabilities())

        let withoutProfile = OPNStreamSessionSnapshot.resolved(applicationID: "snapshot-no-profile",
                                                               settings: settings,
                                                               presentationMode: OPNVideoPresentationMode.balanced.rawValue).logLine
        #expect(withoutProfile.contains("perGameProfile=none"))

        OPNStreamPreferences.saveProfile(forGame: "snapshot-with-profile", profile: OPNStreamPreferenceProfile())
        let withProfile = OPNStreamSessionSnapshot.resolved(applicationID: "snapshot-with-profile",
                                                            settings: settings,
                                                            presentationMode: OPNVideoPresentationMode.vrr.rawValue).logLine
        #expect(withProfile.contains("perGameProfile=enabled"))
        #expect(withProfile.contains("framePacing=vrr"))
    }
}

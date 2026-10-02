import Testing
@testable import OpenNOW

private let bundle = OPNProductIdentity.releaseBundleIdentifier

@Suite("OPNInstanceFeatureGate")
struct OPNInstanceFeatureGateTests {
    private let primary = OPNInstanceFeatureGate(instance: OPNAppInstance(number: 1, bundleIdentifier: bundle))
    private let secondary = OPNInstanceFeatureGate(instance: OPNAppInstance(number: 2, bundleIdentifier: bundle))

    @Test func theFirstInstanceKeepsEveryFeature() {
        #expect(!primary.isSecondary)
        #expect(primary.allowsUpdater)
        #expect(primary.allowsCloudSync)
        #expect(primary.allowsCaptureMigration)
        #expect(primary.allowsLaunchAtLogin)
        #expect(primary.allowsDiscordPresence)
        #expect(primary.allowsMenuBarItem)
        #expect(primary.allowsRemoteCoOpHosting)
        #expect(!primary.alwaysOpensWindow)
        #expect(!primary.quitsWithLastWindow)
        #expect(!primary.signInStartsOnQRCode)
    }

    @Test func aSecondaryInstanceDropsTheSharedMachineryAndOwnsItsWindow() {
        #expect(secondary.isSecondary)
        #expect(!secondary.allowsUpdater)
        #expect(!secondary.allowsCloudSync)
        #expect(!secondary.allowsCaptureMigration)
        #expect(!secondary.allowsLaunchAtLogin)
        #expect(!secondary.allowsDiscordPresence)
        #expect(!secondary.allowsMenuBarItem)
        #expect(!secondary.allowsRemoteCoOpHosting)
        #expect(secondary.alwaysOpensWindow)
        #expect(secondary.quitsWithLastWindow)
        #expect(secondary.signInStartsOnQRCode)
    }

    @Test func microphoneStartsOffOnlyForASecondaryInstance() {
        #expect(secondary.startingMicrophoneMode(storedMode: "voice-activity") == "disabled")
        #expect(secondary.startingMicrophoneMode(storedMode: "push-to-talk") == "disabled")
        #expect(primary.startingMicrophoneMode(storedMode: "voice-activity") == "voice-activity")
    }

    @Test func theProcessWithoutTheFlagIsThePrimary() {
        #expect(!OPNInstanceFeatureGate.current.isSecondary)
    }
}

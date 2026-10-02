import Foundation

struct OPNInstanceFeatureGate: Equatable, Sendable {
    static let secondaryInstanceMicrophoneMode = "disabled"

    let instance: OPNAppInstance

    static var current: OPNInstanceFeatureGate { OPNInstanceFeatureGate(instance: OPNAppInstance.current) }

    var isSecondary: Bool { !instance.isPrimary }

    var allowsUpdater: Bool { !isSecondary }
    var allowsCloudSync: Bool { !isSecondary }
    var allowsCaptureMigration: Bool { !isSecondary }
    var allowsLaunchAtLogin: Bool { !isSecondary }
    var allowsDiscordPresence: Bool { !isSecondary }
    var allowsMenuBarItem: Bool { !isSecondary }
    var allowsRemoteCoOpHosting: Bool { !isSecondary }
    var alwaysOpensWindow: Bool { isSecondary }
    var quitsWithLastWindow: Bool { isSecondary }
    var signInStartsOnQRCode: Bool { isSecondary }

    func startingMicrophoneMode(storedMode: String) -> String {
        isSecondary ? Self.secondaryInstanceMicrophoneMode : storedMode
    }
}

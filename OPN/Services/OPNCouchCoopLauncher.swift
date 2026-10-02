import AppKit
import Foundation

@MainActor
enum OPNCouchCoopLauncher {
    static let maximumInstanceNumber = 2
    static let persistenceArguments = ["-ApplePersistenceIgnoreState", "YES"]

    static func launchArguments(instanceNumber: Int) -> [String] {
        [OPNAppInstance.argumentName, String(instanceNumber)] + persistenceArguments
    }

    static func nextInstanceNumber(occupied: [Int]) -> Int? {
        ((OPNAppInstance.primaryNumber + 1)...maximumInstanceNumber).first { !occupied.contains($0) }
    }

    static func canStart(isFlagEnabled: Bool, occupied: [Int]) -> Bool {
        isFlagEnabled && nextInstanceNumber(occupied: occupied) != nil
    }

    static var occupiedInstanceNumbers: [Int] {
        Array(Set(OPNCouchCoopPresence.shared.roster.instanceNumbers + [OPNAppInstance.current.number]))
    }

    static func prepare() {
        guard OPNLabs.isCouchCoopEnabled else { return }
        OPNCouchCoopPresence.shared.start()
    }

    static func startSecondInstance() {
        guard OPNLabs.isCouchCoopEnabled, let number = nextInstanceNumber(occupied: occupiedInstanceNumbers) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        configuration.arguments = launchArguments(instanceNumber: number)
        OPNLog.info(.app, "Starting couch co-op instance \(number)")
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            guard let error else { return }
            OPNLog.error(.app, "Could not start couch co-op instance \(number): \(error.localizedDescription)")
        }
    }

    static func mainWindowTitle(isCouchCoopActive: Bool) -> String {
        OPNCouchCoopLabels.windowTitle(base: "OpenNOW", instance: OPNAppInstance.current, isCouchCoopActive: isCouchCoopActive)
    }
}

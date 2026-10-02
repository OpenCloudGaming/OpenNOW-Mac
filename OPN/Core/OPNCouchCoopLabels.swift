import Foundation

enum OPNCouchCoopLabels {
    static func isLabeled(instance: OPNAppInstance, isCouchCoopActive: Bool) -> Bool {
        !instance.isPrimary || isCouchCoopActive
    }

    static func playerName(instance: OPNAppInstance) -> String {
        "Player \(instance.number)"
    }

    static func windowTitle(base: String, instance: OPNAppInstance, isCouchCoopActive: Bool) -> String {
        guard isLabeled(instance: instance, isCouchCoopActive: isCouchCoopActive) else { return base }
        return "\(base) \u{00B7} \(playerName(instance: instance))"
    }

    static func dockMark(instance: OPNAppInstance, isCouchCoopActive: Bool) -> String? {
        guard isLabeled(instance: instance, isCouchCoopActive: isCouchCoopActive) else { return nil }
        return "P\(instance.number)"
    }
}

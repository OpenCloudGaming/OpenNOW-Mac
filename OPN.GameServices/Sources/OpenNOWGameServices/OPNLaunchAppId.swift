import Foundation

struct OPNResolvedLaunchAppId: Equatable, Sendable {
    let stringValue: String
    let intValue: Int
}

enum OPNLaunchAppId {
    static func resolve(_ value: String) -> OPNResolvedLaunchAppId? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let intValue = Int(trimmed), intValue > 0 else { return nil }
        return OPNResolvedLaunchAppId(stringValue: trimmed, intValue: intValue)
    }
}

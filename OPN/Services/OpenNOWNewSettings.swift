//  Which settings rows are new enough to wear the NEW tag. A row names the release it landed in;
//  the tag shows while the running app is at or before that release and the user has not yet
//  changed the setting, so it expires on the next release without anyone maintaining a list of
//  removals, and never nags after first use.
//

import Foundation

@MainActor
enum OpenNOWNewSettings {
    enum Row: String, CaseIterable {
        case surroundSound
        case sessionReadyAction

        /// The marketing version the row shipped in.
        nonisolated var introducedIn: String {
            switch self {
            case .surroundSound, .sessionReadyAction: "0.6.0"
            }
        }
    }

    static let acknowledgedKey = "OpenNOW.Interface.AcknowledgedNewSettings"

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    static func isNew(_ row: Row) -> Bool {
        isNew(introducedIn: row.introducedIn, currentVersion: currentVersion, acknowledged: acknowledgedRows.contains(row.rawValue))
    }

    /// Called when the user changes the setting; the tag has done its job.
    static func acknowledge(_ row: Row) {
        var rows = acknowledgedRows
        guard !rows.contains(row.rawValue) else { return }
        rows.insert(row.rawValue)
        OPNAppPreferenceStorage.standard.set(Array(rows).sorted(), forKey: acknowledgedKey)
    }

    nonisolated static func isNew(introducedIn: String, currentVersion: String, acknowledged: Bool) -> Bool {
        guard !acknowledged else { return false }
        return compareVersions(introducedIn, currentVersion) != .orderedAscending
    }

    /// Numeric dotted-version comparison; missing components count as zero, so `0.6` == `0.6.0`.
    nonisolated static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = versionComponents(lhs)
        let right = versionComponents(rhs)
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a < b ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    private nonisolated static func versionComponents(_ version: String) -> [Int] {
        version.split(separator: "-").first.map(String.init)?.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 } ?? []
    }

    private static var acknowledgedRows: Set<String> {
        Set(OPNAppPreferenceStorage.standard.array(forKey: acknowledgedKey) as? [String] ?? [])
    }
}

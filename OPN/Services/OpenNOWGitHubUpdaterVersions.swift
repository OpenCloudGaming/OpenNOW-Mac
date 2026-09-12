import Foundation

extension OpenNOWGitHubUpdater {
    nonisolated static func normalizedVersion(_ version: String) -> String {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.lowercased().hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
    }

    /// Semver precedence: equal cores are ranked by their prerelease suffix, and a version without
    /// one outranks the same core with one, so 0.8.0 supersedes the 0.8.0-beta.N it was cut from.
    nonisolated static func compareVersion(_ left: String, to right: String) -> Int {
        let leftFields = versionFields(left)
        let rightFields = versionFields(right)
        let coreResult = compareCoreFields(leftFields.core, to: rightFields.core)
        guard coreResult == 0 else { return coreResult }
        return comparePrereleaseFields(leftFields.prerelease, to: rightFields.prerelease)
    }

    private nonisolated static func versionFields(_ version: String) -> (core: [String], prerelease: [String]) {
        let normalized = normalizedVersion(version)
        guard let suffixStart = normalized.firstIndex(of: "-") else {
            return (normalized.components(separatedBy: "."), [])
        }
        let core = String(normalized[normalized.startIndex..<suffixStart])
        let prerelease = String(normalized[normalized.index(after: suffixStart)...])
        return (core.components(separatedBy: "."), prerelease.components(separatedBy: "."))
    }

    private nonisolated static func compareCoreFields(_ left: [String], to right: [String]) -> Int {
        // A shorter core is padded rather than ranked lower, so 0.8 and 0.8.0 are the same release.
        for index in 0..<max(left.count, right.count) {
            let leftPart = index < left.count ? left[index] : "0"
            let rightPart = index < right.count ? right[index] : "0"
            let result = compareIdentifier(leftPart, to: rightPart)
            if result != 0 { return result }
        }
        return 0
    }

    private nonisolated static func comparePrereleaseFields(_ left: [String], to right: [String]) -> Int {
        guard !left.isEmpty else { return right.isEmpty ? 0 : 1 }
        guard !right.isEmpty else { return -1 }

        for index in 0..<min(left.count, right.count) {
            let result = compareIdentifier(left[index], to: right[index])
            if result != 0 { return result }
        }
        if left.count < right.count { return -1 }
        return left.count > right.count ? 1 : 0
    }

    private nonisolated static func compareIdentifier(_ left: String, to right: String) -> Int {
        let leftNumber = Int(left)
        let rightNumber = Int(right)
        if let leftNumber, let rightNumber {
            if leftNumber < rightNumber { return -1 }
            return leftNumber > rightNumber ? 1 : 0
        }
        // Semver ranks a numeric identifier below an alphanumeric one.
        if leftNumber != nil { return -1 }
        if rightNumber != nil { return 1 }
        let result = left.compare(right)
        if result == .orderedAscending { return -1 }
        return result == .orderedDescending ? 1 : 0
    }
}

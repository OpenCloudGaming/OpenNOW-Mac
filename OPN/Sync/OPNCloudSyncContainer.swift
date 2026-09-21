import Foundation

/// Resolves OpenNOW's iCloud Drive container: the folder a signed-in user's backup lives in, shared
/// across every Mac they sign into. Resolution blocks, so callers await `resolve()`.
public enum OPNCloudSyncContainer {
    public static let identifier = "iCloud.io.github.opencloudgaming.opennow"
    /// The folder name the container draws in iCloud Drive, matching `NSUbiquitousContainerName`.
    public static let folderName = "OpenNOW"

    public enum Availability: Sendable, Equatable {
        case available(root: URL)
        case unavailable(reason: String)
    }

    /// Resolves the container off the main actor.
    public static func resolve() async -> Availability {
        await Task.detached(priority: .utility) { OPNCloudSyncContainer.resolveBlocking() }.value
    }

    /// The blocking lookup, exposed so callers can name why the container is missing. Never call
    /// this on the main actor: the iCloud daemon can stall the calling thread for seconds.
    public nonisolated static func resolveBlocking() -> Availability {
        guard let container = FileManager.default.url(forUbiquityContainerIdentifier: identifier) else {
            return .unavailable(reason: "Sign in to iCloud and turn on iCloud Drive to sync OpenNOW.")
        }
        let root = container
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
        return .available(root: root)
    }

    public static func prepare(_ root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
}

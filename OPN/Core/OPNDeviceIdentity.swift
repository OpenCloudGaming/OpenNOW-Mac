import Foundation

@objc(OPNDeviceIdentity)
public final class OPNDeviceIdentity: NSObject {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedCloudmatchDeviceId = ""

    @objc(stableCloudmatchDeviceId)
    public static func stableCloudmatchDeviceId() -> String {
        lock.lock()
        defer { lock.unlock() }

        if !cachedCloudmatchDeviceId.isEmpty {
            return cachedCloudmatchDeviceId
        }

        let supportDirectory = ("~/Library/Application Support/OpenNOW" as NSString).expandingTildeInPath
        let path = (supportDirectory as NSString).appendingPathComponent("device-id.plist")
        let legacyPath = ("~/Library/Application Support/com.nvidia.gfn-device-id" as NSString).expandingTildeInPath
        let existing = NSDictionary(contentsOfFile: path) ?? NSDictionary(contentsOfFile: legacyPath)
        let storedDeviceId = existing?["deviceId"] as? String
        let deviceId: String
        if let storedDeviceId, !storedDeviceId.isEmpty {
            deviceId = storedDeviceId
        } else {
            deviceId = UUID().uuidString.lowercased()
        }

        let directoryAttributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        try? FileManager.default.createDirectory(
            atPath: supportDirectory,
            withIntermediateDirectories: true,
            attributes: directoryAttributes
        )
        NSDictionary(dictionary: ["deviceId": deviceId]).write(toFile: path, atomically: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)

        cachedCloudmatchDeviceId = deviceId
        return deviceId
    }
}

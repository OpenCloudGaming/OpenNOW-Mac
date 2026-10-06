import CryptoKit
import Foundation

@objc(OPNDeviceIdentity)
public final class OPNDeviceIdentity: NSObject {
    static let lock = NSLock()
    nonisolated(unsafe) private static var cachedCloudmatchDeviceId = ""
    nonisolated(unsafe) private static var cachedAccountDeviceIds: [String: String] = [:]

    @objc(stableCloudmatchDeviceId)
    public static func stableCloudmatchDeviceId() -> String {
        lock.lock()
        defer { lock.unlock() }
        return machineDeviceIdLocked()
    }

    /// The device id one account streams under.
    ///
    /// The seat allows a single live session per device, and this client reports one device hash for
    /// the whole Mac, so a second account launching from here is refused with
    /// `SESSION_LIMIT_PER_DEVICE_EXCEEDED_STATUS`. This gives each account its own device, derived
    /// from the machine's so it is stable across launches: the same account always looks like the
    /// same device, and a session still resumes against the identity that created it.
    static func cloudmatchDeviceId(accountID: OPNAccountID) -> String {
        lock.lock()
        defer { lock.unlock() }
        let key = accountID.rawValue
        if let cached = cachedAccountDeviceIds[key] { return cached }
        let derived = uuidFormattedDigest(of: "\(machineDeviceIdLocked())|\(key)")
        cachedAccountDeviceIds[key] = derived
        return derived
    }

    private static func machineDeviceIdLocked() -> String {
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

    /// A UUID-shaped digest, because the seat expects this field to look like a device id.
    private static func uuidFormattedDigest(of value: String) -> String {
        let hex = SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        let characters = Array(hex.prefix(32))
        let groups = [characters[0..<8], characters[8..<12], characters[12..<16], characters[16..<20], characters[20..<32]]
        return groups.map { String($0) }.joined(separator: "-")
    }
}

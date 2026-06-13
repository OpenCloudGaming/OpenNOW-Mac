import Foundation

public struct OPNAppPreferenceStorage: @unchecked Sendable {
    public static let standard = OPNAppPreferenceStorage(defaults: .standard, defaultsDomain: "io.github.opencloudgaming.opennow")

    private let defaults: UserDefaults
    private let defaultsDomain: String

    public init(defaults: UserDefaults, defaultsDomain: String) {
        self.defaults = defaults
        self.defaultsDomain = defaultsDomain
    }

    public func string(forKey key: String) -> String? {
        defaults.string(forKey: key)
    }

    public func array(forKey key: String) -> [Any]? {
        defaults.array(forKey: key)
    }

    public func dictionary(forKey key: String) -> [String: Any]? {
        defaults.dictionary(forKey: key)
    }

    public func object(forKey key: String) -> Any? {
        defaults.object(forKey: key)
    }

    public func double(forKey key: String) -> Double {
        defaults.double(forKey: key)
    }

    public func set(_ value: Any, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    public func removeObject(forKey key: String) {
        defaults.removeObject(forKey: key)
    }

    public func synchronize() {
        defaults.synchronize()
    }

    public func storedValue(forKey key: String, preferCanonicalDomain: Bool) -> Any? {
        if preferCanonicalDomain, let canonical = defaults.persistentDomain(forName: defaultsDomain)?[key] {
            return canonical
        }
        if let value = defaults.object(forKey: key) {
            return value
        }
        if let value = defaults.persistentDomain(forName: defaultsDomain)?[key] {
            return value
        }
        return defaults.persistentDomain(forName: UserDefaults.globalDomain)?[key]
    }

    public func setCanonicalInt(_ value: Int, forKey key: String) {
        defaults.set(value, forKey: key)
        var domain = defaults.persistentDomain(forName: defaultsDomain) ?? [:]
        domain[key] = value
        defaults.setPersistentDomain(domain, forName: defaultsDomain)
    }
}

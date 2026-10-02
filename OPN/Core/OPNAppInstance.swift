import AppKit
import Darwin
import Foundation

enum OPNAppInstanceResolution: Equatable {
    case resolved(OPNAppInstance)
    case numberInUse(Int)
}

final class OPNAppInstanceLock: @unchecked Sendable {
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    static func acquire(number: Int, in directory: URL) -> OPNAppInstanceLock? {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appending(path: "\(number).lock", directoryHint: .notDirectory).path
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        return OPNAppInstanceLock(descriptor: descriptor)
    }
}

struct OPNAppInstance: Equatable, Sendable {
    static let argumentName = "--opn-instance"
    static let primaryNumber = 1

    let number: Int
    let bundleIdentifier: String

    init(number: Int, bundleIdentifier: String) {
        self.number = max(number, Self.primaryNumber)
        self.bundleIdentifier = bundleIdentifier
    }

    var isPrimary: Bool { number == Self.primaryNumber }

    var storageIdentifier: String {
        isPrimary ? bundleIdentifier : "\(bundleIdentifier).instance\(number)"
    }

    var keychainAccountPrefix: String {
        isPrimary ? "" : "instance\(number)."
    }

    var deviceIdentitySeedSuffix: String {
        isPrimary ? "" : ":instance\(number)"
    }

    var diagnosticsLogFileName: String {
        isPrimary ? "OpenNOW-diagnostics-current.log" : "OpenNOW-diagnostics-current-instance\(number).log"
    }

    var clipboardHistoryDirectoryName: String {
        isPrimary ? OPNProductIdentity.releaseBundleIdentifier : storageIdentifier
    }

    var defaults: UserDefaults {
        guard !isPrimary else { return .standard }
        return UserDefaults(suiteName: storageIdentifier) ?? .standard
    }

    func scopedPreferenceKey(_ key: String) -> String {
        isPrimary ? key : "\(key).instance\(number)"
    }

    func supportDirectory(under applicationSupport: URL) -> URL {
        let root = applicationSupport.appending(path: "OpenNOW", directoryHint: .isDirectory)
        guard !isPrimary else { return root }
        return root.appending(path: storageIdentifier, directoryHint: .isDirectory)
    }

    func authStoreURL(under applicationSupport: URL) -> URL? {
        guard !bundleIdentifier.isEmpty else { return nil }
        guard !isPrimary || bundleIdentifier != OPNProductIdentity.releaseBundleIdentifier else { return nil }
        return applicationSupport
            .appending(path: "OpenNOW", directoryHint: .isDirectory)
            .appending(path: storageIdentifier, directoryHint: .isDirectory)
            .appending(path: "auth.store", directoryHint: .notDirectory)
    }

    func imageCacheStoreURL(under applicationSupport: URL) -> URL {
        let directory = isPrimary ? applicationSupport : supportDirectory(under: applicationSupport)
        return directory.appending(path: "CatalogImageCache.store", directoryHint: .notDirectory)
    }

    func keychainAccountName(prefix tokenPrefix: String, identity: String) -> String {
        tokenPrefix + keychainAccountPrefix + identity
    }

    func ownsKeychainAccount(_ account: String, tokenPrefix: String) -> Bool {
        guard account.hasPrefix(tokenPrefix) else { return isPrimary }
        let remainder = account.dropFirst(tokenPrefix.count)
        guard !isPrimary else { return !Self.hasInstancePrefix(remainder) }
        return remainder.hasPrefix(keychainAccountPrefix)
    }

    private static func hasInstancePrefix(_ remainder: Substring) -> Bool {
        guard remainder.hasPrefix("instance") else { return false }
        let afterWord = remainder.dropFirst("instance".count)
        let digits = afterWord.prefix { $0.isNumber }
        guard !digits.isEmpty else { return false }
        return afterWord.dropFirst(digits.count).hasPrefix(".")
    }

    static func requestedNumber(arguments: [String]) -> Int? {
        for (index, argument) in arguments.enumerated() {
            if argument == argumentName {
                guard arguments.indices.contains(index + 1) else { return nil }
                return positiveNumber(arguments[index + 1])
            }
            if argument.hasPrefix(argumentName + "=") {
                return positiveNumber(String(argument.dropFirst(argumentName.count + 1)))
            }
        }
        return nil
    }

    private static func positiveNumber(_ text: String) -> Int? {
        guard let number = Int(text), number >= primaryNumber else { return nil }
        return number
    }

    static func resolve(
        arguments: [String],
        isCouchCoopEnabled: Bool,
        bundleIdentifier: String,
        lockDirectory: URL
    ) -> (resolution: OPNAppInstanceResolution, lock: OPNAppInstanceLock?) {
        let primary = OPNAppInstance(number: primaryNumber, bundleIdentifier: bundleIdentifier)
        guard isCouchCoopEnabled, let number = requestedNumber(arguments: arguments), number > primaryNumber else {
            return (.resolved(primary), nil)
        }
        guard let lock = OPNAppInstanceLock.acquire(number: number, in: lockDirectory) else {
            return (.numberInUse(number), nil)
        }
        return (.resolved(OPNAppInstance(number: number, bundleIdentifier: bundleIdentifier)), lock)
    }

    private static let launchState: (instance: OPNAppInstance, lock: OPNAppInstanceLock?) = {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? OPNProductIdentity.releaseBundleIdentifier
        let lockDirectory = URL.applicationSupportDirectory
            .appending(path: "OpenNOW", directoryHint: .isDirectory)
            .appending(path: "instances", directoryHint: .isDirectory)
        let outcome = resolve(
            arguments: ProcessInfo.processInfo.arguments,
            isCouchCoopEnabled: OPNLabs.isCouchCoopEnabled,
            bundleIdentifier: bundleIdentifier,
            lockDirectory: lockDirectory
        )
        switch outcome.resolution {
        case .resolved(let instance):
            return (instance, outcome.lock)
        case .numberInUse:
            activateRunningCopy(bundleIdentifier: bundleIdentifier)
            exit(EXIT_SUCCESS)
        }
    }()

    static var current: OPNAppInstance { launchState.instance }

    private static func activateRunningCopy(bundleIdentifier: String) {
        let ownProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .first { $0.processIdentifier != ownProcessIdentifier }?
            .activate()
    }
}

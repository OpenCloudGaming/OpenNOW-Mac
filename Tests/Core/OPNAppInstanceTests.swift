import Foundation
import Testing
@testable import OpenNOW

private let releaseBundle = OPNProductIdentity.releaseBundleIdentifier
private let applicationSupport = URL(fileURLWithPath: "/tmp/support", isDirectory: true)

private func temporaryLockDirectory() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "opn-instance-\(UUID().uuidString)", directoryHint: .isDirectory)
}

@Suite("OPNAppInstance")
struct OPNAppInstanceTests {
    @Test func parsesSeparateAndInlineArguments() {
        #expect(OPNAppInstance.requestedNumber(arguments: ["OpenNOW", "--opn-instance", "2"]) == 2)
        #expect(OPNAppInstance.requestedNumber(arguments: ["OpenNOW", "--opn-instance=3"]) == 3)
        #expect(OPNAppInstance.requestedNumber(arguments: ["OpenNOW"]) == nil)
        #expect(OPNAppInstance.requestedNumber(arguments: ["OpenNOW", "--opn-instance"]) == nil)
        #expect(OPNAppInstance.requestedNumber(arguments: ["OpenNOW", "--opn-instance", "zero"]) == nil)
        #expect(OPNAppInstance.requestedNumber(arguments: ["OpenNOW", "--opn-instance", "0"]) == nil)
    }

    @Test func flagOffAlwaysResolvesToThePrimary() {
        let outcome = OPNAppInstance.resolve(
            arguments: ["OpenNOW", "--opn-instance", "2"],
            isCouchCoopEnabled: false,
            bundleIdentifier: releaseBundle,
            lockDirectory: temporaryLockDirectory()
        )
        #expect(outcome.resolution == .resolved(OPNAppInstance(number: 1, bundleIdentifier: releaseBundle)))
        #expect(outcome.lock == nil)
    }

    @Test func secondInstanceHoldsItsNumberUntilReleased() {
        let directory = temporaryLockDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let arguments = ["OpenNOW", "--opn-instance", "2"]

        var first: (resolution: OPNAppInstanceResolution, lock: OPNAppInstanceLock?)? = OPNAppInstance.resolve(
            arguments: arguments, isCouchCoopEnabled: true, bundleIdentifier: releaseBundle, lockDirectory: directory
        )
        #expect(first?.resolution == .resolved(OPNAppInstance(number: 2, bundleIdentifier: releaseBundle)))
        #expect(first?.lock != nil)

        let contender = OPNAppInstance.resolve(
            arguments: arguments, isCouchCoopEnabled: true, bundleIdentifier: releaseBundle, lockDirectory: directory
        )
        #expect(contender.resolution == .numberInUse(2))

        first = nil
        let afterRelease = OPNAppInstance.resolve(
            arguments: arguments, isCouchCoopEnabled: true, bundleIdentifier: releaseBundle, lockDirectory: directory
        )
        #expect(afterRelease.resolution == .resolved(OPNAppInstance(number: 2, bundleIdentifier: releaseBundle)))
    }

    @Test func primaryKeepsTodaysIdentifiersAndSecondariesDeriveTheirs() {
        let primary = OPNAppInstance(number: 1, bundleIdentifier: releaseBundle)
        let secondary = OPNAppInstance(number: 2, bundleIdentifier: releaseBundle)
        #expect(primary.storageIdentifier == releaseBundle)
        #expect(secondary.storageIdentifier == "\(releaseBundle).instance2")
        #expect(primary.scopedPreferenceKey("OpenNOW.Stream.ActiveSessionId") == "OpenNOW.Stream.ActiveSessionId")
        #expect(secondary.scopedPreferenceKey("OpenNOW.Stream.ActiveSessionId") == "OpenNOW.Stream.ActiveSessionId.instance2")
        #expect(primary.diagnosticsLogFileName == "OpenNOW-diagnostics-current.log")
        #expect(secondary.diagnosticsLogFileName == "OpenNOW-diagnostics-current-instance2.log")
        #expect(primary.deviceIdentitySeedSuffix.isEmpty)
        #expect(secondary.deviceIdentitySeedSuffix == ":instance2")
    }

    @Test func authStoreLocationPerInstance() {
        let releasePrimary = OPNAppInstance(number: 1, bundleIdentifier: releaseBundle)
        let devPrimary = OPNAppInstance(number: 1, bundleIdentifier: "\(releaseBundle).dev")
        let secondary = OPNAppInstance(number: 2, bundleIdentifier: releaseBundle)
        #expect(releasePrimary.authStoreURL(under: applicationSupport) == nil)
        #expect(devPrimary.authStoreURL(under: applicationSupport)?.path == "/tmp/support/OpenNOW/\(releaseBundle).dev/auth.store")
        #expect(secondary.authStoreURL(under: applicationSupport)?.path == "/tmp/support/OpenNOW/\(releaseBundle).instance2/auth.store")
    }

    @Test func supportDirectoryAndImageCachePerInstance() {
        let primary = OPNAppInstance(number: 1, bundleIdentifier: releaseBundle)
        let secondary = OPNAppInstance(number: 2, bundleIdentifier: releaseBundle)
        #expect(primary.supportDirectory(under: applicationSupport).path == "/tmp/support/OpenNOW")
        #expect(secondary.supportDirectory(under: applicationSupport).path == "/tmp/support/OpenNOW/\(releaseBundle).instance2")
        #expect(primary.imageCacheStoreURL(under: applicationSupport).path == "/tmp/support/CatalogImageCache.store")
        #expect(secondary.imageCacheStoreURL(under: applicationSupport).path == "/tmp/support/OpenNOW/\(releaseBundle).instance2/CatalogImageCache.store")
    }

    @Test func keychainAccountsAreNamespacedAndScopedToTheirOwner() {
        let primary = OPNAppInstance(number: 1, bundleIdentifier: releaseBundle)
        let second = OPNAppInstance(number: 2, bundleIdentifier: releaseBundle)
        let third = OPNAppInstance(number: 3, bundleIdentifier: releaseBundle)
        #expect(primary.keychainAccountName(prefix: "tokens.", identity: "session.abc") == "tokens.session.abc")
        #expect(second.keychainAccountName(prefix: "tokens.", identity: "session.abc") == "tokens.instance2.session.abc")

        let accounts = ["tokens.session.abc", "tokens.profile-one", "tokens.instance2.session.abc", "tokens.instance3.profile"]
        #expect(accounts.filter { primary.ownsKeychainAccount($0, tokenPrefix: "tokens.") } == ["tokens.session.abc", "tokens.profile-one"])
        #expect(accounts.filter { second.ownsKeychainAccount($0, tokenPrefix: "tokens.") } == ["tokens.instance2.session.abc"])
        #expect(accounts.filter { third.ownsKeychainAccount($0, tokenPrefix: "tokens.") } == ["tokens.instance3.profile"])
    }

    @Test func accountsWithoutTheTokenPrefixBelongToThePrimary() {
        let primary = OPNAppInstance(number: 1, bundleIdentifier: releaseBundle)
        let second = OPNAppInstance(number: 2, bundleIdentifier: releaseBundle)
        #expect(primary.ownsKeychainAccount("legacy-account", tokenPrefix: "tokens."))
        #expect(!second.ownsKeychainAccount("legacy-account", tokenPrefix: "tokens."))
    }

    @Test func couchCoopFlagIsRegistered() {
        #expect(OPNLabs.flags.contains { $0.id == "couchCoop" })
    }
}
